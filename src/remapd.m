/*
 * remapd — one place that decides what a key means, given where you are.
 *
 * WHY THIS EXISTS (added 2026-09-08):
 *   The remapping was spread over three systems that could not see each other.
 *   Karabiner owned key-to-key and the hold-space layers; BetterTouchTool owned
 *   153 keyboard triggers, each scoped by a hand-typed NSPredicate string; and
 *   fusion_ui/hotkeys.py owned Fusion's own commands with a proper domain model.
 *   Only the third could answer "what does F mean right now, and is this key free
 *   here?" — so only the third could be edited without fear.
 *
 *   The BTT half had drifted exactly the way an un-modelled ruleset drifts:
 *     * eighteen rules existed only to re-emit the plain letter when the
 *       condition was false, because a BTT keyboard trigger swallows the key;
 *     * four byte-identical copies of the same f/one-finger/Fusion rule;
 *     * s, d and f each carried BOTH a fingers==1 rule and an overlapping
 *       fingers>=1&&<=3 rule, with no way to see which won;
 *     * and two-finger D sent Ctrl+Opt+A — the same chord as two-finger A — so
 *       one of the four keys in the stack had silently never worked.
 *   None of those are BTT being bad at its job. They are what you get when the
 *   scope of a rule is a string and nothing can reason about it.
 *
 *   This daemon takes the BTT half, and only that half. See remap/README.md for
 *   what deliberately stays with Karabiner (everything below the event-tap layer)
 *   and with BTT (gestures, haptics, the named triggers the slots engine calls).
 *
 * THE MODEL (the whole point — it is fusion_ui/hotkeys.py's, on purpose):
 *   Every binding declares a DOMAIN as axis:value pairs. At press time the axes
 *   are sampled and the claimants for that key are walked most-specific-first;
 *   the first whose domain matches wins. Exclusivity between two bindings is
 *   DERIVED from disjoint values on a shared axis, never declared — which is what
 *   lets remapctl.py answer "is this key free in this scope" and explain why.
 *   Axis vocabulary: remap/contexts.json. Bindings: remap/bindings.json.
 *
 * PASSTHROUGH IS THE DEFAULT AND IT IS LOAD-BEARING.
 *   A key no binding claims is returned untouched. That is the difference that
 *   deletes the eighteen identity rules, and it is also the failure mode: a
 *   daemon that dies, a config that will not parse, a tap that never opens, and
 *   the keyboard is an ordinary keyboard. Nothing here may ever fail closed.
 *   Kill switch, for the same reason: `touch /tmp/remapd_off`.
 *
 * WHY THE EVENT IS REWRITTEN IN PLACE, not swallowed-and-reposted:
 *   BTT's "send shortcut" posts a fresh chord — synthetic modifier downs, key,
 *   modifier ups — which loses autorepeat, races the real key-up, and needs a
 *   re-entry guard so the tap does not eat its own output. Setting the keycode
 *   and flags on the event already in flight has none of those problems: it is
 *   still the hardware's event, with the hardware's down/up pairing.
 *
 * WHY THE TRANSFORM IS LATCHED PER KEYCODE:
 *   The context can change between a key going down and coming up — that is the
 *   entire nature of a trackpad-finger modifier, since the finger lifts. If the
 *   key-up were resolved independently it would emit a DIFFERENT chord than the
 *   key-down, and the app would see a modifier stuck down forever. So the down
 *   decides, the latch remembers, and the up replays it. Autorepeat replays it
 *   too, so a held chord cannot change under the hand.
 *
 * THREADING:
 *   main thread   — the event tap and NOTHING else. No AX call, no file I/O, no
 *                   spawn; a blocking call here is what trips
 *                   kCGEventTapDisabledByTimeout and takes the keyboard with it.
 *   worker thread — samples the frontmost app and the focused element's AX role
 *                   every POLL_MS, and reloads bindings.json when its mtime
 *                   moves. Publishes into globals under gLock.
 *   MT thread     — MultitouchSupport's own contact-frame callback; publishes an
 *                   atomic finger count and touches nothing else.
 *
 * WHY POLLING FOR THE AX ROLE (the same finding as textfield_watch.m):
 *   kAXFocusedUIElementChangedNotification is not emitted reliably by every app —
 *   WKWebView hosts in particular — and an observer must be torn down and
 *   re-registered on every app switch. One read every POLL_MS is cheap, uniform,
 *   and cannot go stale in a way that fails closed.
 *
 * THE HOLD AXIS — a held KEY, seen from above Karabiner (added 2026-09-16):
 *   Holding space while still being able to TYPE a space needs tap-vs-hold
 *   arbitration, and only Karabiner's virtual keyboard is below the event tap
 *   where that can happen. So Karabiner keeps exactly that one decision, and
 *   reports it up: space held is F20 DOWN (autorepeating; ignored), a tap is a
 *   space. F20 never reaches an app (browsers excepted) — this tap swallows it. Everything a
 *   held space MEANS is then an ordinary binding here, resolved by the one
 *   resolver with the one rule, per binding, with its own scope. The Karabiner
 *   layers this replaces were first-match-wins with a variable per layer and the
 *   scope on the hold key, and every overlap between two of them was a bug.
 *
 *   (Space + semicolon was a second value on this axis until 2026-09-29; gone.)
 *
 *   J held, J + K held, J + K + L held, D held and F held are the other values — the LETTER HOLD, which
 *   is ours with no Karabiner report at all: a letter's chord-or-typing
 *   question is answered by release order, which Karabiner cannot express.
 *   See THE LETTER HOLD below.
 *
 * WHY NOT ONE SYSTEM WITH fusion_ui/hotkeys.py: that router runs inside Fusion's
 *   Python process and routes Fusion COMMANDS through Fusion's own keymap. This
 *   is a system-wide event tap that routes KEYSTROKES. They cannot be one
 *   process. They share the model, the axis vocabulary and the checker instead.
 *
 * Build:  bin/build.sh remapd        (must be signed — AX + a stable TCC identity)
 * Run:    launchd job com.josh.remapd
 *         ./remapd -v   log every binding that fires
 *         ./remapd -d   also print the sampled domain whenever it changes — the
 *                       first thing to reach for when a binding will not fire.
 *         touch /tmp/remapd_trace   log EVERY key-down with the domain it resolved
 *                       (the hold included)
 *                       against and that sample's age, including the ones that
 *                       matched nothing. Needs no restart and no flag, because the
 *                       keystroke worth tracing is always one you have already
 *                       pressed. `rm` the file to stop.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/mman.h>   // reanchorPin
#include <fcntl.h>
#include <notify.h>

static NSString *gDir = @"/Users/josh/Code/Scripts/remap";
static NSString *kBindings = @"/Users/josh/Code/Scripts/remap/bindings.json";
static NSString *kSituations = @"/Users/josh/Code/Scripts/remap/situations.json";

// The newest schema this binary understands. A file declaring anything higher is
// REFUSED WHOLE — see the note on it in loadConfig. Bump only together with the
// code that reads the new shape.
#define SCHEMA_MAX 2
static NSString *const kOffFile  = @"/tmp/remapd_off";
// The live domain, republished whenever it changes. The settings window reads it
// so that "where am I right now" is something you look at rather than deduce —
// which is the whole reason a binding gets a domain instead of a predicate string.
static NSString *const kContext  = @"/tmp/remapd_context";
// Same shape as the kill switch, and for the same reason: the question "why did
// THAT keystroke not fire" can only be answered at the moment it is pressed, and
// that moment is never the moment you are attached to a debugger. `touch
// /tmp/remapd_trace` and every key-down logs the domain it resolved against and
// how old that sample was; delete the file to stop.
static NSString *const kTraceFile = @"/tmp/remapd_trace";
// Written by fusion_ui/hotkeys.py at every commandStarting/commandTerminated — the
// command axis. 'unknown' when the file has never existed, 'stale' when nothing has
// touched it in COMMAND_STALE_S seconds (the add-in died, reloaded, or Fusion quit):
// a reserved-chord rewrite must stand down on either, not guess 'none'. See
// sampleCommand() and fusion_ui/reserved.json.
static NSString *const kCommandFile = @"/tmp/fusion_command";
// The sketch axis: 'in' / 'out', published beside the command stamp by the same
// hotkeys.py call (_publish_sketch) and under the same staleness rule — missing or
// stale reads 'unknown', so a sketch-scoped binding stands down rather than guess.
static NSString *const kSketchFile = @"/tmp/fusion_sketch";
// The mode axis: an app's own mode, as a situation names it (`mode`: Photoshop's
// none / mattes / transform — Control Room's Photoshop situations). Written and kept
// fresh by ../bin/psmatte; missing or stale reads 'none', so a mode-scoped binding
// stands down and the app's ordinary keys come back if the writer dies.
static NSString *const kModeFile = @"/tmp/photoshop_mode";
#define COMMAND_STALE_S 3.0
#define POLL_MS 50

static BOOL gVerbose = NO;
static BOOL gDump    = NO;   // -d: print the sampled context whenever it changes

static void vlog(NSString *fmt, ...) {
    if (!gVerbose) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "%s\n", s.UTF8String);
    fflush(stderr);
}

/* ── Key names ────────────────────────────────────────────────────────────────
   Enough of the ANSI layout to write any binding by the character printed on the
   key. Anything missing is a compile-time-visible error in remapctl, not a
   silently ignored binding — see compileChord(). */
static NSDictionary<NSString *, NSNumber *> *keyTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{@"a":@0,  @"s":@1,  @"d":@2,  @"f":@3,  @"h":@4,  @"g":@5,
              @"z":@6,  @"x":@7,  @"c":@8,  @"v":@9,  @"b":@11, @"q":@12,
              @"w":@13, @"e":@14, @"r":@15, @"y":@16, @"t":@17,
              @"1":@18, @"2":@19, @"3":@20, @"4":@21, @"6":@22, @"5":@23,
              @"=":@24, @"9":@25, @"7":@26, @"-":@27, @"8":@28, @"0":@29,
              @"]":@30, @"o":@31, @"u":@32, @"[":@33, @"i":@34, @"p":@35,
              @"l":@37, @"j":@38, @"'":@39, @"k":@40, @";":@41, @"\\":@42,
              @",":@43, @"/":@44, @"n":@45, @"m":@46, @".":@47, @"`":@50,
              @"return":@36, @"tab":@48, @"space":@49, @"delete":@51,
              @"escape":@53, @"esc":@53,
              @"left":@123, @"right":@124, @"down":@125, @"up":@126,
              // F19 and F20 are not here: they are Karabiner's reports
              // (KC_LITERAL, KC_F20) and never reach the resolver.
              @"f1":@122, @"f2":@120, @"f3":@99,  @"f4":@118, @"f5":@96,
              @"f6":@97,  @"f7":@98,  @"f8":@100, @"f9":@101, @"f10":@109,
              @"f11":@103, @"f12":@111, @"f13":@105, @"f14":@107, @"f15":@113,
              @"f16":@106, @"f17":@64,  @"f18":@79};
    });
    return t;
}

/* A trackpad gesture's OWN key, "pad.<hand>.<gesture>" (pad.left.right2): what the
   gesture does while its hand navigates (§ The trackpad keyboard). No physical key, so
   a virtual keycode from PAD_KC0 up, assigned on first sight; only auxEmit asks for one,
   and it is never an output. */
#define PAD_KC0 1000
static BOOL padKeyCode(id spec, int *outKey) {
    if (![spec isKindOfClass:NSString.class] || ![[spec lowercaseString] hasPrefix:@"pad."]) return NO;
    static NSMutableDictionary<NSString *, NSNumber *> *codes;
    @synchronized ([NSObject class]) {
        if (!codes) codes = [NSMutableDictionary new];
        NSString *k = [spec lowercaseString];
        NSNumber *n = codes[k];
        if (!n) codes[k] = n = @(PAD_KC0 + (int)codes.count);
        *outKey = n.intValue;
    }
    return YES;
}

static BOOL isFunctionKey(int kc) {
    switch (kc) {
        case 122: case 120: case 99:  case 118: case 96:  case 97:
        case 98:  case 100: case 101: case 109: case 103: case 111:
        case 105: case 107: case 113: case 106: case 64:  case 79:
            return YES;
    }
    return NO;
}

#define MODMASK (kCGEventFlagMaskCommand | kCGEventFlagMaskShift | \
                 kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | \
                 kCGEventFlagMaskSecondaryFn)

static CGEventFlags modNamed(NSString *m) {
    m = m.lowercaseString;
    if ([m isEqual:@"cmd"] || [m isEqual:@"command"]) return kCGEventFlagMaskCommand;
    if ([m isEqual:@"shift"])                          return kCGEventFlagMaskShift;
    if ([m isEqual:@"ctrl"] || [m isEqual:@"control"]) return kCGEventFlagMaskControl;
    if ([m isEqual:@"alt"]  || [m isEqual:@"opt"] || [m isEqual:@"option"])
                                                       return kCGEventFlagMaskAlternate;
    if ([m isEqual:@"fn"])                             return kCGEventFlagMaskSecondaryFn;
    return 0;
}

/* "ctrl+shift+f" -> keycode 3, flags ctrl|shift. Returns NO on any unknown part,
   and the caller drops the whole binding: a chord we cannot spell is a binding
   that would silently never fire, which is the bug class this file exists to
   remove. */
static BOOL compileChord(NSString *spec, int *outKey, CGEventFlags *outFlags) {
    NSArray *parts = [spec.lowercaseString componentsSeparatedByString:@"+"];
    CGEventFlags f = 0;
    NSString *keyName = nil;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *p = parts[i];
        // A trailing empty part is the literal "+" key written as "shift++".
        if (p.length == 0) { p = @"="; f |= kCGEventFlagMaskShift; }
        CGEventFlags m = modNamed(p);
        if (m && i + 1 < parts.count) { f |= m; continue; }
        keyName = p;
    }
    NSNumber *kc = keyTable()[keyName ?: @""];
    if (!kc) return NO;
    *outKey = kc.intValue;
    *outFlags = f;
    return YES;
}

/* A key this table cannot spell and Karabiner's can — a modifier as a key, caps
   lock, fn, forward delete, or any chord holding fn. Mirrors KARABINER_KEYS in
   remapctl.py. A binding on one is Karabiner's and is skipped without a word:
   the checker tells "a key nothing can spell" from "a key the other engine
   spells"; this daemon only needs to stay out of the way. */
static BOOL isKarabinerOnlyKey(NSString *spec) {
    if (![spec isKindOfClass:NSString.class]) return NO;
    static NSSet *only;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        only = [NSSet setWithArray:@[@"left_shift", @"right_shift", @"left_command",
            @"right_command", @"left_control", @"right_control", @"left_option",
            @"right_option", @"caps_lock", @"fn", @"spacebar", @"delete_forward",
            @"shift", @"alt", @"opt", @"option", @"cmd", @"command", @"ctrl", @"control"]];
    });
    NSArray *parts = [spec.lowercaseString componentsSeparatedByString:@"+"];
    for (NSUInteger i = 0; i + 1 < parts.count; i++)
        if ([parts[i] isEqualToString:@"fn"]) return YES;
    return [only containsObject:parts.lastObject ?: @""];
}

/* ── The compiled binding ─────────────────────────────────────────────────── */

@interface RRule : NSObject
@property (nonatomic) int           fromKey;
@property (nonatomic) CGEventFlags  fromFlags;
@property (nonatomic, copy) NSArray<NSString *> *apps;  // nil/empty = unconstrained
@property (nonatomic, copy) NSArray<NSString *> *notApps; // apps that must NOT be front
@property (nonatomic, copy) NSString *element;  // nil = unconstrained
@property (nonatomic, copy) NSString *notElement; // an element that must NOT be focused
@property (nonatomic, copy) NSString *command;  // nil = unconstrained
@property (nonatomic, copy) NSString *sketch;   // nil = unconstrained, else in|out
@property (nonatomic, copy) NSString *mode;     // nil = unconstrained, else kModeFile's value
@property (nonatomic) BOOL          emptyLine;  // situation "line": "empty" — the caret's line has nothing typed (live AX read)
@property (nonatomic) int           fMin, fMax; // -1 = unconstrained
@property (nonatomic) int           hold;       // -1 = unconstrained, else a HOLD_ value
@property (nonatomic) BOOL          shiftThrough; // Shift may be down and rides through
@property (nonatomic) CGEventFlags  emitFlags;  // the hold's own modifier: may or may not be on
// Does this rule name what is HELD — a finger count, or a held key? A hold is a
// MODIFIER, not a scope: while one is down, the rule that names it beats any rule
// that says nothing about it, however narrowly that one is scoped otherwise. See
// the sort at the end of loadConfig for what this cost before it existed.
@property (nonatomic) BOOL          held;
@property (nonatomic) int           spec, prio, order;
@property (nonatomic) BOOL          block;      // a gesture's `to: none`: swallowed, nothing fires
@property (nonatomic) int           toKey;      // -1 = keycode unchanged
@property (nonatomic) CGEventFlags  toFlags;
@property (nonatomic) int           repeat;     // 1 = normal, >1 = a burst of that many taps
// `then`: a second chord tapped right after `to` (a word jump: ⌥← then ←). Posted
// like a burst — the key swallowed, both tapped on each down and each autorepeat.
// A separate field, so every other reader of `to` still reads one chord.
@property (nonatomic) BOOL          hasThen;
@property (nonatomic) int           thenKey;
@property (nonatomic) CGEventFlags  thenFlags;
// `lines: "stop"`: a word jump stops at a line break instead of running through it
// (lineStopBurst). Posted like a burst, so it can choose what to post per press.
@property (nonatomic) BOOL          lineStop;
// `repeating` (bindings.json's top-level list of command ids, matched on `_for` /
// `_also`): a step command — Photoshop's opacity / slider up-down. Each press AND each
// autorepeat is a fresh tap, posted like a burst: Photoshop runs a script's key once
// and ignores its autorepeats, so held never kept stepping (2026-10-13).
@property (nonatomic) BOOL          tapRepeat;
// `double: <ms>` (true = DOUBLE_MS_DEFAULT): the key fires only as the second of two
// presses that close together; a lone press is swallowed. Claude's ⎋ (stop) — one
// stray press used to kill the response (2026-10-15).
@property (nonatomic) int           doubleMs;   // 0 = a single press fires
@property (nonatomic, copy) NSString *run;      // non-nil = shell action, key swallowed
@property (nonatomic, copy) NSString *chain;    // non-nil = a sequence (THE SEQUENCES), key swallowed
@property (nonatomic, copy) NSString *ident;
// `move_held: true` (a gesture binding, 2026-10-18): while the fingers that are its
// MODIFIER rest on the left pad (pad.right_one … right_five), the pointer still moves —
// the left pad's touch freeze stands aside (auxMoverUpdate). padLayer: "right_three".
@property (nonatomic) BOOL          moveHeld;
@property (nonatomic, copy) NSString *padLayer;
@end
@implementation RRule @end

/* ── Shared state ─────────────────────────────────────────────────────────────
   Everything below gLock is written by the worker and read by the tap. The
   finger count is the exception: it comes from MultitouchSupport's own thread and
   is a plain atomic, because a lock in that callback would be a lock in the
   trackpad's hot path. */
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSArray<RRule *> *gRules = nil;          // compiled, sorted most-specific-first
static NSArray<RRule *> *gMoverRules = nil;     // the move_held ones (auxMoverWanted, per aux frame)
static NSDictionary     *gApps  = nil;          // short name -> {bundle:[], name:[]}
// Compiled once at load, not per keystroke: foldApp runs on the tap thread and a
// regex compile there would be paid on every key you press.
static NSDictionary<NSString *, NSRegularExpression *> *gAppPatterns = nil;
static NSString         *gFrontBundle = @"";
static NSString         *gFrontName   = @"";
static NSString         *gFrontApp    = nil;     // foldApp of the above, per sample (auxValue)
static NSString         *gElement     = @"none";
static NSString         *gCommand     = @"unknown";  // see sampleCommand()
static NSString         *gSketch      = @"unknown";  // see sampleSketch()
static NSString         *gMode        = @"none";     // see sampleMode()

static _Atomic int  gFingers = 0;   // the `fingers` axis: the aux pad's count while it has any, else the main pad's
// Per pad (bin/auxpad.h). With no aux pad configured every pad is "main" and
// gFingers == gMainFingers, which is how it always was.
static _Atomic int  gMainFingers = 0, gAuxFingers = 0;
static _Atomic bool gLastTouchAux = false;   // which pad the newest touch landed on
static _Atomic uint64_t gAuxLiftNs = 0;
static _Atomic uint64_t gMainHandNs = 0;      // last frame of a whole hand on the main pad (touchCallback)
static _Atomic bool     gMainPinch = false;   // the main pad's touch LANDED as a pinch (touchCallback)
static _Atomic uint64_t gMainPinchNs = 0;     // its last frame
// Measured 2026-10-18 (remapd.log 'main land2'): pinches 34–63 mm at 41–52°,
// two-finger scrolls 16–27 mm at 1–39° (one 16 mm at 50°). Later landings (same log)
// put side-by-side scrolls out to 29–44 mm at under 40°: judged pinches, their scroll
// was dropped in every app — "scrolling feels off in Chrome". So a shallow landing is
// a pinch only when very wide; steep ones (thumb under finger, 50°+) stay pinches.
#define PINCH_LAND_MM          45.0f   // two contacts landing this far apart = a pinch, any angle
#define PINCH_LAND_MM_UPRIGHT  26.0f   // ... or this far, one well above the other:
#define PINCH_LAND_DEG         45.0f   // ... at least this steep from side by side
static bool gAuxWanted = false;               // aux_trackpad set at launch → the tap watches the pointer
// The held key, written and read on the tap thread only (F20 and quote are key
// events). Atomic so the worker's context line can read it without the lock.
// J, J+K and J+K+L are the LETTER HOLD — remapd's own, no Karabiner report (see there).
// D and F are the same single-letter hold as J (2026-10-14); D + Space and
// F + Space are them with the space held on top (the lead down first).
enum { HOLD_NONE = 0, HOLD_SPACE = 1, HOLD_J = 2, HOLD_JK = 3, HOLD_JKL = 4,
       HOLD_D = 5, HOLD_F = 6, HOLD_DS = 7, HOLD_FS = 8, HOLD_MAX = 8 };
static _Atomic int  gHold = HOLD_NONE;
static const char *holdName(int h) {
    switch (h) {
        case HOLD_SPACE:      return "space";
        case HOLD_J:          return "j";
        case HOLD_JK:         return "j+k";
        case HOLD_JKL:        return "j+k+l";
        case HOLD_D:          return "d";
        case HOLD_F:          return "f";
        case HOLD_DS:         return "d+space";
        case HOLD_FS:         return "f+space";
        default:              return "none";
    }
}
// The key Karabiner hands up: F20 is what a held space becomes.
#define KC_F20    90
// F19: "the next key down is Karabiner's OUTPUT, not a key the hand pressed" —
// karabiner_layers.py LITERAL. A remap remaps the physical key, so what another
// remap produced is never resolved again. Swallowed; the flag lasts one key and
// LITERAL_NS, so a marker whose key never came cannot eat a later real press.
#define KC_LITERAL 80
#define LITERAL_NS 100000000ull
static uint64_t gLiteralNs = 0;   // tap thread only
// Events this daemon posts itself carry this so the tap lets them pass untouched.
#define OUR_MARK 0x72656d61   // 'rema'
#define NAV_ZOOM_MARK 0x7a6f6f6d   // 'zoom': reanchor's pinch-zoom scrolls — keep in sync: reanchor.m, FusionScrollFilter.c
#define PS_ZOOM_MARK  0x70737a6d   // 'pszm': the same over Photoshop (pscursor zooms them) — keep in sync: reanchor.m, pscursor.m
#define PS_PAN_MARK   0x70616e     // reanchor's 2-finger touch pan over Photoshop (finished, like the zooms) — same
#define NAV_MMB_MARK  0x6d6d6220   // 'mmb ': reanchor's nav middle button (postMMB) — keep in sync: reanchor.m
// A key the letter hold held back and now sends as it was pressed: it IS resolved
// (a replayed x still means whatever x means), but against the hold the hand had
// at the time — REPLAY_BASE + that HOLD_ value — not whatever gHold is by the time
// the posted copy comes round, and the letter hold itself never sees it again.
#define REPLAY_BASE 0x72706c00   // 'rpl\0'
static _Atomic bool gOff     = false;
static _Atomic bool gTrace   = false;
// When the app/element pair above was last sampled, on the monotonic clock. Read
// by the tap only to say how stale it was — a trace line that reports the domain
// without its age cannot distinguish "the rule is wrong" from "the sample had not
// caught up yet", and those two have opposite fixes.
static _Atomic uint64_t gSampleNs = 0;
// When the last contact frame arrived. The finger count is live rather than
// polled, so it can never be "stale" the way the app/element pair can — but it
// CAN be dead, and a dead stream is indistinguishable from an open hand: both
// read zero. This is what tells the two apart in a trace.
static _Atomic uint64_t gFingersNs = 0;

// The click guard. Three-Finger Drag is on, so three fingers resting on the pad
// ARE a left button to macOS: the drag's mouseDown, or the click it posts when
// they lift, lands at the pointer — in Notes that moves the caret to wherever the
// mouse happens to be, on top of the binding the fingers were held for. A key
// that fires a 3+-finger binding arms this for the rest of that touch; the tap
// swallows left-button events until the fingers lift (plus a grace, since the
// tap-click arrives after the lift). A new touch disarms it, so a later genuine
// three-finger drag is untouched. Tap thread only, except `armed` and the lift
// time, which the multitouch thread writes.
//
// The HELD down. Resting three fingers for ~0.5s makes Three-Finger Drag press
// the button with no movement at all, and it stays pressed until they lift. A
// key pressed after that fired its binding on time, but Notes sat in its
// mouse-tracking loop and applied the keys only on the lift ("works if I'm
// quick"). So a down that arrives under 3+ fingers is held back, not delivered:
// the pointer moving past HELD_DRAG_PX means a real drag (post the down, then
// the drags follow), an up with no binding means a tap-click (post the down,
// then the up), and a 3+-finger binding firing drops it and eats the rest.
static _Atomic bool     gClickGuard = false;
static _Atomic uint64_t gLiftNs     = 0;
static bool             gEatingDrag = false;   // a swallowed down owns its drags/up
static CGEventRef      gHeldDown   = NULL;    // tap thread only
static CGPoint          gHeldAt;
#define CLICK_GUARD_GRACE_NS (400ull * 1000000ull)
#define HELD_DRAG_PX 6.0
#define HELD_SHORT_MS 150
static uint64_t         gHeldGen    = 0;       // tap thread only
static uint64_t         gHeldNs     = 0;       // tap thread only: when gHeldDown came
static bool             gHeldMulti  = false;   // tap thread only: held for 2+ fingers (not Photoshop's)
static NSMutableArray  *gTapWait    = nil;     // tap thread only: clicks waiting on a tap's gesture
static _Atomic uint64_t gPadFireNs  = 0;       // a gesture's own binding last fired (auxPadFire)
static CGEventRef       gRightHeld  = NULL;    // tap thread only: a 2-finger tap's right-click, held
static uint64_t         gRightNs    = 0;       // tap thread only: when gRightHeld came
static uint64_t         gRightGen   = 0;       // tap thread only
// A tap-click under 2+ fingers (down + up together) is the pad's own click for a tap
// the gesture code classifies only ~100 ms later (2026-10-17: a bound 3-finger tap
// also selected what was under the pointer). Both are held TAP_CLICK_WAIT_MS: a
// bound gesture firing meanwhile drops them, else they go out as they were.
#define TAP_CLICK_GAP_NS (40ull * 1000000ull)
#define TAP_CLICK_WAIT_MS 250
#define DOUBLE_MS_DEFAULT 400                  // a `double` rule's window, `double: true`
static uint64_t         gDoubleNs[128];        // tap thread only: when a `double` key armed (0 = not)

static inline uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// A short-held down (Photoshop, 1–2 fingers) still unresolved after HELD_SHORT_MS
// goes out as it was — a press-and-hold that isn't a chord. The tap runs on the main
// run loop, so the main queue is the tap thread: no lock on gHeldDown.
static void heldDownLate(uint64_t gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, HELD_SHORT_MS * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (gen != gHeldGen || !gHeldDown) return;
        CGEventSetIntegerValueField(gHeldDown, kCGEventSourceUserData, OUR_MARK);
        CGEventPost(kCGSessionEventTap, gHeldDown);
        CFRelease(gHeldDown); gHeldDown = NULL;
    });
}

/* ── Config ──────────────────────────────────────────────────────────────────
   A parse failure keeps the previous table. That is the same contract as
   config/load_settings.sh, and for the same reason: a half-saved edit must not
   be able to take the keyboard down. */
// JSON null arrives as NSNull, which answers no string selector. Left in place it
// is not a quiet wrong answer, it is a CRASH on the first keypress that reaches
// the comparison — and a crash in the tap takes the keyboard's remapping with it.
static id nilIfNull(id v) { return (v == [NSNull null]) ? nil : v; }

static NSDictionary *readJSON(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

static void loadConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:kBindings];
    if (!d) { vlog(@"config: unreadable, keeping previous table"); return; }
    NSError *err = nil;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (![j isKindOfClass:NSDictionary.class]) {
        fprintf(stderr, "remapd: bindings.json will not parse (%s) — keeping previous table\n",
                err.localizedDescription.UTF8String ?: "?");
        fflush(stderr);
        return;
    }

    // THE GUARD THAT SHOULD HAVE BEEN HERE FROM THE START (added 2026-09-08 after
    // it bit): a schema this binary does not know is refused WHOLE, exactly like a
    // file that will not parse. Without it, a bindings.json written for a newer
    // reader was not rejected — it was read with every field this binary did not
    // recognise simply absent, which for a scope means "no constraints", which
    // means EVERY BINDING MATCHED EVERYWHERE. Editing the file to a new shape while
    // this daemon was live turned q into p, m into 1, system-wide, instantly.
    // "Unrecognised" must never fall through to "global".
    NSInteger schema = j[@"schema"] ? [j[@"schema"] integerValue] : 1;
    if (schema < 1 || schema > SCHEMA_MAX) {
        fprintf(stderr, "remapd: bindings.json declares schema %ld and this build "
                        "understands up to %d — REFUSED, keeping previous table\n",
                (long)schema, SCHEMA_MAX);
        fflush(stderr);
        return;
    }

    // Schema 2 names a situation per binding instead of spelling the scope inline.
    // The situations live in their own file because both engines read them: the
    // hold-a-KEY ones compile to Karabiner and never appear in this table at all.
    NSDictionary *sits = nil;
    if (schema >= 2) {
        NSDictionary *sj = readJSON(kSituations);
        NSArray *list = sj[@"situations"];
        if (![list isKindOfClass:NSArray.class]) {
            fprintf(stderr, "remapd: schema 2 needs situations.json and it did not "
                            "read — REFUSED, keeping previous table\n");
            fflush(stderr);
            return;
        }
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSDictionary *s in list)
            if ([s isKindOfClass:NSDictionary.class] && s[@"id"]) m[s[@"id"]] = s;
        sits = m;
    }

    NSMutableArray<RRule *> *rules = [NSMutableArray array];
    NSArray *raw = j[@"bindings"];
    NSSet *repeating = [j[@"repeating"] isKindOfClass:NSArray.class]
                     ? [NSSet setWithArray:j[@"repeating"]] : [NSSet set];
    int order = 0;
    for (NSDictionary *b in (raw ?: @[])) {
        if (![b isKindOfClass:NSDictionary.class]) continue;
        NSString *ident = b[@"id"] ?: @"?";
        BOOL tapRepeat = [repeating containsObject:nilIfNull(b[@"_for"]) ?: @""];
        if ([b[@"_also"] isKindOfClass:NSArray.class])
            for (id a in b[@"_also"]) tapRepeat |= [repeating containsObject:a];
        // A disabled binding is DROPPED from the table, not kept and skipped at press
        // time: the resolver's cost belongs to bindings that can actually fire, and a
        // row that is off should be invisible to "what claims this key". It stays in
        // the file, so the settings window can still show and re-enable it.
        if (b[@"enabled"] != nil && ![b[@"enabled"] boolValue]) continue;

        // The situation is resolved FIRST. A binding held by a key belongs to
        // Karabiner, and this daemon must not complain about its spelling — those
        // keys are written in Karabiner's vocabulary and are none of our business.
        //
        // A GATED situation is Karabiner's for the same reason and must be skipped
        // just as hard: a gate is a Karabiner variable (space_held, cad_hover), and
        // this daemon cannot see one. Loading such a binding would not fail — it
        // would run the mapping with the gate simply ignored, which is the whole
        // condition missing. F in Fusion is the case that proves it: it maps to
        // Shift+Option+F only while space is held, and unconditionally would break
        // the key outright.
        //
        // Karabiner's for OTHER reasons, all derived (remapctl.karabiners is the
        // one home of this rule; this mirrors it): a hold/tap binding needs
        // tap-vs-hold arbitration below the tap; `to: none` is a block, which must
        // happen below the quote-becomes-delete swap; and a key this daemon's
        // table cannot spell but Karabiner's can (caps lock, a modifier, fn+…) is
        // simply theirs. None of those are DROPPED — they are not ours.
        if (b[@"hold"] || b[@"tap"]) continue;
        // Held only / Pressed only (`press`), and base rows (quote is Delete) that
        // sit under every layer: both Karabiner's, for the same reasons.
        if (nilIfNull(b[@"press"]) || [nilIfNull(b[@"base"]) boolValue]) continue;
        // A gesture's block is ours: no keyboard key, so nothing for Karabiner to block.
        int padKc;
        bool block = [b[@"to"] isKindOfClass:NSString.class]
            && [[b[@"to"] lowercaseString] isEqualToString:@"none"];
        if (block && !padKeyCode(b[@"key"], &padKc)) continue;
        if (isKarabinerOnlyKey(b[@"key"])) continue;
        // The one DECLARED reason (remapctl.forced_karabiner): the output is some
        // app's global hotkey, and that app's tap may sit ahead of ours.
        if ([b[@"engine"] isKindOfClass:NSString.class]
            && [[b[@"engine"] lowercaseString] isEqualToString:@"karabiner"]) continue;
        // A dialog row (`"dialog": true`) waits on Windows' modal dialog, which only
        // Karabiner hears (max/winlink → vm_dialog).
        if ([nilIfNull(b[@"dialog"]) boolValue]) continue;

        // `situation` is a string or a LIST of strings: the same binding in
        // several situations. One rule per situation, same ident; each Karabiner
        // situation in the list is skipped on its own, so a list may straddle the
        // engines and each takes the situations it owns.
        NSArray *sitIds;
        if (schema >= 2) {
            id sv = b[@"situation"];
            if ([sv isKindOfClass:NSArray.class]) sitIds = sv;
            else sitIds = @[ [sv isKindOfClass:NSString.class] ? sv : @"" ];
        } else {
            sitIds = @[ @"" ];
        }

        int fk; CGEventFlags ff;
        if (!b[@"key"]) continue;      // a Slots command with no key yet (set on Shortcuts ▸ Slots)
        if (padKeyCode(b[@"key"], &fk)) ff = 0;   // a gesture's own key (§ The trackpad keyboard)
        else if (!compileChord(b[@"key"], &fk, &ff)) {
            fprintf(stderr, "remapd: binding '%s' has an unspellable key '%s' — DROPPED\n",
                    ident.UTF8String, [b[@"key"] ?: @"(none)" UTF8String]);
            fflush(stderr);
            continue;
        }

        for (id sidObj in sitIds) {
        NSString *sid = [sidObj isKindOfClass:NSString.class] ? sidObj : @"";
        NSDictionary *sit = nil;
        if (schema >= 2) {
            sit = sits[sid];
            // A GATED situation is still Karabiner's (a gate is a Karabiner
            // variable). A hold-a-KEY situation is ours now: see THE HOLD AXIS.
            if (sit && nilIfNull(sit[@"gate"])) continue;
            // Fn held is Karabiner's too (remapctl.karabiners).
            if (sit && [nilIfNull(sit[@"hold"][@"kind"]) isEqual:@"modifier"]
                && [nilIfNull(sit[@"hold"][@"key"]) isEqual:@"fn"]) continue;
        }
        RRule *r = [RRule new];
        r.ident = ident; r.fromKey = fk; r.fromFlags = ff;
        r.toKey = -1; r.fMin = -1; r.fMax = -1; r.hold = -1; r.repeat = 1; r.order = order++;
        r.prio = [b[@"priority"] intValue];
        if ([nilIfNull(b[@"move_held"]) boolValue] && fk >= PAD_KC0) {
            NSArray *parts = [[b[@"key"] lowercaseString] componentsSeparatedByString:@"."];
            if (parts.count == 3) { r.moveHeld = YES; r.padLayer = parts[1]; }
        }

        if (schema >= 2) {
            if (sit == nil) {
                // Inert, never global. A binding whose scope cannot be resolved is
                // dropped: see the schema guard above for what the other choice cost.
                fprintf(stderr, "remapd: binding '%s' names situation '%s', which does "
                                "not exist — DROPPED\n", ident.UTF8String,
                        sid.length ? sid.UTF8String : "(none)");
                fflush(stderr);
                continue;
            }
            NSString *kind = nilIfNull(sit[@"hold"][@"kind"]) ?: @"none";
            if ([kind isEqualToString:@"fingers"]) {
                int n = [sit[@"hold"][@"count"] intValue];
                r.fMin = r.fMax = n;
                r.held = YES;
            } else if ([kind isEqualToString:@"key"]) {
                // The hold keys: space (what Karabiner reports as F20), and the
                // letter hold's J, J+K, J+K+L, D and F. Anything else is a situation
                // this binary cannot sample, and a binding in it is dropped
                // rather than run unconditionally.
                NSString *hk = nilIfNull(sit[@"hold"][@"key"]) ?: @"";
                NSString *with = nilIfNull(sit[@"hold"][@"with"]) ?: @"";
                int hv = -1;
                if ([hk isEqualToString:@"spacebar"])
                    hv = !with.length ? HOLD_SPACE : -1;
                else if ([hk isEqualToString:@"j"])
                    hv = !with.length ? HOLD_J
                       : [with isEqualToString:@"k"]   ? HOLD_JK
                       : [with isEqualToString:@"k+l"] ? HOLD_JKL : -1;
                else if ([hk isEqualToString:@"d"])
                    hv = !with.length ? HOLD_D
                       : [with isEqualToString:@"space"] ? HOLD_DS : -1;
                else if ([hk isEqualToString:@"f"])
                    hv = !with.length ? HOLD_F
                       : [with isEqualToString:@"space"] ? HOLD_FS : -1;
                if (hv < 0) {
                    fprintf(stderr, "remapd: binding '%s' is held by '%s%s%s', which this "
                                    "daemon cannot sample — DROPPED\n", ident.UTF8String,
                            hk.UTF8String, with.length ? "+" : "", with.UTF8String);
                    fflush(stderr);
                    continue;
                }
                r.hold = hv;
                r.held = YES;
                // A hold that also SENDS a modifier (Fusion's space is Option) may or
                // may not have it on the key under it: Karabiner holds it on the F20
                // report, but lets go of a held event's modifiers once another key
                // goes down. So it is ignored in the match, never required.
                NSString *emits = nilIfNull(sit[@"hold"][@"emits"]);
                if ([emits isKindOfClass:NSString.class]) r.emitFlags = modNamed(emits);
                r.shiftThrough = [nilIfNull(sit[@"shift_through"]) boolValue];
            } else if ([kind isEqualToString:@"modifier"]) {
                // A held MODIFIER needs no report: it is already on every key event,
                // so it is part of the match, like `emits`. Nothing else is held.
                NSString *mk = nilIfNull(sit[@"hold"][@"key"]) ?: @"";
                CGEventFlags mf = modNamed(mk);
                if (mf != kCGEventFlagMaskShift && mf != kCGEventFlagMaskCommand
                    && mf != kCGEventFlagMaskControl && mf != kCGEventFlagMaskAlternate) {
                    fprintf(stderr, "remapd: binding '%s' is held by modifier '%s', which "
                                    "this daemon cannot sample — DROPPED\n",
                            ident.UTF8String, mk.UTF8String);
                    fflush(stderr);
                    continue;
                }
                r.fromFlags |= mf;
                r.hold = HOLD_NONE;
            }
            NSArray *apps = nilIfNull(sit[@"apps"]);
            if ([apps isKindOfClass:NSArray.class] && apps.count) r.apps = apps;
            NSArray *notApps = nilIfNull(sit[@"not_apps"]);
            if ([notApps isKindOfClass:NSArray.class] && notApps.count) r.notApps = notApps;
            r.element = nilIfNull(sit[@"element"]);
            // A FUSION ▸ SHORTCUTS ROW IS NEVER IN A TEXT FIELD unless its situation
            // says so. Fusion drops its own shortcuts while text is being edited, so
            // the rewrite would only eat the letter — and a hand-made text-field row
            // on the same key is then no rival. Photoshop's rows too: T in a layer
            // name typed into the rename box fired Free Transform (2026-10-15).
            // Mirrored in remapctl.domain.
            if (!r.element && nilIfNull(b[@"_for"])
                && ([ident hasPrefix:@"fusion."] || [ident hasPrefix:@"photoshop."]))
                r.notElement = @"text";
            // "typing": false — right-click ▸ Active While Typing off, any app: the
            // row stands aside in a text field. Mirrored in remapctl.domain and
            // karabiner_layers.typing_cond.
            if (!r.element && [nilIfNull(b[@"typing"]) isEqual:@NO])
                r.notElement = @"text";
            // "typing": "only" — right-click ▸ While Typing Only: the row fires only
            // in a text field (where Mirror and the like live).
            if (!r.element && [nilIfNull(b[@"typing"]) isEqual:@"only"]) {
                r.element = @"text"; r.notElement = nil;
            }
            r.command = nilIfNull(sit[@"command"]);
            r.sketch  = nilIfNull(sit[@"sketch"]);
            r.mode    = nilIfNull(sit[@"mode"]);
            r.emptyLine = [nilIfNull(sit[@"line"]) isEqual:@"empty"];
            r.spec = (r.apps.count ? 1 : 0) + (r.notApps.count ? 1 : 0)
                   + (r.element || r.notElement ? 1 : 0) + (r.emptyLine ? 1 : 0)
                   + (r.command ? 1 : 0) + (r.sketch ? 1 : 0) + (r.mode ? 1 : 0)
                   + (r.fMin >= 0 ? 1 : 0) + (r.hold >= 0 ? 1 : 0);
        } else {
            NSDictionary *when = b[@"when"];
            if ([when isKindOfClass:NSDictionary.class]) {
                if (nilIfNull(when[@"app"])) r.apps = @[when[@"app"]];
                r.element = nilIfNull(when[@"element"]);
                NSString *fg = nilIfNull(when[@"fingers"]);
                if ([fg isKindOfClass:NSString.class]) {
                    // "2" | "4+" | "1-3"
                    if ([fg hasSuffix:@"+"])            { r.fMin = fg.intValue; r.fMax = 99; }
                    else if ([fg containsString:@"-"])  {
                        NSArray *p = [fg componentsSeparatedByString:@"-"];
                        r.fMin = [p[0] intValue]; r.fMax = [p.lastObject intValue];
                    } else                              { r.fMin = r.fMax = fg.intValue; }
                }
                r.spec = (r.apps.count ? 1 : 0) + (r.element ? 1 : 0) + (r.fMin >= 0 ? 1 : 0);
            }
        }

        id dbl = nilIfNull(b[@"double"]);
        if ([dbl isKindOfClass:NSNumber.class])
            r.doubleMs = dbl == (id)kCFBooleanTrue ? DOUBLE_MS_DEFAULT
                       : dbl == (id)kCFBooleanFalse ? 0 : MAX(0, MIN(2000, [dbl intValue]));

        if ([nilIfNull(b[@"chain"]) isKindOfClass:NSString.class]) {
            r.chain = b[@"chain"];          // its `run` is the fallback for Karabiner's rules
        } else if (b[@"run"]) {
            r.run = b[@"run"];
        } else if (block) {
            // A gesture's ✕ Empty (Control Room): does nothing here, so a wider
            // binding (the All column's) never reaches this app / situation.
            r.block = YES;
        } else if (b[@"to"]) {
            int tk; CGEventFlags tf;
            if (![b[@"to"] isKindOfClass:NSString.class] || !compileChord(b[@"to"], &tk, &tf)) {
                fprintf(stderr, "remapd: binding '%s' emits an unspellable chord '%s' — DROPPED\n",
                        ident.UTF8String, [[b[@"to"] description] UTF8String]);
                fflush(stderr);
                continue;
            }
            r.toKey = tk; r.toFlags = tf;
            NSString *then = nilIfNull(b[@"then"]);
            if (then) {
                int k2; CGEventFlags f2;
                if (![then isKindOfClass:NSString.class] || !compileChord(then, &k2, &f2)) {
                    fprintf(stderr, "remapd: binding '%s' has an unspellable 'then' '%s' — DROPPED\n",
                            ident.UTF8String, [[then description] UTF8String]);
                    fflush(stderr);
                    continue;
                }
                r.hasThen = YES; r.thenKey = k2; r.thenFlags = f2;
            }
            r.lineStop = [nilIfNull(b[@"lines"]) isEqual:@"stop"];
            id rep = nilIfNull(b[@"repeat"]);
            if (rep) r.repeat = MAX(1, MIN(50, [rep intValue]));
            r.tapRepeat = tapRepeat;
        } else {
            fprintf(stderr, "remapd: binding '%s' has neither 'to' nor 'run' — DROPPED\n",
                    ident.UTF8String);
            fflush(stderr);
            continue;
        }
        [rules addObject:r];
        }   // for sid
    }

    // WHAT IS HELD WINS FIRST, then most specific, then priority, then declared
    // later. The tail is hotkeys.py::claimants, deliberately — two implementations
    // of one rule are allowed to exist only while they cannot disagree about the
    // order — and the head is an axis hotkeys.py does not have, so they still
    // cannot.
    //
    // Why the head exists (added 2026-09-18 after it bit): a hold is a MODIFIER,
    // not one scope among several. {fusion, 1 finger} and {fusion, idle} both
    // constrain two axes, so they TIED on specificity and the one declared later
    // took the key — s under one finger fired fusion.reserved.s (Command Search)
    // instead of fusion.finger1.s (Combine), and no amount of scoping the finger
    // layer more narrowly could have fixed it. A rule that names what the hand is
    // holding now outranks every rule that says nothing about it.
    //
    // Note it is an ORDERING, not an exclusion: a rule with no hold constraint
    // still fires under a hold when no held rule claims that key. That is what
    // keeps the finger layers sparse — four fingers down does not blank the rest
    // of the keyboard — and it is why `always` still means always.
    [rules sortUsingComparator:^NSComparisonResult(RRule *a, RRule *b) {
        if (a.held  != b.held)  return a.held            ? NSOrderedAscending : NSOrderedDescending;
        if (a.spec  != b.spec)  return a.spec  > b.spec  ? NSOrderedAscending : NSOrderedDescending;
        if (a.prio  != b.prio)  return a.prio  > b.prio  ? NSOrderedAscending : NSOrderedDescending;
        if (a.order != b.order) return a.order > b.order ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSDictionary *apps = [j[@"apps"] isKindOfClass:NSDictionary.class] ? j[@"apps"] : @{};
    NSMutableDictionary *pats = [NSMutableDictionary new];
    for (NSString *shortName in apps) {
        NSDictionary *def = apps[shortName];
        if (![def isKindOfClass:NSDictionary.class]) continue;
        NSString *p = nilIfNull(def[@"pattern"]);
        if (![p isKindOfClass:NSString.class] || !p.length) continue;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p
                                                                            options:0 error:NULL];
        // An unparseable pattern falls back to the prefix list rather than
        // matching nothing: a typo in the table must not silently delete an app
        // from the vocabulary and take every binding scoped to it with it.
        if (re) pats[shortName] = re;
        else fprintf(stderr, "remapd: app '%s' has an unparseable pattern — "
                             "falling back to bundle prefixes\n", shortName.UTF8String);
    }
    os_unfair_lock_lock(&gLock);
    gRules = rules; gApps = apps; gAppPatterns = pats;
    gMoverRules = [rules filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RRule *r, id _) { (void)_; return r.moveHeld; }]];
    os_unfair_lock_unlock(&gLock);
    vlog(@"config: %lu bindings loaded", (unsigned long)rules.count);
}

/* ── Sampling: which app ─────────────────────────────────────────────────────
   Folded to a short name at PRESS time rather than here, so that a config reload
   which renames an app cannot leave a stale numeric id behind. The cost is a
   handful of prefix compares per keystroke. */
static NSString *foldApp(NSString *bundle, NSString *name, NSDictionary *apps) {
    for (NSString *shortName in apps) {
        NSDictionary *def = apps[shortName];
        if (![def isKindOfClass:NSDictionary.class]) continue;
        // `pattern` REPLACES the prefix test rather than adding to it — that is
        // what the apps table says it is for, and what it is for is this exact
        // pair: "com.josh.Fusion" is a prefix of com.josh.FusionDock, so without
        // it the dock folded to `fusionwin` and every Fusion-window binding was
        // live over a dock that owns none of them. hotkeys.py has always read the
        // pattern; this side had not, which is precisely the kind of disagreement
        // the shared vocabulary exists to prevent.
        NSRegularExpression *re = gAppPatterns[shortName];
        if (re) {
            if (bundle.length && [re numberOfMatchesInString:bundle options:0
                                    range:NSMakeRange(0, bundle.length)]) return shortName;
        } else {
            for (NSString *b in (def[@"bundle"] ?: @[]))
                if (bundle.length && [bundle hasPrefix:b]) return shortName;
        }
        for (NSString *n in (def[@"name"] ?: @[]))
            if (name.length && [name isEqualToString:n]) return shortName;
    }
    return nil;
}

/* ── Sampling: what has focus ────────────────────────────────────────────────
   The role fold from textfield_watch.m, widened to the values contexts.json
   declares. 'secure' is reported honestly rather than hidden as 'other', so that
   a binding accidentally scoped to a password field is visible in the log
   instead of merely not firing. Nothing should ever bind to it. */
static NSString *sampleElement(pid_t pid) {
    if (pid <= 0) return @"none";
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return @"none";
    // Fusion answers AX slowly — it has no tree to speak of and takes ~100ms to say
    // so (see the fusion-ax-blind note). Uncapped, that ONE app stretched the whole
    // loop from the intended 50ms to ~150ms, which is the interval the app axis was
    // really being republished at. The element is a hint that is re-read twenty
    // times a second; waiting longer than a tick for it is never worth it.
    AXUIElementSetMessagingTimeout(app, 0.05);
    CFTypeRef focused = NULL;
    AXError e = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
    CFRelease(app);
    if (e != kAXErrorSuccess || !focused) { if (focused) CFRelease(focused); return @"none"; }

    NSString *out = @"other";
    CFTypeRef sub = NULL;
    if (AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, &sub) == kAXErrorSuccess && sub) {
        if (CFGetTypeID(sub) == CFStringGetTypeID() &&
            CFEqual(sub, CFSTR("AXSecureTextField"))) out = @"secure";
        CFRelease(sub);
    }
    if ([out isEqual:@"other"]) {
        CFTypeRef role = NULL;
        if (AXUIElementCopyAttributeValue(focused, kAXRoleAttribute, &role) == kAXErrorSuccess && role) {
            if (CFGetTypeID(role) == CFStringGetTypeID()) {
                if (CFEqual(role, CFSTR("AXTextField")) || CFEqual(role, CFSTR("AXTextArea")) ||
                    CFEqual(role, CFSTR("AXComboBox")))      out = @"text";
                else if (CFEqual(role, CFSTR("AXOutline")))  out = @"outline";
            }
            CFRelease(role);
        }
    }
    CFRelease(focused);
    return out;
}

/* ── Sampling: a panel that has the keys without being frontmost ─────────────
   Spotlight (⌘Space) takes the keyboard but never activates: frontmostApplication
   stays whatever was under it, so the app axis said Fusion and the element was
   Fusion's — the Mirror never fired in Spotlight's field, and Fusion's own keys
   could. The system-wide focused element would answer this, but it returns
   kAXErrorCannotComplete here (textfield_watch.m). Asking the panel's own app
   element does work: kAXErrorNoValue while it is closed, its text field while it
   is open (probed 2026-10-13). One AX call per tick to a process that answers at
   once. Add a bundle here for any other launcher that behaves the same. */
static NSString *const kPanels[] = { @"com.apple.Spotlight" };

static NSRunningApplication *panelWithKeys(void) {
    static NSRunningApplication *cached[sizeof kPanels / sizeof *kPanels];
    for (size_t i = 0; i < sizeof kPanels / sizeof *kPanels; i++) {
        if (!cached[i] || cached[i].terminated)
            cached[i] = [NSRunningApplication
                         runningApplicationsWithBundleIdentifier:kPanels[i]].firstObject;
        if (!cached[i]) continue;
        AXUIElementRef app = AXUIElementCreateApplication(cached[i].processIdentifier);
        if (!app) continue;
        AXUIElementSetMessagingTimeout(app, 0.05);
        CFTypeRef focused = NULL;
        AXError e = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
        CFRelease(app);
        if (focused) CFRelease(focused);
        if (e == kAXErrorSuccess && focused) return cached[i];
    }
    return nil;
}

/* ── Sampling: what command Fusion is running ────────────────────────────────
   Written by fusion_ui/hotkeys.py::_publish_command at every commandStarting and
   commandTerminated, and touched (mtime bumped, no rewrite) on an idle tick — see
   its docstring. 'unknown' when the file has never existed (the add-in has not run
   since boot, or never will); 'stale' once nothing has touched it in
   COMMAND_STALE_S seconds, which is what actually protects a reserved-chord rewrite:
   an add-in that died or was mid-reload must read as "cannot tell", never as
   'none'. Cached by mtime — this runs on the worker's own tick, same as
   sampleElement, and a stat() every 50ms is the only cost paid to notice a change.

   THE CACHE KEY IS NANOSECONDS AND THE INODE, not st_mtime. st_mtime is
   st_mtimespec.tv_sec: WHOLE SECONDS. Keyed on that, every rewrite landing in the
   same wall-clock second as the last one this read was invisible — and a command
   that starts and ends inside one second (an orbit, a pan, a zoom: every trackpad
   nav gesture) does exactly that. The axis then sat on the command name for up to
   a second AFTER Fusion had already published 'none', so a reserved-chord rewrite
   scoped to fusion-idle silently missed and the bare key went to Fusion instead.
   Intermittent by construction — it depended only on where in the second you
   pressed. _publish_command renames a temp file into place, so the inode changes
   on every content write too; it costs nothing to compare and closes the case
   where a clock adjustment leaves the timestamp unmoved. */
static NSString *sampleCommand(void) {
    struct stat st;
    if (stat(kCommandFile.UTF8String, &st) != 0) return @"unknown";
    double age = [NSDate date].timeIntervalSince1970 - (double)st.st_mtime;
    if (age > COMMAND_STALE_S) return @"stale";
    static struct timespec lastMtime = {0, 0};
    static ino_t lastIno = 0;
    static NSString *lastVal = @"none";
    if (st.st_mtimespec.tv_sec  != lastMtime.tv_sec ||
        st.st_mtimespec.tv_nsec != lastMtime.tv_nsec ||
        st.st_ino               != lastIno) {
        NSString *s = [NSString stringWithContentsOfFile:kCommandFile
                                                 encoding:NSUTF8StringEncoding error:NULL];
        lastVal = [s stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"none";
        if (!lastVal.length) lastVal = @"none";
        lastMtime = st.st_mtimespec;
        lastIno   = st.st_ino;
    }
    return lastVal;
}

/* Same file discipline as sampleCommand, for kSketchFile. Cheap enough to re-read
   whole every turn: two bytes, and only while the stamp is fresh. */
static NSString *sampleSketch(void) {
    struct stat st;
    if (stat(kSketchFile.UTF8String, &st) != 0) return @"unknown";
    if ([NSDate date].timeIntervalSince1970 - (double)st.st_mtime > COMMAND_STALE_S)
        return @"unknown";
    NSString *s = [NSString stringWithContentsOfFile:kSketchFile
                                             encoding:NSUTF8StringEncoding error:NULL];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : @"unknown";
}

/* kModeFile, the same way — but missing or stale is 'none': a mode is something the
   app is IN, and an app nothing has said anything about is in no mode. */
static NSString *sampleMode(void) {
    struct stat st;
    if (stat(kModeFile.UTF8String, &st) != 0) return @"none";
    if ([NSDate date].timeIntervalSince1970 - (double)st.st_mtime > COMMAND_STALE_S)
        return @"none";
    NSString *s = [NSString stringWithContentsOfFile:kModeFile
                                             encoding:NSUTF8StringEncoding error:NULL];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : @"none";
}

/* ── The worker ───────────────────────────────────────────────────────────────
   The wake source is what lets an app activation be acted on immediately instead
   of up to a tick later. It carries no payload: being woken IS the message, and
   the very next turn of the loop re-reads everything anyway. It doubles as the
   source that makes the sleep below a real sleep. */
static CFRunLoopSourceRef gWake       = NULL;
static CFRunLoopRef       gWorkerLoop = NULL;
static void wakePerform(void *info) { (void)info; }

static void wakeWorker(void) {
    if (!gWake || !gWorkerLoop) return;
    CFRunLoopSourceSignal(gWake);
    CFRunLoopWakeUp(gWorkerLoop);
}

static dispatch_queue_t gAuxQ;          // the trackpad keyboard's (§ The trackpad keyboard)
static void auxLoadKeys(void);
static void auxLoadPrint(void);
static void hudLoad(void);   // THE HUD
static _Atomic bool gTyping;
// bin/thumbprint is calibrating: it keeps /tmp/remapd_calibrating fresh (touched each
// second). Meanwhile the pads neither type nor click (the pointer still moves) — no click lands on a window,
// nothing types into the terminal. Stale after 3 s, so a killed run frees them.
static _Atomic bool gCalib = false;
static _Atomic bool gCalibLeft = false;   // /tmp/remapd_calibrating_left: the LEFT pad sends nothing (bin/thumbprint combo / idle)
static void auxFreezeUpdate(void);
static void typingSet(bool on, const char *why);
static void workerLoop(void) {
    // THE SLEEP DEPENDS ON THIS SOURCE EXISTING. -[NSRunLoop runUntilDate:] is
    // documented to exit immediately when the mode holds no source or timer, and
    // this thread registered neither — so for as long as that was true, POLL_MS
    // was a comment rather than an interval: the loop spun, and every turn fired a
    // synchronous AX round-trip into whatever app was frontmost. Measured before
    // the fix: ~30% of a core here, and several hundred AX requests a second
    // landing on Fusion's main thread.
    gWorkerLoop = CFRunLoopGetCurrent();
    CFRunLoopSourceContext wctx = {0};
    wctx.perform = wakePerform;
    gWake = CFRunLoopSourceCreate(NULL, 0, &wctx);
    CFRunLoopAddSource(gWorkerLoop, gWake, kCFRunLoopDefaultMode);

    struct stat st;
    // Seeded from the file main() already loaded, so the first tick does not
    // reload a table that is one millisecond old.
    time_t lastMtime = (stat(kBindings.UTF8String, &st) == 0) ? st.st_mtime : 0;
    long   lastSize  = (lastMtime ? (long)st.st_size : 0);
    // situations.json is half the table now that hold-key situations are ours:
    // a scope edited there has to reload just like a binding edited here.
    time_t lastSitMtime = (stat(kSituations.UTF8String, &st) == 0) ? st.st_mtime : 0;
    // auxpad.json (the trackpad keyboard) is edited from Control Room's Trackpad mode.
    NSString *auxFile = [gDir stringByAppendingPathComponent:@"auxpad.json"];
    struct timespec lastAux = (stat(auxFile.UTF8String, &st) == 0) ? st.st_mtimespec : (struct timespec){0};
    NSString *printFile = [gDir stringByAppendingPathComponent:@"thumbprint.json"];
    struct timespec lastPrint = (stat(printFile.UTF8String, &st) == 0) ? st.st_mtimespec : (struct timespec){0};
    // hud.json (THE HUD): compiled by Control Room; zero, so the first turn loads it.
    NSString *hudFile = [gDir stringByAppendingPathComponent:@"hud.json"];
    struct timespec lastHud = {0};
    NSString *shown = nil;
    for (;;) {
        @autoreleasepool {
            bool changed = false;
            if (stat(kBindings.UTF8String, &st) == 0 &&
                (st.st_mtime != lastMtime || st.st_size != lastSize)) {
                lastMtime = st.st_mtime; lastSize = st.st_size; changed = true;
            }
            if (stat(kSituations.UTF8String, &st) == 0 && st.st_mtime != lastSitMtime) {
                lastSitMtime = st.st_mtime; changed = true;
            }
            if (changed) loadConfig();
            if (stat(auxFile.UTF8String, &st) == 0 &&
                (st.st_mtimespec.tv_sec != lastAux.tv_sec || st.st_mtimespec.tv_nsec != lastAux.tv_nsec)) {
                lastAux = st.st_mtimespec;
                if (gAuxQ) dispatch_async(gAuxQ, ^{ auxLoadKeys(); fprintf(stderr, "auxpad.json reloaded\n"); fflush(stderr); });
            }
            if (stat(hudFile.UTF8String, &st) == 0 &&
                (st.st_mtimespec.tv_sec != lastHud.tv_sec || st.st_mtimespec.tv_nsec != lastHud.tv_nsec)) {
                lastHud = st.st_mtimespec;
                hudLoad();
            }
            // thumbprint.json: written by bin/thumbprint after a calibration.
            if (stat(printFile.UTF8String, &st) == 0 && st.st_mtimespec.tv_sec != lastPrint.tv_sec) {
                lastPrint = st.st_mtimespec;
                if (gAuxQ) dispatch_async(gAuxQ, ^{ auxLoadPrint(); });
            }
            bool typing = access("/tmp/remapd_typing", F_OK) == 0;   // remap/typing.sh, or another remapd
            if (typing != atomic_load(&gTyping) && gAuxQ)
                dispatch_async(gAuxQ, ^{ typingSet(typing, "command"); });
            atomic_store(&gOff,   access(kOffFile.UTF8String,   F_OK) == 0);
            atomic_store(&gTrace, access(kTraceFile.UTF8String, F_OK) == 0);
            bool calib = stat("/tmp/remapd_calibrating", &st) == 0 && time(NULL) - st.st_mtime <= 3;
            if (calib != atomic_exchange(&gCalib, calib)) {
                fprintf(stderr, "aux calibrating %s\n", calib ? "ON (pads silent)" : "off"); fflush(stderr);
                auxFreezeUpdate();
            }
            bool calibL = stat("/tmp/remapd_calibrating_left", &st) == 0 && time(NULL) - st.st_mtime <= 3;
            if (calibL != atomic_exchange(&gCalibLeft, calibL)) {
                fprintf(stderr, "aux calibrating left %s\n", calibL ? "ON (left pad silent, right pad plain)" : "off"); fflush(stderr);
            }

            NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
            // Spotlight open = it is the app, whatever is frontmost under it. The
            // one AX read that has to come before the publish below — it is what
            // decides which app is being published.
            NSRunningApplication *panel = panelWithKeys();
            if (panel) front = panel;
            NSString *bundle = front.bundleIdentifier ?: @"";
            NSString *name   = front.localizedName    ?: @"";

            // THE APP AXIS IS PUBLISHED BEFORE THE ELEMENT IS SAMPLED, and that
            // ordering is the fix, not a tidy-up. Published after, it was only ever
            // as fresh as the slowest AX round-trip on the machine — so switching
            // from Fusion into one of its dialogs left `app` reading `fusion` for
            // ~150ms while the dialog already had the keystrokes. Which app you are
            // in is known here, for free, without asking anybody.
            os_unfair_lock_lock(&gLock);
            BOOL appChanged = ![bundle isEqualToString:gFrontBundle];
            gFrontBundle = bundle; gFrontName = name;
            // The element belongs to the app it was read from. Carried across a
            // switch it is not stale data, it is data about somewhere else — and it
            // would let a text-field binding fire in an app whose focus was never
            // looked at. Unknown until re-read, one turn from now at worst.
            if (appChanged) gElement = @"none";
            os_unfair_lock_unlock(&gLock);

            NSString *elem = sampleElement(front.processIdentifier);
            NSString *cmd  = sampleCommand();
            NSString *skt  = sampleSketch();
            NSString *mde  = sampleMode();

            os_unfair_lock_lock(&gLock);
            gElement = elem;
            gCommand = cmd;
            gSketch  = skt;
            gMode    = mde;
            NSString *folded = foldApp(gFrontBundle, gFrontName, gApps);
            gFrontApp = folded;
            os_unfair_lock_unlock(&gLock);
            atomic_store(&gSampleNs, nowNs());

            // -d is the answer to "I cannot tell what state I am in". It prints the
            // domain exactly as the resolver sees it, so a binding that does not fire
            // can be diagnosed by looking rather than by guessing which axis is wrong.
            int nf = atomic_load(&gFingers);
            const char *hn = holdName(atomic_load(&gHold));
            NSString *now = [NSString stringWithFormat:
                             @"app=%@ (%@) element=%@ command=%@ sketch=%@ mode=%@ fingers=%d hold=%s",
                             folded ?: @"-", name, elem, cmd, skt, mde, nf, hn];
            if (![now isEqualToString:shown ?: @""]) {
                shown = now;
                if (gDump) { fprintf(stderr, "%s\n", now.UTF8String); fflush(stderr); }
                // Written only on CHANGE, which for a contact count means once per
                // touch-down rather than once per frame. Written whole and renamed
                // into place so a reader can never see half a state.
                NSDictionary *ctx = @{@"app": folded ?: @"", @"app_name": name,
                                      @"element": elem, @"command": cmd, @"sketch": skt,
                                      @"mode": mde,
                                      @"fingers": @(nf),
                                      @"hold": @(hn),
                                      @"ts": @([NSDate date].timeIntervalSince1970)};
                NSData *jd = [NSJSONSerialization dataWithJSONObject:ctx options:0 error:nil];
                NSString *tmp = [kContext stringByAppendingString:@".tmp"];
                if (jd && [jd writeToFile:tmp atomically:NO])
                    rename(tmp.UTF8String, kContext.UTF8String);
            }

            // frontmostApplication is notification-backed: without a run loop turn
            // it never changes. Pumping the loop IS the sleep (textfield_watch.m) —
            // but ONLY while the loop has something to wait on. See the port added
            // before this loop: without it runUntilDate: finds an empty mode,
            // returns immediately, and this becomes a spin that reads AX as fast as
            // the target app can answer instead of twenty times a second.
            [NSRunLoop.currentRunLoop runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:POLL_MS / 1000.0]];
        }
    }
}

/* ── Multitouch, with hot-plug ────────────────────────────────────────────────
   Lifted from bin/reanchor.m, including the reason: MTDeviceCreateDefault()
   binds the trackpad ONCE, and a Magic Trackpad that sleeps, runs flat or drops
   its Bluetooth link is re-published under a NEW handle while the old one goes
   silent. The process keeps running and never sees another touch. Watching IOKit
   for AppleMultitouchDevice arrivals makes cold start and reconnect the same
   path. Here the failure would be quieter still than reanchor's: the finger count
   would read 0 forever and every trackpad-scoped binding would simply stop,
   looking exactly like "I must have lifted my finger". */
typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint pos, vel; } mtReadout;
typedef struct {
    int frame; double timestamp; int identifier, state, foo3, foo4;
    mtReadout normalized; float size; int zero1;
    float angle, majorAxis, minorAxis; mtReadout mm; int zero2[2]; float unk2;
} Finger;
typedef void *MTDeviceRef;
// The first argument is the device itself (declared int until 2026-10-16, which on
// arm64 kept only its low 32 bits — fine while every pad meant the same thing).
typedef int (*MTContactCallbackFunction)(MTDeviceRef, Finger *, int, double, int);
MTDeviceRef MTDeviceCreateFromService(io_service_t);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
void MTDeviceStop(MTDeviceRef);
#include "auxpad.h"

// Aux pads seen so far, one slot per device ID. Written on the main thread at bind,
// read by the multitouch thread. A pad that re-matches (wake, HID reset) REPLACES its
// slot — 2026-10-19 the built-in pad re-matched ~65× in a burst, the 8 slots filled with
// stale refs, and the live left pad read as the main pad (pointer moved, no freeze).
#define AUX_MAX 8
static MTDeviceRef _Atomic gAuxDevs[AUX_MAX];
static uint64_t gAuxIds[AUX_MAX];
static _Atomic int gAuxCount = 0;
static bool isAuxDev(MTDeviceRef dev) {
    int n = atomic_load(&gAuxCount);
    for (int i = 0; i < n; i++) if (atomic_load(&gAuxDevs[i]) == dev) return true;
    return false;
}

/* ── The trackpad keyboard ────────────────────────────────────────────────────
   Both pads type, independently (one bin/auxgest.h recogniser each): the AUX pad
   is the left hand, the MAIN pad the right. remap/auxpad.json maps gesture names
   to keys per layer; the key is POSTED — through this tap like a typed key, so
   every binding applies (with the keyboard's held modifiers: combined-session source).
   - left  (aux pad): always a keyboard. Its HELD thumb = Shift for keys from EITHER pad (the right's too, while typing);
           a thumb swipe is its own gesture (Space in the map).
   - right (main pad): a plain trackpad until TYPING is on — latched by a command
           (typing.on / typing.off: a gesture's value in auxpad.json, by default spread5 /
           pinch5, or remap/typing.sh from a key). Then a keyboard, the cursor frozen and
           its pointer events dropped (auxRightKbd); its HELD thumb = Shift like the left's,
           its thumb swipe = Space (Delete: swipe left 4; the left pad swipe right 4). (Holding the thumb to type was retired 2026-10-16.)
           The latch lives in /tmp/remapd_typing (exists = on) and shows on the HUD.
   MODIFIERS (2026-10-16): a HELD thumb (either pad's; the right one only while
   typing) = ⌘. Fingers resting still on the OTHER pad: one = ⇧, two = Space held
   (an F20 posted around the key, so the Space layer's bindings apply exactly as
   from the keyboard). A thumb TAP is its own gesture (thumbtap, ⏎ by default).
   LAYERS, per hand (<hand> = left / right), picked per gesture — the first that
   has it of <hand>_one … _five (fingers resting on the other pad) / _thumb (whichever is held), else <hand> with the
   modifiers above. A layer's own value gets no modifiers from what chose it.
   <hand>_cmd (taps by default): COMMANDS TAP, SWIPES TYPE — a key there is posted from
   that gesture only when it fires a command binding (auxIsCommand), and from its own
   gesture only when it types; checked first, with the plain layer's modifiers.
   A value is a key ("h", "left", "alt+left"), a command (typing.on / off / toggle),
   or a binding's id (word.left: posted like that binding — its `then`, `lines`).
   LEFT HAND TYPES, RIGHT HAND NAVIGATES (2026-10-16): <hand>_nav is checked before
   <hand> while that hand navigates — the left pad whenever no text field has focus
   (gElement), the right pad whenever it isn't typing; the right pad then acts only on
   _nav and the modifier layers (thumb-down taps: Wispr Flow, voice jump), and its
   thumb gestures' tap-to-clicks are dropped (auxRightThumbClick). The left hand
   navigating, on a gesture left_nav doesn't set, fires that gesture's OWN binding
   (key "pad.left.<gesture>", padKeyCode / auxPadFire) — never the letter it types.
   "+thumb" (thumb
   landed with the fingers / swiped along) = the thumb held. Values tap:<chord> /
   sh:<command> act (auxAction); "space+<key>" holds Space around the key.
   Shapes tell a lone thumb from a finger (remap/thumbprint.json, bin/thumbprint).
   No mirror, no F20 here: those stay the keyboard's (2026-10-16).
   Everything runs on gAuxQ; the multitouch thread only copies frames over. */
#include "auxgest.h"
#include "navwords.h"   // the pin / claim words shared with reanchor
#include "hidpoint.h"   // HID-tap posts under the screen zoom
enum { PAD_LEFT = 0, PAD_RIGHT = 1 };
static dispatch_queue_t gAuxQ;
static AuxGest gGest[2];                        // gAuxQ only
static AgPrint gPrint[2];                       // gAuxQ only; gGest[p].print points here
static AgRoll gRoll[2];                         // gAuxQ only; gGest[p].roll points here
static AgRest gRest[2];                         // gAuxQ only; gGest[p].rest points here
static AgLone gLone[2];                         // gAuxQ only; gGest[p].lone points here
static AgRestSec gRestSec[2];                   // gAuxQ only; gGest[p].restSec points here (zeros = defaults)
static AgHold gPadHold[2];                         // gAuxQ only; the left pad's held kinds (`thumbprint left hold`)
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *gAuxMap;   // layer → gesture → value
static CGEventSourceRef gAuxSrc;
// The keyboard's own held modifiers, from flags-changed events that are not ours
// (tapCallback). Posted keys carry exactly these (+ Shift for a held thumb): a
// combined-session source handed them a Shift left over from an earlier capital,
// so h after T came out H and rolled arrows selected (2026-10-16).
static _Atomic uint64_t gHwFlags = 0;
static _Atomic bool gTyping = false;            // typing latched on (typingSet)
static void auxCursorHide(bool hide);
// Why the pointer is hidden: the right pad typing, or a right-pad touch landing while
// the left pad is held (FLICK: a fast move there still jogs the detached cursor, then
// snaps back — hidden, the jump never shows; 2026-10-18). Shown when neither holds.
enum { HIDE_TYPING = 1, HIDE_FLICK = 2 };
static _Atomic int gHideWhy = 0;
static void auxHideWhy(int bit, bool on) {
    int was = on ? atomic_fetch_or(&gHideWhy, bit) : atomic_fetch_and(&gHideWhy, ~bit);
    if (((was & bit) != 0) != on) auxCursorHide(on);
}
// A move_held binding's modifier is resting on the left pad (auxMoverUpdate): no freeze.
static _Atomic bool gAuxMover = false;
// WHICH PAD SENT IT (2026-10-21): every event macOS makes from a pad carries that pad's
// HID service registry ID in CGEvent field 87 (measured 2026-10-21, probe since deleted: left 0x100081f61,
// right 0x10001c4b4), so the left pad's events are told apart even with both hands
// moving. gAuxSender is the aux pad's, set at bind (mtMatched); 0 = not known yet, and
// the old touch-stream guesses apply.
#define SENDER_FIELD ((CGEventField)87)
static _Atomic uint64_t gAuxSender = 0;
static uint64_t evSender(CGEventRef e) { return (uint64_t)CGEventGetIntegerValueField(e, SENDER_FIELD); }
static bool auxSent(CGEventRef e) { uint64_t s = atomic_load(&gAuxSender); return s && evSender(e) == s; }
// A CLAIMED touch on the main pad (THE CLAIM, below; until 2026-10-18 every thumb-down
// touch), or reanchor pinning its nav: the pointer freezes and the fingers' moves /
// scrolls go nowhere — they are gestures.
// gMainThumbNs: when the fingers joined (the freeze winds back to just before it).
static _Atomic bool gMainThumbHold = false;
static CGPoint gThumbPin;   // gPosLock: where a thumb-down session holds the pointer
static _Atomic uint64_t gMainThumbNs = 0;
// A THUMB-DOWN SESSION: from gMainThumbHold until the main pad is clear (+ the click
// grace) nothing clicks — macOS tap-clicks the swiping fingers and the thumb's lift,
// and in Photoshop that painted a dab (2026-10-18). A new touch ends it.
static _Atomic bool gMainThumbSess = false;
// A 2-finger scroll in progress (tapCallback): a "thumb" read after it began is a palm or
// finger brushing the pad, not a thumb-down gesture — it used to freeze the pointer and
// drop the rest of the scroll mid-way, in every app (2026-10-18).
static _Atomic bool     gScrollLive = false;
static _Atomic uint64_t gScrollBeganNs = 0;
// Last REAL scroll event (began / changed / ended, or any momentum — never the may-begin /
// cancelled pair a bare two-finger touch sends): rolls are dropped near one (auxEmit).
static _Atomic uint64_t gScrollAnyNs = 0;
#define ROLL_SCROLL_NS (600ull * 1000000ull)
#define SCROLL_OWNS_NS (60ull * 1000000ull)   // a scroll this old by the thumb's read keeps going
static _Atomic bool gMainTwoClose = false;   // the main pad: exactly two contacts, finger-close (touchCallback)
#define TWO_FINGERS_MM 35.0f
// REANCHOR'S WORD on that pin (2026-10-18): while its Fusion / Max orbit, pan or zoom owns
// the touch, the pin is where reanchor says, or none — ours pinned at where the touch
// began, so a thumb joining a pan jumped back, and stayed sticky through the orbit after
// the thumb lifted (jitter against reanchor's drags). The word: navwords.h.
static uint64_t reanchorPin(CGPoint *at) {
    static _Atomic uint64_t *word;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ word = navword_map(NAV_PIN_FILE, false); });
    uint64_t w = word ? atomic_load(word) : 0;
    if (at) *at = pinword_at(w);
    return w;
}
// THE CLAIM (2026-10-18, user: "if I bind something to that gesture, beginning it should
// not send anything — unbound, it works as normal"). The main pad's touch STATE — thumb
// down or not, how many fingers, fingers resting on the left pad — is CLAIMED when a swipe
// made of exactly that state is bound HERE (this app / situation; auxRightClaims). From
// the landing the pointer is pinned and nothing moves, scrolls, zooms, orbits or clicks:
// remapd's own drops (gMainThumbHold), reanchor's nav and pinch zoom (it reads
// /tmp/remapd_claim), FusionScrollFilter's zoom made of it. A contact LANDING re-judges
// (thumb + 1 claimed → thumb + 2 = the zoom again); contacts LIFTING keep it (the thumb
// left alone after the swipe). Taps claim nothing here — a tap that fires drops its own
// click (gPadFireNs). One or two fingers alone (the pointer, the scroll / orbit) and the
// thumb's pinches (the zoom itself) are never claimed on landing; they fire at the lift.
static _Atomic bool gMainClaim = false;   // gAuxQ writes; the tap reads
static void claimPublish(bool on) {       // gAuxQ only. The word: navwords.h
    static _Atomic uint64_t *word;
    if (!word && !(word = navword_map(CLAIM_FILE, true))) return;
    atomic_store(word, claimword_make(on));   // stamped, so a stale word (remapd died) times out
}
static bool auxRightClaims(bool thumb, int n, int still, char *why, size_t wn);   // after the resolver
static bool auxRightBound(const char *name, int still);
static void auxShowPointer(void);
static bool auxRightKbd(void) { return atomic_load(&gTyping); }

// THE TYPING LATCH. One setter for the gesture, the command script and the file poll
// (workerLoop): the file is the truth others can see, gTyping the fast copy.
static const char *kTypingFile = "/tmp/remapd_typing";
static void typingSet(bool on, const char *why) {
    if (atomic_load(&gTyping) == on) return;   // gAuxQ only, so no race with itself
    // The file first: the poll compares it with gTyping, and must never see the old file
    // with the new flag (it would set it straight back).
    if (on) { FILE *f = fopen(kTypingFile, "w"); if (f) fclose(f); }
    else unlink(kTypingFile);
    atomic_store(&gTyping, on);
    if (!on) atomic_store(&gFingers, 0);
    auxFreezeUpdate();
    auxHideWhy(HIDE_TYPING, on);
    fprintf(stderr, "aux typing %s (%s)\n", on ? "ON" : "off", why); fflush(stderr);
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/Users/josh/bin/hud"];
    t.arguments = @[@"show", on ? @"On" : @"Off", @"--ms", @"900"];
    t.standardOutput = t.standardError = NSFileHandle.fileHandleWithNullDevice;
    [t launchAndReturnError:NULL];
}
static void auxRunCmd(NSString *cmd) {
    if ([cmd isEqualToString:@"typing.on"]) typingSet(true, "gesture");
    else if ([cmd isEqualToString:@"typing.off"]) typingSet(false, "gesture");
    else if ([cmd isEqualToString:@"typing.toggle"]) typingSet(!atomic_load(&gTyping), "gesture");
}

// `mods`: the value's own modifiers (+ Shift for a held thumb). The flags are SET,
// never inherited: the keyboard's held modifiers (gHwFlags), these, and the fn /
// keypad bits the arrows and nav keys carry when typed for real.
static void auxPostKey(int kc, bool down, bool repeat, CGEventFlags mods) {
    CGEventRef e = CGEventCreateKeyboardEvent(gAuxSrc, (CGKeyCode)kc, down);
    if (!e) return;
    if (repeat) CGEventSetIntegerValueField(e, kCGKeyboardEventAutorepeat, 1);
    CGEventFlags f = (CGEventFlags)atomic_load(&gHwFlags) | mods;
    if (kc >= 123 && kc <= 126) f |= kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad;
    else if (kc == 117 || kc == 115 || kc == 119 || kc == 116 || kc == 121) f |= kCGEventFlagMaskSecondaryFn;
    CGEventSetFlags(e, f);
    CGEventPost(kCGHIDEventTap, e); CFRelease(e);
}
// A held gesture's key repeats like a real one: the system's InitialKeyRepeat /
// KeyRepeat (units of 15 ms), the initial delay counted from the touch (the hold
// itself took AG_HOLD_S of it). One repeat per pad. gAuxQ only.
static uint64_t gAuxRepeatGen[2];
// THE HELD KEY IS LATCHED PER PAD (2026-10-21), as remapd latches a keycode: the down
// decides, the up only lifts what went down. The up used to re-resolve the gesture, and
// a context the held key itself changed (Escape leaving a text field flips the left pad
// to _nav) returned before the repeat was stopped — Escape repeated into Claude at 30/s
// until a reboot. auxRelease runs first in auxEmit, before anything can return. gAuxQ only.
typedef struct { bool on; int kc; CGEventFlags mods; bool space; } AuxHeld;
static AuxHeld gAuxHeld[2];
static void auxRelease(int pad) {
    gAuxRepeatGen[pad]++;   // stops the repeat
    AuxHeld *h = &gAuxHeld[pad];
    if (!h->on) return;
    h->on = false;
    auxPostKey(h->kc, false, false, h->mods);
    if (h->space) auxPostKey(KC_F20, false, false, 0);
}
static void auxRepeat(int pad, int kc, CGEventFlags mods, uint64_t gen, double after) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * 1e9)), gAuxQ, ^{
        if (gen != gAuxRepeatGen[pad]) return;
        // Backstop: the pad holds nothing (no up reached auxEmit — a pad unplugged
        // mid-hold, calibration started): lift it rather than repeat forever.
        if (!gGest[pad].holding) { auxRelease(pad); return; }
        auxPostKey(kc, true, true, mods);
        NSInteger r = [NSUserDefaults.standardUserDefaults integerForKey:@"KeyRepeat"];
        auxRepeat(pad, kc, mods, gen, (r > 0 ? r : 2) * 0.015);
    });
}
static bool auxPostBinding(NSString *ident);   // after the latch (postBurst)
static bool auxParseKey(NSString *v, int *kc, CGEventFlags *mods);
static bool auxIsCommand(int kc, CGEventFlags mods, bool space, NSString **ident);   // after the resolver
static bool auxPadFire(NSString *padKey, CGEventFlags mods, bool space);             // after the resolver
static bool padResolves(NSString *padKey, CGEventFlags mods, bool space);            // after the resolver
static void startChain(NSString *cid, int kc, CGEventFlags kf);                       // THE SEQUENCES
static void padChain(NSString *cid);                                                  // THE SEQUENCES
// A text field has focus: AX's element = text, or — in the VM's apps, where AX sees only
// Parallels — Windows' own focus via max/winlink (/tmp/vm_text_field, 2026-10-17).
static bool auxTextFocused(void) {
    os_unfair_lock_lock(&gLock);
    NSString *app = gFrontApp, *elem = gElement;
    os_unfair_lock_unlock(&gLock);
    bool vm = [app isEqualToString:@"3dsmax"] || [app isEqualToString:@"explorer"] || [app isEqualToString:@"windows"];
    return vm ? access("/tmp/vm_text_field", F_OK) == 0 : [elem isEqualToString:@"text"];
}
// PER APP (2026-10-17): "<layer>@<app>" (app = bindings.json apps key, as folded) wins
// over the shared layer — Control Room writes there from an app's column. PER SITUATION:
// each column is "<layer>@<app>~<sit>" (index.js padAppOf), checked before "<layer>@<app>"
// (Notes / Claude's one column): sit = "typing" in a text field, else Fusion "sketch" /
// "viewport" (sketch axis), Photoshop "photoshop" / "mattes" / "transform" (mode), else "main".
static NSString *auxValue(NSString *layer, const char *name) {
    os_unfair_lock_lock(&gLock);
    NSString *app = gFrontApp, *skt = gSketch, *mode = gMode;
    os_unfair_lock_unlock(&gLock);
    bool typing = auxTextFocused();
    // A feature dialog's text box is one of OUR Fusion windows: Control Room's Fusion ·
    // While Typing column (2026-10-17).
    if (typing && [app isEqualToString:@"fusionwin"]) app = @"fusion";
    NSString *sit = !app ? nil : typing ? @"typing"
        : [app isEqualToString:@"fusion"] ? ([skt isEqualToString:@"in"] ? @"sketch" : [skt isEqualToString:@"out"] ? @"viewport" : nil)
        : [app isEqualToString:@"photoshop"] ? ([mode isEqualToString:@"mattes"] || [mode isEqualToString:@"transform"] ? mode : @"photoshop")
        : @"main";
    NSString *v = sit ? gAuxMap[[NSString stringWithFormat:@"%@@%@~%@", layer, app, sit]][@(name)] : nil;
    if (!v && app) v = gAuxMap[[NSString stringWithFormat:@"%@@%@", layer, app]][@(name)];
    if ([v isEqualToString:@"-"]) return nil;                    // nothing, in this app / situation
    return v ?: gAuxMap[layer][@(name)];
}
static void auxAction(NSString *v);   // tap: / sh: values, after tapChord
static bool auxClick(NSString *v, int phase, CGEventFlags held);   // click: values, after auxShowPointer
// 1–5 fingers resting on the other pad → <hand>_one … _five (Control Room's "… on Right");
// the left pad's hold (auxLeftHold) adds _three_thumb, and its _five = four + the thumb.
static NSString *auxStillLayer(NSString *hand, int still) {
    static NSString *const sub[AG_HOLD_STATES] = { @"", @"_one", @"_two", @"_three", @"_four", @"_five", @"_three_thumb" };
    return still >= 1 && still < AG_HOLD_STATES ? [hand stringByAppendingString:sub[still]] : hand;
}
// THE HOLD (auxgest.h auxgestHold): what rests on the left pad as the right pad's modifier —
// fingertips counted, the thumb only between three / four, knuckles and the palm never.
// Nothing while the left pad is being calibrated: the right pad works plain.
static int auxLeftHold(double now) {
    return atomic_load(&gCalibLeft) ? 0 : auxgestHold(&gGest[PAD_LEFT], &gPadHold[PAD_LEFT], now, NULL);
}
// EARLY (2026-10-17): the right pad navigating fires its mapped _nav swipes mid-motion
// (app / slot switches) instead of after the lift + merge gap. Typing gestures still wait.
// RESTING SECTIONS (auxgest agRestOf, 2026-10-21): "rest<r>:<g>" = fingers resting on the
// right pad, others doing g by them → the layer <hand>_rest_one … _three, nothing else.
// "restthumb:<g>" = the thumb resting there, fingers doing g → <hand>_rest_thumb (r 5).
// 2026-10-29: "rest4:<g>" (four fingers; the thumb's swipes / tap) → _rest_four, and
// "restthumb<f>:<g>" = the thumb + f fingers resting → _rest_thumb_one … _three (r 6–8).
#define AUX_REST_THUMB 5
#define AUX_REST_N 8
static NSString *auxRestLayer(NSString *hand, int r) {
    static NSString *const sub[] = { @"_rest_one", @"_rest_two", @"_rest_three", @"_rest_four",
                                     @"_rest_thumb", @"_rest_thumb_one", @"_rest_thumb_two", @"_rest_thumb_three" };
    return r >= 1 && r <= AUX_REST_N ? [hand stringByAppendingString:sub[r - 1]] : nil;
}
// The name prefix of section r (auxRestSplit backwards): "rest2:", "restthumb:", "restthumb1:".
static void auxRestPrefix(int r, char *p, size_t n) {
    if (r < AUX_REST_THUMB) snprintf(p, n, "rest%d:", r);
    else if (r == AUX_REST_THUMB) snprintf(p, n, "restthumb:");
    else snprintf(p, n, "restthumb%d:", r - AUX_REST_THUMB);
}
// Splits "rest2:up1" → 2 and "up1" (into g), "restthumb:up1" → AUX_REST_THUMB,
// "restthumb2:up1" → AUX_REST_THUMB + 2; 0 = no prefix.
static int auxRestSplit(const char *name, char *g, size_t n) {
    int r = 0, at = 0;
    if (!strncmp(name, "restthumb:", 10)) { strlcpy(g, name + 10, n); return AUX_REST_THUMB; }
    if (sscanf(name, "restthumb%d:%n", &r, &at) == 1 && at && r >= 1 && r <= 3) { strlcpy(g, name + at, n); return AUX_REST_THUMB + r; }
    if (sscanf(name, "rest%d:%n", &r, &at) != 1 || !at || r < 1 || r >= AUX_REST_THUMB) return 0;
    strlcpy(g, name + at, n);
    return r;
}
static bool auxEarly(const char *name, void *ctx) {
    (void)ctx;
    if (atomic_load(&gTyping) || atomic_load(&gCalib) || atomic_load(&gOff)) return false;
    // Only where auxEmit would pick right_nav: no command / resting-finger layer has it.
    int still = auxLeftHold((double)nowNs() / 1e9);
    if (auxValue(@"right_cmd", name) || (still && auxValue(auxStillLayer(@"right", still), name))) return false;
    return auxValue(@"right_nav", name) != nil;
}
static void auxEmit(const char *gname, int phase, int flags, const char *detail, void *ctx) {
    int pad = (int)(intptr_t)ctx;
    const char *side = pad == PAD_LEFT ? "left" : "right";
    NSString *hand = @(side);
    double now = (double)nowNs() / 1e9;
    // A held key lifts on its own up — or on anything new from this pad — before the
    // gesture is resolved again (THE HELD KEY IS LATCHED PER PAD).
    if (phase != AG_TAP || gAuxHeld[pad].on) auxRelease(pad);
    if (atomic_load(&gCalib)) return;   // bin/thumbprint is reading the pads
    // "+thumb": the thumb LANDED WITH the fingers (or swiped along) — the same as held
    // (2026-10-16: no waiting with the thumb down first).
    char name[32];
    strlcpy(name, gname, sizeof name);
    char *plus = strstr(name, "+thumb");
    if (plus) *plus = 0;
    char rg[32];   // RESTING SECTIONS: "rest<r>:<g>" reads <hand>_rest_<r> alone (auxRestLayer)
    int rest = auxRestSplit(name, rg, sizeof rg);
    if (rest) strlcpy(name, rg, sizeof name);
    // ROLLS ARE TAPS, never touches in a scroll (2026-11-15): two fingers put down to stop
    // a coasting scroll land staggered and read as rollL2 / rollR2. Any real scroll or
    // momentum within ROLL_SCROLL_NS of the decision drops the roll.
    if (phase == AG_TAP && strstr(name, "roll")) {
        uint64_t age = nowNs() - atomic_load(&gScrollAnyNs);
        if (age < ROLL_SCROLL_NS) {
            fprintf(stderr, "aux %s %s: dropped — scroll %.0f ms ago | %s\n", side, name, age / 1e6, detail ? detail : "");
            fflush(stderr);
            return;
        }
    }
    // NAVIGATING (<hand>_nav, 2026-10-16): the left pad when no text field has focus, the
    // right pad while it isn't typing (its usual state: the right hand navigates).
    bool typingR = atomic_load(&gTyping);
    bool nav = pad == PAD_LEFT ? !auxTextFocused() : !typingR;
    // The right pad navigating: fingers held still there are RESTING — the left pad's
    // One…Four Fingers modifier — never a held key (2026-10-17: four resting = "tap4
    // HELD" jumped to Claude before the left tap landed).
    if (pad == PAD_RIGHT && !typingR && phase != AG_TAP) return;
    // What is held (see the header): this pad's thumb, or the other's while the right
    // pad types; fingers resting on the other pad.
    int other = pad == PAD_LEFT ? PAD_RIGHT : PAD_LEFT;
    bool thumb = plus || (flags & AG_THUMB_HELD) != 0
              || (pad == PAD_LEFT ? typingR && auxgestThumbDown(&gGest[PAD_RIGHT])
                                  : typingR && auxgestThumbDown(&gGest[PAD_LEFT]));
    // The left pad's hold (fingertips / thumb, knuckles and palm left out) for the right
    // pad; the right pad's resting fingers, plain, for the left.
    int kinds[AG_MAX]; for (int i = 0; i < AG_MAX; i++) kinds[i] = -1;
    int still = other == PAD_LEFT ? (atomic_load(&gCalibLeft) ? 0 : auxgestHold(&gGest[PAD_LEFT], &gPadHold[PAD_LEFT], now, kinds))
                                  : auxgestStill(&gGest[other], now, true);
    // Why the other pad did / didn't count as resting fingers (diagnosis, 2026-10-17).
    {
        const AuxGest *o = &gGest[other];
        static const char *const kn[AGK_N] = { "tip", "thumb", "knuckle", "palm", "idle", "idle", "idle" };
        char buf[320]; size_t at = (size_t)snprintf(buf, sizeof buf, "n=%d thumb=%d", o->n, o->thumbId >= 0);
        for (int i = 0; i < o->n && at < sizeof buf; i++)
            at += (size_t)snprintf(buf + at, sizeof buf - at, " [%s live=%d fr=%d age=%.0fms mv=%.3f]",
                                   other == PAD_LEFT && kinds[i] >= 0 ? kn[kinds[i]] : kinds[i] == AGK_UNSURE ? "unsure" : "-", o->t[i].live,
                                   o->t[i].frames, (now - o->t[i].t0) * 1000, o->t[i].move);
        fprintf(stderr, "aux %s %s: other pad still=%d %s | %s\n", side, name, still, buf, detail ? detail : ""); fflush(stderr);
    }
    // <hand>_cmd: the gestures (taps) that fire a key's COMMANDS — first, whatever is held.
    NSString *cmdLayer = [hand stringByAppendingString:@"_cmd"];
    bool cmdGesture = !rest && auxValue(cmdLayer, name) != nil;
    NSString *layer = cmdGesture ? cmdLayer : hand;
    bool own = false;   // a modifier layer had it: no added modifiers
    if (rest) {
        layer = auxRestLayer(hand, rest);
        if (!layer || !auxValue(layer, name)) {
            fprintf(stderr, "aux %s gesture %s [%s] (unmapped)\n", side, name, layer ? layer.UTF8String : "rest?"); fflush(stderr);
            return;
        }
        own = true;
    } else
    for (NSString *l in cmdGesture ? @[] : @[still ? auxStillLayer(hand, still) : hand, thumb ? [hand stringByAppendingString:@"_thumb"] : hand]) {
        if ([l isEqualToString:hand]) continue;
        if (auxValue(l, name)) { layer = l; own = true; break; }
    }
    // THUMB DOWN (2026-10-17): this pad's own thumb held picks <hand>_thumb's value or
    // NOTHING — never the thumb-up gesture with ⌘ added (a cleared Thumb Down gesture
    // does nothing; Control Room draws it empty). The other pad's thumb while the right
    // pad types is still ⌘ below.
    if ((plus || (flags & AG_THUMB_HELD)) && !own && !cmdGesture && strncmp(name, "thumbswipe", 10)
        && strcmp(name, "thumbtap") && strcmp(name, "none")) {
        fprintf(stderr, "aux %s gesture %s [%s_thumb] (unmapped)\n", side, name, side); fflush(stderr);
        return;
    }
    // Navigating: <hand>_nav before the plain layer (held modifiers still apply).
    NSString *navLayer = [hand stringByAppendingString:@"_nav"];
    if (!own && !cmdGesture && nav && auxValue(navLayer, name)) layer = navLayer;
    NSString *v = auxValue(layer, name);
    // A command gesture (typing on / off) acts whether or not the pad is typing.
    if ([v hasPrefix:@"typing."]) {
        fprintf(stderr, "aux %s gesture %s [%s] → %s\n", side, name, layer.UTF8String, v.UTF8String); fflush(stderr);
        if (phase == AG_TAP && !atomic_load(&gOff)) auxRunCmd(v);
        return;
    }
    // NOT WHILE TYPING (2026-10-16): the left hand navigating, on a gesture its _nav layer
    // doesn't set, fires that gesture's OWN binding (key "pad.left.<gesture>") — never the
    // letter the typing layer has there. Nothing bound = nothing. Once, on the tap or the
    // hold's down. A thumb-down layer's own value still wins (own).
    if (pad == PAD_LEFT && nav && !own && !cmdGesture && [layer isEqualToString:hand] && strcmp(name, "none")) {
        if (phase == AG_UP || atomic_load(&gOff)) return;
        CGEventFlags fl = (thumb ? kCGEventFlagMaskCommand : 0) | (still == 1 ? kCGEventFlagMaskShift : 0);
        if (auxPadFire([NSString stringWithFormat:@"pad.%s.%s", side, name], fl, still == 2)) auxShowPointer();
        return;
    }
    // The right pad types only while typing is on; else it is the mouse — but for its
    // _nav gestures and the modifier layers (thumb-down taps…). A gesture with its OWN
    // binding (key "pad.right.<gesture>") still fires it, as on the left hand — Control
    // Room shows the typing layer's "bind" there too (2026-10-17: tap3 Rename did nothing).
    if (pad == PAD_RIGHT && !typingR && !own && layer != navLayer) {
        if (phase != AG_UP && !atomic_load(&gOff) && strcmp(name, "none")
            && auxPadFire([NSString stringWithFormat:@"pad.%s.%s", side, name], still == 1 ? kCGEventFlagMaskShift : 0, still == 2)) {
            auxShowPointer();   // its key hid the pointer (2026-10-18: Control Room Select Up / Down)
            return;
        }
        if (atomic_load(&gTrace)) { fprintf(stderr, "trace right pad %s (mouse)\n", name); fflush(stderr); }
        return;
    }
    // "bind": the gesture's own binding in that layer (Control Room's Command type) —
    // pad.<hand>.<g> for _nav, pad.<hand>_typing.<g> for the hand's typing layer,
    // pad.<layer>.<g> for the rest. Once, on the tap or the hold's down.
    if ([v isEqualToString:@"bind"]) {
        if (phase == AG_UP || atomic_load(&gOff)) return;
        NSString *kl = [layer hasSuffix:@"_nav"] ? hand
                     : [layer isEqualToString:hand] ? [hand stringByAppendingString:@"_typing"] : layer;
        // A resting-finger / thumb layer IS the modifier: its own rows carry no Shift /
        // Space (2026-10-17: One Finger rows never matched with Shift added).
        bool add = !own;
        if (auxPadFire([NSString stringWithFormat:@"pad.%@.%s", kl, name],
                       add && still == 1 ? kCGEventFlagMaskShift : 0, add && still == 2))
            auxShowPointer();
        return;
    }
    CGEventFlags held = 0;
    bool space = false;
    if (!own && strncmp(name, "thumbswipe", 10) && strcmp(name, "thumbtap")) {
        if (thumb) held |= kCGEventFlagMaskCommand;
        if (still == 1) held |= kCGEventFlagMaskShift;
        space = still == 2;
    } else if (own && still == 1 && [layer hasSuffix:@"_thumb"]) {
        held |= kCGEventFlagMaskShift;   // capitals in the thumb's mirrored letters
    }
    // "space+down": the key with Space held (the Space layer's big jumps).
    NSString *kv = v;
    if ([kv hasPrefix:@"space+"]) { kv = [kv substringFromIndex:6]; space = true; }
    int k = -1; CGEventFlags mods = 0;
    bool key = kv && auxParseKey(kv, &k, &mods);
    mods |= held;
    fprintf(stderr, "aux %s gesture %s%s%s%s%s [%s]%s %s\n", side, name,
            phase == AG_DOWN ? " HELD" : phase == AG_UP ? " released" : "",
            held & kCGEventFlagMaskCommand ? " +cmd" : "", held & kCGEventFlagMaskShift ? " +shift" : "",
            space ? " +space" : "", layer.UTF8String,
            v ? [NSString stringWithFormat:@" → %@", v].UTF8String
              : (strcmp(name, "none") ? " (unmapped)" : ""), detail);
    fflush(stderr);
    if (!v || atomic_load(&gOff)) return;
    auxShowPointer();
    if (auxClick(v, phase, held)) return;
    if ([v hasPrefix:@"tap:"] || [v hasPrefix:@"sh:"]) {   // once, on the tap or the hold's down
        if (phase != AG_UP) auxAction(v);
        return;
    }
    if (!key) {   // a binding's id: once, on the tap or the hold's down
        if (phase != AG_UP && !auxPostBinding(v)) {
            fprintf(stderr, "aux: %s — no such key or binding\n", v.UTF8String); fflush(stderr);
        }
        return;
    }
    // COMMANDS TAP, SWIPES TYPE (2026-10-16): a key that has a <hand>_cmd gesture is
    // posted from it only when it fires a command here (auxIsCommand), and from its
    // own gesture only when it doesn't. A command gesture is always one press.
    static bool gated[2];
    if (cmdGesture && phase == AG_UP) return;
    if (phase != AG_UP) {
        gated[pad] = false;
        if (cmdGesture || [gAuxMap[cmdLayer].allValues containsObject:v]) {
            NSString *ident = nil;
            bool cmd = auxIsCommand(k, mods, space, &ident);
            gated[pad] = cmd != cmdGesture;
            fprintf(stderr, "aux %s: %s (%s)%s\n", name, cmd ? "command" : "typing",
                    ident ? ident.UTF8String : "no binding",
                    gated[pad] ? (cmdGesture ? " — taps only fire commands, dropped" : " — tap for commands, dropped") : "");
            fflush(stderr);
        }
    }
    if (gated[pad]) return;
    if (cmdGesture) phase = AG_TAP;
    // Space held: Karabiner's report (F20) around the key, through the tap like the real one.
    static bool spaceOn[2];
    if (phase != AG_UP && space) { auxPostKey(KC_F20, true, false, 0); spaceOn[pad] = true; }
    if (phase == AG_TAP) {
        auxPostKey(k, true, false, mods); auxPostKey(k, false, false, mods);
        if (spaceOn[pad]) { auxPostKey(KC_F20, false, false, 0); spaceOn[pad] = false; }
        return;
    }
    if (phase == AG_UP) return;   // auxRelease lifted the latched key, at the top
    uint64_t gen = gAuxRepeatGen[pad];
    auxPostKey(k, true, false, mods);
    gAuxHeld[pad] = (AuxHeld){ true, k, mods, spaceOn[pad] };
    spaceOn[pad] = false;   // the latch lifts it
    NSInteger ir = [NSUserDefaults.standardUserDefaults integerForKey:@"InitialKeyRepeat"];
    auxRepeat(pad, k, mods, gen, fmax((ir > 0 ? ir : 25) * 0.015 - AG_HOLD_S, 0.05));
}
/* MULTI-TAPS RETIRED (2026-10-21, user: no double / triple tap rows): every tap fires at
   once. auxEmitPad only drops the left pad's gestures while bin/thumbprint reads it. */
static bool auxRestBound(int pad, const char *name) {
    char g[32];
    int r = auxRestSplit(name, g, sizeof g);
    NSString *l = auxRestLayer(pad == PAD_LEFT ? @"left" : @"right", r);
    if (l && !*g) {   // "rest<r>:" — anything in the section, here (auxgest agRestArmed)
        NSMutableSet *names = [NSMutableSet set];
        for (NSString *k in gAuxMap) if ([k isEqualToString:l] || [k hasPrefix:[l stringByAppendingString:@"@"]])
            [names addObjectsFromArray:[gAuxMap[k] allKeys]];
        char pre[16];
        auxRestPrefix(r, pre, sizeof pre);
        for (NSString *n in names) if (auxRestBound(pad, [NSString stringWithFormat:@"%s%@", pre, n].UTF8String)) return true;
        return false;
    }
    NSString *v = l ? auxValue(l, g) : nil;
    return v &&(![v isEqualToString:@"bind"] || padResolves([NSString stringWithFormat:@"pad.%@.%s", l, g], 0, false));
}
static bool auxWants(const char *name, void *ctx) { return auxRestBound((int)(intptr_t)ctx, name); }
static void auxEmitPad(const char *gname, int phase, int flags, const char *detail, void *ctx) {
    if ((int)(intptr_t)ctx == PAD_LEFT && atomic_load(&gCalibLeft)) {   // bin/thumbprint is reading the left pad: it sends nothing
        fprintf(stderr, "aux left %s: calibrating — dropped\n", gname); fflush(stderr);
        return;
    }
    auxEmit(gname, phase, flags, detail, ctx);
}
static void auxThumb(bool down, void *ctx) {
    int pad = (int)(intptr_t)ctx;
    // Held = ⌘ (auxEmit), on either pad; the right one only while typing is on.
    bool live = pad == PAD_LEFT || atomic_load(&gTyping);
    fprintf(stderr, "aux %s thumb %s\n", pad == PAD_LEFT ? "left" : "right",
            down ? (live ? "held (cmd)" : "held (not typing)") : "up");
    fflush(stderr);
}
static void auxTick(int pad, double deadline) {
    if (deadline <= 0) return;
    double wait = deadline - (double)nowNs() / 1e9;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(wait, 0) * 1e9) + 1000000), gAuxQ, ^{
        auxgestTick(&gGest[pad], (double)nowNs() / 1e9);
    });
}
// A key spelled as one character or by name, after any modifiers: "h", "left",
// "alt+left", "cmd+shift+z".
static bool auxParseKey(NSString *v, int *kc, CGEventFlags *mods) {
    static const char *chars = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.";
    NSDictionary *named = @{@"space": @49, @"return": @36, @"tab": @48, @"delete": @51,
                            @"fwddelete": @117, @"escape": @53, @"home": @115, @"end": @119,
                            @"pageup": @116, @"pagedown": @121,
                            @"left": @123, @"right": @124, @"down": @125, @"up": @126};
    NSDictionary *modNames = @{@"cmd": @(kCGEventFlagMaskCommand), @"ctrl": @(kCGEventFlagMaskControl),
                               @"alt": @(kCGEventFlagMaskAlternate), @"opt": @(kCGEventFlagMaskAlternate),
                               @"shift": @(kCGEventFlagMaskShift)};
    NSArray *parts = v.length > 1 ? [v componentsSeparatedByString:@"+"] : @[v];
    CGEventFlags m = 0;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSNumber *f = modNames[[parts[i] lowercaseString]];
        if (!f) return false;
        m |= f.unsignedLongLongValue;
    }
    NSString *last = parts.lastObject;
    int code = -1;
    if (named[last.lowercaseString]) code = [named[last.lowercaseString] intValue];
    else if (last.length == 1) {
        char ch = (char)tolower([last characterAtIndex:0]);
        for (int c = 0; c < 48; c++) if (ch && chars[c] == ch) { code = c; break; }
    }
    if (code < 0) return false;
    *kc = code; *mods = m;
    return true;
}
// auxpad.json: every layer's values as written; a value that is neither a key nor a
// command is taken for a binding's id, checked when it fires (bindings reload apart).
static void auxLoadKeys(void) {
    NSData *d = [NSData dataWithContentsOfFile:[gDir stringByAppendingPathComponent:@"auxpad.json"]];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    NSMutableDictionary *layers = [NSMutableDictionary dictionary];
    for (NSString *layer in j) {
        if (![j[layer] isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *g in j[layer]) {
            id v = j[layer][g];
            if ([v isKindOfClass:NSString.class] && [v length]) m[g] = v;
            else { fprintf(stderr, "auxpad.json: %s.%s — not a key, skipped\n", layer.UTF8String, g.UTF8String); fflush(stderr); }
        }
        layers[layer] = m;
    }
    gAuxMap = layers;
}
// remap/thumbprint.json (bin/thumbprint): per hand, the finger and thumb shapes.
static void auxLoadPrint(void) {
    NSData *d = [NSData dataWithContentsOfFile:[gDir stringByAppendingPathComponent:@"thumbprint.json"]];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    for (int p = 0; p < 2; p++) {
        AgPrint pr = { .ok = false };
        NSDictionary *h = [j isKindOfClass:NSDictionary.class] ? j[p == PAD_LEFT ? @"left" : @"right"] : nil;
        if ([h isKindOfClass:NSDictionary.class]) {
            pr.ok = true;
            NSArray *cls = @[@"finger", @"thumb"];
            for (int c = 0; c < 2; c++) {
                NSDictionary *s = h[cls[c]];
                NSArray *mu = [s isKindOfClass:NSDictionary.class] ? s[@"mu"] : nil, *sd = mu ? s[@"sd"] : nil;
                if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class]
                    || mu.count != AGF || sd.count != AGF) { pr.ok = false; break; }
                for (int i = 0; i < AGF; i++) {
                    pr.mu[c][i] = [mu[i] floatValue];
                    pr.sd[c][i] = fmaxf([sd[i] floatValue], 0.02f);
                }
            }
            // The context part (offset from recent finger landings), when it was learnt.
            NSDictionary *cx = pr.ok && [h[@"ctx"] isKindOfClass:NSDictionary.class] ? h[@"ctx"] : nil;
            pr.window = [cx[@"window"] floatValue];
            pr.ctxOk = cx && pr.window > 0;
            for (int c = 0; c < 2 && pr.ctxOk; c++) {
                NSDictionary *s = cx[cls[c]];
                NSArray *mu = [s isKindOfClass:NSDictionary.class] ? s[@"mu"] : nil, *sd = mu ? s[@"sd"] : nil;
                if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class]
                    || mu.count != 2 || sd.count != 2) { pr.ctxOk = false; break; }
                for (int i = 0; i < 2; i++) {
                    pr.cmu[c][i] = [mu[i] floatValue];
                    pr.csd[c][i] = fmaxf([sd[i] floatValue], 0.03f);
                }
            }
            // The group part (`thumbprint <side> group`): the thumb swiping with fingers.
            NSDictionary *gp = [h[@"group"] isKindOfClass:NSDictionary.class] ? h[@"group"] : nil;
            pr.grpOk = gp != nil;
            for (int c = 0; c < 2 && pr.grpOk; c++) {
                NSDictionary *s = gp[cls[c]];
                NSArray *mu = [s isKindOfClass:NSDictionary.class] ? s[@"mu"] : nil, *sd = mu ? s[@"sd"] : nil;
                if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class]
                    || mu.count != AGG || sd.count != AGG) { pr.grpOk = false; break; }
                for (int i = 0; i < AGG; i++) {
                    pr.gmu[c][i] = [mu[i] floatValue];
                    pr.gsd[c][i] = fmaxf([sd[i] floatValue], 0.01f);
                }
            }
        }
        gPrint[p] = pr;
        gGest[p].print = &gPrint[p];
        // The roll rules (`thumbprint <side> roll`): independent of the shape print.
        NSDictionary *rl = [h isKindOfClass:NSDictionary.class] && [h[@"roll"] isKindOfClass:NSDictionary.class] ? h[@"roll"] : nil;
        AgRoll ro = agRollDefault;
        if (rl && [rl[@"gap"] floatValue] > 0) {
            ro.gap = [rl[@"gap"] floatValue];
            ro.dur = [rl[@"dur"] floatValue]; ro.durPer = [rl[@"durPer"] floatValue];
            ro.move = [rl[@"move"] floatValue]; ro.land = [rl[@"land"] floatValue];
        }
        // Less touchy (2026-11-15: rolls fired off scrolls): the right pad learnt a 4 ms gap,
        // 0.03 drift and soft landings — floor them, so a roll is clearly staggered TAPS.
        ro.gap = fmaxf(ro.gap, AG_ROLL_MIN_GAP);
        if (ro.move > 0) ro.move = fminf(ro.move, AG_ROLL_MAX_MOVE);
        ro.land = fmaxf(ro.land, AG_ROLL_MIN_LAND);
        gRoll[p] = ro;
        gGest[p].roll = &gRoll[p];
        // Thumb-down taps (`thumbprint <side> thumbtap`): fingers tapping by a resting thumb.
        NSDictionary *rs = [h isKindOfClass:NSDictionary.class] && [h[@"rest"] isKindOfClass:NSDictionary.class] ? h[@"rest"] : nil;
        AgRest re = agRestDefault;
        if (rs && [rs[@"lead"] floatValue] > 0) {
            re.lead = [rs[@"lead"] floatValue]; re.still = [rs[@"still"] floatValue];
            re.land = [rs[@"land"] floatValue]; re.dur = [rs[@"dur"] floatValue];
            re.durPer = [rs[@"durPer"] floatValue]; re.gap = [rs[@"gap"] floatValue]; re.shape = [rs[@"shape"] floatValue];
        }
        gRest[p] = re;
        gGest[p].rest = &gRest[p];
        // Fingers resting on this pad (`thumbprint right rest`): lead / still / finger-close mm,
        // and THE LAYOUT (layout.<thumb|1|2|3>: mu / sd, mm) with its weight.
        NSDictionary *rq = [h isKindOfClass:NSDictionary.class] && [h[@"restsec"] isKindOfClass:NSDictionary.class] ? h[@"restsec"] : nil;
        AgRestSec rsec = { [rq[@"lead"] floatValue], [rq[@"still"] floatValue], [rq[@"fingerMM"] floatValue], [rq[@"layW"] floatValue] };
        NSDictionary *lay = [rq[@"layout"] isKindOfClass:NSDictionary.class] ? rq[@"layout"] : nil;
        for (int c = 0; c < AG_LAYS; c++) {
            NSDictionary *e = lay[c == AG_LAY_THUMB ? @"thumb" : [NSString stringWithFormat:@"%d", c]];
            if (![e isKindOfClass:NSDictionary.class] || [e[@"mu"] count] != 2 || [e[@"sd"] count] != 2) continue;
            for (int a = 0; a < 2; a++) { rsec.mu[c][a] = [e[@"mu"][a] floatValue]; rsec.sd[c][a] = [e[@"sd"][a] floatValue]; }
        }
        gRestSec[p] = rsec;
        gGest[p].restSec = &gRestSec[p];
        // The lone thumb (`thumbprint right lone`): learnt on the right hand, the left
        // mirrors it unless it has its own.
        NSDictionary *rj = [j isKindOfClass:NSDictionary.class] && [j[@"right"] isKindOfClass:NSDictionary.class] ? j[@"right"] : nil;
        NSDictionary *ln = [h isKindOfClass:NSDictionary.class] && [h[@"lone"] isKindOfClass:NSDictionary.class] ? h[@"lone"]
                         : [rj[@"lone"] isKindOfClass:NSDictionary.class] ? rj[@"lone"] : nil;
        AgLone lo = agLoneDefault;
        if (ln && ln[@"shape"]) {
            lo.shape = [ln[@"shape"] floatValue]; lo.swipe = [ln[@"swipe"] floatValue];
            lo.dur = [ln[@"dur"] floatValue]; lo.land = [ln[@"land"] floatValue];
        }
        gLone[p] = lo;
        gGest[p].lone = &gLone[p];
        // The hold kinds (`thumbprint left hold`): fingertip / thumb / knuckle / palm, and the
        // resting hand's clusters (`thumbprint left idle`: hold.idle, a list).
        NSDictionary *hd = [h isKindOfClass:NSDictionary.class] && [h[@"hold"] isKindOfClass:NSDictionary.class] ? h[@"hold"] : nil;
        AgHold ho = { .ok = false };
        static NSString *const kinds[AGK_IDLE] = { @"finger", @"thumb", @"knuckle", @"palm" };
        NSArray *idle = [hd[@"idle"] isKindOfClass:NSArray.class] ? hd[@"idle"] : @[];
        for (int k = 0; hd && k < AGK_N; k++) {
            id e = k < AGK_IDLE ? hd[kinds[k]] : k - AGK_IDLE < (int)idle.count ? idle[k - AGK_IDLE] : nil;
            NSDictionary *s = [e isKindOfClass:NSDictionary.class] ? e : nil;
            NSArray *mu = s[@"mu"], *sd = s[@"sd"];
            if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class] || mu.count != sd.count
                || (mu.count != AGH && mu.count != AGHP)) continue;
            ho.has[k] = true;
            for (int i = 0; i < AGHP; i++) {   // a shape-only fit: place says nothing (same broad Gaussian for all)
                bool in = i < (int)mu.count;
                ho.mu[k][i] = in ? [mu[i] floatValue] : 0;
                ho.sd[k][i] = in ? fmaxf([sd[i] floatValue], i < AGH ? 0.02f : 0.01f) : 1e3f;
            }
        }
        ho.ok = ho.has[AGK_FINGER];
        ho.margin = [hd[@"margin"] floatValue];   // unsure → nothing (0 = off)
        // The hand reader (auxgest.h AgReader): when learnt, it reads the hold instead.
        NSDictionary *rj2 = [hd[@"reader"] isKindOfClass:NSDictionary.class] ? hd[@"reader"] : nil;
        bool (^gauss)(id, AgGauss *) = ^bool(id e, AgGauss *g) {
            NSDictionary *s = [e isKindOfClass:NSDictionary.class] ? e : nil;
            NSArray *mu = s[@"mu"], *sd = s[@"sd"];
            if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class] || mu.count != AGH || sd.count != AGH) return false;
            for (int i = 0; i < AGH; i++) { g->mu[i] = [mu[i] floatValue]; g->sd[i] = fmaxf([sd[i] floatValue], 0.02f); }
            return true;
        };
        NSArray *rr = [rj2[@"rest"] isKindOfClass:NSArray.class] ? rj2[@"rest"] : @[], *rw = [rj2[@"w"] isKindOfClass:NSArray.class] ? rj2[@"w"] : @[];
        bool rok = rj2 && gauss(rj2[@"tip"], &ho.rd.tip) && gauss(rj2[@"thumb"], &ho.rd.thumb) && rr.count == AGR_RESTS && rw.count == AGR;
        for (int k = 0; rok && k < AGR_RESTS; k++) rok = gauss(rr[k], &ho.rd.rest[k]);
        for (int d = 0; rok && d < AGR; d++) ho.rd.w[d] = [rw[d] floatValue];
        ho.rd.tau = rok ? [rj2[@"tau"] floatValue] : 0; ho.rd.keep = rok ? [rj2[@"keep"] floatValue] : 0;
        ho.rd.ok = rok;
        gPadHold[p] = ho;
        fprintf(stderr, "thumbprint %s: %s%s; rolls %s gap %.0f ms; thumb-down taps %s; lone thumb %s; hold %s\n", p == PAD_LEFT ? "left" : "right",
                !pr.ok ? "none (thumb told by place)"
                : pr.ctxOk ? "loaded (thumb told by shape + recent fingers)" : "loaded (thumb told by shape)",
                pr.grpOk ? " + group (thumb swiping with fingers)" : "",
                rl ? "learnt" : "default", ro.gap * 1000, rs ? "learnt" : "default",
                lo.shape >= AG_LONE_OFF ? "off (run `thumbprint right lone`)" : [NSString stringWithFormat:@"shape > %.0f", lo.shape].UTF8String,
                ho.rd.ok ? [NSString stringWithFormat:@"hand reader (tau %.2f, keep %.2f)", ho.rd.tau, ho.rd.keep].UTF8String
                : ho.ok ? [NSString stringWithFormat:@"learnt (%s%s%s%s), unsure margin %.1f", ho.has[AGK_THUMB] ? "thumb " : "",
                         ho.has[AGK_KNUCKLE] ? "knuckle " : "", ho.has[AGK_PALM] ? "palm " : "", ho.has[AGK_IDLE] ? "idle" : "", ho.margin].UTF8String
                      : "by the thumbprint (run `thumbprint left hold`)");
    }
    fflush(stderr);
}

/* The CURSOR. Dropping mouseMoved in a tap hides the motion from apps, but the
   HID system has already moved the cursor (2026-10-16: "still works as normal").
   So while the aux pad alone is touched the cursor is detached from the mouse
   (CGAssociateMouseAndMouseCursorPosition), and any move that slips through is
   warped back to where the touch began. Main thread only. */
extern int _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(int, int, CFStringRef, CFTypeRef);
#define AUX_LIFT_GRACE_NS (150ull * 1000000ull)   // see auxOwnsEvent
static _Atomic uint64_t gAuxFreezeGen = 0;
static CGPoint gAuxAnchor;
static bool gAuxFrozen = false;
// The freeze's PIN (2026-10-19): with Photoshop in front the detach doesn't hold — every
// left swipe moved the pointer, then the tap snapped it back. Same cure as the thumb-down
// pin: warp to the anchor each touch frame and at least every 100 ms, so macOS keeps
// ignoring the pads' moves (a warp suppresses them ~¼ s) and never draws one.
static _Atomic bool gAuxPinned = false;
static CGPoint gAuxPin;   // gPosLock
/* Where the cursor was BEFORE aux motion began. A fast flick moves it in the frames
   before the motion is told apart (2026-10-16: "a sudden movement … a jog"), so a
   motion freeze winds back to the position just before gAuxMoveStartNs: the tap logs
   each move (time + location before it); the main pad was still all that while. */
static _Atomic uint64_t gAuxMoveStartNs = 0, gAuxTouchNs = 0;
static bool auxMoving(void);
static bool auxMainStill(void);
enum { POS_RING = 64 };
static struct { uint64_t ns; CGPoint before; } gPosRing[POS_RING];
static int gPosHead = 0;
static os_unfair_lock gPosLock = OS_UNFAIR_LOCK_INIT;
static void auxLogMove(CGEventRef ev) {   // tap thread
    CGPoint p = CGEventGetLocation(ev);
    p.x -= CGEventGetIntegerValueField(ev, kCGMouseEventDeltaX);
    p.y -= CGEventGetIntegerValueField(ev, kCGMouseEventDeltaY);
    os_unfair_lock_lock(&gPosLock);
    gPosRing[gPosHead % POS_RING].ns = nowNs(); gPosRing[gPosHead % POS_RING].before = p; gPosHead++;
    os_unfair_lock_unlock(&gPosLock);
}
static bool auxPosBefore(uint64_t ns, CGPoint *out) {   // the first logged move at/after ns
    bool found = false;
    os_unfair_lock_lock(&gPosLock);
    for (int k = gPosHead - 1; k >= 0 && k >= gPosHead - POS_RING; k--) {
        if (gPosRing[k % POS_RING].ns < ns) break;
        *out = gPosRing[k % POS_RING].before; found = true;
    }
    os_unfair_lock_unlock(&gPosLock);
    return found;
}
/* An aux gesture's key makes apps hide the pointer until the mouse moves (typing), and
   the frozen aux pad's moves never reach them — so it stayed hidden (2026-10-16). A
   zero-distance move, just after the key lands, shows it again where it is. */
// Several times, from just after the key (2026-10-18: one move at 60 ms still showed the
// pointer blinking off) — an app hides it whenever it handles the key, so the soonest
// move after that wins and the later ones catch a slow app.
static void auxShowPointer(void) {
    static const int ms[] = { 10, 25, 50, 100, 200 };
    for (int i = 0; i < (int)(sizeof ms / sizeof *ms); i++)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms[i] * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (atomic_load(&gTyping)) return;   // the right pad types: hidden on purpose
        // Detached, the "current" location is where the aux pad WOULD have put the pointer
        // (2026-10-16: posting there made every left swipe jump) — the visible one is the pin.
        CGPoint p;
        os_unfair_lock_lock(&gPosLock); p = gAuxPin; os_unfair_lock_unlock(&gPosLock);
        if (!gAuxFrozen) {
            CGEventRef e = CGEventCreate(NULL);
            p = e ? CGEventGetLocation(e) : CGPointZero;
            if (e) CFRelease(e);
        }
        CGEventRef m = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
        if (!m) return;
        CGEventSetIntegerValueField(m, kCGEventSourceUserData, OUR_MARK);
        hidPlace(m); CGEventPost(kCGHIDEventTap, m);
        CFRelease(m);
    });
}
// MOUSE CLICKS (2026-10-19): a gesture value "click:[mods+]left|right|middle" clicks
// where the pointer is (the anchor while the aux pad has it frozen). A tap clicks; a
// held gesture presses on its down and releases on its lift. Modifiers go down as real
// keys around the click (apps read the live state, not only the event's flags). Two
// clicks inside the double-click interval at one spot count up (double-click). gAuxQ.
static bool auxClick(NSString *v, int phase, CGEventFlags held) {
    if (![v hasPrefix:@"click:"]) return false;
    NSArray *parts = [[v substringFromIndex:6] componentsSeparatedByString:@"+"];
    NSString *btn = parts.lastObject;
    CGMouseButton b = [btn isEqualToString:@"right"] ? kCGMouseButtonRight
                    : [btn isEqualToString:@"middle"] ? kCGMouseButtonCenter : kCGMouseButtonLeft;
    static const struct { const char *name; CGEventFlags flag; int kc; } MODS[] = {
        { "cmd", kCGEventFlagMaskCommand, 55 }, { "shift", kCGEventFlagMaskShift, 56 },
        { "alt", kCGEventFlagMaskAlternate, 58 }, { "ctrl", kCGEventFlagMaskControl, 59 } };
    CGEventFlags f = held;
    for (NSUInteger i = 0; i + 1 < parts.count; i++)
        for (int j = 0; j < 4; j++) if ([parts[i] isEqualToString:@(MODS[j].name)]) f |= MODS[j].flag;
    CGPoint p;   // the pin while frozen (OWN CURSOR moves it)
    os_unfair_lock_lock(&gPosLock); p = gAuxPin; os_unfair_lock_unlock(&gPosLock);
    if (!gAuxFrozen) { CGEventRef e = CGEventCreate(NULL); p = e ? CGEventGetLocation(e) : CGPointZero; if (e) CFRelease(e); }
    static CGPoint lastAt; static uint64_t lastNs; static int count;
    void (^mods)(bool) = ^(bool down) {
        for (int j = 0; j < 4; j++) {
            if (!(f & MODS[j].flag)) continue;
            CGEventRef k = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)MODS[j].kc, down);
            if (!k) continue;
            CGEventSetType(k, kCGEventFlagsChanged);
            CGEventSetFlags(k, down ? f : 0);
            CGEventSetIntegerValueField(k, kCGEventSourceUserData, OUR_MARK);
            CGEventPost(kCGHIDEventTap, k); CFRelease(k);
        }
    };
    void (^press)(bool) = ^(bool down) {
        CGEventType t = b == kCGMouseButtonRight ? (down ? kCGEventRightMouseDown : kCGEventRightMouseUp)
                      : b == kCGMouseButtonCenter ? (down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp)
                      : (down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp);
        CGEventRef m = CGEventCreateMouseEvent(NULL, t, p, b);
        if (!m) return;
        CGEventSetFlags(m, (CGEventFlags)atomic_load(&gHwFlags) | f);
        CGEventSetIntegerValueField(m, kCGMouseEventClickState, count);
        CGEventSetIntegerValueField(m, kCGEventSourceUserData, OUR_MARK);
        hidPlace(m); CGEventPost(kCGHIDEventTap, m); CFRelease(m);
    };
    if (phase != AG_UP) {
        uint64_t now = nowNs();
        // The tap's own (plain) tap-click is held TAP_CLICK_WAIT_MS: drop it, or it
        // lands after this one and a ⌘-click reads as a plain click (2026-10-19).
        atomic_store(&gPadFireNs, now);
        bool again = now - lastNs < (uint64_t)(NSEvent.doubleClickInterval * 1e9)
                  && fabs(p.x - lastAt.x) < 4 && fabs(p.y - lastAt.y) < 4;
        count = again ? count + 1 : 1;
        lastNs = now; lastAt = p;
        mods(true);
        press(true);
    }
    if (phase != AG_DOWN) {
        press(false);
        mods(false);
    }
    fprintf(stderr, "aux click %s%s at %.0f,%.0f (count %d)\n", v.UTF8String,
            phase == AG_DOWN ? " pressed" : phase == AG_UP ? " released" : "", p.x, p.y, count);
    fflush(stderr);
    return true;
}
static void auxFreeze(bool on) {
    uint64_t gen = atomic_fetch_add(&gAuxFreezeGen, 1) + 1;
    // Free at once when the main pad starts moving; a lift keeps the grace.
    bool grace = !on && atomic_load(&gAuxFingers) == 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, grace ? 150 * NSEC_PER_MSEC : 0),
                   dispatch_get_main_queue(), ^{
        if (atomic_load(&gAuxFreezeGen) != gen || on == gAuxFrozen) return;   // superseded
        if (on) {
            CGEventRef e = CGEventCreate(NULL);
            gAuxAnchor = e ? CGEventGetLocation(e) : CGPointZero;
            if (e) CFRelease(e);
            // Undo what the aux pad moved before a MOTION freeze landed (main pad down,
            // resting). Never for the main pad's lift: that would undo its own moves.
            CGPoint back;
            if (atomic_load(&gMainFingers) > 0 && atomic_load(&gAuxFingers) > 0 && auxMainStill() && auxMoving()
                && auxPosBefore(atomic_load(&gAuxMoveStartNs), &back)) {
                if (atomic_load(&gTrace)) { fprintf(stderr, "trace aux cursor wind back %.0f,%.0f -> %.0f,%.0f\n",
                    gAuxAnchor.x, gAuxAnchor.y, back.x, back.y); fflush(stderr); }
                gAuxAnchor = back;
                CGWarpMouseCursorPosition(back);
            }
        }
        gAuxFrozen = on;
        if (on) {
            os_unfair_lock_lock(&gPosLock); gAuxPin = gAuxAnchor; os_unfair_lock_unlock(&gPosLock);
            CGWarpMouseCursorPosition(gAuxAnchor);   // starts the suppression
        } else if (atomic_load(&gAuxSender)) {   // OWN CURSOR moved the pin: re-attach there
            CGPoint pin;
            os_unfair_lock_lock(&gPosLock); pin = gAuxPin; os_unfair_lock_unlock(&gPosLock);
            // Steering warped every frame, each muting real motion ¼ s — the right pad stalled
            // after every left lift (2026-10-21). A last warp with NO suppression ends it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CGSetLocalEventsSuppressionInterval(0.0);
            CGWarpMouseCursorPosition(pin);
            CGSetLocalEventsSuppressionInterval(0.25);
#pragma clang diagnostic pop
        }
        atomic_store(&gAuxPinned, on);
        // A background process's detach seems not to hold (2026-10-16: fast flicks jumped,
        // then snapped back) — the same connection property that lets it hide the cursor.
        static bool armed = false;
        if (!armed) {
            int cid = _CGSDefaultConnection();
            CGSSetConnectionProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
            armed = true;
        }
        CGError ae = CGAssociateMouseAndMouseCursorPosition(!on);
        if (ae && atomic_load(&gTrace)) { fprintf(stderr, "trace aux cursor associate err %d\n", ae); fflush(stderr); }
        if (atomic_load(&gTrace)) { fprintf(stderr, "trace aux cursor %s (aux=%d moving=%d main=%d still=%d)\n", on ? "frozen" : "free",
            atomic_load(&gAuxFingers), auxMoving(), atomic_load(&gMainFingers), auxMainStill()); fflush(stderr); }
    });
}
// Fingers RESTING on the main pad don't move the pointer, so with the left pad also
// touched any motion is the left pad's (2026-10-16: right fingers held, left still
// moved the cursor). Still = its contacts' centroid hasn't moved for a moment.
static _Atomic uint64_t gMainMoveNs = 0;
static bool auxMainStill(void) {
    return atomic_load(&gMainFingers) == 0 || nowNs() - atomic_load(&gMainMoveNs) > 120ull * 1000000ull;
}
// Fingers RESTING on the aux pad don't move the pointer either, so with the main pad
// touched only aux MOTION needs the freeze — resting left fingers (held Shift / Space)
// never block the right pad (2026-10-16: "should not inhibit at all"). Moving = any
// aux contact faster than 15 mm/s just now (touchCallback); the few pixels before that leak.
static _Atomic uint64_t gAuxMoveNs = 0;
static bool auxMoving(void) {
    return atomic_load(&gAuxFingers) > 0 && nowNs() - atomic_load(&gAuxMoveNs) < 120ull * 1000000ull;
}
// Frozen while ANY finger is on the aux pad — neither pad moves the pointer then
// (2026-10-17, user: replaces "resting left fingers never block the right pad") —
// or while the right pad types. (Detaching whenever the main pad was untouched, and
// pinning on re-attach, broke plain right-pad use — 2026-10-16, reverted.)
// Not while a move_held binding's modifier rests there (gAuxMover, 2026-10-18).
// 2026-10-21 (user: the left pad "only used as a modifier, never moves the cursor", the
// right pad unaffected): with sender IDs the freeze stays on for any left touch, and the
// right pad steers the frozen cursor itself (OWN CURSOR) — so move_held is moot there.
static void auxFreezeUpdate(void) {
    if (atomic_load(&gAuxSender)) { auxFreeze(atomic_load(&gAuxFingers) > 0 || auxRightKbd()); return; }
    auxFreeze((atomic_load(&gAuxFingers) > 0 && !atomic_load(&gAuxMover)) || auxRightKbd());
}

/* OWN CURSOR (2026-10-21). The freeze (detach + pin + the warps' ~¼ s suppression of
   real motion) is what stops the left pad — so while it is touched remapd MOVES THE PIN
   from the right pad's raw contacts (MultitouchSupport), and posts the moves / drags apps
   need. Dead ends it replaces: steering by event deltas (they read 0 while detached) and
   undoing each left move on an attached cursor (every next move built on the uncorrected
   position). Clicks / scrolls from the right pad are relocated to the pin in the tap.
   The FEEL is macOS's own, learnt: while the right pad points natively, its contact's
   path (mm) is paired with the points the cursor moved, per speed bin, and kept in
   ~/Library/Application Support/remapd/pointer_gain.json (log: "own cursor gain"). */
enum { GAIN_BINS = 16 };
static double gainV(int k) { return 2.0 * pow(1.5, k); }   // bin centre, mm/s: 2 … 876
static struct { double g; int n; } gGain[GAIN_BINS];   // points per mm; gGainLock
static double gGainSign[2];   // Σ mm·pt per axis — its sign maps pad axes to screen axes
static bool gGainDirty = false;
static os_unfair_lock gGainLock = OS_UNFAIR_LOCK_INIT;
#define GAIN_FULL 8   // samples before a bin is trusted outright; fewer blend with the default
static double gainDefault(double v) { return 1.5 + 0.08 * v; }   // a guess until learnt
static double gainAt(double v) {
    double lv = log(fmax(v, 1.0) / 2.0) / log(1.5);
    int k0 = (int)floor(lv); double t = lv - k0, g[2];
    os_unfair_lock_lock(&gGainLock);
    for (int j = 0; j < 2; j++) {
        int k = k0 + j < 0 ? 0 : k0 + j >= GAIN_BINS ? GAIN_BINS - 1 : k0 + j;
        double w = fmin(gGain[k].n, GAIN_FULL) / (double)GAIN_FULL;
        g[j] = w * gGain[k].g + (1 - w) * gainDefault(gainV(k));
    }
    os_unfair_lock_unlock(&gGainLock);
    return g[0] * (1 - t) + g[1] * t;
}
static NSString *gainPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/remapd/pointer_gain.json"];
}
static void gainLoad(void) {
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:gainPath()] ?: [NSData data]
                                                      options:0 error:nil];
    if (![d isKindOfClass:NSDictionary.class]) return;
    NSArray *b = d[@"bins"], *s = d[@"sign"];
    os_unfair_lock_lock(&gGainLock);
    for (NSUInteger k = 0; k < b.count && k < GAIN_BINS; k++) {
        gGain[k].g = [b[k][@"g"] doubleValue]; gGain[k].n = [b[k][@"n"] intValue];
    }
    if (s.count == 2) { gGainSign[0] = [s[0] doubleValue]; gGainSign[1] = [s[1] doubleValue]; }
    os_unfair_lock_unlock(&gGainLock);
}
static void gainSave(void) {   // main thread, every 30 s while there is something new
    NSMutableArray *b = [NSMutableArray array]; NSArray *s;
    os_unfair_lock_lock(&gGainLock);
    bool dirty = gGainDirty; gGainDirty = false;
    for (int k = 0; k < GAIN_BINS; k++)
        [b addObject:@{ @"v": @(round(gainV(k))), @"g": @(gGain[k].g), @"n": @(gGain[k].n) }];
    s = @[ @(gGainSign[0]), @(gGainSign[1]) ];
    os_unfair_lock_unlock(&gGainLock);
    if (!dirty) return;
    [NSFileManager.defaultManager createDirectoryAtPath:gainPath().stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:@{ @"bins": b, @"sign": s } options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:gainPath() atomically:YES];
    NSMutableString *line = [NSMutableString string];
    for (NSDictionary *e in b) if ([e[@"n"] intValue]) [line appendFormat:@" %@:%.1f(%@)", e[@"v"], [e[@"g"] doubleValue], e[@"n"]];
    fprintf(stderr, "own cursor gain (mm/s:pt/mm(n))%s  sign %+.0f %+.0f\n", line.UTF8String,
            [s[0] doubleValue], [s[1] doubleValue]); fflush(stderr);
}
// The tap's half of the learning: what the right pad's native moves moved the cursor.
static os_unfair_lock gLearnLock = OS_UNFAIR_LOCK_INIT;
static double gLearnPt, gLearnSx, gLearnSy; static bool gLearnClipped;   // gLearnLock
static bool nearEdge(CGPoint p) {   // a move clipped at a screen edge says nothing about gain
    CGDirectDisplayID d; uint32_t c = 0;
    if (CGGetDisplaysWithPoint(p, 1, &d, &c) != kCGErrorSuccess || !c) return true;
    CGRect r = CGDisplayBounds(d);
    return p.x < r.origin.x + 3 || p.y < r.origin.y + 3 || p.x > CGRectGetMaxX(r) - 4 || p.y > CGRectGetMaxY(r) - 4;
}
static void ownNoteEvent(CGEventRef e) {   // tap thread: a native right-pad move, cursor attached
    double dx = CGEventGetDoubleValueField(e, kCGMouseEventDeltaX), dy = CGEventGetDoubleValueField(e, kCGMouseEventDeltaY);
    bool edge = nearEdge(CGEventGetLocation(e));
    os_unfair_lock_lock(&gLearnLock);
    gLearnPt += hypot(dx, dy); gLearnSx += dx; gLearnSy += dy; gLearnClipped |= edge;
    os_unfair_lock_unlock(&gLearnLock);
}
static CGPoint ownClamp(CGPoint from, CGPoint to) {   // stay on a display: slide along an edge
    CGDirectDisplayID d; uint32_t c = 0;
    CGPoint tries[3] = { to, CGPointMake(to.x, from.y), CGPointMake(from.x, to.y) };
    for (int i = 0; i < 3; i++)
        if (CGGetDisplaysWithPoint(tries[i], 1, &d, &c) == kCGErrorSuccess && c) return tries[i];
    return from;
}
static void ownMove(double dx, double dy) {   // multitouch thread
    CGPoint p, q;
    os_unfair_lock_lock(&gPosLock);
    p = gAuxPin; q = ownClamp(p, CGPointMake(p.x + dx, p.y + dy)); gAuxPin = q;
    os_unfair_lock_unlock(&gPosLock);
    if (q.x == p.x && q.y == p.y) return;
    CGWarpMouseCursorPosition(q);
    // Apps see motion only as events (hover, drags): post one, with whatever button is down.
    CGEventType t = kCGEventMouseMoved; CGMouseButton b = kCGMouseButtonLeft;
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)) t = kCGEventLeftMouseDragged;
    else if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight))
        t = kCGEventRightMouseDragged, b = kCGMouseButtonRight;
    else if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonCenter))
        t = kCGEventOtherMouseDragged, b = kCGMouseButtonCenter;
    CGEventRef m = CGEventCreateMouseEvent(NULL, t, q, b);
    if (!m) return;
    CGEventSetIntegerValueField(m, kCGMouseEventDeltaX, (int64_t)lround(q.x - p.x));
    CGEventSetIntegerValueField(m, kCGMouseEventDeltaY, (int64_t)lround(q.y - p.y));
    CGEventSetFlags(m, (CGEventFlags)atomic_load(&gHwFlags));
    CGEventSetIntegerValueField(m, kCGEventSourceUserData, OUR_MARK);
    hidPlace(m); CGEventPost(kCGHIDEventTap, m);
    CFRelease(m);
}
/* Every right-pad frame (multitouch thread). The driving contact is the lone finger, or
   with a button held (thumb pressing, finger dragging) the one that moved most; two or
   more fingers without a button are a scroll / gesture and move nothing, as in macOS. */
static void ownFrame(const Finger *f, int n, double ts) {
    enum { IDS = 12 };
    static int pid[IDS], pn = 0; static float pxm[IDS], pym[IDS];   // last frame's contacts
    static int lid = -1; static double lts = 0, v = 0;
    static double wMm = 0, wSx = 0, wSy = 0, wT = 0;   // the learning window (mm, pad axes)
    int cn = 0, pick = -1; float best = -1;
    bool button = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)
               || CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight);
    for (int i = 0; i < n; i++) if (f[i].state >= 4 && f[i].state <= 5) cn++;
    for (int i = 0; i < n; i++) {
        if (f[i].state < 4 || f[i].state > 5) continue;
        if (cn == 1) { pick = i; break; }
        if (!button) break;
        float d = 0;
        for (int j = 0; j < pn; j++)
            if (pid[j] == f[i].identifier) d = hypotf(f[i].mm.pos.x - pxm[j], f[i].mm.pos.y - pym[j]);
        if (f[i].identifier == lid) d += 0.05f;   // the driver keeps it when both are still
        if (d > best) { best = d; pick = i; }
    }
    float x = pick >= 0 ? f[pick].mm.pos.x : 0, y = pick >= 0 ? f[pick].mm.pos.y : 0;
    float lx = 0, ly = 0; bool had = false;
    for (int j = 0; pick >= 0 && j < pn; j++)
        if (pid[j] == f[pick].identifier) { lx = pxm[j]; ly = pym[j]; had = true; }
    pn = 0;
    for (int i = 0; i < n && pn < IDS; i++)
        if (f[i].state >= 4 && f[i].state <= 5) { pid[pn] = f[i].identifier; pxm[pn] = f[i].mm.pos.x; pym[pn] = f[i].mm.pos.y; pn++; }
    // Also through the freeze's 150 ms grace after the left pad lifts (2026-10-21: the right
    // pad stalled at every left lift while nothing steered).
    bool steer = atomic_load(&gAuxPinned) && atomic_load(&gAuxSender)
              && !atomic_load(&gMainThumbHold) && !atomic_load(&gMainClaim) && !auxRightKbd();
    double dt = ts - lts;
    bool cont = pick >= 0 && had && f[pick].identifier == lid && dt > 0 && dt < 0.1;
    lid = pick >= 0 ? f[pick].identifier : -1; lts = ts;
    // Learning: one finger, cursor native, a window of ~80 ms of the same contact.
    bool learn = cont && cn == 1 && !atomic_load(&gAuxPinned) && !atomic_load(&gMainThumbHold) && atomic_load(&gAuxSender);
    if (!learn) {
        wMm = wSx = wSy = wT = 0;
        os_unfair_lock_lock(&gLearnLock); gLearnPt = gLearnSx = gLearnSy = 0; gLearnClipped = false; os_unfair_lock_unlock(&gLearnLock);
    }
    if (!cont) { v = 0; return; }
    double dx = x - lx, dy = y - ly, inst = hypot(dx, dy) / dt;
    v = v ? 0.5 * v + 0.5 * inst : inst;
    if (steer) {
        double g = gainAt(v), sx, sy;
        os_unfair_lock_lock(&gGainLock);
        sx = gGainSign[0] >= 0 ? 1 : -1; sy = gGainSign[1] > 0 ? 1 : -1;   // pad y is up, screen y down
        os_unfair_lock_unlock(&gGainLock);
        ownMove(sx * g * dx, sy * g * dy);
        return;
    }
    if (!learn) return;
    wMm += hypot(dx, dy); wSx += dx; wSy += dy; wT += dt;
    if (wT < 0.08) return;
    double pt, psx, psy; bool clipped;
    os_unfair_lock_lock(&gLearnLock);
    pt = gLearnPt; psx = gLearnSx; psy = gLearnSy; clipped = gLearnClipped;
    gLearnPt = gLearnSx = gLearnSy = 0; gLearnClipped = false;
    os_unfair_lock_unlock(&gLearnLock);
    if (!clipped && wMm >= 0.4 && pt > 0) {
        double speed = wMm / wT, ratio = pt / wMm;
        int k = (int)lround(log(fmax(speed, 1.0) / 2.0) / log(1.5));
        k = k < 0 ? 0 : k >= GAIN_BINS ? GAIN_BINS - 1 : k;
        os_unfair_lock_lock(&gGainLock);
        double a = fmax(0.05, 1.0 / (gGain[k].n + 1));
        gGain[k].g = gGain[k].n ? gGain[k].g * (1 - a) + ratio * a : ratio;
        if (gGain[k].n < 1000) gGain[k].n++;
        gGainSign[0] += wSx * psx; gGainSign[1] += wSy * psy;
        gGainDirty = true;
        os_unfair_lock_unlock(&gGainLock);
    }
    wMm = wSx = wSy = wT = 0;
}
// While typing is on the pointer is also HIDDEN ("locked or just disappear", 2026-10-16):
// a background process may hide it only with SetsCursorInBackground on its connection.
// One hide per show, so the count never drifts; WindowServer restores it if we die.
extern int _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(int, int, CFStringRef, CFTypeRef);
static void auxCursorHide(bool hide0) {
    (void)hide0;   // the reasons as they stand when this runs (auxHideWhy), not when asked
    dispatch_async(dispatch_get_main_queue(), ^{
        bool hide = atomic_load(&gHideWhy) != 0;
        static bool hidden = false, armed = false;
        if (hide == hidden) return;
        if (!armed) {
            int cid = _CGSDefaultConnection();
            CGSSetConnectionProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
            armed = true;
        }
        if (hide) CGDisplayHideCursor(kCGNullDirectDisplay); else CGDisplayShowCursor(kCGNullDirectDisplay);
        hidden = hide;
    });
}

static void auxMoverUpdate(void);   // after the resolver
static int touchCallback(MTDeviceRef dev, Finger *f, int n, double ts, int frame) {
    (void)frame;
    bool aux = isAuxDev(dev);
    int was = atomic_exchange(aux ? &gAuxFingers : &gMainFingers, n);
    if (was == 0 && n > 0) atomic_store(&gLastTouchAux, aux);
    if ((was == 0) != (n == 0)) auxFreezeUpdate();   // a pad started or stopped being touched
    if (atomic_load(&gAuxPinned) && !atomic_load(&gMainThumbHold)) {   // the freeze's pin (gAuxPin)
        static _Atomic uint64_t lastPinNs = 0;
        uint64_t t = nowNs();
        if (t - atomic_load(&lastPinNs) >= 50ull * 1000000ull) {   // well inside the ¼ s
            CGPoint pin;
            os_unfair_lock_lock(&gPosLock); pin = gAuxPin; os_unfair_lock_unlock(&gPosLock);
            CGWarpMouseCursorPosition(pin);
            atomic_store(&lastPinNs, t);
        }
    }
    // FLICK HIDE: the right pad landing while the left is held (frozen) — not the left
    // landing on a resting right hand (typing would blink it). Off when either lifts.
    // Not with sender IDs: the right pad steers the frozen cursor then (OWN CURSOR).
    if (!aux && was == 0 && n > 0 && atomic_load(&gAuxFingers) > 0 && !atomic_load(&gAuxMover)
        && !atomic_load(&gAuxSender))
        auxHideWhy(HIDE_FLICK, true);
    if (was > 0 && n == 0) auxHideWhy(HIDE_FLICK, false);
    if (aux && was > 0 && n == 0) atomic_store(&gAuxLiftNs, nowNs());
    if (aux && was == 0 && n > 0) atomic_store(&gAuxTouchNs, nowNs());
    if (atomic_load(&gTrace) && aux && was != n) {
        fprintf(stderr, "trace aux pad %d -> %d\n", was, n); fflush(stderr);
    }
    if (!aux) {   // main pad moving? (auxMainStill) — centroid in mm, re-anchored on a count change
        static float ax, ay; static int an = 0;
        float cx = 0, cy = 0; int cn = 0;
        for (int i = 0; i < n; i++)
            if (f[i].state >= 4 && f[i].state <= 5) { cx += f[i].mm.pos.x; cy += f[i].mm.pos.y; cn++; }
        if (cn) { cx /= cn; cy /= cn; }
        if (cn != an) { ax = cx; ay = cy; an = cn; }
        else if (cn && hypotf(cx - ax, cy - ay) > 0.8f) {
            atomic_store(&gMainMoveNs, nowNs()); ax = cx; ay = cy;
        }
        ownFrame(f, n, ts);   // OWN CURSOR: steer the frozen cursor, or learn the native feel
    } else {   // aux pad moving? (auxMoving) — per contact, so a resting thumb can't mask a sliding finger.
        // By SPEED: a slow drift adds next to nothing to the pointer, so it never freezes
        // ("moving a little bit … won't be a problem", 2026-10-16). Each contact is judged
        // over ~50 ms windows; a quick jump of 1.5 mm counts at once.
        enum { SLOTS = 16 };
        static int ids[SLOTS]; static float px[SLOTS], py[SLOTS], lx[SLOTS], ly[SLOTS];
        static uint64_t pt[SLOTS], lt[SLOTS]; static int used = 0;
        int nid[SLOTS]; float nx[SLOTS], ny[SLOTS], mx[SLOTS], my[SLOTS]; uint64_t nt[SLOTS], mt[SLOTS]; int nn = 0;
        uint64_t now = nowNs();
        for (int i = 0; i < n && nn < SLOTS; i++) {
            if (f[i].state < 4 || f[i].state > 5) continue;
            float x = f[i].mm.pos.x, y = f[i].mm.pos.y; uint64_t t = now;
            int j = 0; while (j < used && ids[j] != f[i].identifier) j++;
            if (j < used) {
                float d = hypotf(x - px[j], y - py[j]);
                double dt = (now - pt[j]) / 1e9;
                // A flick shows in ONE frame: > 80 mm/s since the last frame (2026-10-16: small moves leaked).
                double fdt = (now - lt[j]) / 1e9;
                bool flick = fdt > 0.002 && hypotf(f[i].mm.pos.x - lx[j], f[i].mm.pos.y - ly[j]) / fdt > 80.0;
                if (flick || d > 1.5f || (dt >= 0.05 && d / dt > 15.0)) {   // > 15 mm/s
                    if (!auxMoving()) atomic_store(&gAuxMoveStartNs, pt[j]);
                    atomic_store(&gAuxMoveNs, now);
                }
                if (d <= 1.5f && dt < 0.05) { x = px[j]; y = py[j]; t = pt[j]; }   // window still open
            }
            nid[nn] = f[i].identifier; nx[nn] = x; ny[nn] = y; nt[nn] = t;
            mx[nn] = f[i].mm.pos.x; my[nn] = f[i].mm.pos.y; mt[nn] = now; nn++;
        }
        memcpy(ids, nid, sizeof(int) * nn); memcpy(px, nx, sizeof(float) * nn);
        memcpy(py, ny, sizeof(float) * nn); memcpy(pt, nt, sizeof(uint64_t) * nn);
        memcpy(lx, mx, sizeof(float) * nn); memcpy(ly, my, sizeof(float) * nn); memcpy(lt, mt, sizeof(uint64_t) * nn);
        used = nn;
    }
    {   // the freeze follows either pad going still / moving
        static _Atomic bool lastStill = true, lastAuxMoving = false;
        bool still = auxMainStill(), moving = auxMoving();
        bool flip = atomic_exchange(&lastStill, still) != still;
        flip |= atomic_exchange(&lastAuxMoving, moving) != moving;
        if (flip && atomic_load(&gAuxFingers) > 0) auxFreezeUpdate();
    }
    // Both pads feed their recogniser (the right one types only under its held thumb).
    struct { AgContact c[AG_MAX]; int n; } fr = { .n = 0 };   // a struct: blocks copy it whole
    for (int i = 0; i < n && fr.n < AG_MAX; i++)
        if (f[i].state >= 4 && f[i].state <= 5)   // make-touch / touching, not hover or lift
            fr.c[fr.n++] = (AgContact){ f[i].identifier, f[i].normalized.pos.x, f[i].normalized.pos.y,
                                        f[i].majorAxis, f[i].minorAxis, f[i].angle, f[i].size };
    // A whole hand on the main pad (spread5 / pinch5 = typing on / off): its system
    // gesture events are dropped (tapCallback) until the hand is off, or the Dock
    // reads the pinch as Apps / Launchpad (2026-10-16).
    if (!aux) {
        static bool hand = false;
        if (n >= 4) hand = true;
        if (hand) atomic_store(&gMainHandNs, nowNs());
        if (n == 0) hand = false;
    }
    // A PINCH is told from a two-finger scroll by how it LANDS (2026-10-18): thumb and
    // forefinger come down wide apart and one above the other; scrolling fingers land
    // side by side, close. Judged once, on the first frame with two contacts; a pinch's
    // scroll (and magnify) is then dropped until the pad is clear (mainPinchScroll).
    if (!aux) {
        static bool judged = false;
        if (n == 0) { judged = false; atomic_store(&gMainPinch, false); }
        int li[2], ln = 0;
        for (int i = 0; i < n && ln < 3; i++) if (f[i].state >= 4 && f[i].state <= 5) { if (ln < 2) li[ln] = i; ln++; }
        // Two contacts close together are two fingers (a scroll), never thumb + finger:
        // a resting thumb sits ≥ 44 mm from the nearest finger in every thumbtap
        // calibration, scroll fingers land 17–29 mm apart (2026-10-18). Without this a
        // staggered landing read the first finger as a thumb and dropped the scroll whole.
        atomic_store(&gMainTwoClose, ln == 2 && hypotf(f[li[1]].mm.pos.x - f[li[0]].mm.pos.x,
                                                       f[li[1]].mm.pos.y - f[li[0]].mm.pos.y) < TWO_FINGERS_MM);
        if (!judged && ln == 2) {
            judged = true;
            float dx = f[li[1]].mm.pos.x - f[li[0]].mm.pos.x, dy = f[li[1]].mm.pos.y - f[li[0]].mm.pos.y;
            float d = hypotf(dx, dy), ang = atan2f(fabsf(dy), fabsf(dx)) * 180.0f / (float)M_PI;
            bool pinch = d >= PINCH_LAND_MM || (d >= PINCH_LAND_MM_UPRIGHT && ang >= PINCH_LAND_DEG);
            if (pinch) { atomic_store(&gMainPinch, true); atomic_store(&gMainPinchNs, nowNs()); }
            fprintf(stderr, "main land2 %.0fmm %.0f° → %s\n", d, ang, pinch ? "pinch (scroll dropped)" : "scroll");
            fflush(stderr);
        }
        if (atomic_load(&gMainPinch)) atomic_store(&gMainPinchNs, nowNs());
    }
    double now = (double)nowNs() / 1e9;
    int pad = aux ? PAD_LEFT : PAD_RIGHT;
    dispatch_async(gAuxQ, ^{
        auxTick(pad, auxgestFrame(&gGest[pad], fr.c, fr.n, now));
        if (pad == PAD_LEFT) auxMoverUpdate();
        else {   // A CLAIMED touch (THE CLAIM) or reanchor's pin: freeze (gMainThumbHold)
            const AuxGest *rg = &gGest[PAD_RIGHT];
            int thumbId = atomic_load(&gCalib) ? -1 : auxgestThumbRestId(rg);
            bool thumb = thumbId >= 0;
            static bool toldTwo = false;   // logged once per close pair
            if (!atomic_load(&gMainTwoClose)) toldTwo = false;
            if (thumb && !atomic_load(&gMainThumbHold) && atomic_load(&gMainTwoClose)) {
                if (!toldTwo) {
                    toldTwo = true;
                    fprintf(stderr, "aux right: \"thumb\" is a finger beside another (two fingers close) — not a thumb\n"); fflush(stderr);
                }
                thumb = false;
            }
            if (thumb && !atomic_load(&gMainThumbHold) && atomic_load(&gScrollLive)
                && nowNs() - atomic_load(&gScrollBeganNs) > SCROLL_OWNS_NS) {
                static uint64_t said = 0;   // once per scroll
                if (said != atomic_load(&gScrollBeganNs)) {
                    said = atomic_load(&gScrollBeganNs);
                    fprintf(stderr, "aux right: thumb read mid-scroll — ignored, the scroll keeps going\n"); fflush(stderr);
                }
                thumb = false;
            }
            // Judged when a contact lands, the thumb is read or the left pad's resting
            // count changes; kept while contacts only lift (sticky: "the mouse flies around").
            int live = 0;
            for (int i = 0; i < rg->n; i++) live += rg->t[i].live;
            int still = auxLeftHold(now);
            static int jLive = 0, jStill = 0; static bool jThumb = false;
            bool claim = atomic_load(&gMainClaim);
            char why[48] = "";
            // THE THUMB LATCH (2026-10-20, user: "as soon as it detects the thumb is on the
            // trackpad, halt all movement" — the fingers joining it swiped the pointer about
            // before the claim was judged). Seen resting by fingers, the pointer freezes
            // whatever is bound, and stays frozen until the pad is clear — already pinned
            // when the fingers land, so the tap drops their first move too. Never for a
            // contact ALONE (lone thumb retired 2026-10-29: lone fingers read as the thumb).
            static bool thumbLatch = false;
            bool off = live == 0 || atomic_load(&gMainFingers) == 0 || atomic_load(&gCalib) || atomic_load(&gOff) || auxRightKbd();
            if (off) thumbLatch = false;
            else if (!thumbLatch && thumb) {
                thumbLatch = true;
                int a = agFind(rg, thumbId);
                fprintf(stderr, "aux right: thumb down (by fingers, shape %+.0f) → pointer held till the pad is clear\n",
                        a >= 0 && rg->print ? agTrackScore(rg->print, &rg->t[a]) : 0.0f); fflush(stderr);
            }
            if (thumbLatch && atomic_load(&gMainTwoClose) && !thumb) {   // two fingers close = a scroll after all
                thumbLatch = false;
                atomic_store(&gMainThumbSess, false);
                fprintf(stderr, "aux right: thumb latch dropped — two fingers close (a scroll)\n"); fflush(stderr);
            }
            if (off) claim = false, live = 0, thumb = false, still = 0;
            else if (live > jLive || (thumb && !jThumb) || still != jStill) {
                claim = auxRightClaims(thumb, live - (thumb ? 1 : 0), still, why, sizeof why);
                // Fingers landing further apart than AG_LAND_SPREAD are no one swipe (the lift
                // says the same, agName): a thumb joining a 3-finger orbit, or a third finger
                // joining thumb + 2, reads as 4 fingers (no rest-thumb: it landed late) and
                // claimed up4 — reanchor's zoom held dead (2026-10-29).
                if (claim && !thumb && live >= 2) {
                    double first = 1e18, last = 0;
                    for (int i = 0; i < rg->n; i++) if (rg->t[i].live) {
                        first = fmin(first, rg->t[i].t0); last = fmax(last, rg->t[i].t0);
                    }
                    if (last - first > AG_LAND_SPREAD) {
                        claim = false;
                        fprintf(stderr, "aux right: %s not claimed — landed over %.0f ms, no one swipe\n",
                                why, (last - first) * 1000); fflush(stderr);
                    }
                }
            }
            // RESTING SECTIONS: fingers landing by fingers already resting here (auxgest
            // agRestOf) — claimed when anything their count could do there is bound: up / down /
            // tap with that many (two+: pinch / spread), or (one) the thumb's swipes and tap (2026-10-21).
            // The thumb + fingers resting (2026-10-29): restthumb<f>:up / down / tap<m> only.
            int movers = 0;
            bool restThumb = false;
            int rested = claim || live <= jLive ? 0 : auxgestRestSplit(rg, &movers, &restThumb);
            static const char *const restG[] = { "up", "down", "tap", "pinch", "spread", "thumbswipeL", "thumbswipeR", "thumbtap" };
            for (int d = 0; rested && d < (restThumb ? 3 : 8) && !claim; d++) {
                char nm[40];
                if (restThumb) { if (rested + movers > 5) break; snprintf(nm, sizeof nm, "restthumb%d:%s%d", rested - 1, restG[d], movers); }
                else if (d < 5) { if (rested + movers > (d >= 3 ? 5 : 4) || (d >= 3 && movers < 2)) continue; snprintf(nm, sizeof nm, "rest%d:%s%d", rested, restG[d], movers); }
                else { if (movers != 1) break; snprintf(nm, sizeof nm, "rest%d:%s", rested, restG[d]); }
                if (auxRestBound(PAD_RIGHT, nm)) { claim = true; snprintf(why, sizeof why, "%s", nm); }
            }
            if (rested && (movers == 2 || movers == 3) && !claim && rested + movers <= (restThumb ? 5 : 4)) {   // tap2 / tap3's roll twins (2026-10-29)
                char nm[40];
                if (restThumb) snprintf(nm, sizeof nm, "restthumb%d:rollL%d", rested - 1, movers); else snprintf(nm, sizeof nm, "rest%d:rollL%d", rested, movers);
                if (auxRestBound(PAD_RIGHT, nm)) { claim = true; snprintf(why, sizeof why, "%s", nm); }
            }
            jLive = live; jThumb = thumb; jStill = still;
            if (claim != atomic_load(&gMainClaim)) {
                atomic_store(&gMainClaim, claim);
                claimPublish(claim);
                fprintf(stderr, "aux right: %s\n", claim ? [NSString stringWithFormat:@"claimed by %s — nothing sent", why].UTF8String
                                                          : "unclaimed"); fflush(stderr);
            }
            bool hold = claim;
            CGPoint rpAt;
            uint64_t rp = reanchorPin(&rpAt);
            bool rpOurs = pinword_ours(rp) && atomic_load(&gMainFingers) > 0;   // reanchor's touch: its pin or none
            if (thumbLatch && !rpOurs) hold = true;
            if (rpOurs && pinword_pinned(rp)) {
                hold = true;
                os_unfair_lock_lock(&gPosLock); gThumbPin = rpAt; os_unfair_lock_unlock(&gPosLock);
            }
            if (hold && !atomic_load(&gMainThumbHold)) {
                // From the first landing (a thumb told by shape is known some frames in).
                double land = now - 0.03;
                const AuxGest *rg = &gGest[PAD_RIGHT];
                for (int i = 0; i < rg->n; i++) if (rg->t[i].live && rg->t[i].t0 - 0.01 < land) land = rg->t[i].t0 - 0.01;
                atomic_store(&gMainThumbNs, (uint64_t)(land * 1e9));
                if (live >= 2 || claim || rpOurs) atomic_store(&gMainThumbSess, true);   // a lone thumb still clicks
                // PINNED where it was before the fingers joined (what they moved since, undone).
                CGPoint back;
                if (rpOurs) back = rpAt;
                // Steered by OWN CURSOR: the visible spot is the pin (the logged moves are hidden ones).
                else if (atomic_load(&gAuxPinned) && atomic_load(&gAuxSender)) {
                    os_unfair_lock_lock(&gPosLock); back = gAuxPin; os_unfair_lock_unlock(&gPosLock);
                }
                else if (!auxPosBefore(atomic_load(&gMainThumbNs), &back)) {
                    CGEventRef e = CGEventCreate(NULL);
                    back = e ? CGEventGetLocation(e) : CGPointZero;
                    if (e) CFRelease(e);
                }
                os_unfair_lock_lock(&gPosLock); gThumbPin = back; os_unfair_lock_unlock(&gPosLock);
                atomic_store(&gMainThumbHold, true);   // before the warp: its own move must be pinned too
                CGWarpMouseCursorPosition(back);
            }
            // Every frame: back to the pin if anything got through — and at least every
            // 100 ms anyway: a warp makes macOS ignore the pad's moves for ~¼ s, so warping
            // before that runs out means it never draws one (2026-10-18: macOS draws each
            // move before the tap can warp it back — the pointer flashed far off — except in
            // the first ¼ s after the session's own warp, which was "perfect").
            static double lastWarp = 0;
            if (hold) {
                CGEventRef e = CGEventCreate(NULL);
                CGPoint c = e ? CGEventGetLocation(e) : CGPointZero, pin;
                if (e) CFRelease(e);
                os_unfair_lock_lock(&gPosLock); pin = gThumbPin; os_unfair_lock_unlock(&gPosLock);
                if (fabs(c.x - pin.x) + fabs(c.y - pin.y) >= 1 || now - lastWarp >= 0.1) {
                    CGWarpMouseCursorPosition(pin);
                    lastWarp = now;
                }
            }
            if (hold && live >= 2 && !atomic_load(&gMainThumbSess)) atomic_store(&gMainThumbSess, true);   // fingers joined the thumb
            static bool wasHold = false;
            atomic_store(&gMainThumbHold, hold);
            if (wasHold != hold) {
                wasHold = hold;
                fprintf(stderr, "aux right: thumb down + fingers → pointer %s\n", hold ? "frozen" : "free"); fflush(stderr);
                if (!hold && !gAuxFrozen) CGAssociateMouseAndMouseCursorPosition(true);   // ends the warp's event suppression
            }
        }
    });
    // The aux pad is a keyboard, never the `fingers` axis: a resting thumb read as
    // "1 finger" would fire every finger-chord binding. Nor is the right pad while it types.
    if (aux) return 0;
    if (auxRightKbd()) n = 0;
    int prev = atomic_exchange(&gFingers, n);
    if (prev != n && atomic_load(&gTrace)) {
        char st[64] = ""; for (int i = 0; i < n && i < 10; i++) sprintf(st + strlen(st), "%d", f[i].state);
        fprintf(stderr, "trace fingers %d -> %d  states=%s  t=%llums\n", prev, n, st,
                (unsigned long long)(nowNs() / 1000000)); fflush(stderr);
    }
    if (was > 0 && n == 0) atomic_store(&gLiftNs, nowNs());
    else if (was == 0 && n > 0) { atomic_store(&gClickGuard, false); atomic_store(&gMainThumbSess, false); }   // a new touch
    atomic_store(&gFingersNs, nowNs());
    return 0;
}
static void mtMatched(void *cb, io_iterator_t it) {
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        MTDeviceRef dev = MTDeviceCreateFromService(s);
        if (dev) {
            if (auxpadClassify(dev, "remapd")) {
                uint64_t id = auxpadID(dev), rid = 0;
                if (IORegistryEntryGetRegistryEntryID(s, &rid) == KERN_SUCCESS) {   // its events' sender (SENDER_FIELD)
                    atomic_store(&gAuxSender, rid);
                    fprintf(stderr, "remapd: aux pad sends as 0x%llx\n", (unsigned long long)rid); fflush(stderr);
                }
                int n = atomic_load(&gAuxCount), i = 0;
                while (i < n && gAuxIds[i] != id) i++;
                if (i < n) {   // re-matched: the new ref replaces the stale one
                    MTDeviceRef old = atomic_exchange(&gAuxDevs[i], dev);
                    if (old && old != dev) MTDeviceStop(old);
                } else if (n < AUX_MAX) {
                    gAuxIds[n] = id;
                    atomic_store(&gAuxDevs[n], dev);
                    atomic_fetch_add(&gAuxCount, 1);
                } else { fprintf(stderr, "remapd: aux table full, id=%llu not tracked\n", (unsigned long long)id); fflush(stderr); }
            }
            MTRegisterContactFrameCallback(dev, (MTContactCallbackFunction)cb);
            MTDeviceStart(dev, 0);
        }
        IOObjectRelease(s);
    }
}

/* ── The aux pad's pointer ────────────────────────────────────────────────────
   macOS events carry no device, so "from the aux pad" is read off the touch
   streams: the aux pad has fingers and the main pad has none. Its lift gets a
   short grace (a tap-click and the last move land after the frame that lifts),
   and momentum scrolling — which runs on for a second after any lift — is the
   aux pad's whenever the newest touch was. A swallowed down owns its drags/up. */
/* A THUMB-DOWN TAP on the right pad is a gesture (right_thumb: Wispr Flow…), but macOS
   tap-to-clicks it too — at the fingers' lift, before the gesture is decided. So a
   click is the thumb gesture's, and dropped, when the right pad has a thumb (held, or
   told by place / shape among the tracks) and every other finger has already lifted:
   a tap, not a press (a physical click comes with the finger still down). A lone
   contact's click always passes (lone thumb taps retired 2026-10-29). Tap thread. */
#define AUX_RCLICK_SYNC 0.025   // a 2-finger tap's fingers land at most this far apart (s);
                                // 12 ms dropped ~40% of real right-clicks (landings one
                                // frame apart read 14–17 ms, 2026-10-18)
static bool auxRightThumbClick(bool right) {
    if (atomic_load(&gMainFingers) == 0 && nowNs() - atomic_load(&gLiftNs) > AUX_LIFT_GRACE_NS) return false;
    __block bool eat = false;
    dispatch_sync(gAuxQ, ^{
        const AuxGest *g = &gGest[PAD_RIGHT];
        if (g->n < 2) return;
        if (agRollTap(g)) { eat = true; return; }   // a roll is no 2-finger tap (2026-10-17)
        // A RIGHT-CLICK needs its fingers down TOGETHER (2026-10-18: rolls still
        // right-clicked — the click can beat the last lift, so agRollTap above, which
        // waits for every lift, never fired). Landings more than AUX_RCLICK_SYNC apart
        // = no right-click, unless it is a real press (fingers still down long after).
        if (right) {
            double first = 1e18, last = -1e18; bool allLive = true;
            for (int i = 0; i < g->n; i++) {
                first = fmin(first, g->t[i].t0); last = fmax(last, g->t[i].t0);
                allLive &= g->t[i].live;
            }
            double now = (double)nowNs() / 1e9, spread = last - first;
            bool press = allLive && now - last > AG_TAP_S;
            fprintf(stderr, "aux right: right-click, %d fingers landed %.0f ms apart%s → %s\n", g->n, spread * 1000,
                    press ? " (press)" : "", !press && spread > AUX_RCLICK_SYNC ? "dropped" : "kept");
            fflush(stderr);
            if (!press && spread > AUX_RCLICK_SYNC) { eat = true; return; }
        }
        AgTrack t[AG_MAX]; int k = g->n;
        for (int i = 0; i < k; i++) t[i] = g->t[i];
        int ti = agThumbOf(g, t, k);
        if (ti < 0) return;
        for (int i = 0; i < k; i++) if (i != ti && t[i].live) return;
        eat = true;
    });
    if (eat) { fprintf(stderr, "aux right: thumb gesture / roll tap-click dropped\n"); fflush(stderr); }
    return eat;
}
static bool gAuxEatingButton = false;   // tap thread only
static bool isMove(CGEventType t) {
    return t == kCGEventMouseMoved || t == kCGEventLeftMouseDragged
        || t == kCGEventRightMouseDragged || t == kCGEventOtherMouseDragged;
}

static bool auxOwnsEvent(CGEventType type, CGEventRef ev) {
    if (!atomic_load(&gAuxCount)) return false;
    if (CGEventGetIntegerValueField(ev, kCGEventSourceUserData) == OUR_MARK) return false;
    if (auxSent(ev)) return true;   // the left pad never points, scrolls, clicks or gestures
    bool down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
    bool up   = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
    bool drag = type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged;
    if (gAuxEatingButton && (up || drag)) { if (up) gAuxEatingButton = false; return true; }
    if (auxRightKbd()) { if (down) gAuxEatingButton = true; return true; }   // the right pad is typing
    if (down && auxRightThumbClick(type == kCGEventRightMouseDown)) { gAuxEatingButton = true; return true; }   // a thumb-down tap's click
    // Calibrating (bin/thumbprint): the pointer still moves, but nothing clicks,
    // scrolls or gestures — a prompted tap must not land on a window.
    if (atomic_load(&gCalib) && type != kCGEventMouseMoved) { if (down) gAuxEatingButton = true; return true; }
    // Main pad touched: with the aux pad touched too, nothing but clicks goes through —
    // no move, drag, scroll or gesture (the pointer is frozen, auxFreezeUpdate; 2026-10-18,
    // user: "any fingers on the left trackpad, scrolling and dragging doesn't work").
    // A thumb-down session's swipe coasting on after the lift: no momentum scroll.
    if (type == kCGEventScrollWheel && atomic_load(&gMainThumbSess)) return true;
    if (atomic_load(&gMainFingers) > 0) {
        if (atomic_load(&gMainThumbHold)) return !(down || up || type == 34);   // thumb down + fingers: no moves / scrolls
        // Sender known: the right pad works with the left touched (2026-10-21) — its clicks
        // and scrolls pass here, its motion is OWN CURSOR's (the tap, ownFrame).
        if (atomic_load(&gAuxSender)) return false;
        // A move_held modifier resting there: the right pad's moves and drags go through.
        if (atomic_load(&gAuxFingers) > 0 && atomic_load(&gAuxMover) && (drag || type == kCGEventMouseMoved)) return false;
        if (atomic_load(&gAuxFingers) > 0) return !(down || up || type == 34);   // 34 = pressure (force click)
        return false;
    }
    if (atomic_load(&gAuxSender)) return false;   // not the left pad's (auxSent above)
    bool owns = atomic_load(&gAuxFingers) > 0
             || nowNs() - atomic_load(&gAuxLiftNs) < AUX_LIFT_GRACE_NS
             || (type == kCGEventScrollWheel && atomic_load(&gLastTouchAux)
                 && CGEventGetIntegerValueField(ev, kCGScrollWheelEventMomentumPhase) != 0);
    if (owns && down) gAuxEatingButton = true;
    return owns;
}
static void startMultitouchHotplug(MTContactCallbackFunction cb) {
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
    io_iterator_t it;
    if (IOServiceAddMatchingNotification(port, kIOMatchedNotification,
            IOServiceMatching("AppleMultitouchDevice"), mtMatched, (void *)cb, &it)
        == KERN_SUCCESS)
        mtMatched((void *)cb, it);   // drain the connected device(s) AND arm future arrivals
}

/* ── The latch ───────────────────────────────────────────────────────────────
   One slot per physical keycode. See the header: the down decides, the up and
   every autorepeat replay it, so a chord cannot change shape under the hand when
   the finger lifts mid-press. */
// `added`: modifiers the output carries that were not physically held at the down
// (`held`) — a latch with any is posted by postChordHalf, not rewritten in place.
// `posted`: the same, for a down there was no event to rewrite (the letter hold
// decides after the key went down): its repeats are rewritten, its up is posted.
typedef struct { bool active, swallow; int toKey; CGEventFlags toFlags; int repeat;
                 CGEventFlags added, held; bool posted, quiet;
                 bool hasThen; int thenKey; CGEventFlags thenFlags;
                 bool tap;            // tap: a `repeating` rule, posted like a burst
                 bool lineStop; } Latch;
static Latch gLatch[128];

static void applyLatch(CGEventRef e, Latch *l) {
    if (l->toKey >= 0)
        CGEventSetIntegerValueField(e, kCGKeyboardEventKeycode, l->toKey);
    CGEventFlags f = CGEventGetFlags(e);
    f = (f & ~MODMASK) | l->toFlags;
    CGEventSetFlags(e, f);
}

/* ── THE HUD ──────────────────────────────────────────────────────────────────
   Control Room's Show Name on HUD (remap/index.js § SHOW NAME ON HUD, 2026-10-29): a
   command ticked there flashes its Control Room name at the bottom middle (~/bin/hud)
   when it runs. remap/hud.json (compiled by the page, server.py hud_set) says what to
   watch for: {apps: {<page app>: [{label, apps, chord} | {label, run} | {label, chain}]}}.
   A chord is the one the app RECEIVES, so it is matched after this tap and Karabiner
   have both had the key — a listen-only tap at the annotated session point (hudTap):
   a plain key, a finger layer's rewrite and a gesture's posted chord all land there
   alike. A run line or a sequence never reaches an app: runShell and startChain ask
   directly. Worker loads; tap thread reads, under gLock. */
#define HUD_MODS (kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)
static NSArray<NSDictionary *> *gHudChords = nil;   // {apps, kc, flags, label}
static NSDictionary<NSString *, NSString *> *gHudRuns = nil, *gHudChains = nil;
static CFMachPortRef gHudTap = NULL;

static void hudLoad(void) {
    NSDictionary *doc = readJSON([gDir stringByAppendingPathComponent:@"hud.json"]);
    NSDictionary *pages = [doc[@"apps"] isKindOfClass:NSDictionary.class] ? doc[@"apps"] : @{};
    NSMutableArray *chords = [NSMutableArray array];
    NSMutableDictionary *runs = [NSMutableDictionary dictionary], *chains = [NSMutableDictionary dictionary];
    for (NSString *page in pages) {
        if (![pages[page] isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *e in pages[page]) {
            if (![e isKindOfClass:NSDictionary.class] || ![e[@"label"] isKindOfClass:NSString.class]) continue;
            if ([e[@"run"] isKindOfClass:NSString.class]) runs[e[@"run"]] = e[@"label"];
            else if ([e[@"chain"] isKindOfClass:NSString.class]) chains[e[@"chain"]] = e[@"label"];
            else if ([e[@"chord"] isKindOfClass:NSString.class]) {
                int kc; CGEventFlags f;
                if (!compileChord(e[@"chord"], &kc, &f)) continue;
                NSArray *on = [e[@"apps"] isKindOfClass:NSArray.class] ? e[@"apps"] : @[@"*"];
                [chords addObject:@{@"apps": on, @"kc": @(kc), @"flags": @(f & HUD_MODS), @"label": e[@"label"]}];
            }
        }
    }
    os_unfair_lock_lock(&gLock);
    gHudChords = chords; gHudRuns = runs; gHudChains = chains;
    os_unfair_lock_unlock(&gLock);
    fprintf(stderr, "hud.json: %lu chords, %lu runs, %lu sequences\n",
            (unsigned long)chords.count, (unsigned long)runs.count, (unsigned long)chains.count);
    fflush(stderr);
}

static void hudShow(NSString *label) {
    if (!label.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/Users/josh/bin/hud"];
        t.arguments = @[@"show", label, @"--ms", @"900"];
        @try { [t launchAndReturnError:nil]; } @catch (__unused id e) {}
    });
}

// A run line / a sequence id: its name, if ticked. Any thread.
static void hudFor(bool chain, NSString *key) {
    if (!key) return;
    os_unfair_lock_lock(&gLock);
    NSString *label = (chain ? gHudChains : gHudRuns)[key];
    os_unfair_lock_unlock(&gLock);
    hudShow(label);
}

static CGEventRef hudTapCallback(CGEventTapProxy proxy, CGEventType type,
                                 CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gHudTap) CGEventTapEnable(gHudTap, true);
        return event;
    }
    if (type != kCGEventKeyDown || CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return event;
    int kc = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags f = CGEventGetFlags(event) & HUD_MODS;
    NSString *label = nil;
    os_unfair_lock_lock(&gLock);
    for (NSDictionary *e in gHudChords) {
        if ([e[@"kc"] intValue] != kc || [e[@"flags"] unsignedLongLongValue] != f) continue;
        for (NSString *a in e[@"apps"])
            if ([a isEqualToString:@"*"] || (gApps[a] && foldApp(gFrontBundle, gFrontName, @{a: gApps[a]}))) { label = e[@"label"]; break; }
        if (label) break;
    }
    os_unfair_lock_unlock(&gLock);
    // A plain (or shifted) key into a text field is typing, not the command.
    if (label && !(f & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)) && auxTextFocused())
        return event;
    hudShow(label);
    return event;
}

static void runShell(NSString *cmd) {
    hudFor(false, cmd);
    // Off the tap thread, always. A spawn here would be measured in milliseconds
    // and the tap budget is not.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // `bash -c`, not `-lc`: a login shell sources the profile on every key
        // (~30ms of a slot jump, 2026-10-10). What the profile was for — finding
        // Homebrew / ~/bin tools by bare name — is given here as PATH instead.
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
        t.arguments = @[@"-c", cmd];
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
        env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        t.environment = env;
        @try { [t launchAndReturnError:nil]; } @catch (__unused id e) {}
    });
}

// `n` down/up pairs of `key`, posted at the session tap, which is below this tap
// and above the apps: Karabiner never sees them (it reads devices, not the
// session), so the swap cannot turn them into anything else, and the mark keeps
// this tap from resolving its own output.
static void postKey(int key, CGEventFlags flags, int n) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    for (int i = 0; i < n; i++) {
        CGEventRef d = CGEventCreateKeyboardEvent(src, key, true);
        CGEventRef u = CGEventCreateKeyboardEvent(src, key, false);
        CGEventSetFlags(d, flags); CGEventSetFlags(u, flags);
        CGEventSetIntegerValueField(d, kCGEventSourceUserData, OUR_MARK);
        CGEventSetIntegerValueField(u, kCGEventSourceUserData, OUR_MARK);
        CGEventPost(kCGSessionEventTap, d);
        CGEventPost(kCGSessionEventTap, u);
        CFRelease(d); CFRelease(u);
    }
    if (src) CFRelease(src);
}

// `lines: "stop"` (the word moves): a word jump never runs through a line break.
// ⌥← then ← from the first word on a line landed at the end of the line above; now
// it stops at the line's start, and only a press AT the start crosses — one
// character, to the end of the line above. Same for ⌥→ (stops at the line's end)
// and ⌥⌫ then ⌫. Spaces and punctuation are still skipped. Read live from the
// focused text over AX — the caret and up to 256 characters on the side it moves;
// unreadable (Fusion, a canvas) or a selection = the plain jump. Word characters
// are guessed (letters, digits, _ and an apostrophe), only to tell where ⌥ lands.
static bool isLineBreak(unichar c) { return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029; }
static bool isWordChar(unichar c) {
    return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c]
        || c == '_' || c == '\'' || c == 0x2019;
}

// The focused text on one side of a collapsed caret. nil = unreadable.
static NSString *caretSide(bool back) {
    pid_t pid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    AXUIElementRef app = pid > 0 ? AXUIElementCreateApplication(pid) : NULL;
    CFTypeRef focused = NULL;
    if (app) {
        AXUIElementSetMessagingTimeout(app, 0.1);
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
        CFRelease(app);
    }
    if (!focused) return nil;
    AXUIElementRef el = (AXUIElementRef)focused;
    AXUIElementSetMessagingTimeout(el, 0.1);
    NSString *out = nil;
    CFTypeRef sel = NULL, cnt = NULL, str = NULL;
    CFRange r;
    if (AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute, &sel) == kAXErrorSuccess && sel
        && AXValueGetValue((AXValueRef)sel, kAXValueTypeCFRange, &r) && r.length == 0) {
        CFRange want;
        if (back) {
            want.location = MAX(0, r.location - 256);
            want.length = r.location - want.location;
        } else {
            CFIndex total = -1;
            if (AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute, &cnt) == kAXErrorSuccess
                && cnt && CFGetTypeID(cnt) == CFNumberGetTypeID())
                CFNumberGetValue(cnt, kCFNumberCFIndexType, &total);
            if (total >= r.location) {
                want.location = r.location;
                want.length = MIN(256, total - r.location);
            } else want.length = -1;
        }
        if (want.length == 0) out = @"";
        else if (want.length > 0) {
            AXValueRef wv = AXValueCreate(kAXValueTypeCFRange, &want);
            if (AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute, wv, &str)
                    == kAXErrorSuccess && str && CFGetTypeID(str) == CFStringGetTypeID())
                out = [(__bridge NSString *)str copy];
            CFRelease(wv);
        }
    }
    if (sel) CFRelease(sel);
    if (cnt) CFRelease(cnt);
    if (str) CFRelease(str);
    CFRelease(focused);
    return out;
}

static bool isBlank(unichar c) { return c == ' ' || c == '\t' || c == 0xA0; }

// ⌥⌫ then ⌫ (word.delete): delete the word at / before the caret with the blanks
// round it, then leave ONE space if text remains on both sides. ⌥⌫ already eats the
// blanks after a word, so the plain pair ate both spaces. Returns false = no AX text.
static bool wholeWordDelete(void) {
    NSString *s = caretSide(true), *f = caretSide(false);
    if (!s.length || !f) return false;
    NSInteger n = s.length, fn = f.length, i, j, k, m = 0;
    for (i = n; i > 0 && isBlank([s characterAtIndex:i - 1]); i--) ;
    for (j = i; j > 0 && isWordChar([s characterAtIndex:j - 1]); j--) ;
    if (j == i) return false;                           // no word behind: old pair
    for (k = j; k > 0 && isBlank([s characterAtIndex:k - 1]); k--) ;
    if (i == n) for (; m < fn && isWordChar([f characterAtIndex:m]); m++) ;   // caret mid-word
    for (; m < fn && isBlank([f characterAtIndex:m]); m++) ;
    bool left = k > 0 && !isLineBreak([s characterAtIndex:k - 1]);
    bool right = m < fn && !isLineBreak([f characterAtIndex:m]);
    postKey(51, 0, (int)(n - k));
    if (m) postKey(117, 0, (int)m);
    if (left && right) postKey(49, 0, 1);
    return true;
}

// One press of a lineStop latch. Returns false = nothing in the way, post the plain jump.
static bool lineStopBurst(const Latch *l) {
    if (l->toKey == 51 && l->hasThen && l->thenKey == 51 && !(l->thenFlags & kCGEventFlagMaskAlternate))
        return wholeWordDelete();
    bool back = l->toKey == 123 || l->toKey == 51;      // ← / ⌫; else → / ⌦
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSString *s = caretSide(back);
    if (!s.length) return false;
    NSInteger n = s.length, i, j;
    CGEventFlags plain = l->toFlags & ~kCGEventFlagMaskAlternate;
    int step = 0; bool dropThen = false;
    if (back) {
        for (i = n; i > 0 && !isWordChar([s characterAtIndex:i - 1]) && !isLineBreak([s characterAtIndex:i - 1]); i--) ;
        if (i > 0 && isLineBreak([s characterAtIndex:i - 1])) step = i == n ? 1 : (int)(n - i);
        else if (i > 0) {
            for (j = i; j > 0 && isWordChar([s characterAtIndex:j - 1]); j--) ;
            dropThen = j > 0 && isLineBreak([s characterAtIndex:j - 1]);
        }
    } else {
        for (i = 0; i < n && !isWordChar([s characterAtIndex:i]) && !isLineBreak([s characterAtIndex:i]); i++) ;
        if (i < n && isLineBreak([s characterAtIndex:i])) step = i == 0 ? 1 : (int)i;
        else if (i < n) {
            for (j = i; j < n && isWordChar([s characterAtIndex:j]); j++) ;
            dropThen = j < n && isLineBreak([s characterAtIndex:j]);
        }
    }
    if (atomic_load(&gTrace)) {
        fprintf(stderr, "trace lines: step=%d dropThen=%d in %.1fms\n", step, dropThen,
                (CFAbsoluteTimeGetCurrent() - t0) * 1000);
        fflush(stderr);
    }
    if (step) { postKey(l->toKey, plain, step); return true; }
    if (dropThen && l->hasThen) { postKey(l->toKey, l->toFlags, 1); return true; }
    return false;
}

// A burst latch (repeat > 1, or a `to` list): each tap of the sequence, `repeat` times.
static void postBurst(const Latch *l) {
    if (l->lineStop && lineStopBurst(l)) return;
    for (int i = 0; i < l->repeat; i++) {
        postKey(l->toKey, l->toFlags, 1);
        if (l->hasThen) postKey(l->thenKey, l->thenFlags, 1);
    }
}

// A rule that fires as a burst (repeat > 1, a `then`, a tap repeat, a line stop):
// latch kc to it and post the first burst. False = not one; the caller posts the chord.
static bool latchBurst(int kc, RRule *win, CGEventFlags outFlags) {
    if (!(win.repeat > 1 || win.hasThen || win.tapRepeat || win.lineStop)) return false;
    gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = win.toKey,
                          .toFlags = outFlags, .repeat = win.repeat,
                          .hasThen = win.hasThen, .thenKey = win.thenKey, .thenFlags = win.thenFlags,
                          .tap = win.tapRepeat, .lineStop = win.lineStop };
    postBurst(&gLatch[kc]);
    return true;
}

// A trackpad-keyboard value naming a binding (word.left): one press of what that
// binding posts — its chord, `then` and `lines` — wherever it is scoped. gAuxQ.
static bool auxPostBinding(NSString *ident) {
    for (RRule *r in gRules) {
        if (![r.ident isEqualToString:ident] || r.toKey < 0 || r.run || r.chain) continue;
        Latch l = { .active = true, .toKey = r.toKey, .toFlags = r.toFlags, .repeat = MAX(r.repeat, 1),
                    .hasThen = r.hasThen, .thenKey = r.thenKey, .thenFlags = r.thenFlags,
                    .lineStop = r.lineStop };
        postBurst(&l);
        return true;
    }
    return false;
}

// A chord whose modifiers are not physically held, posted the way a keyboard would
// send it: each added modifier down as its own flags-changed event, then the key; on
// the up, the key, then each modifier up again, back to what was held. Rewriting the
// event in place only makes the key CARRY ⌥⇧⌘, and nothing ever says they came up —
// Qt (Fusion) goes on believing they are held, so after Space's ⌥⇧⌘J surrogate every
// click was a ⌘-click and the selection accumulated. One the user IS holding stays down.
static const struct { CGEventFlags mask; int kc; } kMods[] = {
    { kCGEventFlagMaskCommand,   55 }, { kCGEventFlagMaskShift,   56 },
    { kCGEventFlagMaskAlternate, 58 }, { kCGEventFlagMaskControl, 59 },
};

// Where postFlags / postChordHalf post. The tap note (remap/tap) posts at the HID
// tap instead: Wispr Flow listens there, below the session, so a session-posted
// ⌃⇧F never reached it (2026-10-15) — Karabiner's ⌘F → ⌃⇧F always arrived from below.
static _Thread_local CGEventTapLocation tPostAt = kCGSessionEventTap;

static void postFlags(CGEventSourceRef src, int kc, CGEventFlags flags) {
    CGEventRef f = CGEventCreateKeyboardEvent(src, kc, false);
    if (!f) return;
    CGEventSetType(f, kCGEventFlagsChanged);
    CGEventSetFlags(f, flags);
    CGEventSetIntegerValueField(f, kCGEventSourceUserData, OUR_MARK);
    CGEventPost(tPostAt, f);
    CFRelease(f);
}

// `quiet` (Photoshop in front, quietMods): the key alone carries the added modifiers,
// no flags-changed events. Photoshop swaps tools on a bare ⌘ / ⌥ down (temporary
// Move / Eyedropper), so each ⌥⌘F* surrogate flashed that tool's cursor over the
// brush; its menus match on the key's own flags, and nothing in it sticks the way Qt did.
static bool quietMods(void) {
    os_unfair_lock_lock(&gLock);
    bool q = [gFrontBundle hasPrefix:@"com.adobe.Photoshop"];
    os_unfair_lock_unlock(&gLock);
    return q;
}

static void postChordHalf(const Latch *l, bool down) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    size_t n = l->quiet ? 0 : sizeof kMods / sizeof kMods[0];
    CGEventFlags cur = l->held;
    if (down)
        for (size_t i = 0; i < n; i++)
            if (l->added & kMods[i].mask) { cur |= kMods[i].mask; postFlags(src, kMods[i].kc, cur); }
    CGEventRef k = CGEventCreateKeyboardEvent(src, l->toKey, down);
    if (k) {
        CGEventSetFlags(k, l->toFlags);
        CGEventSetIntegerValueField(k, kCGEventSourceUserData, OUR_MARK);
        CGEventPost(tPostAt, k);
        CFRelease(k);
    }
    if (!down) {
        cur = l->held | l->added;
        for (size_t i = n; i-- > 0; )
            if (l->added & kMods[i].mask) { cur &= ~kMods[i].mask; postFlags(src, kMods[i].kc, cur); }
    }
    if (src) CFRelease(src);
}

/* ── The resolver ─────────────────────────────────────────────────────────────
   One loop, three callers: the tap for every key, and the letter hold for "could
   J (or J+K) mean anything here?" and "what does X mean under J?". */
// The domain a resolve runs against. Unretained: the globals' own objects, valid
// only while gLock is held — copy out (resolveKey's `dom`) before letting go.
typedef struct { __unsafe_unretained NSString *app, *elem, *cmd, *skt, *mde; } Domain;

// Has the focused text's caret line nothing typed on it? Read live — typing changes it
// between samples — but only by the few rules that ask, and cached 50 ms so one key's
// resolve + holdLive calls cost one read. Whitespace and attachment glyphs (Notes'
// checkbox is U+FFFC) don't count as typed. Unreadable = not empty.
static bool caretLineEmpty(void) {
    static CFAbsoluteTime at = 0;
    static bool cached = false;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at < 0.05) return cached;
    at = now;
    cached = false;
    // The front app's own element, not the system-wide one: a cold first read of
    // Notes takes ~50 ms, and the system-wide timeout would be every AX call's.
    pid_t pid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    AXUIElementRef app = pid > 0 ? AXUIElementCreateApplication(pid) : NULL;
    CFTypeRef focused = NULL;
    if (app) {
        AXUIElementSetMessagingTimeout(app, 0.15);
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
        CFRelease(app);
    }
    if (!focused) {
        if (atomic_load(&gTrace)) { fprintf(stderr, "trace line: no focused element\n"); fflush(stderr); }
        return cached;
    }
    AXUIElementSetMessagingTimeout((AXUIElementRef)focused, 0.15);
    AXUIElementRef el = (AXUIElementRef)focused;
    CFTypeRef lineNo = NULL, range = NULL, str = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXInsertionPointLineNumberAttribute, &lineNo) == kAXErrorSuccess && lineNo
        && AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForLineParameterizedAttribute, lineNo, &range) == kAXErrorSuccess && range
        && AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute, range, &str) == kAXErrorSuccess
        && str && CFGetTypeID(str) == CFStringGetTypeID()) {
        NSMutableCharacterSet *blank = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [blank addCharactersInString:@"￼"];
        cached = [(__bridge NSString *)str stringByTrimmingCharactersInSet:blank].length == 0;
    }
    if (lineNo) CFRelease(lineNo);
    if (range) CFRelease(range);
    if (str) CFRelease(str);
    CFRelease(focused);
    if (atomic_load(&gTrace)) {
        fprintf(stderr, "trace line empty=%d in %.1fms\n", cached, (CFAbsoluteTimeGetCurrent() - now) * 1000);
        fflush(stderr);
    }
    return cached;
}

// Every axis but the key and its flags. Empty `want` = in scope.
static void scopeWant(RRule *r, int hold, const Domain *d, int fingers,
                      char *want, size_t n) {
    want[0] = 0;
    if (r.hold >= 0 && hold != r.hold)
        snprintf(want, n, "hold=%s", holdName(r.hold));
    else if (r.apps.count && ![r.apps containsObject:d->app ?: @""])
        snprintf(want, n, "app=%s", [r.apps componentsJoinedByString:@"|"].UTF8String);
    else if (r.notApps.count && [r.notApps containsObject:d->app ?: @""])
        snprintf(want, n, "app!=%s", [r.notApps componentsJoinedByString:@"|"].UTF8String);
    else if (r.element && ![r.element isEqualToString:d->elem])
        snprintf(want, n, "element=%s", r.element.UTF8String);
    else if (r.notElement && [r.notElement isEqualToString:d->elem])
        snprintf(want, n, "element!=%s", r.notElement.UTF8String);
    else if (r.command && ![r.command isEqualToString:d->cmd])
        snprintf(want, n, "command=%s", r.command.UTF8String);
    else if (r.sketch && ![r.sketch isEqualToString:d->skt])
        snprintf(want, n, "sketch=%s", r.sketch.UTF8String);
    else if (r.mode && ![r.mode isEqualToString:d->mde])
        snprintf(want, n, "mode=%s", r.mode.UTF8String);
    else if (r.fMin >= 0 && (fingers < r.fMin || fingers > r.fMax))
        snprintf(want, n, "fingers=%d..%d", r.fMin, r.fMax);
    else if (r.emptyLine && !caretLineEmpty())
        snprintf(want, n, "line=empty");
}

// Caller holds gLock.
static Domain sampleDomain(void) {
    return (Domain){ foldApp(gFrontBundle, gFrontName, gApps), gElement, gCommand, gSketch, gMode };
}

// MOVE WHILE HELD (2026-10-18, Control Room right-click ▸ Pointer Moves While Held):
// fingers resting on the left pad are a modifier (right_one … right_five); when a
// binding under that modifier, live here, has move_held, the touch freeze stands aside
// so the right pad still points. gAuxQ, every left-pad frame.
static void auxMoverUpdate(void) {
    bool want = false;
    if (atomic_load(&gAuxFingers) > 0 && !atomic_load(&gTyping)) {
        int still = auxLeftHold((double)nowNs() / 1e9);
        if (still >= 1 && still < AG_HOLD_STATES) {
            NSString *layer = auxStillLayer(@"right", still);
            int fingers = atomic_load(&gFingers);
            os_unfair_lock_lock(&gLock);
            if (gMoverRules.count) {
                Domain d = sampleDomain();
                char w[128];
                for (RRule *r in gMoverRules) {
                    if (![r.padLayer isEqualToString:layer]) continue;
                    if (r.emptyLine) { want = true; break; }   // a live AX read: not per frame
                    scopeWant(r, r.hold, &d, fingers, w, sizeof w);
                    if (!w[0]) { want = true; break; }
                }
            }
            os_unfair_lock_unlock(&gLock);
        }
    }
    if (atomic_exchange(&gAuxMover, want) == want) return;
    fprintf(stderr, "aux pointer %s (move_held)\n", want ? "moves while held" : "frozen again"); fflush(stderr);
    if (want) auxHideWhy(HIDE_FLICK, false);
    auxFreezeUpdate();
}

// The winning rule for this key, or nil. `miss` (may be NULL) collects every rule
// that claimed the key and lost on an axis — the trace's whole answer.
// `dom` (may be NULL): app, element, command, sketch as sampled, for the trace.
static RRule *resolveKey(int kc, CGEventFlags flags, int hold, int fingers,
                         NSString *__strong *dom, char *miss, size_t missLen) {
    RRule *win = nil;
    if (miss && missLen) miss[0] = 0;
    os_unfair_lock_lock(&gLock);
    NSArray<RRule *> *rules = gRules;
    Domain d = {0};
    if (rules.count) {
        d = sampleDomain();
        for (RRule *r in rules) {
            if (r.fromKey != kc) continue;
            // Shift-through: the mirror is typed with Shift for capitals, so Shift
            // is not part of the match and rides through to the output.
            CGEventFlags cmp = r.shiftThrough ? (flags & ~kCGEventFlagMaskShift) : flags;
            cmp &= ~r.emitFlags;
            if (r.fromFlags != cmp) continue;
            char want[128];
            scopeWant(r, hold, &d, fingers, want, sizeof want);
            if (want[0]) {
                size_t n = miss ? strlen(miss) : 0;
                if (miss && n < missLen - 96)
                    snprintf(miss + n, missLen - n, "  MISS %s wants %s",
                             r.ident.UTF8String, want);
                continue;
            }
            win = r;
            break;
        }
    }
    if (dom) { dom[0] = d.app; dom[1] = d.elem; dom[2] = d.cmd; dom[3] = d.skt; }
    os_unfair_lock_unlock(&gLock);
    return win;
}

// The trackpad keyboard's split (auxEmit): would this key, posted now, fire a COMMAND —
// a run, a sequence, or a chord with ⌘ / ⌃ — rather than type? Typing = no winner, or
// one that makes it another key without ⌘ / ⌃: an editing key (arrows, delete, word
// moves…) or a character in a text field (the mirror, the number row).
static bool auxIsCommand(int kc, CGEventFlags mods, bool space, NSString **ident) {
    CGEventFlags flags = ((CGEventFlags)atomic_load(&gHwFlags) | mods) & MODMASK;
    int hold = space ? HOLD_SPACE : atomic_load(&gHold);
    int fingers = atomic_load(&gFingers);
    char miss[1024];
    RRule *r = resolveKey(kc, flags, hold, fingers, NULL, miss, sizeof miss);
    fprintf(stderr, "aux resolve kc=%d flags=0x%llx hold=%s fingers=%d main=%d -> %s%s\n", kc,
            (unsigned long long)flags, holdName(hold), fingers, atomic_load(&gMainFingers),
            r ? r.ident.UTF8String : "(none)", miss);
    fflush(stderr);
    if (ident) *ident = r.ident;
    if (!r) return false;
    if (r.run || r.chain) return true;
    if (r.toFlags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) return true;
    int t = r.toKey;
    bool edit = t < 0 || (t >= 123 && t <= 126) || t == 51 || t == 117 || t == 115 || t == 119
             || t == 116 || t == 121 || t == 36 || t == 48 || t == 49 || t == 53;
    return !edit && ![r.element isEqualToString:@"text"];
}

// A navigating gesture's own binding (auxEmit, key "pad.<hand>.<gesture>"): resolved like
// a key — situation, held modifiers, Space / letter hold, fingers — and fired once: its
// sequence, its run, or its chord (`then`, `repeat`, `lines` as from auxPostBinding).
static bool auxPadFire(NSString *padKey, CGEventFlags mods, bool space) {
    int kc;
    if (!padKeyCode(padKey, &kc)) return false;
    CGEventFlags flags = ((CGEventFlags)atomic_load(&gHwFlags) | mods) & MODMASK;
    int hold = space ? HOLD_SPACE : atomic_load(&gHold);
    char miss[1024];
    RRule *r = resolveKey(kc, flags, hold, atomic_load(&gFingers), NULL, miss, sizeof miss);
    fprintf(stderr, "aux %s hold=%s -> %s%s\n", padKey.UTF8String, holdName(hold),
            r ? r.ident.UTF8String : "(nothing bound)", miss);
    fflush(stderr);
    if (!r) return false;
    atomic_store(&gPadFireNs, nowNs());   // its tap's own click is dropped (TAP_CLICK_WAIT_MS)
    if (r.block) return true;
    if (r.chain) padChain(r.chain);
    else if (r.run) runShell(r.run);
    else if (r.toKey >= 0) {
        Latch l = { .active = true, .toKey = r.toKey, .toFlags = r.toFlags, .repeat = MAX(r.repeat, 1),
                    .hasThen = r.hasThen, .thenKey = r.thenKey, .thenFlags = r.thenFlags,
                    .lineStop = r.lineStop };
        CGEventFlags added = r.toFlags & ~flags & (MODMASK & ~kCGEventFlagMaskSecondaryFn);
        if (added && !(r.repeat > 1 || r.hasThen || r.lineStop)) {
            // A chord's modifiers as their own downs / ups (postChordHalf): Qt (Fusion)
            // believes a modifier only carried on the key is still held afterwards.
            l.added = added; l.held = flags; l.quiet = quietMods();
            postChordHalf(&l, true); postChordHalf(&l, false);
        } else postBurst(&l);
    }
    return true;
}

// THE CLAIM's question: would this gesture key resolve to a binding here, right now?
static bool padResolves(NSString *padKey, CGEventFlags mods, bool space) {
    int kc;
    if (!padKeyCode(padKey, &kc)) return false;
    CGEventFlags flags = ((CGEventFlags)atomic_load(&gHwFlags) | mods) & MODMASK;
    int hold = space ? HOLD_SPACE : atomic_load(&gHold);
    return resolveKey(kc, flags, hold, atomic_load(&gFingers), NULL, NULL, 0) != nil;
}
// Would the right pad, navigating, do something with this gesture — auxEmit's own choice:
// the resting-finger layer's value, else right_nav's, else its own binding pad.right.<g>.
static bool auxRightBound(const char *name, int still) {
    if (still) {
        NSString *l = auxStillLayer(@"right", still), *v = auxValue(l, name);
        if (v) return ![v isEqualToString:@"bind"] || padResolves([NSString stringWithFormat:@"pad.%@.%s", l, name], 0, false);
    }
    NSString *v = auxValue(@"right_nav", name);
    if (v && ![v isEqualToString:@"bind"]) return true;
    return padResolves([NSString stringWithFormat:@"pad.right.%s", name], still == 1 ? kCGEventFlagMaskShift : 0, still == 2);
}
// THE CLAIM: is a SWIPE made of this state bound here? Thumb down: the Resting Thumb section's
// up<n> / down<n> / left<n> / right<n> (n 1–4, right_rest_thumb). No thumb: up / down / left / right<n> from three
// fingers — or from one with fingers resting on the left pad. `why` gets the gesture that
// claimed it.
static bool auxRightClaims(bool thumb, int n, int still, char *why, size_t wn) {
    if (n < 1 || n > 5 || (thumb && n > 4) || (!thumb && !still && n <= 2)) return false;
    static const char *const dirs[] = { "up", "down", "left", "right", "pinch", "spread" };
    for (int d = 0; d < (thumb && n >= 2 ? 6 : 4); d++) {   // the thumb's pinch / spread<n> too (2026-10-21)
        char nm[32];
        snprintf(nm, sizeof nm, "%s%s%d", thumb ? "restthumb:" : "", dirs[d], n);
        if (thumb ? auxRestBound(PAD_RIGHT, nm) : auxRightBound(nm, still)) {
            if (still) snprintf(why, wn, "%s (%d resting)", nm, still); else snprintf(why, wn, "%s", nm);
            return true;
        }
    }
    return false;
}

// Could anything held by `hold` fire here, whatever key comes next?
static bool holdLive(int hold) {
    bool live = false;
    int fingers = atomic_load(&gFingers);
    os_unfair_lock_lock(&gLock);
    NSArray<RRule *> *rules = gRules;
    if (rules.count) {
        Domain d = sampleDomain();
        char want[128];
        for (RRule *r in rules) {
            if (r.hold != hold) continue;
            scopeWant(r, hold, &d, fingers, want, sizeof want);
            if (!want[0]) { live = true; break; }
        }
    }
    os_unfair_lock_unlock(&gLock);
    return live;
}

/* ── The letter hold ──────────────────────────────────────────────────────────
   J held is a modifier; J and K held together are another (added 2026-09-29,
   replacing ; held as Right Control). Both are letters you also TYPE, so neither
   may send on key down, and the question "was that a chord or two letters typed
   with an overlap" is answered by RELEASE ORDER — which no Karabiner rule can
   express and Karabiner's tap-vs-hold (decided on the first key's timing alone)
   gets wrong both ways. So this one is remapd's, whole; Karabiner never sees it.

     J down                  held back (nothing sent)
     J up alone              j
     J held, X down          X means nothing under J  -> j, x at once
                             X does mean something     -> held back too, and then:
       X up first            the binding (J is a modifier now; later keys under
                             the same J fire at once, with autorepeat)
       J up first            j, x — the hand was typing, just late off the J
       both held COMMIT_MS   the binding, so it can autorepeat (J+F held = →→→)
       a third key down      j, x, that key — typing
     K down                  held back, only where a J+K binding could fire
       J down with it        the J+K layer: both swallowed, keys fire at once
       any other key         k, that key
       K up alone            k
     J, then K (before X)    the J+K layer too
     J+K let go unused       both letters, in the order they went down — unless
                             they were down together SETTLE_MS: then nothing
     L down under J+K        the J+K+L layer (added 2026-09-29): L swallowed,
                             only where a J+K+L binding could fire — else L is
                             an ordinary key under J+K
       L up                  back to the J+K layer, where letting go types nothing
       any unbound key       that key alone
     J+K+L let go            nothing — all three down together is never typing
     J (K) held, L down      J+L (K+L): both held back (L only under J when L
                             means nothing there), waiting for the third:
       K (J) down            the J+K+L layer, where a J+K+L binding could fire
       either up             the two letters in press order — or nothing, if they
                             were down together SETTLE_MS (2026-10-07)
       any other key         the letters (unless settled), that key
     L down                  held back like K, only where a J+K+L binding could
                             fire; J or K with it is the pair above
     D (F) down              the single-letter hold J has, with D (F) as the lead
                             (added 2026-10-14: D + R/F/C, F + D = arrows): armed,
                             pending, commit and release order exactly as J's; no
                             K/L layers above it. D held then F is D's binding for
                             F; F held then D is F's for D — the first one down leads.
     Space down under D (F)  D + Space (F + Space), where such a binding could
                             fire (added 2026-10-14: the word moves): still held
                             back, the lead's hold becomes the +Space one —
       X down                pending under it, decided exactly as above
       lead up first         d, then the Space layer (the space types on its own up)
       Space up first        d — typed now, ahead of Karabiner's space
     Space down, lead USED   the lead's modifier gains Space at once; Space up
                             drops back to the lead alone, the lead up to Space.

   Held back only WHERE IT MATTERS: J (K, L) arms only when some J, J+K or J+K+L
   (J+K or J+K+L; J+K+L) binding is in scope right now (holdLive), and only with
   no modifier down and nothing else held — everywhere else they type on the
   down, with no delay.

   What is held back goes out later as REPLAY_BASE-marked copies, in press order,
   each resolved against the hold of the moment it was pressed. The event that
   forces a decision is swallowed and replayed after them, never let through
   ahead. Keys that stay physically down after their letter was sent have their
   repeats and up eaten (gEat). Tap thread only (the commit timer is on the tap's
   run loop), so no locking. */
#define KC_J 38
#define KC_K 40
#define KC_L 37
#define KC_D 2
#define KC_F 3
#define COMMIT_MS 200
#define SETTLE_MS 250            // two letters down together this long: a chord, never typing
enum { LH_IDLE, LH_J_ARMED, LH_J_PENDING, LH_J_USED, LH_K_ARMED, LH_JK, LH_JKL,
       LH_L_ARMED, LH_PAIR };    // LH_PAIR: L + gPairOther (J or K), no layer of its own
static int gLH = LH_IDLE;
static CGEventRef gJDown = NULL, gKDown = NULL, gLDown = NULL, gXDown = NULL;  // held-back downs
// The LH_J_* states' letter: J, D or F (gJDown holds its down). Only J has K/L above it.
static int gLeadKc = KC_J, gLeadHold = HOLD_J;
static bool gLeadSpace = false;  // gLeadHold is the lead's +Space hold (HOLD_DS / HOLD_FS)
static bool gSpaceFirst = false; // ...and the space went down before the lead: typing it is the Space layer's
static bool gCapTyped = false;   // LH_J_ARMED, D/F: the capital hold already typed the lead's capital
// LH_J_PENDING: the lead came up first, its up swallowed. X up within GRACE_MS is the
// two let go together — a chord (rolled releases ~15 ms apart, 2026-10-14) — else typing.
static bool gLeadGone = false;
#define GRACE_MS 40
static bool gSpaceDown = false;  // Karabiner's F20 is down: the space is held
static int gXKc = -1;
static bool gJFirst = true;      // J+K: J went down first
static bool gJKUsed = false;     // J+K fired something: letting go types nothing
static bool gJKLUsed = false;    // J+K+L fired something: the same, one layer up
static int gPairOther = -1;      // LH_PAIR: KC_J or KC_K
static bool gLFirst = false;     // LH_PAIR: L went down first
static CFAbsoluteTime gPairT = 0;   // when the second letter of J+K / LH_PAIR went down
static bool gEat[128];           // down, letter already sent: eat repeats + the up
static CFRunLoopTimerRef gCommit = NULL;

static void lhTrace(const char *what, int kc) {
    if (!atomic_load(&gTrace)) return;
    fprintf(stderr, "trace letter-hold %s kc=%d t=%llums\n", what, kc, nowNs() / 1000000ULL % 100000);
    fflush(stderr);
}

static void lhKeep(CGEventRef *slot, CGEventRef e) {
    if (*slot) CFRelease(*slot);
    *slot = e ? CGEventCreateCopy(e) : NULL;
}

static void replayAs(CGEventRef e, bool down, int64_t mark) {
    CGEventRef c = CGEventCreateCopy(e);
    if (!c) return;
    CGEventSetType(c, down ? kCGEventKeyDown : kCGEventKeyUp);
    CGEventSetIntegerValueField(c, kCGKeyboardEventAutorepeat, 0);
    CGEventSetIntegerValueField(c, kCGEventSourceUserData, mark);
    CGEventPost(kCGSessionEventTap, c);
    CFRelease(c);
}
static void replayTap(CGEventRef down) {
    replayAs(down, true,  REPLAY_BASE + HOLD_NONE);
    replayAs(down, false, REPLAY_BASE + HOLD_NONE);
}
// The held-back lead as typed: under the Space layer when the space came first.
static void replayLead(void) {
    int64_t mark = REPLAY_BASE + (gSpaceFirst ? HOLD_SPACE : HOLD_NONE);
    replayAs(gJDown, true, mark);
    replayAs(gJDown, false, mark);
}

static CFRunLoopTimerRef gCapArm = NULL;   // LH_J_ARMED alone: the capital hold's clock

static void lhCancelTimer(void) {
    if (gCapArm) {
        CFRunLoopTimerInvalidate(gCapArm);
        CFRelease(gCapArm);
        gCapArm = NULL;
    }
    if (!gCommit) return;
    CFRunLoopTimerInvalidate(gCommit);
    CFRelease(gCommit);
    gCommit = NULL;
}

static void lhClear(void) {
    lhCancelTimer();
    lhKeep(&gJDown, NULL); lhKeep(&gKDown, NULL); lhKeep(&gLDown, NULL); lhKeep(&gXDown, NULL);
    gXKc = -1;
    gPairOther = -1;
    gLH = LH_IDLE;
    gSpaceFirst = false;
    gCapTyped = false;
    gLeadGone = false;
    if (gLeadSpace) {   // the lead is gone: the space (if still down) is the Space layer
        gLeadSpace = false;
        atomic_store(&gHold, gSpaceDown ? HOLD_SPACE : HOLD_NONE);
    }
}

// Two letters held together long enough that they can't have been typing.
static bool lhSettled(void) {
    return CFAbsoluteTimeGetCurrent() - gPairT >= SETTLE_MS / 1000.0;
}

// Nothing was a chord: send what was held back as the typing it was — unless a
// held pair settled (or all three were down), which sends nothing. `upKc` is
// the held-back letter whose own up forced this (not eaten — it is here now);
// `trigger` (may be NULL) is any other event that forced it, sent after the rest.
static void lhFlush(int upKc, CGEventRef trigger, bool literal) {
    lhTrace("flush (typing)", trigger ? (int)CGEventGetIntegerValueField(trigger, kCGKeyboardEventKeycode) : upKc);
    switch (gLH) {
    case LH_J_ARMED:
        replayLead();
        if (upKc != gLeadKc) gEat[gLeadKc] = true;
        break;
    case LH_J_PENDING:
        replayLead();
        if (upKc != gLeadKc && !gLeadGone) gEat[gLeadKc] = true;
        // X is still down: its up is its own. Pressed under the space: the Space layer's.
        replayAs(gXDown, true, REPLAY_BASE + (gLeadSpace ? HOLD_SPACE : HOLD_NONE));
        break;
    case LH_K_ARMED:
        replayTap(gKDown);
        if (upKc != KC_K) gEat[KC_K] = true;
        break;
    case LH_L_ARMED:
        replayTap(gLDown);
        if (upKc != KC_L) gEat[KC_L] = true;
        break;
    case LH_PAIR: {
        CGEventRef other = gPairOther == KC_J ? gJDown : gKDown;
        if (!lhSettled()) {
            replayTap(gLFirst ? gLDown : other);
            replayTap(gLFirst ? other : gLDown);
        } else lhTrace("pair settled: nothing", upKc);
        if (upKc != KC_L) gEat[KC_L] = true;
        if (upKc != gPairOther) gEat[gPairOther] = true;
        break;
    }
    case LH_JK:
        if (!gJKUsed && !lhSettled()) {
            replayTap(gJFirst ? gJDown : gKDown);
            replayTap(gJFirst ? gKDown : gJDown);
        }
        if (upKc != KC_J) gEat[KC_J] = true;
        if (upKc != KC_K) gEat[KC_K] = true;
        if (atomic_load(&gHold) == HOLD_JK) atomic_store(&gHold, HOLD_NONE);
        break;
    case LH_JKL:   // all three down together: never typing, so nothing to send
        if (upKc != KC_J) gEat[KC_J] = true;
        if (upKc != KC_K) gEat[KC_K] = true;
        if (upKc != KC_L) gEat[KC_L] = true;
        if (atomic_load(&gHold) == HOLD_JKL) atomic_store(&gHold, HOLD_NONE);
        break;
    default:
        break;
    }
    lhClear();
    if (trigger) {
        bool down = CGEventGetType(trigger) == kCGEventKeyDown;
        replayAs(trigger, down, literal ? OUR_MARK : REPLAY_BASE + atomic_load(&gHold));
    }
}

// A binding decided after its key went down: post the down now, and latch the
// key so its repeats are rewritten and its up is posted (Latch.posted).
static void fireDetached(int kc, RRule *win, CGEventFlags flags) {
    vlog(@"%@  hold=%s (letter hold) -> %@", win.ident, holdName(atomic_load(&gHold)),
         win.run ?: @"(chord)");
    if (win.run) {
        gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = -1 };
        runShell(win.run);
        return;
    }
    CGEventFlags outFlags = win.toFlags | (win.shiftThrough ? (flags & kCGEventFlagMaskShift) : 0);
    if (latchBurst(kc, win, outFlags)) return;
    gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = win.toKey,
                          .toFlags = outFlags, .repeat = 1,
                          .added = outFlags & ~flags & (MODMASK & ~kCGEventFlagMaskSecondaryFn),
                          .held = flags, .posted = true, .quiet = quietMods() };
    postChordHalf(&gLatch[kc], true);
}

// The pending key IS a J chord. `up`: its up, when that is what decided it
// (NULL from the timer).
static void lhCommit(CGEventRef up) {
    lhCancelTimer();
    int kc = gXKc;
    CGEventFlags flags = CGEventGetFlags(gXDown) & MODMASK;
    RRule *win = resolveKey(kc, flags, gLeadHold, atomic_load(&gFingers), NULL, NULL, 0);
    if (!win) {   // the scope moved under the hand in the meantime: it was typing
        lhFlush(-1, up, false);
        return;
    }
    lhTrace(up ? "commit (released first)" : "commit (held)", kc);
    atomic_store(&gHold, gLeadHold);
    fireDetached(kc, win, flags);
    if (up) {
        Latch *l = &gLatch[kc];
        if (l->posted || l->added) postChordHalf(l, false);
        l->active = false;
    }
    lhKeep(&gJDown, NULL); lhKeep(&gXDown, NULL);
    gXKc = -1;
    gLH = LH_J_USED;
}

static void lhStartTimer(void) {
    lhCancelTimer();
    gCommit = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + COMMIT_MS / 1000.0, 0, 0, 0,
        ^(CFRunLoopTimerRef t) { (void)t; if (gLH == LH_J_PENDING) lhCommit(NULL); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), gCommit, kCFRunLoopCommonModes);
}

// The lead letter held alone CAP_MS (THE CAPITAL HOLD's 1 s) in a text field: it
// was never a modifier — type its capital now, and let go of it as typed.
// Off-text nothing happens; letting go still types the letter.
#define LH_CAP_MS 1000
static void lhCapital(void) {
    if (gLH != LH_J_ARMED || !gJDown || gLeadSpace) return;
    os_unfair_lock_lock(&gLock);
    bool text = [gElement isEqualToString:@"text"];
    os_unfair_lock_unlock(&gLock);
    if (!text) return;
    lhTrace("held alone: capital", gLeadKc);
    for (int down = 1; down >= 0; down--) {
        CGEventRef c = CGEventCreateCopy(gJDown);
        if (!c) continue;
        CGEventSetType(c, down ? kCGEventKeyDown : kCGEventKeyUp);
        CGEventSetFlags(c, (CGEventGetFlags(c) & ~MODMASK) | kCGEventFlagMaskShift);
        CGEventSetIntegerValueField(c, kCGKeyboardEventAutorepeat, 0);
        CGEventSetIntegerValueField(c, kCGEventSourceUserData, OUR_MARK);
        CGEventPost(kCGSessionEventTap, c);
        CFRelease(c);
    }
    // D / F stay armed: a bound key pressed while still held takes the capital back
    // (⌫) and fires under the hold — press-and-hold wins (2026-10-14). J lets go.
    if (gLeadKc == KC_D || gLeadKc == KC_F) { gCapTyped = true; return; }
    gEat[gLeadKc] = true;
    lhClear();
}

static void lhArm(int kc, int hold, CGEventRef event) {
    gLeadKc = kc; gLeadHold = hold;
    lhKeep(&gJDown, event);
    gLH = LH_J_ARMED;
    lhTrace(kc == KC_D ? "d armed" : kc == KC_F ? "f armed" : "j armed", kc);
    lhCancelTimer();
    gCapArm = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + LH_CAP_MS / 1000.0, 0, 0, 0,
        ^(CFRunLoopTimerRef t) { (void)t; lhCapital(); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), gCapArm, kCFRunLoopCommonModes);
}

static void lhEnterJK(bool jFirst) {
    gJFirst = jFirst; gJKUsed = false;
    gPairT = CFAbsoluteTimeGetCurrent();
    gLH = LH_JK;
    atomic_store(&gHold, HOLD_JK);
    lhTrace("j+k held", jFirst ? KC_K : KC_J);
}

// L with J or K (the other's down already kept): no layer, wait for the third.
static void lhEnterPair(int other, bool lFirst) {
    gPairOther = other; gLFirst = lFirst;
    gPairT = CFAbsoluteTimeGetCurrent();
    gLH = LH_PAIR;
    lhTrace("pair held", lFirst ? other : KC_L);
}

static void lhEnterJKL(void) {
    lhCancelTimer();
    gXKc = -1; lhKeep(&gXDown, NULL);
    gPairOther = -1;
    gJKLUsed = false;
    gLH = LH_JKL;
    atomic_store(&gHold, HOLD_JKL);
    lhTrace("j+k+l held", KC_L);
}

// L let go while J+K stay down: back to the J+K layer,
// where letting go now types nothing either.
static void lhLeaveJKL(void) {
    gJKUsed = true;
    lhKeep(&gLDown, NULL);
    gLH = LH_JK;
    atomic_store(&gHold, HOLD_JK);
    lhTrace("j+k+l -> j+k", KC_L);
}

// Space went down (Karabiner's F20): whatever is still undecided was typing,
// and must reach the app before the space does — unless D (F) leads and a
// D + Space (F + Space) binding could fire. Returns the hold to take.
static int lhSpace(void) {
    gSpaceDown = true;
    if (gLH == LH_J_ARMED && gCapTyped) {   // the capital stands; the space is its own
        gEat[gLeadKc] = true;
        lhClear();
        return HOLD_SPACE;
    }
    int sh = gLeadKc == KC_D ? HOLD_DS : gLeadKc == KC_F ? HOLD_FS : -1;
    if (sh >= 0 && !gLeadSpace && (gLH == LH_J_ARMED || gLH == LH_J_USED) && holdLive(sh)) {
        gLeadSpace = true; gLeadHold = sh;
        lhTrace("lead + space", KC_F20);
        if (gLH == LH_J_USED) return sh;   // already a modifier: no typing to rule out
        lhCancelTimer();                   // no capital under the space
        return HOLD_SPACE;                 // undecided: a flush resolves under the Space layer
    }
    if (gLH == LH_J_ARMED || gLH == LH_J_PENDING || gLH == LH_K_ARMED
        || gLH == LH_L_ARMED || gLH == LH_PAIR
        || (gLH == LH_JK && !gJKUsed) || (gLH == LH_JKL && !gJKUsed && !gJKLUsed))
        lhFlush(-1, NULL, false);
    return HOLD_SPACE;
}

// Space let go (F20 up). Returns the hold left: a lead still in use keeps its own.
static int lhSpaceUp(void) {
    gSpaceDown = false;
    if (gLeadSpace && gLH == LH_J_ARMED) {
        lhFlush(-1, NULL, false);   // d + a space tap: the d goes ahead of Karabiner's space
        return HOLD_NONE;
    }
    if (gLeadSpace && gLH == LH_J_PENDING && gLeadGone) { lhFlush(gLeadKc, NULL, false); return HOLD_NONE; }
    if (gLeadSpace && gLH == LH_J_PENDING) lhCommit(NULL);   // all three were down together
    if (gLH != LH_J_USED) return HOLD_NONE;
    if (gLeadSpace) {
        gLeadSpace = false;
        gLeadHold = gLeadKc == KC_D ? HOLD_D : HOLD_F;
        lhTrace("lead + space -> lead", KC_F20);
    }
    return gLeadHold;
}

// true = swallow the event (the letter hold has it, or has replayed it).
static bool letterHold(CGEventType type, int kc, bool repeat, CGEventRef event, bool literal) {
    bool down = type == kCGEventKeyDown;
    if ((kc == KC_D || kc == KC_F) && !repeat && atomic_load(&gTrace)) {
        fprintf(stderr, "trace letter-hold raw %s %s state=%d eat=%d hold=%d flags=0x%llx t=%llums\n",
                kc == KC_D ? "d" : "f", down ? "down" : "up", gLH, gEat[kc], atomic_load(&gHold),
                (unsigned long long)(CGEventGetFlags(event) & MODMASK), nowNs() / 1000000ULL % 100000);
        fflush(stderr);
    }

    if (gEat[kc]) {
        if (!down) { gEat[kc] = false; return true; }
        if (repeat) return true;
        gEat[kc] = false;   // a new press: the up we were waiting for was lost
    }
    if (gLH == LH_IDLE && atomic_load(&gOff)) return false;

    if (down && repeat) {
        // Nothing held back may autorepeat through.
        bool leadState = gLH == LH_J_ARMED || gLH == LH_J_PENDING || gLH == LH_J_USED;
        if ((kc == gLeadKc && leadState)
            || (kc == KC_J && gLH != LH_IDLE && !leadState)
            || (kc == KC_K && (gLH == LH_K_ARMED || gLH == LH_JK || gLH == LH_JKL || gLH == LH_PAIR))
            || (kc == KC_L && (gLH == LH_JKL || gLH == LH_L_ARMED || gLH == LH_PAIR)))
            return true;
        if (gLH == LH_J_PENDING && kc == gXKc) return true;
        return false;
    }

    CGEventFlags flags = CGEventGetFlags(event) & MODMASK;
    bool bare = !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl
                           | kCGEventFlagMaskAlternate | kCGEventFlagMaskShift));

    if (down) {
        switch (gLH) {
        case LH_IDLE:
            // Space held, then D (F): undecided between the Space layer's D (F) and D + Space.
            if (!literal && bare && gSpaceDown && atomic_load(&gHold) == HOLD_SPACE
                && ((kc == KC_D && holdLive(HOLD_DS)) || (kc == KC_F && holdLive(HOLD_FS)))) {
                lhArm(kc, kc == KC_D ? HOLD_DS : HOLD_FS, event);
                lhCancelTimer();   // no capital under the space
                gLeadSpace = true; gSpaceFirst = true;
                lhTrace("space first", kc);
                return true;
            }
            if (literal || !bare || atomic_load(&gHold) != HOLD_NONE) return false;
            if (kc == KC_J && (holdLive(HOLD_J) || holdLive(HOLD_JK) || holdLive(HOLD_JKL))) {
                lhArm(KC_J, HOLD_J, event);
                return true;
            }
            if ((kc == KC_D && holdLive(HOLD_D)) || (kc == KC_F && holdLive(HOLD_F))) {
                lhArm(kc, kc == KC_D ? HOLD_D : HOLD_F, event);
                return true;
            }
            if (kc == KC_K && (holdLive(HOLD_JK) || holdLive(HOLD_JKL))) {
                lhKeep(&gKDown, event); gLH = LH_K_ARMED; lhTrace("k armed", kc);
                return true;
            }
            if (kc == KC_L && holdLive(HOLD_JKL)) {
                lhKeep(&gLDown, event); gLH = LH_L_ARMED; lhTrace("l armed", kc);
                return true;
            }
            return false;
        case LH_J_ARMED:
            if (gCapTyped) {   // the capital is out: no typing left to rule out
                if (!literal && resolveKey(kc, flags, gLeadHold, atomic_load(&gFingers), NULL, NULL, 0)) {
                    for (int dn = 1; dn >= 0; dn--) {
                        CGEventRef k = CGEventCreateKeyboardEvent(NULL, 51, dn);   // ⌫ the capital
                        if (!k) continue;
                        CGEventSetFlags(k, 0);
                        CGEventSetIntegerValueField(k, kCGEventSourceUserData, OUR_MARK);
                        CGEventPost(kCGSessionEventTap, k);
                        CFRelease(k);
                    }
                    lhKeep(&gJDown, NULL);
                    gCapTyped = false;
                    gLH = LH_J_USED;
                    atomic_store(&gHold, gLeadHold);
                    lhTrace("capital taken back", kc);
                    return false;   // the tap resolves it under the hold
                }
                gEat[gLeadKc] = true;
                lhClear();
                return false;
            }
            if (!literal && gLeadKc == KC_J && kc == KC_K && (holdLive(HOLD_JK) || holdLive(HOLD_JKL))) {
                lhKeep(&gKDown, event); lhEnterJK(true);
                return true;
            }
            if (!literal && (atomic_load(&gHold) == HOLD_NONE || gLeadSpace)
                && resolveKey(kc, flags, gLeadHold, atomic_load(&gFingers), NULL, NULL, 0)) {
                lhKeep(&gXDown, event); gXKc = kc; gLH = LH_J_PENDING;
                lhTrace("pending", kc);
                lhStartTimer();
                return true;
            }
            if (!literal && gLeadKc == KC_J && kc == KC_L) {
                lhKeep(&gLDown, event); lhEnterPair(KC_J, false);
                return true;
            }
            lhFlush(-1, event, literal);
            return true;
        case LH_J_PENDING:
            if (!literal && gLeadKc == KC_J && gXKc == KC_L && kc == KC_K && holdLive(HOLD_JKL)) {
                lhKeep(&gLDown, gXDown); lhKeep(&gKDown, event);   // J, L (a J binding), K
                gJFirst = true; lhEnterJKL();
                return true;
            }
            lhFlush(-1, event, literal);   // a third key: this was typing
            return true;
        case LH_K_ARMED:
            if (!literal && kc == KC_J) {
                lhKeep(&gJDown, event); lhEnterJK(false);
                return true;
            }
            if (!literal && kc == KC_L) {
                lhKeep(&gLDown, event); lhEnterPair(KC_K, false);
                return true;
            }
            lhFlush(-1, event, literal);
            return true;
        case LH_L_ARMED:
            if (!literal && (kc == KC_J || kc == KC_K)) {
                lhKeep(kc == KC_J ? &gJDown : &gKDown, event); lhEnterPair(kc, true);
                return true;
            }
            lhFlush(-1, event, literal);
            return true;
        case LH_PAIR:
            if (kc == KC_L || kc == gPairOther) return true;   // already down: a lost up
            if (!literal && (kc == KC_J || kc == KC_K) && holdLive(HOLD_JKL)) {   // the third
                lhKeep(kc == KC_J ? &gJDown : &gKDown, event);
                gJFirst = gPairOther == KC_J;
                lhEnterJKL();
                return true;
            }
            lhFlush(-1, event, literal);
            return true;
        case LH_JK:
            if (kc == KC_J || kc == KC_K) return true;   // already down: a lost up
            if (!literal && kc == KC_L && holdLive(HOLD_JKL)) {
                lhKeep(&gLDown, event); lhEnterJKL();
                return true;
            }
            if (gJKUsed) return false;                    // resolves under j+k itself
            if (!literal && resolveKey(kc, flags, HOLD_JK, atomic_load(&gFingers), NULL, NULL, 0)) {
                gJKUsed = true;
                return false;
            }
            lhFlush(-1, event, literal);    // j, k, then this: it was typing
            return true;
        case LH_JKL:
            if (kc == KC_J || kc == KC_K || kc == KC_L) return true;   // a lost up
            if (gJKLUsed) return false;                   // resolves under j+k+l itself
            if (!literal && resolveKey(kc, flags, HOLD_JKL, atomic_load(&gFingers), NULL, NULL, 0)) {
                gJKLUsed = true;
                return false;
            }
            lhFlush(-1, event, literal);    // j, k, l, then this: it was typing
            return true;
        default:   // LH_J_USED: J is a modifier; the tap resolves under it
            return false;
        }
    }

    // Key up.
    switch (gLH) {
    case LH_J_ARMED:
        if (kc == gLeadKc && gCapTyped) { lhClear(); return true; }   // the capital was the typing
        if (kc == gLeadKc) { lhFlush(kc, NULL, false); return true; }
        return false;
    case LH_J_PENDING:
        if (kc == gXKc && gLeadGone) {   // let go together: the chord
            lhCommit(event);
            if (atomic_load(&gHold) == gLeadHold) atomic_store(&gHold, HOLD_NONE);
            lhClear();
            lhTrace("released together: chord", kc);
            return true;
        }
        if (kc == gXKc) { lhCommit(event); return true; }
        if (kc == gLeadKc && !gLeadGone) {
            // An empty-line rule (Notes' D→F checklist) ignores release order: on a
            // line with nothing typed, the letters were never what was meant.
            RRule *w = resolveKey(gXKc, CGEventGetFlags(gXDown) & MODMASK, gLeadHold,
                                  atomic_load(&gFingers), NULL, NULL, 0);
            // D with F (either order, Space or not) ignores release order too (2026-10-14) —
            // in a text field only: off-text the pair is undo / redo, and keeps the full test.
            os_unfair_lock_lock(&gLock);
            bool inText = [gElement isEqualToString:@"text"];
            os_unfair_lock_unlock(&gLock);
            bool dfPair = inText && ((gLeadKc == KC_D && gXKc == KC_F) || (gLeadKc == KC_F && gXKc == KC_D));
            if (w && (w.emptyLine || dfPair)) {
                lhCommit(NULL);
                if (atomic_load(&gHold) == gLeadHold) atomic_store(&gHold, HOLD_NONE);
                lhClear();
                lhTrace(dfPair ? "d/f pair: lead released, still a chord" : "empty line: lead released, still a chord", kc);
                return true;
            }
            gLeadGone = true;   // typing, unless X follows within the grace
            lhCancelTimer();
            gCommit = CFRunLoopTimerCreateWithHandler(NULL,
                CFAbsoluteTimeGetCurrent() + GRACE_MS / 1000.0, 0, 0, 0,
                ^(CFRunLoopTimerRef t) { (void)t;
                    if (gLH == LH_J_PENDING && gLeadGone) lhFlush(gLeadKc, NULL, false); });
            CFRunLoopAddTimer(CFRunLoopGetMain(), gCommit, kCFRunLoopCommonModes);
            lhTrace("lead up first: grace", kc);
            return true;
        }
        return false;
    case LH_J_USED:
        if (kc == gLeadKc) {
            if (atomic_load(&gHold) == gLeadHold) atomic_store(&gHold, HOLD_NONE);
            lhClear();
            lhTrace("lead released", kc);
            return true;
        }
        return false;
    case LH_K_ARMED:
        if (kc == KC_K) { lhFlush(KC_K, NULL, false); return true; }
        return false;
    case LH_JK:
        if (kc == KC_J || kc == KC_K) { lhFlush(kc, NULL, false); return true; }
        return false;
    case LH_L_ARMED:
        if (kc == KC_L) { lhFlush(KC_L, NULL, false); return true; }
        return false;
    case LH_PAIR:
        if (kc == KC_L || kc == gPairOther) { lhFlush(kc, NULL, false); return true; }
        return false;
    case LH_JKL:
        if (kc == KC_L) { lhLeaveJKL(); return true; }
        if (kc == KC_J || kc == KC_K) { lhFlush(kc, NULL, false); return true; }
        return false;
    default:
        return false;
    }
}

/* ── The capital hold ─────────────────────────────────────────────────────────
   A letter that goes out as itself (passthrough) or as another bare letter (a
   binding — the Space-held mirror) never autorepeats; held CAP_MS with nothing
   else pressed, in a text field, it is retyped as its capital: ⌫, then ⇧+letter
   (added 2026-10-13). The letter is typed on the down as always — no delay, no
   reordering; any other key down cancels (that was typing). Off-text the repeats
   are still eaten, but nothing is retyped: ⌫ on a canvas is Delete. Shift (or
   ⌘⌃⌥) already down: no capital to make. Tap thread only. */
#define CAP_MS 1000
static int gCapKc = -1, gCapOut = -1;   // the physical key held, the letter it typed
static bool gNoRepeat[128];             // down, typed a letter: eat its repeats
static CFRunLoopTimerRef gCapTimer = NULL;

static bool isLetterKc(int kc) {
    switch (kc) {
        case 0: case 1: case 2: case 3: case 4: case 5: case 6: case 7: case 8: case 9:
        case 11: case 12: case 13: case 14: case 15: case 16: case 17:
        case 31: case 32: case 34: case 35: case 37: case 38: case 40: case 45: case 46:
            return true;
    }
    return false;
}

static void capCancel(void) {
    gCapKc = -1;
    if (!gCapTimer) return;
    CFRunLoopTimerInvalidate(gCapTimer);
    CFRelease(gCapTimer);
    gCapTimer = NULL;
}

static void capPost(CGEventSourceRef src, int kc, CGEventFlags flags) {
    for (int down = 1; down >= 0; down--) {
        CGEventRef k = CGEventCreateKeyboardEvent(src, kc, down);
        if (!k) continue;
        CGEventSetFlags(k, flags);
        CGEventSetIntegerValueField(k, kCGEventSourceUserData, OUR_MARK);
        CGEventPost(kCGSessionEventTap, k);
        CFRelease(k);
    }
}

static void capFire(void) {
    int out = gCapOut;
    capCancel();
    os_unfair_lock_lock(&gLock);
    bool text = [gElement isEqualToString:@"text"];
    os_unfair_lock_unlock(&gLock);
    if (atomic_load(&gTrace)) {
        fprintf(stderr, "trace capital hold kc=%d %s\n", out, text ? "-> capital" : "(not a text field: nothing)");
        fflush(stderr);
    }
    if (!text) return;
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    capPost(src, 51, 0);                              // ⌫ the lower-case one
    capPost(src, out, kCGEventFlagMaskShift);         // its capital
    if (src) CFRelease(src);
}

// A key down that typed `out` with `flags`: arm it if that was a bare letter.
static void capStart(int kc, int out, CGEventFlags flags) {
    if (!isLetterKc(out)
        || (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)))
        return;
    gNoRepeat[kc] = true;
    if (flags & kCGEventFlagMaskShift) return;
    capCancel();
    gCapKc = kc; gCapOut = out;
    gCapTimer = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + CAP_MS / 1000.0, 0, 0, 0,
        ^(CFRunLoopTimerRef t) { (void)t; if (gCapKc >= 0) capFire(); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), gCapTimer, kCFRunLoopCommonModes);
}

/* ── THE SEQUENCES ────────────────────────────────────────────────────────────
   A binding with "chain": "<id>" runs remap/chains.json's chain of that id (added
   2026-10-14): its steps in order, on their own serial queue, so a wait never holds
   up the tap. A step is a chord (tapped, its modifiers as their own events), a wait
   in ms, a COMMAND (the `fire` the page stored: a chord the app answers to, or a
   shell line) or a UNIVERSAL — universals.json's member for the app in front at the
   press (`ra` = foldApp's name), fired the same way. No member there: skipped.
   `commit`: from the press until ⏎ or ⎋ (or the app changes, or PENDING_NS), those
   two are TAKEN OVER — ⏎ runs `enter` and then sends ⏎, ⎋ runs `cancel` and then ⎋.
   That is a rename's commit: dictation stopped, then the name committed.
   remap/chain <id> asks for the same over a notification (kChainNote) — what a
   Karabiner rule (the VM's) runs, since Karabiner can only shell out. */
static NSString *const kChainNote = @"com.josh.remapd.chain";
static _Atomic int gCmdVSeen = 0;          // ⌘V downs from other apps (TIDY)
static _Atomic int gTyped = 0;             // the user's own typing key downs (TIDY)
static _Atomic int gTyped0 = 0;            // gTyped when the chain started
static NSString *const kChainReq  = @"/tmp/remapd_chain_req";
static dispatch_queue_t gChainQ;
static NSDictionary *gPending = nil;      // tap thread only: {chain, bundle}
static uint64_t gPendingNs = 0;
#define PENDING_NS (600ull * 1000000000ull)
#define STEP_GAP_US 15000                 // between steps: an app reads each key before the next

static NSString *frontApp(void) {
    os_unfair_lock_lock(&gLock);
    NSString *a = foldApp(gFrontBundle, gFrontName, gApps);
    os_unfair_lock_unlock(&gLock);
    return a ?: @"";
}

static void tapChord(NSString *chord) {
    int kc; CGEventFlags fl;
    if (![chord isKindOfClass:NSString.class] || !compileChord(chord, &kc, &fl)) {
        vlog(@"sequence: can't spell %@", chord);
        return;
    }
    // Quiet only for ⌘ / ⌥ (the tool flash): a global hotkey another app listens for
    // (Wispr Flow's ⌃⇧F) tracks real modifier downs and never fires on a quiet chord.
    Latch l = { .toKey = kc, .toFlags = fl, .repeat = 1,
                .quiet = (fl & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate)) && quietMods(),
                .added = fl & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift
                             | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl) };
    if (atomic_load(&gTrace)) {
        fprintf(stderr, "trace sequence tap %s quiet=%d hidFlags=0x%llx t=%llums\n", chord.UTF8String, l.quiet,
                (unsigned long long)CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState),
                (unsigned long long)(nowNs() / 1000000));
        fflush(stderr);
    }
    postChordHalf(&l, true);
    postChordHalf(&l, false);
}

// A trackpad-keyboard value that ACTS (2026-10-16): "tap:ctrl+shift+f" taps a chord the
// way the tap note does (real modifier downs at the HID tap — Wispr Flow's start/stop);
// "sh:<command>" runs a shell command (app switches, voice jump). gChainQ, in order.
static void waitModsUp(void);
static void auxAction(NSString *v) {
    bool tap = [v hasPrefix:@"tap:"];
    NSString *arg = [v substringFromIndex:tap ? 4 : 3];
    dispatch_async(gChainQ, ^{
        if (tap) {
            waitModsUp();
            tPostAt = kCGHIDEventTap;
            tapChord(arg);
            tPostAt = kCGSessionEventTap;
            return;
        }
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
        t.arguments = @[@"-c", arg];
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
        env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        t.environment = env;
        t.standardOutput = t.standardError = NSFileHandle.fileHandleWithNullDevice;
        [t launchAndReturnError:NULL];
    });
}

// A shell step finishes before the next step starts (5 s at most).
static void runSync(NSString *cmd) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[@"-c", cmd];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    t.environment = env;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    t.terminationHandler = ^(NSTask *x) { (void)x; dispatch_semaphore_signal(done); };
    @try { if (![t launchAndReturnError:nil]) return; } @catch (__unused id e) { return; }
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

static void fireStep(NSDictionary *f) {
    if (![f isKindOfClass:NSDictionary.class]) return;
    if ([nilIfNull(f[@"to"]) isKindOfClass:NSString.class]) tapChord(f[@"to"]);
    else if ([nilIfNull(f[@"run"]) isKindOfClass:NSString.class]) runSync(f[@"run"]);
}

static NSDictionary *universalMember(NSString *uid, NSString *app) {
    NSDictionary *doc = readJSON([gDir stringByAppendingPathComponent:@"universals.json"]);
    for (NSDictionary *u in doc[@"universals"] ?: @[]) {
        if (![u isKindOfClass:NSDictionary.class] || ![u[@"id"] isEqual:uid]) continue;
        NSDictionary *ms = u[@"members"];
        if (![ms isKindOfClass:NSDictionary.class]) return nil;
        for (NSString *k in ms) {
            NSDictionary *m = ms[k];
            if ([m isKindOfClass:NSDictionary.class] && [m[@"ra"] isEqual:app]) return m;
        }
    }
    return nil;
}

// A key step waits (1.5 s at most) for the trigger's own modifiers to come up: a
// global hotkey (Wispr Flow's ⌃⇧F) reads the keys physically held, so the ⌘ of ⌘T
// still down made it ⌘⌃⇧F and nothing fired (2026-10-15). Every step waits (3 s at
// most): a held trigger modifier can join any key a step sends, so a sequence on a
// ⌘ key (⌘R) behaves as one on a bare key.
static void waitModsUp(void) {
    const CGEventFlags mods = kCGEventFlagMaskCommand | kCGEventFlagMaskShift
                            | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl;
    for (int i = 0; i < 300 && (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & mods); i++)
        usleep(10000);
}

// TIDY (2026-10-15): the dictated text made a name — commas and full stops out
// (a decimal point between digits stays), each word's first letter capitalised (the
// rest left alone: CNC stays CNC), and the word "bracket" alternates ( / ), an
// unclosed one closed at the end. "(" hugs the word after, ")" the word before.
static NSString *tidyName(NSString *s) {
    NSString *t = [s stringByReplacingOccurrencesOfString:@"(?<!\\d)\\.|\\.(?!\\d)|,"
                                               withString:@" " options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, s.length)];
    NSMutableArray *out = [NSMutableArray array];
    BOOL open = NO, glue = NO;               // glue: the next word joins the last "("
    for (NSString *w in [t componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!w.length) continue;
        if ([w caseInsensitiveCompare:@"bracket"] == NSOrderedSame) {
            if (!open) { [out addObject:@"("]; glue = YES; }
            else if (out.count) { out[out.count - 1] = [out.lastObject stringByAppendingString:@")"]; glue = NO; }
            open = !open;
            continue;
        }
        NSString *cap = [[w substringToIndex:1].uppercaseString stringByAppendingString:[w substringFromIndex:1]];
        if (glue && out.count) out[out.count - 1] = [out.lastObject stringByAppendingString:cap];
        else [out addObject:cap];
        glue = NO;
    }
    if (open) {
        if (glue) [out removeLastObject];      // "(" with nothing after it: dropped
        else if (out.count) out[out.count - 1] = [out.lastObject stringByAppendingString:@")"];
    }
    return [out componentsJoinedByString:@" "];
}

// Always logged (remapd runs quiet): /tmp/remapd_tidy.log.
static void tlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/remapd_tidy.log", "a");
    if (f) { fprintf(f, "%llu %s\n", (unsigned long long)(nowNs() / 1000000), s.UTF8String); fclose(f); }
}

// Text typed as itself (unicode key events, 16 UTF-16 units each), over the selection —
// no clipboard: a ⌘V is read whenever the app gets to it, which in Photoshop was
// after the clipboard had been put back (2026-10-15, the raw name went in).
static void typeUnicode(NSString *t) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    for (NSUInteger i = 0; i < t.length; i += 16) {
        NSRange r = [t rangeOfComposedCharacterSequencesForRange:NSMakeRange(i, MIN(16, t.length - i))];
        unichar buf[32];
        [t getCharacters:buf range:r];
        for (int down = 1; down >= 0; down--) {
            CGEventRef k = CGEventCreateKeyboardEvent(src, 49, down);
            if (!k) continue;
            CGEventSetFlags(k, 0);
            CGEventKeyboardSetUnicodeString(k, r.length, buf);
            CGEventSetIntegerValueField(k, kCGEventSourceUserData, OUR_MARK);
            CGEventPost(tPostAt, k);
            CFRelease(k);
        }
        i = NSMaxRange(r) - 16;
        usleep(5000);
    }
    if (src) CFRelease(src);
}

// TIDY: the name Wispr Flow typed, made a name and typed over the field. No clipboard
// writes: Photoshop reads a ⌘V's clipboard only when it gets to it, so anything put
// there before Wispr's ⌘V is handled gets pasted instead (2026-10-15: a marker became
// the layer name). What was said is Wispr's transcript — it puts it on the clipboard
// (moving it from `pb0`) and then sends ⌘V, which the tap sees (`cv0` → gCmdVSeen):
// ours go after it in the app's queue. Its ⌘V not seen in 1 s: 300 ms more and go on.
static void tidyField(NSInteger pb0, int cv0) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    // Typed since the chain started: the name is what was typed — ⏎ goes now, no
    // wait on Wispr (which, stopped with nothing said, pastes nothing).
    if (atomic_load(&gTyped) != atomic_load(&gTyped0) && pb.changeCount == pb0) {
        tlog(@"typed, not said — committed at once");
        return;
    }
    uint64_t t0 = nowNs();
    // Wispr's text lands 250–550 ms after its stop (remapd_tidy.log); none by 1.5 s =
    // nothing said — the name was TYPED, and ⏎ commits it now, not 6 s later.
    while (pb.changeCount == pb0 && nowNs() - t0 < 1500000000ull) usleep(10000);
    NSString *said = pb.changeCount == pb0 ? nil : [pb stringForType:NSPasteboardTypeString];
    if (!said.length) { tlog(@"nothing said (clipboard never moved) — typed name kept"); return; }
    uint64_t t1 = nowNs();
    while (atomic_load(&gCmdVSeen) == cv0 && nowNs() - t1 < 1000000000ull) usleep(5000);
    bool seen = atomic_load(&gCmdVSeen) != cv0;
    if (!seen) usleep(300000);
    tlog(@"Wispr's text after %llu ms, its ⌘V %s after %llu ms more",
         (unsigned long long)((t1 - t0) / 1000000), seen ? "seen" : "NOT seen",
         (unsigned long long)((nowNs() - t1) / 1000000));
    NSString *tidy = tidyName(said);
    tlog(@"“%@” → “%@”", said, tidy);
    if (!tidy.length) return;
    usleep(30000);                                 // its ⌘V reaches the app first
    tapChord(@"cmd+a"); usleep(STEP_GAP_US);
    typeUnicode(tidy);
    usleep(100000);                                // typed before the ⏎ that follows
}

static void runSteps(NSArray *steps, NSString *app) {   // the chain queue only
    if (![steps isKindOfClass:NSArray.class]) return;
    // TIDY: Wispr's paste moves the clipboard and sends a ⌘V — counted from here.
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSInteger pb0 = pb.changeCount;
    int cv0 = atomic_load(&gCmdVSeen);
    for (NSDictionary *s in steps) {
        if (![s isKindOfClass:NSDictionary.class]) continue;
        NSString *k = nilIfNull(s[@"kind"]);
        if ([k isEqual:@"wait"]) { usleep((useconds_t)MAX(0, MIN(10000, [s[@"ms"] intValue])) * 1000); continue; }
        waitModsUp();                              // every step: see waitModsUp
        if ([k isEqual:@"key"]) tapChord(nilIfNull(s[@"chord"]));
        else if ([k isEqual:@"tidy"]) tidyField(pb0, cv0);
        else if ([k isEqual:@"command"]) fireStep(nilIfNull(s[@"fire"]));
        else if ([k isEqual:@"universal"]) {
            NSDictionary *m = universalMember(nilIfNull(s[@"id"]), app);
            if (m) fireStep(nilIfNull(m[@"fire"]));
            else vlog(@"sequence: universal %@ has nothing in %@", s[@"id"], app);
        }
        usleep(STEP_GAP_US);
    }
}

// Tap thread (main queue): look the chain up and run it on the chain queue.
// `kc`: the key that ran it (-1 from remap/chain) — pressed again while the commit
// is pending, it commits like ⏎ (pendingKey).
static void startChain(NSString *cid, int kc, CGEventFlags kf) {
    hudFor(true, cid);
    atomic_store(&gTyped0, atomic_load(&gTyped));
    os_unfair_lock_lock(&gLock);
    NSString *bundle = [gFrontBundle copy];
    os_unfair_lock_unlock(&gLock);
    NSString *app = frontApp();
    dispatch_async(gChainQ, ^{
        NSDictionary *doc = readJSON([gDir stringByAppendingPathComponent:@"chains.json"]);
        NSDictionary *c = nil;
        for (NSDictionary *x in doc[@"chains"] ?: @[])
            if ([x isKindOfClass:NSDictionary.class] && [x[@"id"] isEqual:cid]) { c = x; break; }
        if (!c) { vlog(@"sequence: no chain %@", cid); return; }
        vlog(@"sequence: %@ in %@", c[@"label"] ?: cid, app);
        if ([nilIfNull(c[@"commit"]) boolValue])
            dispatch_async(dispatch_get_main_queue(), ^{
                gPending = @{ @"chain": c, @"bundle": bundle ?: @"", @"app": app, @"key": @(kc),
                              @"mods": @(kf & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift
                                             | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl)) };
                gPendingNs = nowNs();
            });
        runSteps(c[@"steps"], app);
    });
}

// ⏎ / ⎋ while a commit is pending: the chain's own end, then the key itself. The
// key that ran the chain, pressed again, is a ⏎ (2026-10-15: V, talk, V) — taken here,
// before any situation, since the app may now be in a text field.
// True = taken (the caller swallows it). Tap thread only.
static bool pendingKey(int kc, CGEventFlags flags) {
    // Its key again = the same key with the same modifiers: a bare R typed into the
    // name is a letter, not ⌘R (2026-10-15, R cancelled the rename).
    const CGEventFlags mods = kCGEventFlagMaskCommand | kCGEventFlagMaskShift
                            | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl;
    bool again = gPending && kc >= 0 && [gPending[@"key"] intValue] == kc
              && (flags & mods) == (CGEventFlags)[gPending[@"mods"] unsignedLongLongValue];
    if (!gPending || !(kc == 36 || kc == 76 || kc == 53 || again)) return false;
    os_unfair_lock_lock(&gLock);
    NSString *now = [gFrontBundle copy];
    os_unfair_lock_unlock(&gLock);
    if (nowNs() - gPendingNs > PENDING_NS || ![now isEqualToString:gPending[@"bundle"]]) {
        vlog(@"sequence: commit dropped (app changed or too old)");
        gPending = nil;
        return false;
    }
    // ⏎ / ⎋ with a modifier is someone else's; the chain's own key again carries its
    // trigger's modifiers (⌘R, 2026-10-15) — refusing those re-ran the chain instead.
    if (!again && (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate))) return false;
    NSDictionary *c = gPending[@"chain"];
    NSString *app = gPending[@"app"];
    gPending = nil;
    bool enter = kc != 53;
    vlog(@"sequence: %@ %@%@", c[@"label"] ?: c[@"id"], enter ? @"commit" : @"cancel", again ? @" (its key again)" : @"");
    dispatch_async(gChainQ, ^{
        runSteps(c[enter ? @"enter" : @"cancel"], app);
        waitModsUp();
        tapChord(enter ? @"return" : @"escape");
    });
    return true;
}

// A gesture's sequence (auxPadFire, any thread): the same gesture again while its
// commit is pending commits it like ⏎ (2026-10-17: a second 3-finger tap re-ran Rename
// (Voice) — Wispr toggled off with the raw text and rename reopened). Started with no
// key (-1): 0 is A, and Space+A then committed it.
static void padChain(NSString *cid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPending && [gPending[@"chain"][@"id"] isEqual:cid] && pendingKey(36, 0)) return;
        startChain(cid, -1, 0);
    });
}

/* ── The tap─────────────────────────────────────────────────────────────────── */
static CFMachPortRef gTap = NULL;

// `double`: the first press only arms (swallowed, its repeats and up with it); the
// next within the window goes on as normal and disarms, so a third is a first again.
static bool doubleSwallow(int kc, RRule *win) {
    if (!win || win.doubleMs <= 0) return false;
    uint64_t t = nowNs();
    if (!gDoubleNs[kc] || t - gDoubleNs[kc] > (uint64_t)win.doubleMs * 1000000ull) {
        gDoubleNs[kc] = t;
        gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = -1 };
        vlog(@"%@: first of a double press — swallowed", win.ident);
        return true;
    }
    gDoubleNs[kc] = 0;
    return false;
}

/* A 4/5-finger app switch on the main pad leaked a 2/3-finger scroll (2026-10-16):
   fingers lift one by one, the last two are still sliding, and macOS scrolls (and
   coasts) with them — a sideways scroll is back/forward in a browser. So while a
   whole hand is down (gMainHandNs) the main pad's scrolls are dropped, and the
   scroll that leaked is eaten to its end, momentum included, until a new scroll
   begins. Fusion and SketchUp keep theirs: 4 fingers pan there (reanchor). Tap thread. */
static bool mainHandScroll(CGEventRef ev) {
    static bool eating = false;
    int64_t phase = CGEventGetIntegerValueField(ev, kCGScrollWheelEventScrollPhase);
    int64_t momentum = CGEventGetIntegerValueField(ev, kCGScrollWheelEventMomentumPhase);
    if (nowNs() - atomic_load(&gMainHandNs) < 400ull * 1000000ull) {
        os_unfair_lock_lock(&gLock);
        bool cad = [gFrontBundle hasPrefix:@"com.autodesk.fusion"] || [gFrontBundle hasPrefix:@"com.sketchup."];
        os_unfair_lock_unlock(&gLock);
        if (cad) { eating = false; return false; }
        eating = true;
        return true;
    }
    if (!eating) return false;
    if (momentum == 0 && (phase == kCGScrollPhaseBegan || phase == 0)) { eating = false; return false; }   // a new scroll / a wheel
    return true;
}

/* A touch that LANDED as a pinch (gMainPinch, touchCallback) scrolls nothing: its
   scrolls are dropped while it is down, and the one it began eaten to its end,
   momentum included, until a new scroll begins. Tap thread. */
static bool mainPinchScroll(CGEventRef ev) {
    static bool eating = false;
    if (atomic_load(&gMainPinch) || nowNs() - atomic_load(&gMainPinchNs) < 150ull * 1000000ull) { eating = true; return true; }
    if (!eating) return false;
    int64_t phase = CGEventGetIntegerValueField(ev, kCGScrollWheelEventScrollPhase);
    int64_t momentum = CGEventGetIntegerValueField(ev, kCGScrollWheelEventMomentumPhase);
    if (momentum == 0 && (phase == kCGScrollPhaseBegan || phase == 0)) { eating = false; return false; }
    return true;
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type,
                              CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    // Re-arm rather than die. A tap disabled by timeout is otherwise permanent,
    // and the symptom is "my remaps stopped" with the process still running.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        return event;
    }
    // Scrolling / coasting, for the roll guard (auxEmit). Read before anything eats it.
    if (type == kCGEventScrollWheel && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 0) {
        int64_t ph = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
        int64_t mo = CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase);
        if (mo != 0 || ph == kCGScrollPhaseBegan || ph == kCGScrollPhaseChanged || ph == kCGScrollPhaseEnded)
            atomic_store(&gScrollAnyNs, nowNs());
    }
    // The keyboard's held modifiers, for the trackpad keyboard's keys (auxPostKey).
    if (type == kCGEventFlagsChanged) {
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) != OUR_MARK)
            atomic_store(&gHwFlags, CGEventGetFlags(event) & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift
                                    | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate));
        return event;
    }
    // reanchor's thumb-pinch zoom over Fusion / Max / Photoshop (+ its Photoshop pan), and FusionScrollFilter's zoom made of
    // it (2026-10-18): finished scrolls — no thumb-down / pinch / whole-hand rule drops them.
    if (type == kCGEventScrollWheel) {   // the mark alone (FusionScrollFilter), or mark << 32 | amount (reanchor)
        int64_t ud = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
        // ...but a CLAIMED touch zooms nothing (THE CLAIM): reanchor stops its own zoom
        // there; this catches a tick from the frame before it read the claim.
        bool pinch = (ud >> 32) == NAV_ZOOM_MARK || (ud >> 32) == PS_ZOOM_MARK;
        if (pinch && atomic_load(&gMainClaim) && atomic_load(&gMainFingers) > 0
            && CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase) == kCGScrollPhaseChanged)
            return NULL;
        if (ud == NAV_ZOOM_MARK || pinch || ud == PS_PAN_MARK) return event;
        if (ud != OUR_MARK) {   // a running scroll, for the thumb read (gScrollLive)
            int64_t ph = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
            if (ph == kCGScrollPhaseBegan) { atomic_store(&gScrollBeganNs, nowNs()); atomic_store(&gScrollLive, true); }
            else if (ph == kCGScrollPhaseEnded || ph == kCGScrollPhaseCancelled) atomic_store(&gScrollLive, false);
        }
    }
    // A whole hand on the main pad is typing.on / off, never the Dock's pinch / spread.
    if ((type == 18 || type == 19 || type == 20 || type == 29 || type == 30 || type == 31)
        && nowNs() - atomic_load(&gMainHandNs) < 400ull * 1000000ull) {
        if (atomic_load(&gTrace)) { fprintf(stderr, "trace whole hand: dropped gesture event %d\n", (int)type); fflush(stderr); }
        return NULL;
    }
    if (type == kCGEventScrollWheel && CGEventGetIntegerValueField(event, kCGEventSourceUserData) != OUR_MARK
        && mainHandScroll(event)) {
        if (atomic_load(&gTrace)) { fprintf(stderr, "trace whole hand: dropped scroll\n"); fflush(stderr); }
        return NULL;
    }
    // A pinch (by its landing): no scroll, no magnify / rotate — it is a bound gesture.
    if (type == kCGEventScrollWheel && CGEventGetIntegerValueField(event, kCGEventSourceUserData) != OUR_MARK
        && mainPinchScroll(event))
        return NULL;
    if ((type == 18 || type == 19 || type == 20 || type == 29 || type == 30) && atomic_load(&gMainPinch))
        return NULL;
    // Photoshop never zooms on a pinch (2026-10-18): scroll zooms there and pinches are
    // bound gestures. Drop magnify — NSEventTypeMagnify (30), or a gesture event (29)
    // whose HID subtype (field 110) is zoom (8) — even when the landing read as a scroll.
    if ((type == 30 || (type == 29 && CGEventGetIntegerValueField(event, 110) == 8))
        && [gFrontBundle hasPrefix:@"com.adobe.Photoshop"])
        return NULL;
    // The thumb-down session (gMainThumbSess): every button press in it is dropped, and
    // a dropped down takes its drags and up with it. A down from before keeps its up.
    {
        bool down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
        bool up   = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
        bool drag = type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged;
        static bool eating = false;   // tap thread only
        int64_t ud = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
        if ((down || up || drag) && ud != OUR_MARK && ud != NAV_MMB_MARK) {   // reanchor's nav MMB passes
            if (eating && (up || drag)) { if (up) eating = false; return NULL; }
            if (down && atomic_load(&gMainThumbSess)
                && (atomic_load(&gMainFingers) > 0 || nowNs() - atomic_load(&gLiftNs) < CLICK_GUARD_GRACE_NS)) {
                eating = true;
                fprintf(stderr, "aux right: thumb-down session click dropped (type %d)\n", (int)type); fflush(stderr);
                return NULL;
            }
        }
    }
    if ((type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged) && atomic_load(&gAuxCount)
        && CGEventGetIntegerValueField(event, kCGEventSourceUserData) != OUR_MARK)
        auxLogMove(event);
    // THUMB-DOWN PIN (2026-10-18): macOS ignores the resting thumb, so a swiping finger
    // moves the pointer; detaching leaked from a background process (it flew off and
    // snapped back, or stayed off). Every move goes back to the pin and is dropped —
    // the warp also suppresses the pad's moves for a moment, which helps.
    if (atomic_load(&gMainThumbHold) && atomic_load(&gMainFingers) > 0
        && (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged)
        && CGEventGetIntegerValueField(event, kCGEventSourceUserData) != OUR_MARK) {
        CGPoint pin;
        os_unfair_lock_lock(&gPosLock); pin = gThumbPin; os_unfair_lock_unlock(&gPosLock);
        CGWarpMouseCursorPosition(pin);
        return NULL;
    }
    // OWN CURSOR: the right pad's native events (user data 0; not ours, not reanchor's).
    if (atomic_load(&gAuxSender) && !auxSent(event) && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 0) {
        if (atomic_load(&gAuxPinned)) {
            CGPoint pin;
            os_unfair_lock_lock(&gPosLock); pin = gAuxPin; os_unfair_lock_unlock(&gPosLock);
            // Frozen: its motion is posted by ownMove — the native move is dropped, and a
            // leaked one (detach undone under us) puts the cursor back on the pin.
            if (isMove(type)) {
                CGPoint p = CGEventGetLocation(event);
                if (p.x != pin.x || p.y != pin.y) { CGAssociateMouseAndMouseCursorPosition(false); CGWarpMouseCursorPosition(pin); }
                return NULL;
            }
            // Clicks, pressure, scrolls, gestures: where the cursor is SEEN.
            if (type != kCGEventKeyDown && type != kCGEventKeyUp) CGEventSetLocation(event, pin);
        } else if (isMove(type) && !atomic_load(&gMainThumbHold)) ownNoteEvent(event);   // learn the feel
    }
    if (type != kCGEventKeyDown && type != kCGEventKeyUp && auxOwnsEvent(type, event)) {
        if (gAuxFrozen && (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged)) {
            // A move that beat the freeze — or the freeze undone under us (another
            // process re-associating the mouse): re-detach, and back to the pin.
            CGPoint p = CGEventGetLocation(event), pin;
            os_unfair_lock_lock(&gPosLock); pin = gAuxPin; os_unfair_lock_unlock(&gPosLock);
            if (p.x != pin.x || p.y != pin.y) {
                if (atomic_load(&gTrace)) { fprintf(stderr, "trace aux cursor leak %.0f,%.0f (pin %.0f,%.0f) front=%s\n",
                    p.x, p.y, pin.x, pin.y,
                    NSWorkspace.sharedWorkspace.frontmostApplication.localizedName.UTF8String ?: "?"); fflush(stderr); }
                CGAssociateMouseAndMouseCursorPosition(false);
                CGWarpMouseCursorPosition(pin);
            }
        }
        if (atomic_load(&gTrace) && type != kCGEventMouseMoved && type != kCGEventLeftMouseDragged)
            { fprintf(stderr, "trace aux pad: dropped event type %d\n", (int)type); fflush(stderr); }
        return NULL;
    }
    // A two-finger TAP's right-click (2026-10-28: Photoshop's menu opened and the tap's
    // own binding, Eraser, closed it at once): held like a multi-finger tap-click, and
    // dropped if the tap's binding fires within TAP_CLICK_WAIT_MS. A real press (no up
    // within TAP_CLICK_GAP_NS) goes out as it was, that much late.
    if (type == kCGEventRightMouseDown || type == kCGEventRightMouseUp || type == kCGEventRightMouseDragged) {
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == OUR_MARK) return event;
        if (type == kCGEventRightMouseDragged) return gRightHeld ? NULL : event;
        if (type == kCGEventRightMouseDown) {
            if (gRightHeld) { CFRelease(gRightHeld); gRightHeld = NULL; }
            if (atomic_load(&gOff)) return event;
            if (atomic_load(&gMainFingers) < 2 && nowNs() - atomic_load(&gLiftNs) > AUX_LIFT_GRACE_NS) return event;
            gRightHeld = CGEventCreateCopy(event);
            gRightNs = nowNs();
            uint64_t gen = ++gRightGen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, TAP_CLICK_GAP_NS), dispatch_get_main_queue(), ^{
                if (gen != gRightGen || !gRightHeld) return;   // a press: its down goes out now
                CGEventSetIntegerValueField(gRightHeld, kCGEventSourceUserData, OUR_MARK);
                CGEventPost(kCGSessionEventTap, gRightHeld);
                CFRelease(gRightHeld); gRightHeld = NULL;
            });
            return NULL;
        }
        if (!gRightHeld) return event;   // a press's up: its down went out already
        CGEventRef down = gRightHeld, up = CGEventCreateCopy(event);
        gRightHeld = NULL; ++gRightGen;
        uint64_t since = gRightNs;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, TAP_CLICK_WAIT_MS * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            bool fired = atomic_load(&gPadFireNs) > since;
            fprintf(stderr, "tap right-click %s\n", fired ? "dropped (gesture bound)" : "sent"); fflush(stderr);
            if (!fired) for (int i = 0; i < 2; i++) {
                CGEventRef e2 = i ? up : down;
                CGEventSetIntegerValueField(e2, kCGEventSourceUserData, OUR_MARK);
                CGEventPost(kCGSessionEventTap, e2);
            }
            CFRelease(down); CFRelease(up);
        });
        return NULL;
    }
    bool leftButton = type == kCGEventLeftMouseDown || type == kCGEventLeftMouseDragged
                   || type == kCGEventLeftMouseUp;
    if (!leftButton && type != kCGEventKeyDown && type != kCGEventKeyUp) return event;   // main pad's pointer
    if (leftButton) {
        // our own late post of a held down (heldDownLate) — already decided
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == OUR_MARK) return event;
        if (gTapWait) {   // a tap-click is waiting on its gesture: so does this
            if (type != kCGEventLeftMouseDragged) [gTapWait addObject:(__bridge_transfer id)CGEventCreateCopy(event)];
            return NULL;
        }
        // Space held + click in a Fusion window, Control Room or the Max Browser =
        // Option-click, which is how those pages SELECT a group, folder or layer instead
        // of opening it. Karabiner already sends Option with the hold while Fusion itself
        // is frontmost; with one of these frontmost the hold is only F20, which never
        // reaches the page.
        if (type != kCGEventLeftMouseDragged && atomic_load(&gHold) == HOLD_SPACE) {
            os_unfair_lock_lock(&gLock);
            NSString *app = foldApp(gFrontBundle, gFrontName, gApps);
            BOOL maxBrowser = [gFrontBundle isEqualToString:@"com.josh.MaxBrowser"];
            os_unfair_lock_unlock(&gLock);
            if (maxBrowser || [app isEqualToString:@"fusionwin"] || [app isEqualToString:@"controlroom"])
                CGEventSetFlags(event, CGEventGetFlags(event) | kCGEventFlagMaskAlternate);
        }
        if (atomic_load(&gTrace) && type != kCGEventLeftMouseDragged) {
            fprintf(stderr, "trace left%s fingers=%d t=%llums\n", type == kCGEventLeftMouseDown ? "Down" : "Up",
                    atomic_load(&gFingers), (unsigned long long)(nowNs() / 1000000)); fflush(stderr);
        }
        // The click guard and the held down (see their declarations). Only a down
        // STARTS swallowing, so a drag already under way keeps its own up.
        if (type == kCGEventLeftMouseDown) {
            if (gHeldDown) { CFRelease(gHeldDown); gHeldDown = NULL; }
            if (atomic_load(&gOff)) { gEatingDrag = false; return event; }
            bool live = atomic_load(&gClickGuard)
                && (atomic_load(&gMainFingers) > 0
                    || nowNs() - atomic_load(&gLiftNs) < CLICK_GUARD_GRACE_NS);
            gEatingDrag = live;
            if (gEatingDrag) { vlog(@"click guard: swallowed the finger-chord click"); return NULL; }
            int f = atomic_load(&gMainFingers);   // only the main pad's fingers press its button
            bool ps = false;
            if (f >= 1 && f < 3) {
                os_unfair_lock_lock(&gLock);
                ps = [foldApp(gFrontBundle, gFrontName, gApps) isEqualToString:@"photoshop"];
                os_unfair_lock_unlock(&gLock);
            }
            if (f >= 2 || ps) {
                gHeldDown = CGEventCreateCopy(event);
                gHeldAt = CGEventGetLocation(event);
                gHeldNs = nowNs();
                gHeldMulti = f >= 2;
                // Photoshop under 1–2 fingers: a press on the pad just before a
                // finger chord's key would paint a dab. Hold it HELD_SHORT_MS; a
                // chord in that time drops it, otherwise it goes out late but intact.
                if (ps) heldDownLate(++gHeldGen);
                return NULL;
            }
            return event;
        }
        if (gEatingDrag) {
            if (type == kCGEventLeftMouseUp) gEatingDrag = false;
            return NULL;
        }
        if (!gHeldDown) return event;
        if (type == kCGEventLeftMouseDragged) {
            CGPoint p = CGEventGetLocation(event);
            if (hypot(p.x - gHeldAt.x, p.y - gHeldAt.y) < HELD_DRAG_PX) return NULL;
        }
        // A multi-finger tap-click: wait for the gesture (TAP_CLICK_WAIT_MS). Clicks
        // that follow while waiting (the lifting fingers' own, ~35 ms later) wait with it.
        if (type == kCGEventLeftMouseUp && gHeldMulti && nowNs() - gHeldNs < TAP_CLICK_GAP_NS) {
            gTapWait = [NSMutableArray arrayWithObjects:(__bridge_transfer id)gHeldDown,
                        (__bridge_transfer id)CGEventCreateCopy(event), nil];
            uint64_t since = gHeldNs;
            gHeldDown = NULL; ++gHeldGen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, TAP_CLICK_WAIT_MS * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                NSArray *held = gTapWait;
                gTapWait = nil;
                bool fired = atomic_load(&gPadFireNs) > since;
                if (atomic_load(&gTrace)) { fprintf(stderr, "trace tap-click ×%lu %s\n", (unsigned long)held.count / 2,
                                                    fired ? "dropped (gesture bound)" : "sent"); fflush(stderr); }
                if (!fired) for (id o in held) {
                    CGEventRef e2 = (__bridge CGEventRef)o;
                    CGEventSetIntegerValueField(e2, kCGEventSourceUserData, OUR_MARK);
                    CGEventPost(kCGSessionEventTap, e2);
                }
            });
            return NULL;
        }
        // A real drag, or a tap-click: the down goes out first, then this event.
        CGEventTapPostEvent(proxy, gHeldDown);
        CFRelease(gHeldDown); gHeldDown = NULL;
        return event;
    }
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) return event;

    int kc = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (kc < 0 || kc > 127) return event;
    int64_t mark = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (mark == OUR_MARK) return event;
    // TIDY waits on another app's ⌘V (Wispr Flow's paste) going by.
    if (type == kCGEventKeyDown && kc == 9 && (CGEventGetFlags(event) & kCGEventFlagMaskCommand))
        atomic_fetch_add(&gCmdVSeen, 1);
    // ...and on the user typing the name instead (no ⌘ / ⌃, not ⏎ / ⎋).
    if (type == kCGEventKeyDown && kc != 36 && kc != 76 && kc != 53
        && !(CGEventGetFlags(event) & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)))
        atomic_fetch_add(&gTyped, 1);
    // A key the letter hold held back, sent now: resolved as of when it was pressed.
    int replayHold = (mark >= REPLAY_BASE && mark <= REPLAY_BASE + HOLD_MAX)
                   ? (int)(mark - REPLAY_BASE) : -1;
    bool replayed = replayHold >= 0;

    // ── The hold axis. Sampled here, not by the worker: it IS key events. ──
    bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    // ── The capital hold: a typed letter never repeats; another key down cancels it. ──
    if (type == kCGEventKeyUp) {
        gNoRepeat[kc] = false;
        if (kc == gCapKc) capCancel();
    } else if (repeat) {
        if (gNoRepeat[kc]) return NULL;
    } else if (!replayed) {
        gNoRepeat[kc] = false;   // capStart below re-arms it if this types a letter
        if (kc != gCapKc) capCancel();
    }
    if (kc == KC_F20) {
        // Space held (Karabiner's report). Never reaches an app.
        if (type == kCGEventKeyUp) {
            atomic_store(&gHold, lhSpaceUp());
        } else if (!repeat) {
            // a J, K or L still undecided was typing, and goes first — or D (F) + Space
            atomic_store(&gHold, lhSpace());
        }
        if (atomic_load(&gTrace)) {
            fprintf(stderr, "trace hold -> %s\n", holdName(atomic_load(&gHold)));
            fflush(stderr);
        }
        // ...except to a browser: a page can read F20 as "space held" (joshcallis-site
        // edit mode: hold space while dragging = swap). F20 does nothing there otherwise.
        os_unfair_lock_lock(&gLock);
        BOOL browser = [gFrontBundle isEqualToString:@"com.google.Chrome"]
                    || [gFrontBundle isEqualToString:@"com.apple.Safari"];
        os_unfair_lock_unlock(&gLock);
        return browser ? event : NULL;
    }
    if (kc == KC_LITERAL) {
        if (type == kCGEventKeyDown && !repeat) gLiteralNs = nowNs();
        return NULL;
    }
    bool literal = false;
    if (!replayed && type == kCGEventKeyDown && !repeat && gLiteralNs) {
        literal = nowNs() - gLiteralNs < LITERAL_NS;
        gLiteralNs = 0;
    }
    // ── A sequence waiting for its commit takes ⏎ / ⎋ first (THE SEQUENCES). ──
    if (!replayed && type == kCGEventKeyDown && !repeat && !atomic_load(&gOff)
        && pendingKey(kc, CGEventGetFlags(event))) {
        gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = -1 };
        return NULL;
    }
    // ── The letter hold (J, J+K, J+K+L): may hold this key back, or decide on it. ──
    if (!replayed && letterHold(type, kc, repeat, event, literal)) return NULL;
    if (literal) {
        // Karabiner's output is never rewritten — but a `double` rule still guards it:
        // caps lock IS ⎋ (F19 + ⎋), and that ⎋ is the one Claude's stop must see twice.
        if (!atomic_load(&gOff)) {
            NSString *dom[4] = {nil, nil, nil, nil};
            RRule *w = resolveKey(kc, CGEventGetFlags(event) & MODMASK, atomic_load(&gHold),
                                  atomic_load(&gFingers), dom, NULL, 0);
            if (doubleSwallow(kc, w)) return NULL;
        }
        gLatch[kc].active = false;   // its up passes untouched too
        if (atomic_load(&gTrace)) {
            fprintf(stderr, "trace kc=%-3d -> (literal: Karabiner's output)\n", kc);
            fflush(stderr);
        }
        return event;
    }

    if (type == kCGEventKeyUp) {
        Latch *l = &gLatch[kc];
        if (!l->active) return event;
        if (l->added || l->posted) { postChordHalf(l, false); l->active = false; return NULL; }
        bool swallow = l->swallow;
        applyLatch(event, l);
        l->active = false;
        return swallow ? NULL : event;
    }

    // Autorepeat: replay, never re-resolve.
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) && gLatch[kc].active) {
        Latch *l = &gLatch[kc];
        if (l->repeat > 1 || l->hasThen || l->tap || l->lineStop) {
            postBurst(l);
            return NULL;
        }
        applyLatch(event, l);
        // A posted chord's repeats go out rewritten: its modifiers are down by now.
        return l->swallow && !l->added && !l->posted ? NULL : event;
    }

    if (atomic_load(&gOff)) return event;

    CGEventFlags flags = CGEventGetFlags(event) & MODMASK;
    // macOS sets fn on every F-key press, held or not, so "f13" would never match
    // a bare rule. For those keys fn says nothing and is dropped.
    if (isFunctionKey(kc)) flags &= ~kCGEventFlagMaskSecondaryFn;
    int fingers = atomic_load(&gFingers);
    int hold = replayed ? replayHold : atomic_load(&gHold);

    // A rule that CLAIMS this key but loses on one axis is the only interesting
    // thing about a passthrough, and until now it was invisible: the resolver
    // simply `continue`d and the key went out untouched, identical to a key no
    // binding had ever claimed. Recorded into a fixed buffer rather than an
    // NSString because this runs under the lock on the tap thread.
    bool trace = atomic_load(&gTrace);
    char miss[512]; miss[0] = 0;

    NSString *dom[4] = {nil, nil, nil, nil};
    RRule *win = resolveKey(kc, flags, hold, fingers, dom, trace ? miss : NULL, sizeof miss);
    NSString *app = dom[0], *elem = dom[1], *cmd = dom[2], *skt = dom[3];

    // The trace is the whole answer to "it typed a letter that time and a number
    // every time after". A key that fires logs under -v already; a key that does
    // NOT fire logged nothing at all, which is the one case worth seeing, because
    // passthrough is both the correct default and every failure's symptom. Age is
    // printed with it: an axis that is merely LATE looks identical to an axis that
    // is wrong until you can see that the sample predates the keystroke.
    if (trace) {
        uint64_t t = nowNs();
        double ageMs   = (double)(t - atomic_load(&gSampleNs))  / 1e6;
        double frameMs = (double)(t - atomic_load(&gFingersNs)) / 1e6;
        char winbuf[160] = "(passthrough)";
        if (win) {
            if (win.repeat > 1)
                snprintf(winbuf, sizeof winbuf, "%s ×%d", win.ident.UTF8String, win.repeat);
            else
                snprintf(winbuf, sizeof winbuf, "%s", win.ident.UTF8String);
        }
        fprintf(stderr, "trace kc=%-3d flags=0x%llx  hold=%-15s app=%-10s element=%-6s "
                        "command=%-8s sketch=%-7s fingers=%d (frame %.0fms ago)  sample %.0fms old  -> %s%s\n",
                kc, (unsigned long long)flags, holdName(hold), (app ?: @"-").UTF8String,
                elem.UTF8String, (cmd ?: @"-").UTF8String, (skt ?: @"-").UTF8String,
                fingers, frameMs, ageMs,
                winbuf, miss);
        fflush(stderr);
    }

    bool fresh = type == kCGEventKeyDown && !repeat;
    if (!win) {
        if (fresh) capStart(kc, kc, flags);
        return event;   // passthrough — the default, and the safe one
    }

    vlog(@"%@  hold=%s app=%@ element=%@ command=%@ fingers=%d  -> %@%@",
         win.ident, holdName(hold), app ?: @"-", elem, cmd, fingers, win.run ?: @"(chord)",
         win.repeat > 1 ? [NSString stringWithFormat:@" ×%d", win.repeat] : @"");

    if (fresh && doubleSwallow(kc, win)) return NULL;

    // Any finger chord, not only 3+: a 1-finger R (Brush Tool) in Photoshop came with a
    // real press on the pad, which painted a dab (2026-10-14).
    if (type == kCGEventKeyDown && win.fMin >= 1 && atomic_load(&gMainFingers) >= 1) {
        atomic_store(&gClickGuard, true);
        if (gHeldDown) {   // the resting fingers' press never reaches the app
            CFRelease(gHeldDown); gHeldDown = NULL;
            gEatingDrag = true;
            vlog(@"click guard: dropped the held finger-chord press");
        }
    }

    if (win.chain || win.run) {
        gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = -1, .toFlags = 0, .repeat = 0 };
        if (win.chain) { if (fresh) startChain(win.chain, kc, CGEventGetFlags(event)); }
        else runShell(win.run);
        return NULL;
    }
    CGEventFlags outFlags = win.toFlags | (win.shiftThrough ? (flags & kCGEventFlagMaskShift) : 0);
    // A key rebound to ⏎ / ⎋ commits / cancels a pending sequence like the real one —
    // and isn't the name being typed (TIDY's gTyped counted it above).
    if (fresh && !atomic_load(&gOff) && (win.toKey == 36 || win.toKey == 76 || win.toKey == 53)
        && win.repeat <= 1 && !win.hasThen && pendingKey(win.toKey, outFlags)) {
        if (kc != 36 && kc != 76 && kc != 53 && !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)))
            atomic_fetch_sub(&gTyped, 1);
        gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = -1 };
        return NULL;
    }
    if (latchBurst(kc, win, outFlags)) return NULL;
    CGEventFlags added = outFlags & ~flags & (MODMASK & ~kCGEventFlagMaskSecondaryFn);
    if (added && win.toKey >= 0) {
        // Swallowed and posted (postChordHalf), so the modifiers get their own ups.
        gLatch[kc] = (Latch){ .active = true, .swallow = true, .toKey = win.toKey,
                              .toFlags = outFlags, .repeat = 1, .added = added, .held = flags,
                              .quiet = quietMods() };
        postChordHalf(&gLatch[kc], true);
        return NULL;
    }
    gLatch[kc] = (Latch){ .active = true, .swallow = false, .toKey = win.toKey,
                          .toFlags = outFlags, .repeat = 1 };
    applyLatch(event, &gLatch[kc]);
    if (fresh && win.toKey >= 0) capStart(kc, win.toKey, outFlags);
    return event;
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(int argc, const char *argv[]) {
    BOOL check = NO;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) gVerbose = YES;
        else if (!strcmp(argv[i], "-d")) { gDump = YES; gVerbose = YES; }
        else if (!strcmp(argv[i], "--check")) {
            check = YES;
            // An optional directory, so a candidate config can be proved before it
            // is ever put where the running daemon will pick it up. THIS MODE OPENS
            // NO EVENT TAP: verifying a config must not be able to remap a key.
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                gDir = [NSString stringWithUTF8String:argv[++i]];
            }
        }
    }
    kBindings   = [gDir stringByAppendingPathComponent:@"bindings.json"];
    kSituations = [gDir stringByAppendingPathComponent:@"situations.json"];

    @autoreleasepool {
        if (check) {
            gVerbose = YES;
            loadConfig();
            os_unfair_lock_lock(&gLock);
            NSArray<RRule *> *rs = gRules;
            os_unfair_lock_unlock(&gLock);
            if (!rs) { fprintf(stderr, "remapd --check: nothing loaded\n"); return 1; }
            printf("%lu binding(s) this daemon would run, most specific first:\n",
                   (unsigned long)rs.count);
            for (RRule *r in rs) {
                printf("  %-22s key=%d flags=0x%llx  hold=%-15s apps=%-24s element=%-8s "
                       "command=%-8s fingers=%d..%d  -> %s\n",
                       r.ident.UTF8String, r.fromKey, (unsigned long long)r.fromFlags,
                       r.hold >= 0 ? holdName(r.hold) : "any",
                       (r.apps.count ? [r.apps componentsJoinedByString:@","] : @"any").UTF8String,
                       (r.element ?: @"any").UTF8String, (r.command ?: @"any").UTF8String,
                       r.fMin, r.fMax, r.chain ? "chain" : r.run ? "run" : r.block ? "block" : "chord");
            }
            return 0;
        }
        loadConfig();

        // A background daemon's timers are coalesced: the letter hold's ran ~75 ms
        // late, and its 40 ms release grace never fired in time (2026-10-14).
        static id gActivity;
        gActivity = [NSProcessInfo.processInfo
            beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
                              reason:@"key timing"];
        [NSThread detachNewThreadWithBlock:^{ @autoreleasepool { workerLoop(); } }];
        gAuxQ = dispatch_queue_create("remapd.auxpad", DISPATCH_QUEUE_SERIAL);
        gAuxSrc = CGEventSourceCreate(kCGEventSourceStatePrivate);   // flags set per key (auxPostKey)
        auxgestInit(&gGest[PAD_LEFT], auxEmitPad, auxThumb, (void *)(intptr_t)PAD_LEFT);
        auxgestInit(&gGest[PAD_RIGHT], auxEmitPad, auxThumb, (void *)(intptr_t)PAD_RIGHT);
        gGest[PAD_RIGHT].early = auxEarly;
        gGest[PAD_RIGHT].wants = auxWants;
        gGest[PAD_RIGHT].restSecs = true;   // fingers resting on the right pad: their own sections (auxgest agRestOf)
        gGest[PAD_LEFT].thumbSide = 1; gGest[PAD_RIGHT].thumbSide = -1;   // thumbs land inward
        // 2026-10-17: thumbs retired on BOTH pads — every contact is a finger (1–5); a
        // contact already resting when four fingers tap makes it tap5 (auxgest agRester).
        gGest[PAD_LEFT].noThumb = gGest[PAD_RIGHT].noThumb = true;
        auxLoadKeys();
        auxLoadPrint();
        gainLoad();   // OWN CURSOR's learnt feel, saved every 30 s while it learns
        dispatch_source_t gainTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gainTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(gainTimer, ^{ gainSave(); });
        dispatch_resume(gainTimer);
        static dispatch_source_t keepGainTimer; keepGainTimer = gainTimer;
        startMultitouchHotplug(touchCallback);

        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
                         | CGEventMaskBit(kCGEventFlagsChanged)   // gHwFlags
                         | CGEventMaskBit(kCGEventLeftMouseDown)
                         | CGEventMaskBit(kCGEventLeftMouseDragged)
                         | CGEventMaskBit(kCGEventLeftMouseUp);   // the click guard
        // The aux pad's pointer (auxOwnsEvent): only watched when one is configured,
        // so a plain setup never routes pointer motion through this tap.
        gAuxWanted = auxpadSetting() != nil;
        if (gAuxWanted)
            mask |= CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventScrollWheel)
                  | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
                  | CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventOtherMouseDown)
                  | CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventOtherMouseDragged)
                  | CGEventMaskBit(18) | CGEventMaskBit(19) | CGEventMaskBit(20)   // rotate, begin/end gesture
                  | CGEventMaskBit(29) | CGEventMaskBit(30) | CGEventMaskBit(31)   // gesture, magnify, swipe
                  | CGEventMaskBit(32) | CGEventMaskBit(34);                       // smart magnify, pressure
        gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault, mask, tapCallback, NULL);
        if (!gTap) {
            fprintf(stderr, "remapd: could not create the event tap — is Accessibility "
                            "granted to this binary? Exiting so the keyboard stays plain.\n");
            return 1;
        }
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        CGEventTapEnable(gTap, true);

        // THE HUD's chords: what the app receives, after this tap and Karabiner.
        gHudTap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGTailAppendEventTap,
                                   kCGEventTapOptionListenOnly, CGEventMaskBit(kCGEventKeyDown), hudTapCallback, NULL);
        if (gHudTap) {
            CFRunLoopSourceRef hsrc = CFMachPortCreateRunLoopSource(NULL, gHudTap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), hsrc, kCFRunLoopCommonModes);
            CGEventTapEnable(gHudTap, true);
        } else fprintf(stderr, "remapd: no HUD tap — Show Name on HUD chords will not flash\n");

        // WHY THIS NOTIFICATION AND NOT THE AX ONE. The header's finding stands —
        // kAXFocusedUIElementChangedNotification is not emitted reliably by
        // WKWebView hosts, so the ELEMENT axis has to be polled. App ACTIVATION is
        // a different event with a different reputation: it is emitted by the
        // workspace itself, for every app, without an observer per process.
        //
        // It matters because of what the polled version cost. Fusion's companion
        // dialogs are .accessory apps that activate themselves from an 80ms hover
        // timer, so the panel takes the keyboard some time before any poll notices,
        // and the first keystroke into an empty box resolved against the app you
        // just left. That is one letter where a number was meant, every time the
        // dialog opens — the failure is invisible in the log precisely because
        // passthrough is the correct default.
        //
        // Delivered on this thread, which is the tap's: the block takes the lock,
        // stores two strings and signals the worker. No AX, no I/O, nothing that
        // can block the tap. The worker does the asking, one wake-up sooner.
        [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceDidActivateApplicationNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            NSRunningApplication *a = note.userInfo[NSWorkspaceApplicationKey];
            if (!a) return;
            os_unfair_lock_lock(&gLock);
            gFrontBundle = a.bundleIdentifier ?: @"";
            gFrontName   = a.localizedName    ?: @"";
            gElement     = @"none";   // belongs to the app we just left
            os_unfair_lock_unlock(&gLock);
            atomic_store(&gSampleNs, nowNs());
            wakeWorker();
        }];

        // remap/chain <id>: a sequence asked for from outside the tap (THE SEQUENCES).
        gChainQ = dispatch_queue_create("remapd.chain", DISPATCH_QUEUE_SERIAL);
        int chainTok;
        notify_register_dispatch(kChainNote.UTF8String, &chainTok, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            NSString *cid = [[NSString stringWithContentsOfFile:kChainReq encoding:NSUTF8StringEncoding error:NULL]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (cid.length) startChain(cid, -1, 0);
        });

        // remap/tap <chord>: one chord tapped from outside — claude_ask's dictation
        // start/stop (Wispr Flow's ⌃⇧F), which needs remapd's real-modifier posting
        // and its wait for the trigger's own modifiers to come up.
        int tapTok;
        notify_register_dispatch("com.josh.remapd.tap", &tapTok, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            NSString *ch = [[NSString stringWithContentsOfFile:@"/tmp/remapd_tap_req" encoding:NSUTF8StringEncoding error:NULL]
                            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (ch.length) dispatch_async(gChainQ, ^{
                waitModsUp();
                tPostAt = kCGHIDEventTap;
                tapChord(ch);
                tPostAt = kCGSessionEventTap;
            });
        });

        // distance_zoom's level (bin/distance_zoom.m). ui_zoom.sh's screen glide re-fits
        // windows over AX and snapshots them for its stand-ins: run under the helper's
        // own grants, each snapshot waited on a screen-capture consent alert (~20 s a
        // zoom, 2026-10-20). Run here, it has ours. Only a number is taken, so the note
        // can't be used to run anything else. 0.35 s glide: quicker than a press.
        int zoomTok;
        notify_register_dispatch("com.josh.remapd.uizoom", &zoomTok, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            int pct = [[NSString stringWithContentsOfFile:@"/tmp/remapd_uizoom_req" encoding:NSUTF8StringEncoding
                                                    error:NULL] intValue];
            if (pct >= 100 && pct <= 300)
                runShell([NSString stringWithFormat:
                          @"UI_ZOOM_GLIDE=0.35 /Users/josh/Code/Scripts/ui_zoom.sh set %d", pct]);
        });

        vlog(@"remapd: tap open");
        CFRunLoopRun();
    }
    return 0;
}

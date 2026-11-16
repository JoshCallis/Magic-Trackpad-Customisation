#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>   // accessibility (canvas hit-test)
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>                           // trackpad hot-plug notifications
#include <stdatomic.h>
#include <math.h>                                     // fabs (1-finger orbit dedup)
#include <time.h>                                     // clock_gettime (dock-tap stamp)
#include <sys/stat.h>                                 // nav.json mtime (3ds Max)
#include <sys/socket.h>                               // the Max bridge socket
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <spawn.h>                                    // the HUD (thumb calibration)
#include <sys/wait.h>
#include <libproc.h>                                  // proc_name (remapd's re-posts)
#include <sys/mman.h>                                 // the thumb-pin word shared with remapd
#include <fcntl.h>
#include <pthread.h>                                  // the nav output queue (navOutAdd)

// A 3-finger TAP over the FusionDock window (the Browser/Params dock) is published
// here for the dock to act on — it jumps to the top level. BetterTouchTool's own
// 3-finger-tap trigger is set to All Apps but only converts the gesture over that
// window about one time in ten (measured), while it is reliable over Fusion's canvas.
// Rather than depend on it, the tap is recognised HERE: this process already tracks
// the exact gesture (3 fingers down, no movement, all lifted) for CAD nav.
#define DOCK_TAP_FILE "/tmp/fusion_dock_tap"          // out: "<epoch_ms>"
#define DOCK_TAP_PX   12                              // moved more than this ⇒ a drag, not a tap
#define DOCK_TAP_MS   80                              // ...and lasted longer than this ⇒ fingers RESTING on the
                                                      // trackpad and then lifting, which must not fire. A tap is
                                                      // brief; without this, simply touching three fingers down
                                                      // and releasing jumped to the top level.
// A 3-finger TAP over Fusion's CANVAS (no fingers → three → none within CANVAS_TAP_MS,
// no travel, no orbit) is reported as the `tap3` click gesture, in the file
// FusionScrollFilter writes its click/tap2 gestures to; the Click Actions add-in runs
// whatever fusion_ui/clicks.json binds to it (Go to Top Level). This replaces BTT's
// 3-finger-tap → double-click, which FusionScrollFilter still also recognises (as a
// synthetic tap3) if it is ever turned back on. Synthetic flag 0 here = no click
// reached Fusion (the gesture's left events are swallowed), so nothing was picked.
#define CLICK_EVENT_FILE "/tmp/fusion_click_event"   // out: "<epoch_ms> tap3 <mods> 0"
#define CANVAS_TAP_MS    250                         // first finger down → last finger up. Timed from the
                                                     // FIRST touch, not the 3-finger frame, so resting three
                                                     // fingers, or scrolling with two and adding a third,
                                                     // then lifting doesn't count — only a quick tap does.
#define KC_F20           90                          // Karabiner's held-space report (see FusionScrollFilter)
// Where the dock window is, in CG screen coords: "<x> <y> <w> <h> <visible>", rewritten
// by FusionDock 4x a second. A CGWindowList lookup CANNOT be used for this (an earlier
// cut tried): the dock's window does not appear in the on-screen list THIS process
// sees, though the identical walk finds it from a shell — so the window publishes its
// own geometry instead.
#define DOCK_FRAME_FILE "/tmp/fusion_dock_frame"

// reanchor — turns a 3-finger trackpad drag into CAD navigation (Fusion / SketchUp).
// Build (PREFER `bin/build.sh` — it builds AND code-signs all the nav binaries):
//   clang -O2 -fobjc-arc -o reanchor reanchor.m \
//     -framework Cocoa -framework CoreGraphics -framework ApplicationServices \
//     -framework IOKit -F/System/Library/PrivateFrameworks -framework MultitouchSupport
//   codesign -f -s "Apple Development: you@example.com" -i com.josh.reanchor reanchor
// The codesign step is MANDATORY: elementIsCanvas() (the canvas gate) calls the AX
// API, which macOS TCC checks against THIS binary's code identity. An unsigned tool
// loses its Accessibility grant on every rebuild → the AX query fails → the gate
// fails OPEN and nav fires over chrome. A stable signature keeps the one-time grant.
//   cp reanchor /Users/josh/Code/Scripts/reanchor   (then reanchor.sh orbit to restart)
//
// STATUS: fully working.
//   • focused CAD: 3-finger drag orbits; Shift (or F via Karabiner) pans; live toggle.
//   • Fusion's canvas + Max (2026-10-18): 2 fingers orbit, 3 pan, thumb + 2 fingers
//     pinch-zoom — "Fusion / Max touch nav" below. SketchUp keeps the 3-finger orbit.
//   • 3ds Max in the Parallels VM (2026-10-10): the same, plus 2-finger scroll → zoom
//     frames streamed to Max — see "3ds Max in the Parallels VM" below and max/callis/nav.py;
//     and the Browser's 3-finger tap (clicks are read in Windows: max/callis/rclick.py).
//   • drag-to-focus: drag over an inactive Fusion/SketchUp focuses it AND navigates,
//     with a live Shift/F pan toggle whether or not the key was held when the drag began.
//   • 1-finger orbit-centre: a single finger that moves the cursor over Fusion's
//     viewport and then holds still (or lifts) sets the orbit pivot under the pointer
//     — the same requestOrbitCenter() a 3-finger drag fires on lift. This folds in the
//     old `fusion_dwell` python daemon AND the BTT `/tmp/fusion_dwell_active`
//     touch/rm triggers that fed it: reanchor has authoritative finger counts and
//     keeps getting frames while a finger rests still, so it does the dwell itself.
//     (The BTT triggers + fusion_dwell.sh on/off can be retired once this is live.)
//
// F-as-Shift during drag-to-focus — how it's solved:
//   SketchUp reads the *physical* Shift key (at the HID layer Karabiner owns), so a
//   synthetic CGEvent Shift from reanchor can't make it pan — only Karabiner's F->Shift
//   can. But Karabiner's rule is normally gated on the CAD app being frontmost, which a
//   drag-to-focus isn't. The fix: reanchor runs a throttled hover watch and sets the
//   Karabiner variable `cad_hover` while the pointer is over a Fusion/SketchUp window;
//   Karabiner's F->Shift rule has a branch gated on `cad_hover == 1`, so F becomes Shift
//   over the viewport regardless of focus. Bonus: because Karabiner sits below the
//   CGEvent layer, it converts F->Shift before BetterTouchTool can intercept the key.
//   (BTT had F-key triggers that turned a held F into a tap — invisible once Karabiner
//   claims F first.) reanchor itself only sees the resulting Shift, via physicalShift.

typedef struct { float x,y; } mtPoint;
typedef struct { mtPoint pos,vel; } mtReadout;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, foo3, foo4;
    mtReadout normalized;
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    mtReadout mm;
    int zero2[2];
    float unk2;
} Finger;
typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int,Finger*,int,double,int);
MTDeviceRef MTDeviceCreateDefault(void);
MTDeviceRef MTDeviceCreateFromService(io_service_t);   // bind a SPECIFIC trackpad (hot-plug)
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
#include "auxpad.h"   // the aux pad is remapd's modifier pad — never nav
#include "auxgest.h"  // the thumbprint (AgPrint, agFeatures) — the pinch zoom's thumb
#include "navwords.h" // the pin / claim words shared with remapd
#include "hidpoint.h" // HID-tap posts under the screen zoom (they land at point ÷ zoom otherwise)

// Two ways a 3-finger drag is steered into CAD navigation:
//   MODE_MMB      — the proven path. Suppress the real left-drag and synthesize a
//                   middle-button drag instead. Pan/orbit is chosen from the live Shift
//                   state (physical, or Karabiner's F->Shift): the choice is baked into
//                   the MMB modifier at button-down and re-issued on a mid-drag toggle.
//                   Used whenever the CAD app is frontmost, and for an inactive Fusion.
//   MODE_ACTIVATE — the drag that focuses an *inactive* SketchUp. A synthetic click
//                   can't raise the window and an MMB never focuses it, but the
//                   gesture's own real left-down does — so we pass that left-down
//                   straight through to focus the app, then on the first drag frame
//                   release it and hand off to MODE_MMB. The net effect: the drag
//                   both focuses the app AND behaves exactly like the focused case.
// MODE_INERT — the gesture began over the FusionDock window. No CAD nav happens
// there, but the gesture is still latched so (a) its own hardware left events are
// swallowed, so a 3-finger tap can't click a row in the browser, and (b) the lift can
// tell a tap from a drag and stamp DOCK_TAP_FILE.
// MODE_ZOOM — thumb + fingers over Fusion's canvas / Max / Photoshop's canvas: a pinch zoom (§ Fusion / Max touch nav).
// MODE_VOID — a Fusion / Max 3-finger gesture a 4th finger turned into a swipe: inert to the lift.
enum { MODE_NONE = 0, MODE_MMB, MODE_ACTIVATE, MODE_INERT, MODE_ZOOM, MODE_VOID };

static atomic_bool threeFinger   = false;   // a 3-finger drag is engaged over CAD
static atomic_bool mmbEngaged    = false;   // the synthetic MMB is actually DOWN. Deferred from
                                            // touchdown to the first drag frame: a 3-finger TAP
                                            // (touch+lift, no movement) never presses any button,
                                            // so BetterTouchTool's tap triggers keep firing over
                                            // the canvas (BTT won't recognise a tap while it sees
                                            // a button held). A drag pays nothing: the MMB starts
                                            // on its first movement frame — the first moment an
                                            // orbit could have any visible effect anyway.
static atomic_bool isSynthetic   = false;   // re-entry guard for our own MMB events
static atomic_bool physicalShift = false;   // live state of the Shift key (physical or Karabiner F->Shift)
// A 4th finger on a 3-finger CAD drag = pan, the way Shift / F does (2026-10-16). From
// then to the lift the motion is read off the touches (fourOwn): whether macOS keeps
// three-finger-dragging with four down is not ours to count on, so its drags are dropped.
static atomic_bool gFourPan = false;        // 4+ fingers down on an engaged CAD drag
static atomic_bool gFourOwn = false;        // the gesture's motion comes from the touches
static bool gSketchUpDrag = false;          // this gesture is over SketchUp (reads the REAL Shift)
#define FOUR_PX_PER_MM 9.0                 // touch travel → pointer travel while the touches drive
#define FUSION_PAN_GAIN 2.0                // Fusion pans (F / 4th finger) move this × the touch (2026-10-17)
// Fusion / Max (2026-10-21): THREE fingers orbit, two pan (§ Fusion / Max touch nav).
// gThreePan keeps its name: it marks the latched 3-finger drag, which now ORBITS.
static atomic_bool gThreePan = false;       // the latched 3-finger drag is over Fusion's canvas / Max
static atomic_bool gNavPan = false;         // a touch-driven nav has 2 fingers down: pan
static _Atomic double gThreeMs = 0;         // nowMs() of the latch: the pan waits PAN_SETTLE_MS for a 4th finger
#define PAN_SETTLE_MS 20.0                  // ms — a 4th finger landing this soon makes it a swipe (user: 20, not 80)
static bool panWanted(void) {
    return atomic_load(&physicalShift) || atomic_load(&gFourPan) || atomic_load(&gNavPan);
}
static atomic_bool mmbArmed      = false;   // MODE_ACTIVATE: MMB drag has been started
static atomic_int  pendingActivatePid = 0;  // inactive Fusion: focus it when the drag ends
static atomic_int  dragMode      = MODE_NONE;
static atomic_bool threeEvaluated = false;  // CAD-or-not is decided once, at the gesture's first 3-finger frame
static atomic_bool threeDecided  = false;   // ...and that decision has FINISHED (it waits on an AX query)

// Held left-down. The OS turns a 3-finger drag into a hardware left-down/drag, and
// that can reach the event tap BEFORE the touch callback has finished deciding
// CAD-or-not — the AX canvas query is answered by the CAD app's own main thread, so
// a heavy Fusion model stalls it. Passed through, that left-down starts a selection
// box in the viewport instead of an orbit. So while 3+ fingers are down and the
// decision is pending, the tap HOLDS the gesture's left-down; when the decision
// lands it is dropped (CAD → the MMB nav takes over) or re-posted (anything else →
// e.g. a dialog's 3-finger window drag carries on natively). A physical one-finger
// click never has 3 fingers down, so it is never held.
static atomic_int  gFingers      = 0;       // finger count of the latest touch frame
static atomic_bool leftHeld      = false;
static CGPoint     leftHeldPos;
#define AX_TIMEOUT_S 0.08f                  // cap on each AX call; a busy CAD app fails OPEN (= canvas), Photoshop closed

// The 1-finger dwell and 2-finger focus paths also query AX. They run on this serial
// queue, never on the multitouch thread, so a stalled query can't delay the frames
// that the 3-finger decision depends on.
static dispatch_queue_t gAXQueue;
static void logSlow(const char *what, double ms) {
    FILE *f = fopen("/tmp/reanchor.log", "a");
    if (!f) return;
    time_t t = time(NULL); char ts[32];
    strftime(ts, sizeof ts, "%m-%d %H:%M:%S", localtime(&t));
    fprintf(f, "%s %s %.0fms\n", ts, what, ms);
    fclose(f);
}
static double nowMs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}
// nowMs() of the last Space change. A touch that began before it (the swipe INTO the
// Space, or fingers landing while it slid in) never navigates — only gestures begun on
// the active Space zoom / pan / orbit (user, 2026-10-18: zooms fired on arrival).
static _Atomic double gSpaceChangeMs = 0;
// `touch /tmp/reanchor_trace` logs every MMB press / re-issue with an epoch stamp, to
// line up against what Fusion was doing at that moment.
static void trace(const char *what) {
    if (access("/tmp/reanchor_trace", F_OK) != 0) return;
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    FILE *f = fopen("/tmp/reanchor.log", "a");
    if (!f) return;
    fprintf(f, "%.3f %s\n", ts.tv_sec + ts.tv_nsec / 1e9, what);
    fclose(f);
}

// Two-finger drag-to-focus: a sustained 2-finger touch over an UNFOCUSED CAD
// window activates it, so a 2-finger scroll zooms it the way a 3-finger drag
// orbits it (replacing the old BetterTouchTool "activate window under cursor"
// trigger). Once Fusion is focused, yabai's application_activated signal starts
// FusionScrollFilter, whose activation-grace window holds the first zoom until
// its camera feed is fresh — so the zoom no longer flings to a stale pivot.
static atomic_bool twoActivated  = false;   // already activated CAD this 2-finger gesture
static double      twoStartTs     = 0.0;    // timestamp (s) the current 2-finger run began (0 = none)
#define TWO_ACTIVATE_DELAY 0.07             // s — sustained-2-finger dwell before activating;
                                            // rides out the 2-finger frames a 3-finger touchdown passes through

// One-finger dwell/lift -> orbit centre. A single finger that MOVES the cursor and
// then holds still for ONE_STILL_SECS, or lifts before that, fires an orbit-centre
// request at the pointer — replacing the retired fusion_dwell daemon (and its flaky
// BTT-driven /tmp/fusion_dwell_active signal). The "must have moved" rule means just
// resting a finger never fires; the dedup means re-dwelling on the same spot is a
// no-op. Engagement requires a SINGLE finger and no 3-finger drag in progress.
static double  oneStartTs    = 0.0;          // timestamp (s) the current 1-finger run began (0 = none)
static int     oneStillX     = 0;            // cursor px where the current stillness began
static int     oneStillY     = 0;
static double  oneStillSince  = 0.0;         // timestamp (s) the cursor arrived at (oneStillX,oneStillY)
static bool    oneMoved      = false;        // cursor has moved during this 1-finger run
static bool    oneFired      = false;        // already fired this run
static double  lastOrbitX    = -1e9;         // where the last 1-finger orbit centre was requested (dedup)
static double  lastOrbitY    = -1e9;
#define ONE_STILL_SECS 0.05                 // s — cursor still this long (after moving) before a dwell fire (~50 ms)
#define ONE_DEDUP_PX   6.0                  // px — skip a fire within this distance of the last ("already set here")

// Hover watch -> Karabiner. While the pointer is over a CAD window we set the Karabiner
// variable `cad_hover`; Karabiner's F->Shift rule fires on it so F pans during a
// drag-to-focus even though the CAD app isn't frontmost (see the header note).
static atomic_bool cadHoverState = false;
static void setCadHover(bool on) {
    if (on == atomic_load(&cadHoverState)) return;
    atomic_store(&cadHoverState, on);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        @autoreleasepool {
            NSTask *t = [[NSTask alloc] init];
            t.launchPath = @"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli";
            t.arguments = @[@"--set-variables", on ? @"{\"cad_hover\":1}" : @"{\"cad_hover\":0}"];
            @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
        }
    });
}

// A Fusion companion window (FusionValue, Params, Browser, Dock, Shortcuts) holding
// focus is part of Fusion's own UI, not "another app": activating Fusion over it on a
// 2-finger touch only made the companion grab focus back ~0.27 s later, and every
// bounce tripped the scroll filter's activation grace (zoom swallowed → jumpy).
// Same names as config/borders_exclude's companions.
#define COMPANION_FRONT_FILE "/tmp/fusion_companion_front"
static bool frontIsCompanion(void) {
    @autoreleasepool {
        NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
        NSString *n = app.localizedName;
        return n && [@[@"FusionValue", @"FusionParams", @"FusionBrowser", @"FusionDock",
                       @"FusionShortcuts"] containsObject:n];
    }
}
// Mirrored to a file because FusionScrollFilter (a separate C process) needs the same
// answer at the start of a zoom gesture, before any of our own dwell logic has run.
static void publishCompanionFront(void) {
    const char *v = frontIsCompanion() ? "1" : "0";
    FILE *f = fopen(COMPANION_FRONT_FILE, "w");
    if (f) { fputs(v, f); fclose(f); }
}

static pid_t cadUnderCursor(bool *isFront, bool *isFusion, bool *isMax);
static void refreshCadHover(void) { setCadHover(cadUnderCursor(NULL, NULL, NULL) != 0); }

// ── 3ds Max in the Parallels VM ──────────────────────────────────────────────
// To the Mac, Max is just "the Parallels window". Max's side (max/callis/nav.py)
// publishes, over the shared folder, whether Max is the Windows foreground app, its
// viewport panel's rect and the rects of its own windows that cover it, all in Windows
// desktop pixels, plus its IP. With the VM window's frame that maps the Mac pointer into
// Windows and answers "over Max's viewport" — the gate the Fusion paths get from AX.
//   • 3-finger drag → NOT a synthetic MMB: {"lang":"nav","op":"drag",...} frames (deltas
//     in Windows px, Shift = pan) and an "end" at the lift, down the same socket. Max's
//     own orbit can't always pivot on the surface under the cursor, misses XRef scenes
//     and draws a marker, so nav.py orbits/pans itself (2026-10-10). No click reaches
//     Max, so an unfocused Max needs no activating click (focus follows the lift). F
//     (Karabiner, via cad_hover) pans, live mid-drag, as in Fusion.
//   • 2-finger scroll → swallowed here and streamed to Max down one bridge socket as
//     {"lang":"nav","op":"zoom",...} frames; Max dollies toward the point under the
//     cursor (curve + pivot live Max-side, so they're tuned without a rebuild).
#define MAX_NAV_FILE  "/Users/josh/Code/Scripts/max/.state/nav.json"
#define MAX_NAV_STALE 5.0                       // s — older = Max gone (it rewrites every 2 s)
#define MAX_COVERS    16
static struct {
    bool fg; double deskW, deskH;
    CGRect panel; CGRect covers[MAX_COVERS]; int nCovers;
    char ip[64]; int port;
} gMax;
static struct timespec gMaxMtime;
static double gMaxWritten = 0;                  // the file's own "t" (epoch s)
static CGRect gMaxVMRect;                       // the VM window, as last seen by cadUnderCursor
static atomic_bool gMaxDrag = false;            // the latched 3-finger drag is over Max

static CGRect rectFrom(NSArray *a) {
    if (![a isKindOfClass:[NSArray class]] || a.count < 4) return CGRectNull;
    return CGRectMake([a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]);
}

// Re-read nav.json when its mtime changes (one stat() otherwise). False = no live Max.
static bool loadMaxNav(void) {
    struct stat st;
    if (stat(MAX_NAV_FILE, &st) != 0) return false;
    if (st.st_mtimespec.tv_sec != gMaxMtime.tv_sec || st.st_mtimespec.tv_nsec != gMaxMtime.tv_nsec) {
        gMaxMtime = st.st_mtimespec;
        @autoreleasepool {
            NSData *d = [NSData dataWithContentsOfFile:@MAX_NAV_FILE];
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if (![j isKindOfClass:[NSDictionary class]] || !j[@"panel"]) { gMaxWritten = 0; return false; }
            gMax.fg = [j[@"fg"] boolValue];
            NSArray *desk = j[@"desk"];
            gMax.deskW = desk.count == 2 ? [desk[0] doubleValue] : 0;
            gMax.deskH = desk.count == 2 ? [desk[1] doubleValue] : 0;
            gMax.panel = rectFrom(j[@"panel"]);
            gMax.nCovers = 0;
            for (NSArray *c in j[@"covers"])
                if (gMax.nCovers < MAX_COVERS) gMax.covers[gMax.nCovers++] = rectFrom(c);
            strlcpy(gMax.ip, [j[@"ip"] UTF8String] ?: "", sizeof gMax.ip);
            gMax.port = [j[@"port"] intValue];
            gMaxWritten = [j[@"t"] doubleValue];
        }
    }
    return gMaxWritten > 0 && [[NSDate date] timeIntervalSince1970] - gMaxWritten < MAX_NAV_STALE;
}

// The Mac point `p` in Windows desktop pixels, given the VM window's bounds `r` (top-left
// CG coords). The desktop fills the window's width; anything above it is title bar.
static CGPoint macToWindows(CGPoint p, CGRect r) {
    double s = gMax.deskW > 0 ? r.size.width / gMax.deskW : 1.0;
    double top = r.origin.y + r.size.height - gMax.deskH * s;
    return CGPointMake((p.x - r.origin.x) / s, (p.y - top) / s);
}

// `p` over the VM window `r` lands on Max's viewport, with Max frontmost in Windows and
// none of Max's own dialogs / floaters on top there.
static bool maxViewportAt(CGPoint p, CGRect r, bool coherence, CGPoint *win) {
    if (!loadMaxNav() || (!coherence && !gMax.fg)) return false;
    CGPoint w = macToWindows(p, r);
    if (!CGRectContainsPoint(gMax.panel, w)) return false;
    for (int i = 0; i < gMax.nCovers; i++)
        if (CGRectContainsPoint(gMax.covers[i], w)) return false;
    if (win) *win = w;
    return true;
}

// One persistent socket to the bridge; frames are fire-and-forget. A failed write closes
// it (the frame is dropped — a zoom tick, never worth a stall) and the next one reconnects.
static dispatch_queue_t gNetQ;
static int gMaxSock = -1;
static void maxSendFrame(NSData *json) {
    NSString *ipStr = @(gMax.ip);
    int port = gMax.port ?: 27120;
    dispatch_async(gNetQ, ^{
        const char *ip = ipStr.UTF8String;
        if (gMaxSock < 0 && ip[0]) {
            int s = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
            inet_pton(AF_INET, ip, &a.sin_addr);
            struct timeval tv = { 0, 300000 };
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
            int one = 1;
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) gMaxSock = s;
            else { close(s); logSlow("max bridge connect failed", 0); return; }
        }
        if (gMaxSock < 0) return;
        uint32_t n = htonl((uint32_t)json.length);
        if (write(gMaxSock, &n, 4) != 4 || write(gMaxSock, json.bytes, json.length) != (ssize_t)json.length) {
            close(gMaxSock);
            gMaxSock = -1;
        }
    });
}

// Which scroll-delta sign means "zoom in" — FusionScrollFilter learns it from Fusion's
// camera; Max zooms the same way round so the gesture means the same in both.
static int zoomInSign(void) {
    static int sign = 0;
    if (!sign) {
        sign = 1;
        FILE *f = fopen("/tmp/fusion_zoom_in_sign", "r");
        if (f) { int v = 0; if (fscanf(f, "%d", &v) == 1 && (v == 1 || v == -1)) sign = v; fclose(f); }
    }
    return sign;
}

// A zoom frame at the Mac point `at`: `d` > 0 = in, in scroll pixels. From the thumb
// pinch (§ Fusion / Max touch nav); `begin` = the fingers just landed (pivot under `at`).
static void maxZoomFrame(CGPoint at, double d, bool begin) {
    CGPoint win = macToWindows(at, gMaxVMRect);
    char buf[200];
    snprintf(buf, sizeof buf, "{\"lang\":\"nav\",\"op\":\"zoom\",\"x\":%.0f,\"y\":%.0f,\"d\":%.1f,\"t\":%.4f,\"begin\":%s}",
             win.x, win.y, d, [[NSDate date] timeIntervalSince1970], begin ? "true" : "false");
    maxSendFrame([NSData dataWithBytes:buf length:strlen(buf)]);
}

// 2-finger scroll over Max's viewport → swallowed: two fingers ORBIT there now, read off
// the touches (2026-10-18; it zoomed before — the zoom is the thumb pinch). The over-Max
// decision is made at the gesture's begin and latched through its momentum tail; a plain
// mouse wheel (no phases) is left alone.
static bool gMaxScroll = false;
static CGEventRef maxScroll(CGEventRef event) {
    int64_t phase = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    int64_t momentum = CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase);
    if (!CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous) || (!phase && !momentum))
        return event;
    if (phase == kCGScrollPhaseBegan) {
        bool isMax = false;
        gMaxScroll = cadUnderCursor(NULL, NULL, &isMax) != 0 && isMax;
    }
    return gMaxScroll ? NULL : event;
}

// 3-finger drag over Max → drag frames. `begin` carries where the drag started (the pivot
// is picked under it); dx/dy are the event's own deltas, so they keep coming at a screen edge.
static void maxDragFrameAt(CGPoint at, double mdx, double mdy, bool begin) {
    double s = gMax.deskW > 0 && gMaxVMRect.size.width > 0 ? gMax.deskW / gMaxVMRect.size.width : 1.0;
    double dx = mdx * s, dy = mdy * s;
    CGPoint win = macToWindows(at, gMaxVMRect);
    char buf[220];
    snprintf(buf, sizeof buf, "{\"lang\":\"nav\",\"op\":\"drag\",\"x\":%.0f,\"y\":%.0f,\"dx\":%.2f,\"dy\":%.2f,\"shift\":%s,\"begin\":%s}",
             win.x, win.y, dx, dy, panWanted() ? "true" : "false", begin ? "true" : "false");
    maxSendFrame([NSData dataWithBytes:buf length:strlen(buf)]);
}
static void maxDragFrame(CGEventRef event, bool begin) {
    maxDragFrameAt(CGEventGetLocation(event), CGEventGetDoubleValueField(event, kCGMouseEventDeltaX),
                   CGEventGetDoubleValueField(event, kCGMouseEventDeltaY), begin);
}
static void maxDragEnd(void) {
    const char *end = "{\"lang\":\"nav\",\"op\":\"end\"}";
    maxSendFrame([NSData dataWithBytes:end length:strlen(end)]);
}

// Max's Click Actions (Fusion's, max/callis/browser.py § the viewport's gestures): only
// the three-finger tap comes from here → {"op":"tap3"} (gMaxTouch, at the lift). Clicks
// and right-clicks are read inside Windows (max/callis/rclick.py): Parallels takes the
// mouse ahead of this tap, so swallowing a right-click here never kept Max's quad menu
// shut — and tapping every right-click on the Mac made context menus elsewhere flash.
static void clickMods(char *out, size_t n);
static bool gMaxTouch = false;
static void maxGesture(const char *op) {
    char mods[48], buf[200];
    clickMods(mods, sizeof mods);
    snprintf(buf, sizeof buf, "{\"lang\":\"nav\",\"op\":\"%s\",\"mods\":\"%s\"}", op, mods);
    maxSendFrame([NSData dataWithBytes:buf length:strlen(buf)]);
}

// ── Photoshop ────────────────────────────────────────────────────────────────
// Thumb + 2 fingers over Photoshop's canvas → the pinch ZOOM, as in Fusion (2026-10-21,
// user): the touch nav's zoom (§ Fusion / Max touch nav) posts its ticks tagged
// PS_ZOOM_MARK, which pscursor turns into ⌥-scrolls on its zoom curve. Two fingers PAN,
// read off the touches like Fusion's (navTwoFrame target 3, gNavPs) and posted as pixel
// scrolls tagged PS_PAN_MARK at the (still) pointer; pscursor swallows the hardware
// canvas scroll and scales ours. So the thumb landing on a pan zooms and lifting off a
// zoom pans again, fingers down throughout (navJudge / navResume), as in Fusion. Three
// fingers are a normal macOS 3-finger drag again (the 3-finger pan of 10-11 → 10-21 is gone).
//   • The canvas is pscursor's published rect (PS_CANVAS_FILE): the canvas VIEW's
//     frame, so the docked panels — inside the same window, and one AXStandardWindow
//     to AX — are not canvas. A Photoshop launched without the hook (not via open.sh)
//     publishes nothing: no canvas at all (it pans natively; nothing would read our tags).
//   • A 3-contact landing that isn't the thumb yet holds its left-down for the thumb
//     watch (gPsWatch: the shape score peaks over the landing frames), then lets it out.
#define PS_CANVAS_FILE "/tmp/pscursor_canvas"   // pscursor: "pid x y w h" (global, top-left)
#define PS_ZOOM_MARK   0x70737a6d  // 'pszm' — keep in sync: pscursor.m, remapd.m
#define PS_PAN_MARK    0x70616e    // kCGEventSourceUserData on our pan scrolls — keep in sync: pscursor.m


// JankyBorders' click-through outline: a LAYER-0 window ~10 px bigger than the window it
// frames, on top of it — so a front-to-back hit test must look through it.
static bool isBorderOverlay(CFStringRef owner) {
    return owner && CFStringCompare(owner, CFSTR("borders"), 0) == kCFCompareEqualTo;
}

// True iff `p` is on Photoshop's canvas: the topmost window there is Photoshop's main
// window (layer 0; other apps' non-zero-layer overlays are looked through, as in
// cadUnderCursor) and `p` is inside the canvas rect pscursor published for that
// Photoshop. No rect from this Photoshop (no hook) → false.
static bool psCanvasAt(CGPoint p) {
    CFArrayRef wins = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!wins) return false;
    bool main = false;
    int pid = 0;
    for (CFIndex i = 0, n = CFArrayGetCount(wins); i < n; i++) {   // front-to-back
        CFDictionaryRef info = CFArrayGetValueAtIndex(wins, i);
        CFDictionaryRef b = CFDictionaryGetValue(info, kCGWindowBounds);
        CGRect r;
        if (!b || !CGRectMakeWithDictionaryRepresentation(b, &r) || !CGRectContainsPoint(r, p)) continue;
        int layer = 1;
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        if (layerRef) CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        CFStringRef owner = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (isBorderOverlay(owner)) continue;
        // Invisible overlays (Photoshop's own full-screen layer-8 window at alpha 0.01,
        // seen 2026-10-18) are looked through too.
        double alpha = 1;
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
        if (alpha < 0.05) continue;
        bool ps = owner && CFStringHasPrefix(owner, CFSTR("Adobe Photoshop"));
        if (!ps && layer != 0) continue;
        main = ps && layer == 0;
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        if (pidRef) CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        break;
    }
    CFRelease(wins);
    if (!main) return false;
    FILE *f = fopen(PS_CANVAS_FILE, "r");
    if (!f) return false;
    int fpid = 0;
    double x, y, w, h;
    bool ok = fscanf(f, "%d %lf %lf %lf %lf", &fpid, &x, &y, &w, &h) == 5;
    fclose(f);
    if (!ok || fpid != pid) return false;
    return CGRectContainsPoint(CGRectMake(x, y, w, h), p);
}

// One pan scroll at `at` (px down / right = the content follows the fingers). A scroll
// posted to a tap WARPS the pointer to its location, so `at` is where the pointer is.
static void psPostScroll(CGPoint at, int px, int pxX, int64_t phase) {
    CGEventRef e = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, 0, 0, 0);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, phase);
    double ly = px / 10.0, lx = pxX / 10.0;
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, ly == 0 ? 0 : ly > 0 ? fmax(1, lround(ly)) : fmin(-1, lround(ly)));
    CGEventSetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1, ly);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis1, px);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2, lx == 0 ? 0 : lx > 0 ? fmax(1, lround(lx)) : fmin(-1, lround(lx)));
    CGEventSetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis2, lx);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis2, pxX);
    CGEventSetLocation(e, at);
    CGEventSetFlags(e, 0);
    CGEventSetIntegerValueField(e, kCGEventSourceUserData, PS_PAN_MARK);   // pscursor: a pan, not a zoom
    CGEventPost(kCGSessionEventTap, e);   // our pid → eventCallback passes it untouched
    CFRelease(e);
}

// The 3-finger decision is final: a left-down the tap held meanwhile (see leftHeld) is
// dropped, or handed on where it was pressed. True if one was held.
static bool settleHeld(bool drop) {
    atomic_store(&threeDecided, true);
    bool held = atomic_exchange(&leftHeld, false);
    if (held && !drop) {
        CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, leftHeldPos, kCGMouseButtonLeft);
        hidPlace(down); CGEventPost(kCGHIDEventTap, down);         // our pid → the tap passes it
        CFRelease(down);
        CFRelease(src);
    }
    return held;
}

// Is `pid` remapd? Cached by pid (remapd restarts get a new one).
static bool isRemapd(pid_t pid) {
    static _Atomic pid_t yes = 0, no = 0;
    if (pid == atomic_load(&yes)) return true;
    if (pid == atomic_load(&no)) return false;
    char name[64] = "";
    proc_name(pid, name, sizeof name);
    bool r = strcmp(name, "remapd") == 0;
    atomic_store(r ? &yes : &no, pid);
    return r;
}

// The hover state is otherwise only re-read on mouse MOVES, but a slot/space switch
// changes what's under a still pointer. Left stale at 1, Karabiner's hover F->Shift
// (which sits above Plain Remaps) turns Cmd-F in Claude into a plain Find. So
// re-read on every app activation and space change, twice — once right away and
// once after slots has finished moving windows.
static void watchCadHoverStaleness(void) {
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    publishCompanionFront();
    void (^recheck)(NSNotification *) = ^(NSNotification *n) {
        publishCompanionFront();
        refreshCadHover();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ refreshCadHover(); });
    };
    [nc addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { atomic_store(&gSpaceChangeMs, nowMs()); }];
    for (NSString *name in @[NSWorkspaceDidActivateApplicationNotification,
                             NSWorkspaceActiveSpaceDidChangeNotification])
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:recheck];
}

// Max's Coherence windows: owner name "3ds Max <year>", owned by a Parallels WinApp stub.
static bool isMaxCoherence(CFStringRef owner, pid_t pid) {
    if (!CFStringHasPrefix(owner, CFSTR("3ds Max"))) return false;
    static pid_t cached = 0;
    static bool cachedOk = false;
    if (pid != cached) {
        @autoreleasepool {
            NSString *b = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
            cachedOk = [b hasPrefix:@"com.parallels.winapp."];
        }
        cached = pid;
    }
    return cachedOk;
}

static CGDirectDisplayID displayAt(CGPoint p) {
    CGDirectDisplayID d = CGMainDisplayID();
    uint32_t n = 0;
    CGGetDisplaysWithPoint(p, 1, &d, &n);
    return d;
}

// PID of the frontmost (active) application, straight from the workspace. This is
// the authoritative "who's focused" answer — far more reliable than inferring it
// from CGWindowList z-order, where an overlay window (BTT, the scroll filter, etc.)
// in front of Fusion would make the owner PIDs never match.
static pid_t frontmostPid(void) {
    @autoreleasepool {
        NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
        return app ? app.processIdentifier : 0;
    }
}

// Identify the CAD window (Fusion or SketchUp) directly under the pointer. Returns
// its owning pid (0 if the topmost window under the pointer isn't a CAD app), sets
// *isFront to whether that app is the global frontmost (already active), and
// *isFusion to whether it's Fusion (vs SketchUp). One CGWindowList query. Used at
// gesture start, and (throttled) by the hover watch. This is what lets the 3-finger
// drag become a CAD navigation over the viewport while passing straight through to a
// floater (Finder, etc.) on top, regardless of which app holds focus. The first call
// in a process is ~150ms cold; warmCAD() (called at startup) pays that once.
static pid_t cadUnderCursor(bool *isFront, bool *isFusion, bool *isMax) {
    if (isFront)  *isFront  = false;
    if (isFusion) *isFusion = false;
    if (isMax)    *isMax    = false;
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    CFArrayRef wins = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!wins) return 0;
    pid_t result = 0;
    CFIndex n = CFArrayGetCount(wins);
    for (CFIndex i = 0; i < n; i++) {                 // front-to-back
        CFDictionaryRef info = CFArrayGetValueAtIndex(wins, i);
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 1;
        if (layerRef) CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        if (layer != 0) continue;                     // skip menubar/overlay layers
        pid_t opid = 0;
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        if (pidRef) CFNumberGetValue(pidRef, kCFNumberIntType, &opid);
        CFDictionaryRef b = CFDictionaryGetValue(info, kCGWindowBounds);
        CGRect r;
        if (!b || !CGRectMakeWithDictionaryRepresentation(b, &r)) continue;
        if (!CGRectContainsPoint(r, p)) continue;     // not under the pointer
        CFStringRef owner = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (isBorderOverlay(owner)) continue;
        bool fusion = owner && CFStringCompare(owner, CFSTR("Fusion"),   0) == kCFCompareEqualTo;
        bool sketch = owner && CFStringCompare(owner, CFSTR("SketchUp"), 0) == kCFCompareEqualTo;
        // Parallels: only where the pointer maps onto Max's viewport (see maxViewportAt).
        // Window mode: the VM window ("Parallels Desktop"), Max must be Windows' foreground.
        // Coherence: Max's own windows, owned by its WinAppHelper stub ("3ds Max 2027",
        // com.parallels.winapp.*) — the owner already says it's Max, and the Windows
        // desktop is the display, not the (possibly dialog-sized) window.
        bool coherence = owner && isMaxCoherence(owner, opid);
        if (coherence) r = CGDisplayBounds(displayAt(p));
        bool max = owner && (coherence || CFStringCompare(owner, CFSTR("Parallels Desktop"), 0) == kCFCompareEqualTo)
                   && maxViewportAt(p, r, coherence, NULL);
        if (fusion || sketch || max) {
            result = opid;
            if (isFront)  *isFront  = (opid == frontmostPid());   // authoritative focus check
            if (isFusion) *isFusion = fusion;
            if (isMax)    *isMax    = max;
            if (max) gMaxVMRect = r;
        }
        break;                                         // topmost window at point decides
    }
    CFRelease(wins);
    return result;
}

// True iff `p` is inside the dock window's last published frame, and it is showing.
static bool dockFrameContains(CGPoint p) {
    FILE *f = fopen(DOCK_FRAME_FILE, "r");
    if (!f) return false;
    double x = 0, y = 0, w = 0, h = 0;
    int vis = 0;
    int n = fscanf(f, "%lf %lf %lf %lf %d", &x, &y, &w, &h, &vis);
    fclose(f);
    if (n != 5 || !vis || w <= 0 || h <= 0) return false;
    return p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h;
}

// Pointer position and start time of a MODE_INERT gesture, so the lift can tell a tap
// from a drag (movement) and from resting fingers (duration).
static double gDockStartX = 0, gDockStartY = 0;
static long long gDockStartMs = 0;

// A MODE_MMB gesture over Fusion's canvas, and where it started — a lift with no
// travel is a 3-finger touch (see CLICK_EVENT_FILE).
static bool gCanvasTouch = false;
static double gCanvasStartX = 0, gCanvasStartY = 0;
static double gTouchStartMs = 0;   // nowMs() of the gesture's first finger (0 = no fingers down)

// The modifiers a click gesture reports, spelled as FusionScrollFilter's clickMods
// (keep the two in sync): space is the HID state of F20, and Option under a held
// space is the space itself.
static void clickMods(char *out, size_t n) {
    CGEventFlags fl = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    bool space = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, KC_F20);
    out[0] = 0;
    const struct { bool on; const char *name; } m[] = {
        { space, "space" },
        { (fl & kCGEventFlagMaskShift) != 0, "shift" },
        { (fl & kCGEventFlagMaskCommand) != 0, "cmd" },
        { !space && (fl & kCGEventFlagMaskAlternate) != 0, "alt" },
        { (fl & kCGEventFlagMaskControl) != 0, "ctrl" },
    };
    for (size_t i = 0; i < sizeof m / sizeof m[0]; i++) {
        if (!m[i].on) continue;
        if (out[0]) strlcat(out, ",", n);
        strlcat(out, m[i].name, n);
    }
    if (!out[0]) strlcpy(out, "-", n);
}

// Written whole (tmp + rename) so the add-in's poller never reads half a line.
static void writeCanvasTouch(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long long ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    char mods[48];
    clickMods(mods, sizeof mods);
    FILE *f = fopen(CLICK_EVENT_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f, "%lld tap3 %s 0", ms, mods);
    fclose(f);
    rename(CLICK_EVENT_FILE ".tmp", CLICK_EVENT_FILE);
}

// True iff the accessibility element directly under the pointer is the CAD app's
// 3D viewport canvas — identified as the app's MAIN window (role AXWindow +
// kAXMainAttribute==true). Everything else reports either a more specific role
// (toolbar/timeline buttons → AXButton; menu items/dropdowns → AXMenuItem;
// trays/outliner → AXOutline/AXScrollArea/…) or, for Fusion's own dialogs/panels,
// a non-main window (AXMain=false) — so this narrows CAD nav to the canvas,
// suppressing it over menus, dropdowns, toolbars, panels AND dialogs (incl. large
// ones like Preferences, which an earlier size-based test wrongly took for canvas).
// (Discovered empirically with ax_hover_probe — the viewport is the ONLY place
// the element under the cursor is the standard window.) Fails OPEN (true) on any
// AX error so a missing permission never wedges navigation. One
// AXUIElementCopyElementAtPosition call; done only at gesture start, never on a
// timer (so it can't slow the event-tap hot path). First call is ~cold; warmCAD()
// pays that once at startup.
static bool elementIsCanvas(void) {
    static AXUIElementRef sys = NULL;
    if (!sys) {
        sys = AXUIElementCreateSystemWide();
        // On the system-wide element this sets the GLOBAL timeout for every AX call
        // this process makes. The default (~6 s) is what let a busy Fusion stall the
        // gesture decision; timing out now fails open like any other AX error.
        if (sys) AXUIElementSetMessagingTimeout(sys, AX_TIMEOUT_S);
    }
    if (!sys) return true;
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    AXUIElementRef el = NULL;
    if (AXUIElementCopyElementAtPosition(sys, p.x, p.y, &el) != kAXErrorSuccess || !el)
        return true;                                   // AX unavailable → fail open
    // ⚠ FAIL-OPEN TRAP: returning true here means "treat as canvas", so if this
    // binary loses its Accessibility grant the AX query fails and CAD nav becomes
    // active EVERYWHERE (it then swallows 3-finger window-drags / scroll off-canvas).
    // An unsigned rebuild silently drops the grant — that's why build.sh code-signs
    // with a STABLE identity. See [[cad_nav_binaries_must_be_signed]] before touching.
    bool canvas = false;
    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
    if (role && CFGetTypeID(role) == CFStringGetTypeID() &&
        CFEqual(role, kAXWindowRole)) {
        // The 3D canvas is the app's MAIN window (kAXMainAttribute == true) — true
        // both for the titled window AND for the borderless window the Maximize
        // Viewport add-in produces (subrole AXDialog). Every Fusion dialog/panel
        // (Preferences, etc.) is a window too, but is NOT the main window, so it
        // reports AXMain=false EVEN WHEN LARGE. So gate on AXMain, not subrole/size:
        // the old "AXDialog && size>600x400" test misclassified big dialogs as the
        // canvas and swallowed their three-finger window-drag / scroll.
        CFBooleanRef mainRef = NULL;
        AXError mainErr = AXUIElementCopyAttributeValue(el, kAXMainAttribute,
                                                        (CFTypeRef *)&mainRef);
        bool gotMain = mainErr == kAXErrorSuccess &&
                       mainRef && CFGetTypeID(mainRef) == CFBooleanGetTypeID();
        if (gotMain && CFBooleanGetValue(mainRef)) {
            canvas = true;
        } else if (mainErr == kAXErrorCannotComplete) {
            canvas = true;                             // app too busy to answer → fail open
        } else {
            // AXMain unreadable OR false: the borderless canvas fills the whole display.
            // Fusion can report its only (canvas) window as AXMain=false (seen
            // 2026-10-05: one 3440x1440 AXDialog, main=0) — trusting that killed all
            // 3-finger nav. A real dialog never covers ~the entire screen, so this
            // can't admit one.
            CFTypeRef szRef = NULL;
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &szRef);
            if (szRef && CFGetTypeID(szRef) == AXValueGetTypeID()) {
                CGSize sz;
                if (AXValueGetValue((AXValueRef)szRef, kAXValueCGSizeType, &sz)) {
                    CGRect d = CGDisplayBounds(CGMainDisplayID());
                    canvas = (sz.width  >= 0.9 * d.size.width &&
                              sz.height >= 0.9 * d.size.height);
                }
            }
            if (szRef) CFRelease(szRef);
        }
        if (mainRef) CFRelease(mainRef);
    }
    if (role) CFRelease(role);
    CFRelease(el);
    return canvas;
}

// Prime the WindowServer query so the first real gesture doesn't pay the cold
// ~150ms first-call cost. Result discarded; once warm, every later call is
// sub-millisecond for the life of the process (measured, even across idle gaps).
static void warmCAD(void) { (void)cadUnderCursor(NULL, NULL, NULL); (void)elementIsCanvas(); }

#define NAV_MMB_MARK 0x6d6d6220   // 'mmb ' — our nav's middle button; keep in sync: remapd.m
static void postMMB(CGEventType type, CGPoint pos, CGEventFlags flags) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef event = CGEventCreateMouseEvent(src, type, pos, kCGMouseButtonCenter);
    CGEventSetFlags(event, flags);
    if (type == kCGEventOtherMouseDown) {
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    }
    // remapd's thumb-down session drops every button press — not our nav's (2026-10-18: the
    // orbit / pan resumed after a thumb + fingers zoom never started, its MMB down eaten).
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, NAV_MMB_MARK);
    atomic_store(&isSynthetic, true);
    hidPlace(event); CGEventPost(kCGHIDEventTap, event);
    atomic_store(&isSynthetic, false);
    CFRelease(event);
    CFRelease(src);
}

// The modifier baked into the synthetic MMB. Fusion orbits on Shift+MMB and pans on a
// plain MMB, so Shift held → none; Max (callis/nav.py setup) is the other way round.
static CGEventFlags mmbFlags(void) {
    bool shift = panWanted();
    if (atomic_load(&gMaxDrag)) return shift ? kCGEventFlagMaskShift : 0;
    return shift ? 0 : kCGEventFlagMaskShift;
}

// Re-issue the synthetic MMB so its pan/orbit modifier matches the current Shift state.
// Drives the live mid-drag toggle: Shift -> no modifier (Fusion MMB = pan); otherwise
// add Shift (= orbit). (SketchUp reads the real Shift key directly, but re-issuing the
// MMB still makes it re-sample, so the toggle is live there too.)
static void retargetMMB(void) {
    CGEventRef cur = CGEventCreate(NULL);
    CGPoint pos = CGEventGetLocation(cur);
    CFRelease(cur);
    CGEventFlags flags = mmbFlags();
    postMMB(kCGEventOtherMouseUp, pos, 0);
    postMMB(kCGEventOtherMouseDown, pos, flags);
    postMMB(kCGEventOtherMouseDragged, pos, flags);
}

static void endDrag(void) {
    CGPoint pos = CGEventGetLocation(CGEventCreate(NULL));
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    postMMB(kCGEventOtherMouseUp, pos, 0);
    CGEventRef leftUp = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, pos, kCGMouseButtonLeft);
    hidPlace(leftUp); CGEventPost(kCGHIDEventTap, leftUp);
    CFRelease(leftUp);
    CFRelease(src);
}

// Drop an orbit-centre request at the cursor so Cursor Probe sets the orbit pivot
// under the pointer. Fired by a 3-finger CAD gesture's lift (directly, since only a
// genuine 3-finger nav reaches that call site) and by the 1-finger dwell/lift path
// (via fireOneFingerOrbit, which adds the always-on guards). The probe applies its
// own guards (cursor still here, over Fusion, not paused, …) and removes the file,
// so a write that doesn't land on geometry is harmless.
static void requestOrbitCenter(void) {
    CGEventRef ev = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(ev);
    CFRelease(ev);
    FILE *f = fopen("/tmp/fusion_orbit_center_request", "w");
    if (f) { fprintf(f, "%d,%d", (int)p.x, (int)p.y); fclose(f); }
    f = fopen("/tmp/fusion_dwell_fired", "w");   // legacy marker, mirrors fusion_dwell
    if (f) fclose(f);
}

static CGPoint cursorPos(void) {
    CGEventRef ev = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(ev);
    CFRelease(ev);
    return p;
}

// Fire an orbit-centre request for a 1-finger dwell/lift, with the guards that make
// it safe as an always-on path (the 3-finger path needs none of these because it
// only ever runs from a deliberate 3-finger drag over the canvas):
//   • dedup — skip if we already requested the centre at ~this spot ("no point").
//   • Fusion frontmost AND under the cursor — the orbit centre is set with a
//     synthetic ⌘I/⌘U keystroke, which only lands if Fusion has focus; firing while
//     another app is frontmost would send the keystroke to the wrong place.
//   • over the 3D canvas, not Fusion's chrome (toolbar/menus/panels).
// Cursor Probe still applies its own guards (cursor still in viewport, position
// matches, not paused, no text focus), so a slip past these is harmless.
static void fireOneFingerOrbit(void) {
    CGPoint p = cursorPos();
    if (fabs(p.x - lastOrbitX) <= ONE_DEDUP_PX && fabs(p.y - lastOrbitY) <= ONE_DEDUP_PX)
        return;                                   // already set the pivot here
    bool isFront = false, isFusion = false;
    if (cadUnderCursor(&isFront, &isFusion, NULL) == 0 || !isFusion || !isFront)
        return;                                   // not over a focused Fusion window
    if (!elementIsCanvas())
        return;                                   // over Fusion chrome, not the viewport
    lastOrbitX = p.x;
    lastOrbitY = p.y;
    requestOrbitCenter();
}

// Release a left button that the gesture's real left-down left pressed. Used once
// the activating click has focused the app, to end any selection it began before
// the MMB drag takes over.
static void postLeftUp(CGPoint pos) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef up = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, pos, kCGMouseButtonLeft);
    atomic_store(&isSynthetic, true);
    hidPlace(up); CGEventPost(kCGHIDEventTap, up);
    atomic_store(&isSynthetic, false);
    CFRelease(up);
    CFRelease(src);
}

// Bring a deferred app forward once the gesture is over. Activating mid-drag
// interrupts Fusion's orbit, so an inactive-Fusion drag stashes its pid here and
// we focus it only after the fingers lift.
static void activatePending(void) {
    pid_t pid = atomic_exchange(&pendingActivatePid, 0);
    if (!pid) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRunningApplication *app =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        [app activateWithOptions:NSApplicationActivateAllWindows];
    });
}

// ── Fusion / Max touch nav: 2-finger orbit, thumb pinch zoom (2026-10-18) ─────
// Over Fusion's canvas and Max's viewport (SketchUp as it was; Photoshop's canvas gets the
// ZOOM only, § Photoshop):
//   • TWO fingers dragging = PAN, THREE = ORBIT (the latched 3-finger drag, gThreePan;
//     swapped 2026-10-21, user). macOS sends two fingers as a scroll, not a drag, so the
//     pan is read off the touches, the 4th-finger pan's way; FusionScrollFilter / maxScroll
//     swallow the scroll. A third finger joining a pan orbits from then.
//   • THUMB + two fingers = ZOOM: the fingers' distance from the thumb, spreading = in.
//     Starts when they land with the thumb, or land while it rests, and stays a zoom
//     until the THUMB lifts — fingers may lift and land again meanwhile. Fusion: a
//     phased scroll tagged NAV_ZOOM_MARK that FusionScrollFilter zooms with its curves
//     and walls (remapd lets it through); Max: zoom frames. The pointer is held still
//     (navFreeze), so the zoom stays where it started.
// The thumb: a contact resting first (navRestThumb), or by layout when all three land
// together (navLayoutThumb). remapd's own thumb-down gestures on these fingers
// (Resting Thumb's up2 / down2, pinch3) still fire — Control Room leaves them unbound.
// Tuning: /tmp/reanchor.log "nav …" lines.
#define NAV_ZOOM_MARK    0x7a6f6f6d  // 'zoom' — keep in sync: FusionScrollFilter.c, remapd.m
// Touch travel → pointer travel, accelerated like the pointer (a flat 9 px/mm orbited
// far too fast, 2026-10-18): NAV_PX_SLOW px/mm at a crawl, up to NAV_PX_FAST from NAV_FAST_MMS.
#define NAV_PX_SLOW      2.5
#define NAV_PX_FAST      8.0
#define NAV_SLOW_MMS     15.0        // mm/s — at or below: the slow gain
#define NAV_FAST_MMS     180.0       // mm/s — at or above: the fast gain
#define TWO_START_MM     0.8         // the 2 fingers' travel before they orbit
#define PINCH_PX_PER_MM  40.0        // zoom: change in the thumb→fingers distance → scroll px. 65 matched
                                     // the 2-finger scroll's speeds (scroll p50 ≈ 4100 px/s) but was too
                                     // sensitive — user: 62% of it (2026-10-18; at 30 the velocity curve
                                     // hardly engaged)
#define SWIPE_LAND_MS    120.0       // ms after a touch's first finger before its zoom moves the camera
#define NAV_CLAIM_WAIT_MS 30.0       // ms after the zoom's finger count changes before it moves (remapdClaims)
#define NAV_THUMB_LEAD   0.05        // s — a contact down this long before the others RESTS (auxgest's AG_THUMB_LEAD)
#define NAV_THUMB_STILL  3.0         // mm — ...and has moved at most this
// Landing together, the thumb is the lowest contact, LEFT of the fingers, and this far
// below them (normalized y). Measured 2026-10-18: thumb + 2 fingers 0.13–0.20, three
// fingers ≤ 0.15 but with the lowest on the RIGHT (the ring finger) bar one 0.13 left.
// (An "apart from the fingers" test failed: the thumb read 0.8–1.4× the fingers' gap.)
#define NAV_THUMB_DROP   0.15
#define NAV_THUMB_DROP_P 0.12        // ...or only this far, when the print calls it the thumb
#define NAV_THUMB_DROP2  0.12        // two contacts: the thumb + one finger (no orbit) — two fingers sit level
// The drop rules above are the fallback for no thumbprint; with one, the print decides:
#define NAV_THUMB_SCORE  14.0        // agPrintScore ≥ this = the thumb (pans ≤ 5.6, thumbs ≥ 22.8)
#define NAV_THUMB_WATCH  10          // frames after a 3-contact landing the pan keeps checking: the
                                     // shape peaks over the landing frames (agShapeFrame)

static void navLog(const char *fmt, ...) {
    FILE *f = fopen("/tmp/reanchor.log", "a");
    if (!f) return;
    time_t t = time(NULL); char ts[32];
    strftime(ts, sizeof ts, "%m-%d %H:%M:%S", localtime(&t));
    fprintf(f, "%s nav ", ts);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// The contacts on the pad (lifting ones left out), with where and when each arrived.
// Multitouch thread only.
// role: a contact landing on a running orbit / pan is judged (navJudge) — ROLE_FINGER
// counts, ROLE_CAND (low and left: maybe the thumb) is held out of every count meanwhile.
enum { ROLE_NEW = 0, ROLE_FINGER, ROLE_CAND };
typedef struct { int id; double t0; float mx0, my0, mx, my, nx0, ny0, nx, ny;
                 float pkSize, pkMajor, pkMinor, pkAngle; int frames; bool touching; int role; } NavTouch;
#define NAV_MAX 16
static NavTouch gNT[NAV_MAX];
static int gNTn = 0;
static double gTouchT0 = 0;             // the touch's first frame (multitouch time; 0 = no touch)
static void navTrack(const Finger *d, int n, double ts) {
    NavTouch nt[NAV_MAX]; int m = 0;
    for (int i = 0; i < n && m < NAV_MAX; i++) {
        if (d[i].state < 1 || d[i].state > 5) continue;
        NavTouch t = { .id = d[i].identifier, .t0 = ts, .mx0 = d[i].mm.pos.x, .my0 = d[i].mm.pos.y,
                       .nx0 = d[i].normalized.pos.x, .ny0 = d[i].normalized.pos.y };
        for (int j = 0; j < gNTn; j++) if (gNT[j].id == d[i].identifier) { t = gNT[j]; break; }
        t.mx = d[i].mm.pos.x; t.my = d[i].mm.pos.y;
        t.nx = d[i].normalized.pos.x; t.ny = d[i].normalized.pos.y;
        t.touching = d[i].state >= 4;
        if (t.touching && ++t.frames <= 8 && d[i].size >= t.pkSize) {   // its shape while landing (agShapeFrame)
            t.pkSize = d[i].size; t.pkMajor = d[i].majorAxis; t.pkMinor = d[i].minorAxis; t.pkAngle = d[i].angle;
        }
        nt[m++] = t;
    }
    memcpy(gNT, nt, m * sizeof *nt);
    gNTn = m;
}
// Centroid and count of the TOUCHING contacts (skip = one to leave out). Hovering ones
// (a finger just above the pad, states 1–3) flicker in and out — counted, every flicker
// re-based the pinch and it never zoomed (2026-10-18); they still count for the thumb's
// landing layout.
static void navCentroid(int skip, float *x, float *y, int *n) {
    float cx = 0, cy = 0; int k = 0;
    for (int i = 0; i < gNTn; i++) if (i != skip && gNT[i].touching && gNT[i].role != ROLE_CAND) {
        cx += gNT[i].mx; cy += gNT[i].my; k++;
    }
    *x = k ? cx / k : 0; *y = k ? cy / k : 0; *n = k;
}

// The main pad's thumbprint (remap/thumbprint.json "right", learnt by bin/thumbprint):
// shape only. Not ok = place alone decides.
static AgPrint gNavPrint;
static void navLoadPrint(void) {
    @autoreleasepool {
        NSData *d = [NSData dataWithContentsOfFile:@"/Users/josh/Code/Scripts/remap/thumbprint.json"];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        NSDictionary *h = [j isKindOfClass:NSDictionary.class] ? j[@"right"] : nil;
        if (![h isKindOfClass:NSDictionary.class]) return;
        AgPrint pr = { .ok = true };
        NSArray *cls = @[@"finger", @"thumb"];
        for (int c = 0; c < 2 && pr.ok; c++) {
            NSDictionary *s = h[cls[c]];
            NSArray *mu = [s isKindOfClass:NSDictionary.class] ? s[@"mu"] : nil, *sd = mu ? s[@"sd"] : nil;
            if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class]
                || mu.count != AGF || sd.count != AGF) { pr.ok = false; break; }
            for (int i = 0; i < AGF; i++) {
                pr.mu[c][i] = [mu[i] floatValue];
                pr.sd[c][i] = fmaxf([sd[i] floatValue], 0.02f);
            }
        }
        gNavPrint = pr;
    }
}
// > 0 = thumb-shaped; 0 with no print / no shape yet.
static float navThumbScore(const NavTouch *t) {
    if (!gNavPrint.ok || t->pkSize <= 0) return 0;
    float f[AGF];
    agFeatures(t->pkMajor, t->pkMinor, t->pkAngle, t->pkSize, f);
    return agPrintScore(&gNavPrint, f);
}

// The contact RESTING under the others: down NAV_THUMB_LEAD before every other one,
// still, and thumb-shaped when there is a print. Its index, else -1.
static int navRestThumb(void) {
    if (gNTn < 2) return -1;
    int e = 0;
    for (int i = 1; i < gNTn; i++) if (gNT[i].t0 < gNT[e].t0) e = i;
    if (hypotf(gNT[e].mx - gNT[e].mx0, gNT[e].my - gNT[e].my0) > NAV_THUMB_STILL) return -1;
    for (int i = 0; i < gNTn; i++) if (i != e && gNT[i].t0 - gNT[e].t0 < NAV_THUMB_LEAD) return -1;
    if (gNavPrint.ok && gNT[e].pkSize > 0 && navThumbScore(&gNT[e]) <= 0) return -1;
    return e;
}
// Contact i is the thumb by its print (shape ≥ NAV_THUMB_SCORE) and sits left of and below
// the others. No print: never (the drop rules can't tell a 4-finger swipe's index finger).
#define NAV_SWIPE_SHAPE 2               // frames of shape before 4 contacts are called a swipe
static bool navThumbLike(int i) {
    if (!gNavPrint.ok || gNTn < 2 || navThumbScore(&gNT[i]) < NAV_THUMB_SCORE) return false;
    float mx = 0, my = 0;
    for (int j = 0; j < gNTn; j++) if (j != i) { mx += gNT[j].nx0 / (gNTn - 1); my += gNT[j].ny0 / (gNTn - 1); }
    return gNT[i].nx0 < mx && gNT[i].ny0 < my;
}
// Four touching, shaped, one of them the thumb: thumb + 3 fingers (the zoom), not a swipe.
static bool navFourWithThumb(void) {
    int th = -1, k = 0;
    for (int i = 0; i < gNTn; i++) {
        if (!gNT[i].touching) continue;
        if (gNT[i].frames < NAV_SWIPE_SHAPE) return false;
        k++;
        if (navThumbLike(i)) th = i;
    }
    return k == 4 && th >= 0;
}
// Two to four contacts landing together: the thumb is the lowest, on its side of the
// fingers (left: the main pad is the right hand) and well below them — or, with three, a
// little less far and the only thumb-shaped one. Its index, else -1; `why` for the log.
static int navLayoutThumb(char *why, size_t wn) {
    if (gNTn < 2 || gNTn > (gNavPrint.ok ? 4 : 3)) { snprintf(why, wn, "%d contacts", gNTn); return -1; }
    // The thumbprint decides when there is one: the best-scoring contact, if it scores
    // NAV_THUMB_SCORE and sits left of and below the others. Calibrated 2026-10-18
    // (remap/nav_calib.jsonl, bin/nav_calib.sh): 40 three-finger pans scored ≤ 5.6, 44
    // thumbs ≥ 22.8, every thumb left + below; the drop rule alone read 16 of 44 zooms as pans.
    if (gNavPrint.ok) {
        int b = 0;
        for (int i = 1; i < gNTn; i++) if (navThumbScore(&gNT[i]) > navThumbScore(&gNT[b])) b = i;
        float mx = 0, my = 0, sc = navThumbScore(&gNT[b]);
        for (int i = 0; i < gNTn; i++) if (i != b) { mx += gNT[i].nx0 / (gNTn - 1); my += gNT[i].ny0 / (gNTn - 1); }
        bool place = gNT[b].nx0 < mx && gNT[b].ny0 < my;
        snprintf(why, wn, "score=%.1f place=%d frames=%d", sc, place, gNT[b].frames);
        return sc >= NAV_THUMB_SCORE && place ? b : -1;
    }
    int lo = 0;
    for (int i = 1; i < gNTn; i++) if (gNT[i].ny0 < gNT[lo].ny0) lo = i;
    float my = 0, mx = 0; bool print = gNavPrint.ok && navThumbScore(&gNT[lo]) > 0;
    for (int i = 0; i < gNTn; i++) if (i != lo) {
        my += gNT[i].ny0 / (gNTn - 1); mx += gNT[i].nx0 / (gNTn - 1);
        if (navThumbScore(&gNT[i]) > 0) print = false;
    }
    float drop = my - gNT[lo].ny0;
    bool left = gNT[lo].nx0 < mx;
    snprintf(why, wn, "drop=%.2f left=%d print=%d", drop, left, print);
    bool thumb = gNTn == 2 ? drop >= NAV_THUMB_DROP2
                           : drop >= NAV_THUMB_DROP || (print && drop >= NAV_THUMB_DROP_P);
    return left && thumb ? lo : -1;
}

// Hold the pointer still for the zoom — remapd's freeze (auxFreeze), which only holds
// for a background process with SetsCursorInBackground on its connection.
extern int _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(int, int, CFStringRef, CFTypeRef);
// REMAPD'S THUMB PIN (2026-10-18). remapd pins the pointer whenever a thumb rests with
// fingers (gMainThumbHold) — at where the TOUCH began, and until the pad is clear. Over a
// running orbit / pan that was the jump on thumb-down (back to before the pan) and the
// jitter after thumb-up (its pin warps vs our drags). So while our nav owns the touch we
// say where the pin is, or that there is none, in one shared word (navwords.h).
static _Atomic uint64_t *gPinWord;
// REMAPD'S CLAIM (2026-10-18): the touch's state (thumb down or not, how many fingers) is a
// swipe bound in Control Room for this app / situation — nothing of ours moves the camera
// while it holds (zoom closed, orbit / pan / Max drag still); a finger landing that makes
// it an unbound state lets go, and the zoom re-bases from there. remapd.m claimPublish
// writes it (navwords.h).
static bool remapdClaims(void) {
    static _Atomic uint64_t *word;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ word = navword_map(CLAIM_FILE, false); });
    return word && claimword_live(atomic_load(word));
}
static void navPinSet(bool ours, bool pin, CGPoint at) {
    if (!gPinWord && !(gPinWord = navword_map(NAV_PIN_FILE, true))) return;
    atomic_store(gPinWord, pinword_make(ours, pin, at));
}

// The pointer sits at `at` on both sides: pinned there going in, and put back there coming
// out — frozen, its read position wanders with the fingers, and letting go jumped it there.
static void navFreeze(bool on, CGPoint at) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static bool armed = false;
        if (!armed) {
            int cid = _CGSDefaultConnection();
            CGSSetConnectionProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
            armed = true;
        }
        if (on) CGWarpMouseCursorPosition(at);
        CGAssociateMouseAndMouseCursorPosition(!on);
        if (!on) CGWarpMouseCursorPosition(at);
    });
}

// THE ZOOM (MODE_ZOOM). Multitouch thread only.
static int    gZoomThumb = -1;      // the thumb's contact id; -1 = no zoom running
static bool   gZoomMax = false;     // ...over Max (frames), else Fusion (scrolls)
static bool   gZoomPs = false;      // ...over Photoshop: Fusion's scrolls, tagged PS_ZOOM_MARK for pscursor
static bool   gZoomOpen = false;    // fingers down with the thumb: a scroll stream is open
static bool   gZoomBegin = false;   // ...and nothing sent on it yet (Max's begin frame)
static int    gZoomN = 0;           // the fingers it measures
static float  gZoomD = 0;           // their last distance from the thumb (mm)
static double gZoomAcc = 0;         // Fusion's sub-pixel remainder
static int    gZoomTicks = 0;       // for the log: ticks sent, their sum, finger re-bases
static double gZoomSum = 0;
static int    gZoomRebase = 0;
static double gZoomMs = 0;          // nowMs() at the start
static CGPoint gZoomAt;             // the pointer when the zoom began: every tick lands HERE. Read
                                    // while it is frozen, the pointer's position follows the fingers
                                    // unseen, and a posted scroll WARPS it there (the "mouse goes all
                                    // over" of the first try, 2026-10-18).
// One phased trackpad scroll at the zoom's spot, for FusionScrollFilter (or Photoshop's
// pscursor) to zoom.
static void navZoomPost(int phase, int32_t d) {
    CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, d);
    if (!e) return;
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, phase);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis1, d);
    CGEventSetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1, d);
    // The amount rides in the user data too (mark << 32 | amount): with fingers on the pad
    // macOS zeroed the delta fields of most of these on the way (299 of ~350, 2026-10-18).
    // Photoshop's carries its own mark: FusionScrollFilter zooms Fusion with every NAV_ZOOM_MARK.
    CGEventSetIntegerValueField(e, kCGEventSourceUserData,
                                ((int64_t)(gZoomPs ? PS_ZOOM_MARK : NAV_ZOOM_MARK) << 32) | (uint32_t)d);
    CGEventSetLocation(e, gZoomAt);
    hidPlace(e); CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}
static void navZoomClose(void) {
    // Cancelled, not ended: FusionScrollFilter flings on an END, and lifting to re-grip
    // mid-zoom must never jump the camera to a wall.
    if (gZoomOpen && !gZoomMax) navZoomPost(kCGScrollPhaseCancelled, 0);
    gZoomOpen = false;
}
static void navZoomEnd(void) {
    if (gZoomThumb < 0) return;
    navZoomClose();
    gZoomThumb = -1;
    navFreeze(false, gZoomAt);
    navLog("zoom end: %d ticks, sum %.0f px (in > 0), %d re-bases", gZoomTicks, gZoomSum, gZoomRebase);
}
static void navZoomFrame(void) {
    if (gZoomThumb < 0) return;                     // ended (the thumb lifted first): inert to the lift
    int ti = -1;
    for (int i = 0; i < gNTn; i++) if (gNT[i].id == gZoomThumb) ti = i;
    if (ti < 0) { navZoomEnd(); return; }           // the thumb lifted: the zoom is over
    float cx, cy; int n;
    navCentroid(ti, &cx, &cy, &n);
    if (!n) { navZoomClose(); return; }             // fingers up, thumb still down: wait for them
    // Claimed (thumb + one finger is a bound swipe, 2026-10-18: it zoomed): as if the
    // fingers were up — the zoom re-bases when the claim lets go.
    static bool toldClaim = false;
    if (remapdClaims()) {
        if (!toldClaim) { toldClaim = true; navLog("zoom: held — remapd claims thumb + %d", n); }
        navZoomClose(); gZoomN = 0; return;
    }
    toldClaim = false;
    float d = hypotf(cx - gNT[ti].mx, cy - gNT[ti].my);
    static double rebaseMs = 0;
    if (!gZoomOpen || n != gZoomN) {                // fingers (re)landed / lifted: measure from here
        if (!gZoomOpen && !gZoomMax) navZoomPost(kCGScrollPhaseBegan, 0);
        gZoomBegin = gZoomBegin || !gZoomOpen;
        gZoomOpen = true; gZoomN = n; gZoomD = d; gZoomAcc = 0;
        gZoomRebase++;
        rebaseMs = nowMs();
        return;
    }
    // A count change may be a claimed state remapd is still judging (its frame runs beside
    // ours): no ticks for NAV_CLAIM_WAIT_MS after a re-base.
    if (nowMs() - rebaseMs < NAV_CLAIM_WAIT_MS) { gZoomD = d; return; }
    if (fabsf(d - gZoomD) < 0.05f) return;
    // A 4th finger may follow (a swipe): send nothing till the touch is SWIPE_LAND_MS old.
    // A 4-finger swipe landing 3 first read as thumb + 2 and zoomed -1378 px before its
    // 4th finger (14:12:18, 2026-10-18); remapd's traces: 4th finger p90 50 ms after the 1st.
    if (nowMs() - gZoomMs < PAN_SETTLE_MS * 2 || nowMs() - gTouchStartMs < SWIPE_LAND_MS) { gZoomD = d; return; }
    double in = (d - gZoomD) * PINCH_PX_PER_MM;      // spreading = in (user, 2026-10-21; together = in since 10-18)
    gZoomD = d;
    gZoomTicks++; gZoomSum += in;
    if (gZoomMax) { maxZoomFrame(gZoomAt, in, gZoomBegin); gZoomBegin = false; return; }
    gZoomAcc += in * zoomInSign();                  // the scroll sign Fusion reads as in
    int32_t px = (int32_t)gZoomAcc;
    gZoomAcc -= px;
    if (px) navZoomPost(kCGScrollPhaseChanged, px);
}
static void navZoomStart(int thumb, bool isMax, bool isPs, pid_t cad, bool isFront, const char *why, CGPoint at) {
    gZoomThumb = gNT[thumb].id; gZoomMax = isMax; gZoomPs = isPs; gZoomOpen = false; gZoomBegin = false;
    gZoomAt = at;
    gZoomMs = nowMs();
    gZoomTicks = 0; gZoomSum = 0; gZoomRebase = 0;
    navFreeze(true, gZoomAt);
    // A fresh Cursor Probe ray cast at the frozen pointer: the zoom's walls measure the
    // eye against the probe's last hit, and with the pointer still since a pan (or any
    // camera move that didn't ask for an orbit centre) that hit was the point under the
    // cursor BEFORE the move — the zoom then ran through the real geometry (2026-10-18).
    // A REQUEST bypasses the touch's PAUSE and the cursor-stationary skip.
    if (!isMax && !isPs) { FILE *f = fopen("/tmp/fusion_probe_request", "w"); if (f) fclose(f); }
    // An unfocused Fusion: focus it now — the Cursor Probe feeds FusionScrollFilter's
    // pivot only while Fusion is active (its activation grace holds the zoom till then).
    if (!isMax && !isPs && !isFront) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSRunningApplication runningApplicationWithProcessIdentifier:cad]
                activateWithOptions:NSApplicationActivateAllWindows];
        });
    }
    navLog("zoom start (%s, %s)", isMax ? "Max" : isPs ? "Photoshop" : "Fusion", why);
    navZoomFrame();
}

// THE 2-FINGER ORBIT, and the pan once a third finger joins it. Multitouch thread only,
// but gTouchNav is read by the event tap (it drops the gesture's left events).
static atomic_bool gTouchNav = false;   // a touch-driven orbit / pan owns this gesture
static atomic_int  gTwoTarget = 0;      // the 2-finger touch is over: 0 deciding, -1 neither, 1 Fusion, 2 Max
static atomic_int  gTwoPid = 0;         // ...an unfocused Fusion to focus at the lift
static double gTwoT0 = 0;               // when the 2-finger touch began (0 = none)
static bool   gTwoThumb = false;        // ...one of the two was resting: no orbit (a zoom may follow)
static float  gNavX, gNavY;             // the centroid last moved from (mm)
static int    gNavN = 0;                // ...over this many contacts
static bool   gNavMax = false, gNavDown = false;   // over Max; the MMB / Max drag is under way
static bool   gNavPs = false;           // over Photoshop's canvas: pan scrolls, never an MMB (§ Photoshop)
static double gPsRx = 0, gPsRy = 0;     // ...the pan's sub-pixel remainders; under gOutLk
static CGPoint gNavHome;                // where the orbit began (the pointer goes back here at a screen edge)
static CGRect  gNavScreen;
static CGPoint gNavAt;                  // where our drag is: posted from HERE, never from the pointer —
                                        // with three fingers down macOS moves the pointer too, and
                                        // adding our travel to its made the pan jump (2026-10-18)
static double  gNavTs = 0, gNavSpeed = 0;   // last frame's time; smoothed speed (mm/s)
static bool    gNavDead = false;        // a 4th finger landed: this gesture navigates no more
static float   gPanX0, gPanY0;          // the touches' centroid when a Fusion 3-finger pan latched
static int     gThumbWatch = 0;         // frames the pan still checks for a thumb (NAV_THUMB_WATCH)
static int     gPsWatch = 0;            // ...the same over Photoshop's canvas, its left-down held (§ Photoshop)
static bool    gNavOrbited = false;     // this touch nav orbited (not only panned): set the pivot at the lift
static bool    gCandFrozen = false;     // a maybe-thumb is being judged: the nav holds still, the pointer
static CGPoint gCandAt;                 // ...frozen HERE (where the thumb landed) — the zoom's spot if it is one
static bool    gNavArm = false;         // resumed from a zoom: still until NAV_RESUME_S + TWO_START_MM (a hand
static double  gNavArmTs = 0;           // lifting thumb-first must not orbit on its way up)
#define NAV_RESUME_S 0.06
#define NAV_LATE_S   0.25               // s — a contact landing this long into the touch is no swipe's
                                        // (remapd's AG_LAND_SPREAD): a thumb joining a pan is 4, not a swipe
#define NAV_LATE_DROP 0.05              // a late contact this far below the fingers (and left) may be the thumb
// A 4-finger swipe (Space / app switch) is never nav — not while it lands, not while it
// lifts (4→3→2 used to start a "zoom" by layout, drop 0.4–0.8, as the new Space slid
// in, 2026-10-18), and no zoom starts until the Space has settled.
static bool    gSwipe = false;          // 4+ fingers touched this gesture (cleared at the lift)
static double  gSwipeTs = -1e9;         // the last frame with 4+ touching
#define SWIPE_SETTLE 0.4                // s — no zoom starts this soon after one

// px per mm at this speed — the pointer's kind of acceleration.
static double navGain(double mms) {
    double u = (mms - NAV_SLOW_MMS) / (NAV_FAST_MMS - NAV_SLOW_MMS);
    u = u < 0 ? 0 : u > 1 ? 1 : u * u * (3 - 2 * u);
    return NAV_PX_SLOW + (NAV_PX_FAST - NAV_PX_SLOW) * u;
}

// Fusion orbit / pan OUTPUT, resampled (2026-10-18): one drag per touch frame (~90–125 Hz,
// arriving bunched, sensor noise and all) on a 165 Hz display beat into visible steps.
// navMove only QUEUES the travel (gPend); a timer at the display's refresh posts it, each
// tick easing toward the queued total (NAV_EASE_S) — evenly spread, noise smoothed. Every
// other MMB post on the multitouch thread first flushes the queue (navOutStop).
#define NAV_EASE_S 0.018                // s — the queue's time constant (the lag it adds)
static pthread_mutex_t gOutLk = PTHREAD_MUTEX_INITIALIZER;
static double gPendX = 0, gPendY = 0;   // queued travel (px); under gOutLk, as is gNavAt
static bool   gOutOn = false, gOutRunning = false;
static double gOutLast = 0;
static dispatch_source_t gOutTimer;
// One drag by (px, py) from gNavAt; the screen's edge would stop it: let go, back to where
// it began, grab again. gOutLk held.
static void navOutPost(double px, double py) {
    if (gNavPs) {                                   // Photoshop: scroll pixels at the still pointer
        gPsRx += px; gPsRy += py;
        int ix = (int)trunc(gPsRx), iy = (int)trunc(gPsRy);
        gPsRx -= ix; gPsRy -= iy;
        if (ix || iy) psPostScroll(gNavAt, iy, ix, kCGScrollPhaseChanged);
        return;
    }
    CGPoint at = { gNavAt.x + px, gNavAt.y + py };
    if (!CGRectContainsPoint(gNavScreen, at)) {
        postMMB(kCGEventOtherMouseUp, gNavAt, 0);
        CGWarpMouseCursorPosition(gNavHome);
        gNavAt = gNavHome;
        postMMB(kCGEventOtherMouseDown, gNavAt, mmbFlags());
        return;
    }
    gNavAt = at;
    postMMB(kCGEventOtherMouseDragged, at, mmbFlags());
}
static void navOutTick(void) {
    pthread_mutex_lock(&gOutLk);
    double now = CFAbsoluteTimeGetCurrent();
    if (!gOutOn) { gOutRunning = false; dispatch_suspend(gOutTimer); }
    else if (gPendX != 0 || gPendY != 0) {
        double dt = fmin(now - gOutLast, 0.05);
        double f = 1 - exp(-dt / NAV_EASE_S);
        double mx = gPendX * f, my = gPendY * f;
        if (fabs(gPendX - mx) < 0.05 && fabs(gPendY - my) < 0.05) { mx = gPendX; my = gPendY; }
        gPendX -= mx; gPendY -= my;
        navOutPost(mx, my);
    }
    gOutLast = now;
    pthread_mutex_unlock(&gOutLk);
}
// Queue travel; the timer runs at the nav screen's refresh while the queue is on.
static void navOutAdd(double px, double py) {
    pthread_mutex_lock(&gOutLk);
    if (!gOutTimer) {
        dispatch_queue_t q = dispatch_queue_create("nav.out",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        gOutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_event_handler(gOutTimer, ^{ navOutTick(); });
    }
    gPendX += px; gPendY += py;
    gOutOn = true;
    if (!gOutRunning) {
        CGDirectDisplayID did = CGMainDisplayID(); uint32_t cnt = 0;
        CGGetDisplaysWithPoint(gNavAt, 1, &did, &cnt);
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
        double hz = m ? CGDisplayModeGetRefreshRate(m) : 0;
        if (m) CGDisplayModeRelease(m);
        if (hz < 30) hz = 120;                       // ProMotion panels report 0
        dispatch_source_set_timer(gOutTimer, DISPATCH_TIME_NOW, (uint64_t)(NSEC_PER_SEC / hz), 0);
        gOutLast = CFAbsoluteTimeGetCurrent();
        gOutRunning = true;
        dispatch_resume(gOutTimer);
    }
    pthread_mutex_unlock(&gOutLk);
}
// Post what's still queued at once and stop the queue — before letting go / re-pressing.
static void navOutStop(void) {
    pthread_mutex_lock(&gOutLk);
    if (gOutOn && (gPendX != 0 || gPendY != 0)) navOutPost(gPendX, gPendY);
    gPendX = gPendY = 0;
    gOutOn = false;
    pthread_mutex_unlock(&gOutLk);
}

static void navMove(double ts) {
    float x, y; int n;
    navCentroid(-1, &x, &y, &n);
    if (n != gNavN) { gNavX = x; gNavY = y; gNavN = n; gNavTs = ts; }   // a finger landed / lifted: the centroid jumps
    if (gNavDead) return;
    if (gCandFrozen) { gNavX = x; gNavY = y; gNavTs = ts; return; }   // a thumb may be landing: hold still
    if (remapdClaims()) { gNavX = x; gNavY = y; gNavTs = ts; return; }   // a bound swipe's state: hold still
    if (gNavArm) {                                  // back from a zoom: wait for a real move
        if (ts - gNavArmTs < NAV_RESUME_S) { gNavX = x; gNavY = y; gNavTs = ts; return; }
        if (n < 2 || hypotf(x - gNavX, y - gNavY) < TWO_START_MM) return;
        gNavArm = false;
        gNavX = x; gNavY = y; gNavTs = ts;
        return;
    }
    if (n >= 4 && !gSwipe) {
        // Four contacts, not (yet) a swipe: the thumb + 3 landing for the zoom (gSwipe leaves
        // the thumb out). Hold still while the thumb watch / navJudge decide (2026-10-18:
        // a fresh thumb + 3 was dropped here before the thumb could be told).
        gNavX = x; gNavY = y; gNavTs = ts;
        return;
    }
    if (n >= 4) {
        // Four fingers: an app-switch swipe, never nav. Let go, and stay out till the lift.
        navOutStop();
        if (gNavDown && gNavPs) psPostScroll(gNavAt, 0, 0, kCGScrollPhaseEnded);
        else if (gNavDown && !gNavMax) postMMB(kCGEventOtherMouseUp, gNavAt, 0);
        if (gNavDown && gNavMax) maxDragEnd();
        gNavDown = false; gNavDead = true;
        navLog("orbit: 4 fingers -> dropped");
        return;
    }
    if (n < 2) {
        // One finger left moves the pointer itself; with the MMB down that would orbit.
        if (gNavDown && gNavPs) { navOutStop(); psPostScroll(gNavAt, 0, 0, kCGScrollPhaseEnded); gNavDown = false; }
        else if (gNavDown && !gNavMax) { navOutStop(); postMMB(kCGEventOtherMouseUp, gNavAt, 0); gNavDown = false; }
        return;
    }
    bool pan = n < 3 || gNavPs;                     // two pan, three orbit (user, 2026-10-21; was the reverse);
                                                    // Photoshop only pans
    if (atomic_exchange(&gNavPan, pan) != pan && gNavDown && !gNavMax) {
        navOutStop();                               // the queued travel goes out under the old modifier
        postMMB(kCGEventOtherMouseUp, gNavAt, 0);  // Fusion: re-press with the new modifier
        postMMB(kCGEventOtherMouseDown, gNavAt, mmbFlags());
    }
    float dx = x - gNavX, dy = y - gNavY;
    if (fabsf(dx) <= 0.05f && fabsf(dy) <= 0.05f) return;
    double dt = ts - gNavTs;
    if (dt > 0 && dt < 0.1) gNavSpeed += 0.4 * (hypotf(dx, dy) / dt - gNavSpeed);
    else gNavSpeed = 0;
    gNavX = x; gNavY = y; gNavTs = ts;
    // (Photoshop's pan speed is pscursor's: Pan speed × the fill curve.)
    double g = navGain(gNavSpeed) * (pan && !gNavMax && !gNavPs ? FUSION_PAN_GAIN : 1.0);
    double px = dx * g, py = -dy * g;               // the pad's y runs up
    if (!pan) gNavOrbited = true;
    if (gNavMax) { maxDragFrameAt(gNavAt, px, py, !gNavDown); gNavDown = true; return; }
    if (!gNavDown && gNavPs) {
        pthread_mutex_lock(&gOutLk); gPsRx = gPsRy = 0; pthread_mutex_unlock(&gOutLk);
        psPostScroll(gNavAt, 0, 0, kCGScrollPhaseBegan);
        gNavDown = true;
    }
    if (!gNavDown) { postMMB(kCGEventOtherMouseDown, gNavAt, mmbFlags()); gNavDown = true; }
    navOutAdd(px, py);
}
static void navEnd(void) {
    if (!atomic_load(&gTouchNav)) return;
    navOutStop();
    if (gNavDown) {
        if (gNavMax) maxDragEnd();
        else if (gNavPs) psPostScroll(gNavAt, 0, 0, kCGScrollPhaseEnded);
        else {
            postMMB(kCGEventOtherMouseUp, gNavAt, 0);
            // The pivot only after an ORBIT: a pan keeps the last orbit centre (re-picking
            // under the pointer after a pan landed it on near geometry or reset it over
            // empty space, and the next pan ran at that depth — "erratic", 2026-10-18).
            if (gNavOrbited) requestOrbitCenter();
        }
    }
    gNavDown = false; gNavDead = false; gNavOrbited = false; gNavArm = false;
    if (gCandFrozen) { gCandFrozen = false; navFreeze(false, gCandAt); }
    atomic_store(&gNavPan, false);
    atomic_store(&gTouchNav, false);
    activatePending();
}
// Where an orbit / pan starts from (and returns to at a screen edge).
static void navHome(CGPoint at) {
    gNavHome = gNavAt = at;
    CGDirectDisplayID did = CGMainDisplayID(); uint32_t cnt = 0;
    CGGetDisplaysWithPoint(at, 1, &did, &cnt);
    // The screen's edge is the visible part's while it is zoomed (hidpoint.h).
    gNavScreen = CGRectInset(hidVisible(CGDisplayBounds(cnt ? did : CGMainDisplayID())), 2, 2);
}
// Every contact down now is a finger of this nav: only later ones are judged (navJudge).
static void navMarkFingers(void) {
    for (int i = 0; i < gNTn; i++) if (gNT[i].role == ROLE_NEW) gNT[i].role = ROLE_FINGER;
}
// Each frame while no 3-finger gesture is latched.
static void navTwoFrame(double ts) {
    if (atomic_load(&gTouchNav)) { if (gSwipe) gNavDead = true; if (gNTn) navMove(ts); else navEnd(); return; }
    float x, y; int n;
    navCentroid(-1, &x, &y, &n);
    if (n != 2 || atomic_load(&threeEvaluated) || gSwipe) { if (n != 2) gTwoT0 = 0; return; }
    if (gTwoT0 == 0) {                              // two fingers just down: where?
        gTwoT0 = ts;
        navCentroid(-1, &gNavX, &gNavY, &gNavN);
        char why[64];
        int ti = navRestThumb();
        if (ti < 0) ti = navLayoutThumb(why, sizeof why);   // thumb + one finger: no orbit (and no zoom)
        gTwoThumb = ti >= 0;
        atomic_store(&gTwoTarget, 0);
        if (!gTwoThumb) dispatch_async(gAXQueue, ^{   // AX off the multitouch thread
            bool isFront = false, isFusion = false, isMax = false;
            pid_t cad = cadUnderCursor(&isFront, &isFusion, &isMax);
            int t = cad && isMax ? 2 : cad && isFusion && elementIsCanvas() ? 1
                  : !cad && psCanvasAt(cursorPos()) ? 3 : -1;     // 3: Photoshop's canvas (pans only)
            atomic_store(&gTwoPid, t == 1 && !isFront ? cad : 0);
            atomic_store(&gTwoTarget, t);
        });
        return;
    }
    // Held a moment (a 3-finger touchdown passes through two), then moving: orbit.
    if (gTwoThumb || atomic_load(&gTwoTarget) <= 0 || ts - gTwoT0 < TWO_ACTIVATE_DELAY) return;
    if (hypotf(x - gNavX, y - gNavY) < TWO_START_MM) return;
    gNavX = x; gNavY = y; gNavN = n;
    gNavMax = atomic_load(&gTwoTarget) == 2;
    gNavPs = atomic_load(&gTwoTarget) == 3;
    gNavDown = false;
    navHome(cursorPos());
    navMarkFingers();
    gNavTs = ts; gNavSpeed = 0;
    atomic_store(&pendingActivatePid, atomic_load(&gTwoPid));
    atomic_store(&gNavPan, false);
    atomic_store(&gTouchNav, true);
    trace(gNavMax ? "2f pan (Max)" : gNavPs ? "2f pan (Photoshop)" : "2f pan");
}

static int navTouching(void) { float x, y; int n; navCentroid(-1, &x, &y, &n); return n; }
// A 3-finger PAN (the latched OS drag, gThreePan) down to two fingers: ORBIT from here,
// touch-driven like an orbit begun with two — a third finger back pans again.
static void navTakeOver(double ts) {
    bool engaged = atomic_load(&mmbEngaged);
    gNavMax = atomic_load(&gMaxDrag); gNavPs = false;
    navHome(cursorPos());
    navMarkFingers();
    navCentroid(-1, &gNavX, &gNavY, &gNavN);
    gNavTs = ts; gNavSpeed = 0;
    atomic_store(&gThreePan, false);
    atomic_store(&gNavPan, false);
    atomic_store(&threeFinger, false);
    atomic_store(&dragMode, MODE_NONE);
    atomic_store(&mmbEngaged, false);
    gCanvasTouch = gMaxTouch = false;
    gNavDown = engaged;
    if (engaged && !gNavMax) {                      // Fusion: re-press as an orbit
        postMMB(kCGEventOtherMouseUp, gNavAt, 0);
        postMMB(kCGEventOtherMouseDown, gNavAt, mmbFlags());
    }
    atomic_store(&gTouchNav, true);
    trace(gNavN >= 3 ? "3f orbit -> touch orbit" : "3f orbit -> 2f pan");
}

// THUMB IN / THUMB OUT (2026-10-18): a thumb landing on a running orbit or pan turns it
// into the zoom (navToZoom); the thumb lifting turns the zoom back into an orbit / pan by
// the fingers left (navResume). The pointer stays exactly where the thumb landed — frozen
// there from the landing (gCandAt) through the zoom — and moves on from there after.
static void navToZoom(int thumb, const char *why) {
    CGPoint at; bool isMax, isPs = false;
    if (atomic_load(&gTouchNav)) {                  // a touch-driven orbit / pan: let go
        navOutStop();
        if (gNavDown && gNavPs) psPostScroll(gNavAt, 0, 0, kCGScrollPhaseEnded);
        else if (gNavDown) gNavMax ? maxDragEnd() : postMMB(kCGEventOtherMouseUp, gNavAt, 0);
        at = gCandFrozen ? gCandAt : gNavAt;       // our drags put the pointer at gNavAt
        isMax = gNavMax; isPs = gNavPs;
        gNavDown = false; gNavOrbited = false; gNavArm = false;
        atomic_store(&gNavPan, false);
        atomic_store(&gTouchNav, false);
    } else {                                        // macOS's 3-finger drag, latched as a pan
        isMax = atomic_load(&gMaxDrag);
        at = gCandFrozen ? gCandAt : cursorPos();
        if (atomic_load(&mmbEngaged)) isMax ? maxDragEnd() : postMMB(kCGEventOtherMouseUp, at, 0);
    }
    at = CGPointMake(round(at.x), round(at.y));     // as remapd's rounded pin (navPinSet)
    pid_t cad = atomic_exchange(&pendingActivatePid, 0);
    atomic_store(&gThreePan, false);
    atomic_store(&mmbEngaged, false);
    gCanvasTouch = gMaxTouch = false;
    atomic_store(&dragMode, MODE_ZOOM);
    atomic_store(&threeFinger, true);
    gCandFrozen = false;                            // the zoom holds the freeze now, at the same spot
    navZoomStart(thumb, isMax, isPs, cad, cad == 0, why, at);
}
static void navResume(double ts) {
    CGPoint at = gZoomAt;
    atomic_store(&threeFinger, false);
    atomic_store(&dragMode, MODE_NONE);
    atomic_store(&mmbEngaged, false);
    atomic_store(&gThreePan, false);
    gNavMax = gZoomMax; gNavPs = gZoomPs; gNavDown = false; gNavDead = false; gNavOrbited = false;
    navHome(at);                                    // navZoomEnd put the pointer back here
    navMarkFingers();
    gNavN = -1;                                     // re-based on the first move
    gNavTs = ts; gNavSpeed = 0;
    gNavArm = true; gNavArmTs = ts;
    atomic_store(&gNavPan, false);
    atomic_store(&gTouchNav, true);
    navLog("zoom: thumb up -> %s", navTouching() >= 3 && !gNavPs ? "orbit" : "pan");
}
// Each frame of an orbit / pan: a contact that landed since. Level with or above the
// fingers = a finger at once (2 → 3 still pans immediately); low and left = a CANDIDATE,
// held out of the count until its shape says thumb (→ the zoom) or NAV_THUMB_WATCH frames
// pass (→ a finger).
static void navJudge(void) {
    bool cand = false;
    for (int i = 0; i < gNTn; i++) cand |= gNT[i].touching && gNT[i].role == ROLE_CAND;
    if (gCandFrozen && !cand) { gCandFrozen = false; navFreeze(false, gCandAt); }   // it lifted unjudged
    for (int c = 0; c < gNTn; c++) {
        NavTouch *t = &gNT[c];
        if (!t->touching || t->role == ROLE_FINGER) continue;
        float mx = 0, my = 0; int k = 0;
        for (int i = 0; i < gNTn; i++)
            if (i != c && gNT[i].touching && gNT[i].role == ROLE_FINGER) { mx += gNT[i].nx; my += gNT[i].ny; k++; }
        if (!k) { t->role = ROLE_FINGER; continue; }
        mx /= k; my /= k;
        float drop = my - t->ny0;
        if (t->role == ROLE_NEW) {
            t->role = t->nx0 < mx && drop >= NAV_LATE_DROP ? ROLE_CAND : ROLE_FINGER;
            if (t->role == ROLE_FINGER) continue;
            if (!gCandFrozen) {                     // the thumb is landing: stop right here
                gCandAt = atomic_load(&gTouchNav) ? gNavAt : cursorPos();
                // Whole pixels: remapd's pin (navPinSet) is rounded, and two warps half a pixel
                // apart shook the pointer when the thumb landed on a resumed orbit (2026-10-18).
                gCandAt = CGPointMake(round(gCandAt.x), round(gCandAt.y));
                gCandFrozen = true;
                navFreeze(true, gCandAt);
            }
        }
        float sc = navThumbScore(t);
        bool thumb = gNavPrint.ok ? sc >= NAV_THUMB_SCORE : drop >= NAV_THUMB_DROP;
        char why[96];
        snprintf(why, sizeof why, "thumb joined: score=%.1f drop=%.2f frames=%d, %d finger%s",
                 sc, drop, t->frames, k, k == 1 ? "" : "s");
        if (thumb) { navToZoom(c, why); return; }
        if (t->frames >= NAV_THUMB_WATCH) { t->role = ROLE_FINGER; navLog("late contact = finger (%s)", why); }
    }
}

// THUMB CALIBRATION (2026-10-18). While /tmp/nav_calib_label holds "pan" or "zoom"
// (bin/nav_calib.sh), every 3-contact landing is recorded with that label to
// NAV_CALIB_LOG: each contact's landing place, timing and shape, NAV_CALIB_FRAMES frames
// after the decision (the shape peaks need the landing frames), plus what reanchor
// decided. The HUD shows the running count and whether it read the gesture right.
#define NAV_CALIB_LABEL  "/tmp/nav_calib_label"
#define NAV_CALIB_LOG    "/Users/josh/Code/Scripts/remap/nav_calib.jsonl"
#define NAV_CALIB_FRAMES 10
static int  gCalibLeft = 0;             // frames until the record is written (0 = none pending)
static char gCalibLabel[8], gCalibDecided[8], gCalibWhy[96];
static void navCalibArm(bool zoom, const char *why) {
    gCalibLeft = 0;
    FILE *f = fopen(NAV_CALIB_LABEL, "r");
    if (!f) return;
    char l[16] = ""; fscanf(f, "%15s", l); fclose(f);
    if (strcmp(l, "pan") && strcmp(l, "zoom")) return;
    snprintf(gCalibLabel, sizeof gCalibLabel, "%s", l);
    snprintf(gCalibDecided, sizeof gCalibDecided, "%s", zoom ? "zoom" : "pan");
    snprintf(gCalibWhy, sizeof gCalibWhy, "%s", why);
    gCalibLeft = NAV_CALIB_FRAMES;
}
static void navCalibWrite(void) {
    gCalibLeft = 0;
    FILE *f = fopen(NAV_CALIB_LOG, "a");
    if (!f) return;
    double t00 = 1e18;
    for (int i = 0; i < gNTn; i++) if (gNT[i].t0 < t00) t00 = gNT[i].t0;
    fprintf(f, "{\"t\":%ld,\"label\":\"%s\",\"decided\":\"%s\",\"why\":\"%s\",\"contacts\":[",
            (long)time(NULL), gCalibLabel, gCalibDecided, gCalibWhy);
    for (int i = 0; i < gNTn; i++) {
        const NavTouch *t = &gNT[i];
        fprintf(f, "%s{\"id\":%d,\"lead_ms\":%.1f,\"nx0\":%.4f,\"ny0\":%.4f,\"mx0\":%.2f,\"my0\":%.2f,"
                   "\"mx\":%.2f,\"my\":%.2f,\"size\":%.4f,\"major\":%.3f,\"minor\":%.3f,\"angle\":%.3f,"
                   "\"score\":%.3f,\"touching\":%d}",
                i ? "," : "", t->id, (t->t0 - t00) * 1000, t->nx0, t->ny0, t->mx0, t->my0, t->mx, t->my,
                t->pkSize, t->pkMajor, t->pkMinor, t->pkAngle, navThumbScore(t), t->touching);
    }
    fprintf(f, "]}\n");
    fclose(f);
    // The running count, and whether today's rules read it right.
    int n = 0; char line[4096];
    f = fopen(NAV_CALIB_LOG, "r");
    if (f) {
        char want[32]; snprintf(want, sizeof want, "\"label\":\"%s\"", gCalibLabel);
        while (fgets(line, sizeof line, f)) if (strstr(line, want)) n++;
        fclose(f);
    }
    char msg[96];
    snprintf(msg, sizeof msg, "%s %d  %s", gCalibLabel, n,
             strcmp(gCalibLabel, gCalibDecided) ? "✗ read as the other" : "✓");
    char *text = strdup(msg);
    dispatch_async(gAXQueue, ^{
        pid_t p; char *argv[] = { "/Users/josh/bin/hud", "show", text, "--ms", "1200", NULL };
        extern char **environ;
        if (posix_spawn(&p, argv[0], NULL, NULL, argv, environ) == 0) waitpid(p, NULL, 0);
        free(text);
    });
}

#define PROBE_PAUSE "/tmp/fusion_probe_pause"   // Cursor Probe.py's PAUSE
static bool gProbePaused = false;                 // gAXQueue only
// Palm rejection (2026-10-18): a contact FIRST SEEN in the pad's bottom strip is the palm
// and is left out of every count for its whole life — a finger that later slides down
// there stays a finger. Lowest real landing measured: ny0 0.18 (nav_calib.jsonl thumbs).
#define PALM_EDGE  0.08f
#define PALM_MAX   32
static int touchCallbackRaw(int device, Finger *data, int nFingers, double timestamp, int frame);
static int touchCallback(int device, Finger *data, int nFingers, double timestamp, int frame) {
    static int palm[PALM_MAX], seen[PALM_MAX], nPalm = 0, nSeen = 0;   // multitouch thread only
    int nowSeen[PALM_MAX], nNow = 0, nowPalm[PALM_MAX], nNowPalm = 0;
    Finger kept[PALM_MAX]; int k = 0;
    for (int i = 0; i < nFingers && i < PALM_MAX; i++) {
        int id = data[i].identifier; bool known = false, isPalm = false;
        for (int j = 0; j < nSeen; j++) if (seen[j] == id) { known = true; break; }
        for (int j = 0; j < nPalm; j++) if (palm[j] == id) { isPalm = true; break; }
        if (!known && data[i].normalized.pos.y < PALM_EDGE) {
            isPalm = true;
            navLog("palm: contact %d landed at y %.3f -> ignored", id, data[i].normalized.pos.y);
        }
        nowSeen[nNow++] = id;
        if (isPalm) nowPalm[nNowPalm++] = id;
        else kept[k++] = data[i];
    }
    memcpy(seen, nowSeen, nNow * sizeof *seen); nSeen = nNow;          // gone ids forget (ids recycle)
    memcpy(palm, nowPalm, nNowPalm * sizeof *palm); nPalm = nNowPalm;
    int r = touchCallbackRaw(device, kept, k, timestamp, frame);
    // remapd's thumb pin follows ours while our Fusion / Max nav owns the touch (navPinSet).
    int mode = atomic_load(&dragMode);
    bool three = atomic_load(&threeFinger);
    bool ours = k > 0 && (atomic_load(&gTouchNav)
                || (three && (mode == MODE_ZOOM || (mode == MODE_MMB && atomic_load(&gThreePan)))));
    bool zoomPin = three && mode == MODE_ZOOM && gZoomThumb >= 0;
    navPinSet(ours, gCandFrozen || zoomPin, gCandFrozen ? gCandAt : gZoomAt);
    return r;
}
static int touchCallbackRaw(int device, Finger *data, int nFingers, double timestamp, int frame) {
    atomic_store(&gFingers, nFingers);                    // first, before anything that can block
    if (nFingers > 0 && gTouchStartMs == 0) gTouchStartMs = nowMs();
    if (nFingers > 0 && gTouchT0 == 0) gTouchT0 = timestamp;
    navTrack(data, nFingers, timestamp);
    {   // A swipe's fingers land together: 4+ of the touch's EARLY contacts (a thumb joining a
        // pan later is no swipe), the THUMB left out — thumb + 3 fingers zoom (2026-10-18). So
        // it waits till each has NAV_SWIPE_SHAPE frames of shape. Hovering ones count from 5.
        int early = 0, earlyTouching = 0; bool shaped = true;
        for (int i = 0; i < gNTn; i++) {
            if (gNT[i].t0 - gTouchT0 >= NAV_LATE_S || gNT[i].role == ROLE_CAND || navThumbLike(i)) continue;
            early++;
            if (gNT[i].touching) { earlyTouching++; if (gNT[i].frames < NAV_SWIPE_SHAPE) shaped = false; }
        }
        if ((earlyTouching >= 4 && shaped) || early >= 5) { gSwipe = true; gSwipeTs = timestamp; }
    }
    // A contact joining a running orbit / pan: maybe the thumb (→ the zoom).
    if (!gSwipe && timestamp - gSwipeTs >= SWIPE_SETTLE
        && (atomic_load(&gTouchNav) ? !gNavDead
            : atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_MMB && atomic_load(&gThreePan)))
        navJudge();
    if (!gSwipe && gTouchStartMs && gTouchStartMs <= atomic_load(&gSpaceChangeMs)) {
        gSwipe = true; gSwipeTs = timestamp;                 // began on the old Space: inert to the lift
        navLog("touch began before a Space change -> no nav");
    }
    if (gCalibLeft && (--gCalibLeft == 0 || gNTn < 3)) navCalibWrite();

    // ── Cursor Probe pause ──────────────────────────────────────────────────
    // While a touch that began over Fusion is on the pad, PROBE_PAUSE exists and the
    // Cursor Probe add-in stops ray casting. This was three BTT triggers (1/2 Finger
    // Touch Start, Release Last Finger) until 2026-10-11: their hovered/focused-element
    // conditions made BTT ask the app under the pointer on every touch, from its main
    // thread — which also runs its event tap — so a Photoshop drag (not answering AX
    // until it gets its mouse-up) had the release held ~2.6 s. Here: no AX at all.
    static bool touching = false;
    if (nFingers > 0 && !touching) {
        touching = true;
        dispatch_async(gAXQueue, ^{
            bool fusion = false;
            if (cadUnderCursor(NULL, &fusion, NULL) && fusion) {
                int fd = open(PROBE_PAUSE, O_CREAT | O_WRONLY, 0644);
                if (fd >= 0) close(fd);
                gProbePaused = true;
            }
        });
    } else if (nFingers == 0 && touching) {
        touching = false;
        dispatch_async(gAXQueue, ^{
            if (gProbePaused) { unlink(PROBE_PAUSE); gProbePaused = false; }
        });
    }

    // ── Two-finger drag-to-focus ────────────────────────────────────────────
    // A 2-finger touch that PERSISTS for TWO_ACTIVATE_DELAY over an unfocused CAD
    // window activates it (once per gesture). The dwell rejects the brief 2-finger
    // reading a 3-finger touchdown passes through; we also stay out of the way once
    // a 3-finger gesture is engaged. No-op when the CAD app is already frontmost
    // (let its normal zoom run) or the pointer isn't over CAD.
    // SketchUp only since 2026-10-18: two fingers orbit Fusion / Max (navTwoFrame), which
    // needs no focus, and activating mid-orbit interrupts it — that focus waits for the lift.
    if (nFingers == 2 && !atomic_load(&threeFinger)) {
        if (twoStartTs == 0.0) twoStartTs = timestamp;
        if (!atomic_load(&twoActivated) && (timestamp - twoStartTs) >= TWO_ACTIVATE_DELAY) {
            atomic_store(&twoActivated, true);            // decide once per gesture, either way
            dispatch_async(gAXQueue, ^{                   // AX off the multitouch thread
                bool isFront = false, isFusion = false, isMax = false;
                pid_t cad = cadUnderCursor(&isFront, &isFusion, &isMax);
                if (isFusion || isMax) cad = 0;
                if (cad && !elementIsCanvas()) cad = 0;              // only over the 3D canvas, not chrome/menus
                if (cad && !isFront) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSRunningApplication *app =
                            [NSRunningApplication runningApplicationWithProcessIdentifier:cad];
                        [app activateWithOptions:NSApplicationActivateAllWindows];
                    });
                }
            });
        }
    } else if (nFingers != 2) {
        twoStartTs = 0.0;
        atomic_store(&twoActivated, false);
    }
    if (!atomic_load(&threeFinger)) navTwoFrame(timestamp);   // Fusion / Max: 2-finger orbit

    // ── One-finger dwell / lift -> orbit centre ──────────────────────────────
    // Mirrors the retired fusion_dwell daemon: the cursor must MOVE during a
    // single-finger run, then a fire happens once on either a short still-dwell or
    // the lift. Stays out of the way of an engaged 3-finger drag. fireOneFingerOrbit
    // applies the safety guards (Fusion frontmost + over the canvas + dedup).
    if (nFingers == 1 && !atomic_load(&threeFinger) && !atomic_load(&gTouchNav)) {
        CGPoint p = cursorPos();
        int px = (int)p.x, py = (int)p.y;
        if (oneStartTs == 0.0) {                          // run just began
            oneStartTs = timestamp; oneStillX = px; oneStillY = py;
            oneStillSince = timestamp; oneMoved = false; oneFired = false;
        } else if (px != oneStillX || py != oneStillY) {  // cursor moved from its resting spot
            oneMoved = true; oneStillX = px; oneStillY = py;
            oneStillSince = timestamp; oneFired = false;
        } else if (oneMoved && !oneFired && (timestamp - oneStillSince) >= ONE_STILL_SECS) {
            oneFired = true;                              // moved earlier, now held still -> dwell fire
            dispatch_async(gAXQueue, ^{ fireOneFingerOrbit(); });
        }
    } else if (nFingers == 0) {
        // Lifted after moving, before a dwell could fire. Guard on !threeFinger so a
        // 3-finger gesture's own lift (handled below) never double-fires through here.
        if (oneStartTs != 0.0 && oneMoved && !oneFired && !atomic_load(&threeFinger))
            dispatch_async(gAXQueue, ^{ fireOneFingerOrbit(); });
        oneStartTs = 0.0; oneMoved = false; oneFired = false;
    } else {
        // 2+ fingers down (or a 3-finger drag engaged): abandon the run without firing.
        oneStartTs = 0.0; oneMoved = false; oneFired = false;
    }

    // A 3-finger landing read as a PAN keeps checking for the thumb over its first frames
    // (the shape score peaks as the contacts land): found → it becomes the zoom.
    if (gThumbWatch > 0) {
        gThumbWatch--;
        bool pan = atomic_load(&gTouchNav) ? gNavN >= 3
                 : atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_MMB && atomic_load(&gThreePan);
        char why[96] = "";
        int thumb = pan && !gSwipe && navTouching() >= 3 ? navLayoutThumb(why, sizeof why) : -1;
        if (!pan || gSwipe) gThumbWatch = 0;
        else if (thumb >= 0) {
            gThumbWatch = 0;
            char late[112]; snprintf(late, sizeof late, "late, %s", why);
            navToZoom(thumb, late);
            if (gCalibLeft) snprintf(gCalibDecided, sizeof gCalibDecided, "zoom");
        }
    }

    // Photoshop's canvas, 3 contacts and no thumb at the first frame: the same watch, with
    // the gesture's left-down held meanwhile. Found → the zoom (the left-down dropped);
    // not → macOS's own 3-finger drag (the left-down let out where it was pressed).
    // The third contact may still be HOVERING (fingers resting, the thumb on its way down:
    // nFingers counts it, navTouching doesn't — 2026-10-21, every such try fell through to the
    // drag a frame later). So the watch waits, its frames counted only while 3 touch; a
    // contact that leaves without landing re-opens the decision, so the fingers still pan.
    if (gPsWatch > 0) {
        char why[96] = "";
        int touching = navTouching();
        int thumb = !gSwipe && touching >= 3 ? navLayoutThumb(why, sizeof why) : -1;
        if (thumb >= 0) {
            gPsWatch = 0;
            atomic_store(&dragMode, MODE_ZOOM);
            atomic_store(&threeFinger, true);
            settleHeld(true);
            char late[112]; snprintf(late, sizeof late, "late, %s", why);
            navZoomStart(thumb, false, true, 0, true, late, cursorPos());
        } else if (gSwipe || gNTn < 3 || (touching >= 3 && --gPsWatch == 0)) {
            gPsWatch = 0;
            bool held = settleHeld(false);
            if (!held && !gSwipe && gNTn < 3) {     // it never landed: judge the next 3 afresh
                atomic_store(&threeEvaluated, false);
                atomic_store(&threeDecided, false);
                navLog("ps: third contact left unlanded -> judging again");
            } else navLog("ps: no thumb (%s) -> 3-finger drag", why);
        }
    }

    if ((nFingers == 3 || (nFingers == 4 && navFourWithThumb())) && !atomic_load(&threeFinger) && !atomic_load(&gTouchNav) && !gSwipe) {
        // Decide ONCE, at the gesture's first 3-finger frame, whether this drag is a
        // CAD navigation: only if the pointer is over a CAD window at that moment.
        // We latch the decision (threeEvaluated) and never re-test cadUnderCursor on
        // later frames — so a drag that BEGINS over a floater (e.g. dragging its title
        // bar to move the window) stays native for its whole life even if the pointer
        // then races over Fusion/SketchUp before the window catches the drag. Without
        // the latch, that later frame would re-evaluate, find CAD under the cursor,
        // and hijack the window drag into an orbit.
        if (!atomic_load(&threeEvaluated)) {
            atomic_store(&threeEvaluated, true);
            double t0 = nowMs();
            bool isFront = false, isFusion = false, isMax = false;
            pid_t cad = cadUnderCursor(&isFront, &isFusion, &isMax);
            if (cad && !isMax && !elementIsCanvas()) cad = 0;  // only over the 3D canvas, not chrome/menus
            atomic_store(&gMaxDrag, cad && isMax);
            CGEventRef pe = CGEventCreate(NULL);
            CGPoint pp = CGEventGetLocation(pe);
            CFRelease(pe);
            bool dockNow = cad ? false : dockFrameContains(pp);
            gCanvasTouch = cad && isFusion;
            gSketchUpDrag = cad && !isFusion && !isMax;
            gMaxTouch = cad && isMax;
            gCanvasStartX = pp.x; gCanvasStartY = pp.y;
            // Fusion / Max / Photoshop's canvas: thumb + two fingers = the pinch zoom;
            // three fingers = pan (Fusion / Max), a plain 3-finger drag (Photoshop).
            bool ps = !cad && !dockNow && psCanvasAt(pp);
            int thumb = -1; char why[96] = "";
            if ((cad && (isFusion || isMax)) || ps) {
                thumb = navRestThumb();
                if (thumb >= 0) snprintf(why, sizeof why, "thumb resting");
                else thumb = navLayoutThumb(why, sizeof why);
                if (thumb >= 0 && timestamp - gSwipeTs < SWIPE_SETTLE) {
                    navLog("zoom refused: %.0f ms after a swipe (%s)", (timestamp - gSwipeTs) * 1000, why);
                    thumb = -1;
                }
                if (thumb < 0) navLog("%s (%s)", ps ? "ps: 3 contacts, no thumb yet" : "3f pan", why);
                if (!ps) navCalibArm(thumb >= 0, why);
            }
            if (thumb >= 0) {
                atomic_store(&pendingActivatePid, 0);
                atomic_store(&mmbEngaged, false);
                atomic_store(&dragMode, MODE_ZOOM);
                atomic_store(&threeFinger, true);
                gCanvasTouch = gMaxTouch = false;
                navZoomStart(thumb, isMax, ps, cad, isFront, why, cursorPos());
            } else if (cad) {
                atomic_store(&gThreePan, isFusion || isMax);
                atomic_store(&gThreeMs, nowMs());
                int pn; navCentroid(-1, &gPanX0, &gPanY0, &pn);
                navMarkFingers();                       // the landing's thumb is gThumbWatch's; navJudge takes later ones
                if ((isFusion || isMax) && timestamp - gSwipeTs >= SWIPE_SETTLE) gThumbWatch = NAV_THUMB_WATCH;
                atomic_store(&pendingActivatePid, 0);
                if (!isFront && !isFusion && !isMax) {
                    // Inactive SketchUp: its own real left-down focuses it cleanly, then
                    // we release it and hand off to MODE_MMB on the first drag frame (see
                    // eventCallback). SketchUp tolerates that brief click without a snag.
                    atomic_store(&mmbArmed, false);
                    atomic_store(&mmbEngaged, false);
                    atomic_store(&dragMode, MODE_ACTIVATE);
                    atomic_store(&threeFinger, true);
                } else {
                    // Focused CAD app, OR inactive Fusion: drive the MMB nav. MMB
                    // orbits/pans the window under the pointer even when Fusion is unfocused,
                    // so no left event needs to reach it — which matters because a real
                    // left-down leaves a stray selection in Fusion that blocks the orbit.
                    // For an inactive Fusion we still want it focused, but activating mid-drag
                    // interrupts the orbit, so defer it to the gesture's end.
                    // The MMB button-down itself is DEFERRED to the first drag frame in
                    // eventCallback (see mmbEngaged): latching here still swallows the
                    // gesture's own left events, but a tap ends with no button ever pressed.
                    if (!isFront) atomic_store(&pendingActivatePid, cad);
                    atomic_store(&mmbEngaged, false);
                    atomic_store(&dragMode, MODE_MMB);
                    atomic_store(&threeFinger, true);
                }
            } else if (dockNow) {
                // Over the dock: latch inert (see MODE_INERT). No MMB, no activation,
                // no pivot — only the left-event swallow and the tap/drag decision.
                CGEventRef ev = CGEventCreate(NULL);
                CGPoint dp = CGEventGetLocation(ev);
                CFRelease(ev);
                gDockStartX = dp.x; gDockStartY = dp.y;
                {
                    struct timespec dts;
                    clock_gettime(CLOCK_REALTIME, &dts);
                    gDockStartMs = (long long)dts.tv_sec * 1000 + dts.tv_nsec / 1000000;
                }
                atomic_store(&pendingActivatePid, 0);
                atomic_store(&mmbArmed, false);
                atomic_store(&mmbEngaged, false);
                atomic_store(&dragMode, MODE_INERT);
                atomic_store(&threeFinger, true);
            } else if (ps && timestamp - gSwipeTs >= SWIPE_SETTLE) {
                // Photoshop's canvas, no thumb yet: the left-down stays held while the
                // thumb watch looks (gPsWatch, above), which settles it.
                gPsWatch = NAV_THUMB_WATCH;
            }
            // otherwise: not over CAD, the dock or Photoshop at touchdown — stay dormant
            // for the rest of the gesture.

            // Settle a left-down the tap held while we were deciding (see leftHeld).
            // MMB / dock / zoom: drop it — the gesture never clicks. Dormant, or an inactive
            // SketchUp (whose focusing click IS the left-down): hand it on.
            int mode = atomic_load(&threeFinger) ? atomic_load(&dragMode) : MODE_NONE;
            bool held = false;
            if (!gPsWatch) held = settleHeld(mode != MODE_NONE && mode != MODE_ACTIVATE);
            double ms = nowMs() - t0;
            if (held || ms > 40)
                logSlow(held ? (mode == MODE_MMB ? "3f decide (held left-down dropped → orbit)"
                                : mode == MODE_ZOOM ? "3f decide (held left-down dropped → zoom)"
                                                  : "3f decide (held left-down re-posted)")
                             : "3f decide slow", ms);
        }
    } else if (atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_ZOOM) {
        // The pinch zoom, until the thumb lifts; then inert until every finger has.
        // Four touching: it was a swipe landing — stop, inert to the lift.
        if (gSwipe) {
            navZoomEnd();
            atomic_store(&dragMode, MODE_VOID);
            navLog("zoom: 4 fingers -> dropped (a swipe)");
        } else if (nFingers > 0) {
            navZoomFrame();
            if (gZoomThumb < 0 && navTouching() > 0) navResume(timestamp);   // the thumb lifted: orbit / pan again
        }
        else {
            navZoomEnd();
            atomic_store(&threeFinger, false);
            atomic_store(&dragMode, MODE_NONE);
        }
    } else if (atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_MMB && atomic_load(&gThreePan)
               && navTouching() >= 4) {
        // Fusion / Max: a 4th finger is a 4-finger swipe (app switch), never a pan. Let go
        // and stay inert to the lift (MODE_VOID still swallows the gesture's left events).
        if (atomic_load(&mmbEngaged)) atomic_load(&gMaxDrag) ? maxDragEnd() : postMMB(kCGEventOtherMouseUp, cursorPos(), 0);
        atomic_store(&mmbEngaged, false);
        atomic_store(&gThreePan, false);
        atomic_store(&dragMode, MODE_VOID);
        gCanvasTouch = gMaxTouch = false;
        atomic_store(&pendingActivatePid, 0);
        navLog("3f pan: 4th finger -> dropped (a swipe)");
    } else if (atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_MMB && atomic_load(&gThreePan)
               && !atomic_load(&gMaxDrag) && navTouching() == 3 && !gCandFrozen
               && nowMs() - atomic_load(&gThreeMs) >= PAN_SETTLE_MS && ({
                   float x, y; int n; navCentroid(-1, &x, &y, &n);
                   hypotf(x - gPanX0, y - gPanY0) >= TWO_START_MM; })) {
        // Fusion's 3-finger pan, once it moves: off the touches, posted from our own point
        // (navMove), like the 2-finger orbit. Driving it from macOS's drag events fed our
        // own pointer warps back into their deltas — the pan flew off (2026-10-18). A tap
        // never moves, so it stays here and the lift still sees it.
        navTakeOver(timestamp);
    } else if (atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_MMB && atomic_load(&gThreePan)
               && !atomic_load(&gFourOwn) && navTouching() == 2 && !gCandFrozen) {
        // Fusion / Max pan down to two fingers for a moment (not the lift's 3→2→0): orbit.
        static double since = 0;
        static int seenFrame = -1;
        if (seenFrame != frame - 1) since = timestamp;
        seenFrame = frame;
        if (timestamp - since >= 0.06) navTakeOver(timestamp);
    } else if (atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_MMB && nFingers >= 3
               && !atomic_load(&gThreePan) && (nFingers >= 4 || atomic_load(&gFourOwn))) {
        // (SketchUp only: in Fusion / Max a 4th finger is a swipe. nFingers counts hovering
        // contacts — a palm above the pad turned Fusion pans touch-driven at 18 px/mm.)
        // A 4th finger on a CAD drag: PAN while it is down, ORBIT again once it lifts
        // (gFourPan → mmbFlags / the Max frame's shift). The motion is the touches'
        // centroid from here to the lift (gFourOwn; eventCallback drops macOS's drags).
        static float lx, ly; static int ln = 0;
        float cx = 0, cy = 0; int cn = 0;
        for (int i = 0; i < nFingers; i++)
            if (data[i].state >= 4 && data[i].state <= 5) { cx += data[i].mm.pos.x; cy += data[i].mm.pos.y; cn++; }
        if (cn) { cx /= cn; cy /= cn; }
        bool four = nFingers >= 4;
        if (!atomic_exchange(&gFourOwn, true) || cn != ln) { lx = cx; ly = cy; ln = cn; }
        if (atomic_exchange(&gFourPan, four) != four) {
            trace(four ? "4th finger -> pan" : "4th finger up -> orbit");
            // SketchUp pans on the REAL Shift: post one, at the HID level, for the pan's length.
            if (gSketchUpDrag) {
                CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
                CGEventRef k = CGEventCreateKeyboardEvent(src, 56, four);
                CGEventSetFlags(k, four ? kCGEventFlagMaskShift : 0);
                CGEventPost(kCGHIDEventTap, k);
                CFRelease(k); CFRelease(src);
            }
            if (atomic_load(&mmbEngaged) && !atomic_load(&gMaxDrag)) retargetMMB();
        }
        float ddx = cx - lx, ddy = cy - ly;
        if (cn && (fabsf(ddx) > 0.05f || fabsf(ddy) > 0.05f)) {
            lx = cx; ly = cy;
            // mm → points; the pad's y runs up, the screen's down.
            double g = four && !gSketchUpDrag && !atomic_load(&gMaxDrag) ? FUSION_PAN_GAIN : 1.0;
            double px = ddx * FOUR_PX_PER_MM * g, py = -ddy * FOUR_PX_PER_MM * g;
            CGPoint at = cursorPos();
            at.x += px; at.y += py;
            bool begin = !atomic_exchange(&mmbEngaged, true);
            if (atomic_load(&gMaxDrag)) maxDragFrameAt(at, px, py, begin);
            else {
                if (begin) postMMB(kCGEventOtherMouseDown, at, mmbFlags());
                postMMB(kCGEventOtherMouseDragged, at, mmbFlags());
            }
        }
    } else if (nFingers >= 4 && atomic_load(&threeFinger) && !(atomic_load(&gThreePan) && !gSwipe)) {
        // (A Fusion / Max pan stays latched while the 4th contact is no swipe — gSwipe leaves
        // the thumb out — so the thumb watch / navJudge can turn thumb + 3 into the zoom.
        // 2026-10-18: a fresh thumb + 3 latched a pan at 3 contacts and the thumb ended it here.)
        atomic_store(&threeFinger, false);            // 4th finger cancels the gesture (not a CAD drag)
        if (atomic_load(&dragMode) == MODE_MMB && atomic_load(&mmbEngaged))
            atomic_load(&gMaxDrag) ? maxDragEnd() : endDrag();
        atomic_store(&mmbEngaged, false);
        atomic_store(&dragMode, MODE_NONE);
        activatePending();
    } else if (nFingers == 0 && atomic_load(&threeFinger)) {
        bool navved = atomic_load(&mmbEngaged);       // did this gesture actually orbit/pan?
        int mode = atomic_load(&dragMode);            // read before the reset below
        atomic_store(&threeFinger, false);            // all fingers lifted
        atomic_store(&gFourOwn, false);
        atomic_store(&gThreePan, false);
        if (atomic_exchange(&gFourPan, false) && gSketchUpDrag) {   // the pan's Shift, back up
            CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef k = CGEventCreateKeyboardEvent(src, 56, false);
            CGEventSetFlags(k, 0);
            CGEventPost(kCGHIDEventTap, k);
            CFRelease(k); CFRelease(src);
        }
        if (mode == MODE_MMB && navved) atomic_load(&gMaxDrag) ? maxDragEnd() : endDrag();
        atomic_store(&mmbEngaged, false);
        atomic_store(&dragMode, MODE_NONE);
        activatePending();
        if (mode == MODE_INERT) {
            // Three fingers down over the dock and lifted without travelling: a TAP.
            // Stamp it for the dock, which jumps to the top level.
            CGEventRef ev = CGEventCreate(NULL);
            CGPoint up = CGEventGetLocation(ev);
            CFRelease(ev);
            double dx = up.x - gDockStartX, dy = up.y - gDockStartY;
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            long long ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
            long long held = gDockStartMs ? ms - gDockStartMs : 0;
            if (dx * dx + dy * dy <= (double)(DOCK_TAP_PX * DOCK_TAP_PX)
                && held <= DOCK_TAP_MS) {
                FILE *f = fopen(DOCK_TAP_FILE, "w");
                if (f) { fprintf(f, "%lld", ms); fclose(f); }
            }
            gDockStartMs = 0;
        } else if (mode == MODE_MMB && !navved && gMaxTouch) {
            // The same tap over Max's viewport: Max's go-to-top (maxGesture's comment).
            CGPoint up = cursorPos();
            double dx = up.x - gCanvasStartX, dy = up.y - gCanvasStartY;
            double dur = gTouchStartMs ? nowMs() - gTouchStartMs : 1e9;
            if (dx * dx + dy * dy <= (double)(DOCK_TAP_PX * DOCK_TAP_PX) && dur <= CANVAS_TAP_MS)
                maxGesture("tap3");
            logSlow(dur <= CANVAS_TAP_MS ? "3f max tap" : "3f max touch too long", dur);
        } else if (mode == MODE_MMB && !navved && gCanvasTouch) {
            // Three fingers down over Fusion's canvas and lifted without orbiting or
            // travelling, the whole gesture brief: a tap (see CANVAS_TAP_MS).
            CGPoint up = cursorPos();
            double dx = up.x - gCanvasStartX, dy = up.y - gCanvasStartY;
            double dur = gTouchStartMs ? nowMs() - gTouchStartMs : 1e9;
            if (dx * dx + dy * dy <= (double)(DOCK_TAP_PX * DOCK_TAP_PX)) {
                if (dur <= CANVAS_TAP_MS) writeCanvasTouch();
                logSlow(dur <= CANVAS_TAP_MS ? "3f canvas tap" : "3f canvas touch too long", dur);
            }
        }
        gCanvasTouch = gMaxTouch = false;
        // Pivot-under-cursor only after a REAL nav drag. A 3-finger tap (never moved,
        // no MMB pressed) stays fully inert so it's free for BTT tap triggers. (Max picks
        // its own pivot: callis/nav.py, under the cursor at the drag's first frame.)
        // Not after a Fusion pan: it keeps the last orbit centre (see navEnd).
        if (navved && !atomic_load(&gMaxDrag)) requestOrbitCenter();
    }

    // Re-arm the per-gesture CAD decision once all fingers lift, so the next 3-finger
    // drag is judged afresh by where it starts. (Reset only at 0, not on transient
    // finger-count blips, so a brief 2-finger flicker mid-drag can't re-open the
    // re-evaluation that the latch exists to prevent.)
    if (nFingers == 0) {
        navEnd();
        gTwoT0 = 0;
        gSwipe = false;
        gPsWatch = 0;
        atomic_store(&gThreePan, false);
        gTouchStartMs = 0; gTouchT0 = 0;
        if (gCandFrozen) { gCandFrozen = false; navFreeze(false, gCandAt); }
        atomic_store(&threeEvaluated, false);
        atomic_store(&threeDecided, false);
        atomic_store(&leftHeld, false);
    }
    return 0;
}

static CFMachPortRef gTap = NULL;   // so we can re-arm the tap if the system disables it

static CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    // The system disables a tap it judges too slow or after certain input; re-arm it
    // immediately, otherwise reanchor goes deaf to events and silently stops working.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        return event;
    }

    if (atomic_load(&isSynthetic)) return event;
    if (type == kCGEventScrollWheel) {
        // Our own posts (the pinch zoom's scrolls) are finished events.
        if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) == getpid()) return event;
        return maxScroll(event);
    }

    // Hover watch: while the pointer is over a CAD window, keep Karabiner's `cad_hover`
    // set so its F->Shift fires there even when the app isn't frontmost. Throttled, and
    // the (subprocess) variable set only runs on an enter/leave change.
    // Off the tap: the window-list query is a WindowServer round trip made while
    // WindowServer waits on this tap, so every move/drag behind it queued (measured
    // 20–100 ms per event system-wide, worst while dragging). One check in flight at most.
    if (type == kCGEventMouseMoved) {
        static double lastCheck = 0;
        static atomic_bool inFlight = false;
        struct timeval tv; gettimeofday(&tv, NULL);
        double now = tv.tv_sec + tv.tv_usec / 1e6;
        if (now - lastCheck > 0.08 && !atomic_exchange(&inFlight, true)) {
            lastCheck = now;
            dispatch_async(gAXQueue, ^{
                refreshCadHover();
                atomic_store(&inFlight, false);
            });
        }
        return event;
    }

    if (type == kCGEventFlagsChanged) {
        // A modifier going down is the start of a chord (Cmd-F): make sure `cad_hover`
        // isn't a leftover from before a slot switch moved the CAD window out from
        // under a pointer that never moved — or the hover F->Shift steals the chord.
        // Off the tap: the window-list walk held up the Shift itself — and with it the
        // pan start and every F toggle mid-drag — while the variable set it can lead
        // to was already async (setCadHover), so waiting bought nothing.
        dispatch_async(gAXQueue, ^{
            double t0 = nowMs();
            refreshCadHover();
            double ms = nowMs() - t0;
            if (ms > 5) logSlow("flags hover refresh slow", ms);
        });
        bool shiftDown = (CGEventGetFlags(event) & kCGEventFlagMaskShift) != 0;
        bool wasDown = atomic_load(&physicalShift);
        atomic_store(&physicalShift, shiftDown);

        // In MMB mode the pan/orbit choice is baked into the MMB modifier at button
        // down, so a Shift toggle mid-drag has to re-issue the MMB with the new state.
        // (Only once the deferred MMB is actually down — before the first drag frame
        // there's nothing to re-issue; the fresh Shift state gets baked in then.)
        if (atomic_load(&threeFinger) &&
            atomic_load(&dragMode) == MODE_MMB && !atomic_load(&gMaxDrag) &&
            atomic_load(&mmbEngaged) &&
            shiftDown != wasDown) {
            trace(shiftDown ? "retarget -> pan" : "retarget -> orbit");
            retargetMMB();
        }
        return event;
    }

    // A touch-driven orbit / pan (navTwoFrame) or the pinch zoom: the gesture's own left
    // events (macOS starts a 3-finger drag when fingers join) — hardware, or remapd's
    // re-post of a held one — never reach the app.
    if ((type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventLeftMouseDragged)
        && (atomic_load(&gTouchNav) || (atomic_load(&threeFinger) && atomic_load(&dragMode) == MODE_ZOOM))) {
        pid_t src = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
        if (src == 0 || isRemapd(src)) return NULL;
    }

    // Hold the gesture's left events while the touch callback is still deciding
    // CAD-or-not (see leftHeld). Hardware events only (pid 0), or remapd's re-post of
    // them (it holds every 2+-finger left-down for its tap-clicks and lets it out once the
    // drag moves — inside Photoshop's thumb watch, gPsWatch), and only with exactly
    // 3 fingers down — a real one-finger click is never touched.
    if (!atomic_load(&threeFinger) && !atomic_load(&threeDecided) &&
        atomic_load(&gFingers) == 3 &&
        ({ pid_t s = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
           s == 0 || isRemapd(s); })) {
        if (type == kCGEventLeftMouseDown) {
            leftHeldPos = CGEventGetLocation(event);
            atomic_store(&leftHeld, true);
            // The decision may have landed between the check above and the store —
            // if so it didn't see this left-down; take it back and handle it below.
            if (!atomic_load(&threeDecided) || !atomic_exchange(&leftHeld, false))
                return NULL;
        } else if (type == kCGEventLeftMouseUp) {
            if (atomic_exchange(&leftHeld, false)) return NULL;   // gone: nothing to re-post
        } else if (atomic_load(&leftHeld)) {
            return NULL;                                           // drag of a held press
        }
    }

    if (atomic_load(&threeFinger)) {
        if (atomic_load(&dragMode) == MODE_INERT || atomic_load(&dragMode) == MODE_VOID) {
            // Over the dock: swallow the gesture's OWN hardware left events so a
            // 3-finger tap can't click a row in the browser. Anything a PROCESS posted
            // (BTT's synthetic double-click, the Cursor Probe, …) passes through
            // untouched — same rule, and for the same reason, as the MMB path below.
            if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0)
                return event;
            if (type == kCGEventLeftMouseDown ||
                type == kCGEventLeftMouseUp   ||
                type == kCGEventLeftMouseDragged) return NULL;
            return event;
        }
        if (atomic_load(&dragMode) == MODE_ACTIVATE) {
            // Let the real left-down through so the click focuses the app.
            if (type == kCGEventLeftMouseDown) return event;
            if (type == kCGEventLeftMouseDragged) {
                CGPoint pos = CGEventGetLocation(event);
                if (!atomic_load(&mmbArmed)) {
                    // First drag after focusing: release the activating press, then
                    // start the MMB drag and hand the rest of the gesture to
                    // MODE_MMB so Shift toggles pan/orbit live from here on.
                    atomic_store(&mmbArmed, true);
                    postLeftUp(pos);
                    postMMB(kCGEventOtherMouseDown, pos, mmbFlags());
                    atomic_store(&mmbEngaged, true);
                    atomic_store(&dragMode, MODE_MMB);
                }
                postMMB(kCGEventOtherMouseDragged, pos, CGEventGetFlags(event));
                return NULL;
            }
            // Left-up before any drag: a tap that just focuses the app — let it pass.
            if (type == kCGEventLeftMouseUp) return event;
            return event;
        }

        // MODE_MMB: swallow the GESTURE's left events and drive the middle-button drag.
        // Only hardware/system events belong to the gesture: a left event POSTED BY A
        // PROCESS (kCGEventSourceUnixProcessID != 0 — e.g. BetterTouchTool turning a
        // 3-finger tap into a double-click) must pass through untouched, even when it
        // lands inside the multitouch touch-lift lag window that keeps threeFinger
        // latched briefly after the fingers are physically up. Swallowing those was
        // what made BTT tap triggers flaky over the canvas. (Verified: CGEventPost
        // stamps the poster's pid regardless of its CGEventSource; the OS's own
        // 3-finger-drag left events carry pid 0.)
        if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0)
            return event;
        if (type == kCGEventLeftMouseDown) return NULL;
        if (type == kCGEventLeftMouseUp) return NULL;
        if (type == kCGEventLeftMouseDragged && remapdClaims()) return NULL;   // a bound swipe's state: no pan
        if (type == kCGEventLeftMouseDragged && atomic_load(&gFourOwn)) return NULL;   // the touches drive it (4th finger)
        if (type == kCGEventLeftMouseDragged && atomic_load(&gThreePan) && !atomic_load(&gMaxDrag))
            return NULL;   // Fusion's 3-finger pan runs off the touches (touchCallback → navTakeOver)
        if (type == kCGEventLeftMouseDragged && atomic_load(&gThreePan) && !atomic_load(&mmbEngaged)
            && nowMs() - atomic_load(&gThreeMs) < PAN_SETTLE_MS) return NULL;            // a 4th finger may follow: no pan yet
        if (type == kCGEventLeftMouseDragged && atomic_load(&gMaxDrag)) {
            bool begin = !atomic_exchange(&mmbEngaged, true);
            maxDragFrame(event, begin);
            return NULL;
        }
        if (type == kCGEventLeftMouseDragged) {
            CGPoint pos = CGEventGetLocation(event);
            CGEventFlags flags = CGEventGetFlags(event);
            if (!atomic_load(&mmbEngaged)) {
                // First movement frame: press the MMB deferred at touchdown (see
                // mmbEngaged). Pan/orbit choice samples the live Shift state now.
                atomic_store(&mmbEngaged, true);
                trace(panWanted() ? "mmb down pan" : "mmb down orbit");
                postMMB(kCGEventOtherMouseDown, pos, mmbFlags());
            }
            if (panWanted() && !gSketchUpDrag) {
                // Fusion pan gain: the posted drag moves the pointer, so the OS's next
                // drag starts from there — the extra delta per frame adds up to GAIN × travel.
                pos.x += CGEventGetDoubleValueField(event, kCGMouseEventDeltaX) * (FUSION_PAN_GAIN - 1);
                pos.y += CGEventGetDoubleValueField(event, kCGMouseEventDeltaY) * (FUSION_PAN_GAIN - 1);
            }
            postMMB(kCGEventOtherMouseDragged, pos, flags);
            return NULL;
        }
    }

    return event;
}

// ── Trackpad hot-plug (survive a Bluetooth disconnect/reconnect) ─────────────
// MTDeviceCreateDefault() grabs the trackpad ONCE. When a Magic Trackpad sleeps,
// runs flat, or drops its Bluetooth link, macOS re-publishes it under a NEW device
// handle and the old one goes silent — the process keeps running but never sees
// another touch (the "dead battery silently killed reanchor" failure). So instead
// of acquiring the device once, we watch IOKit for AppleMultitouchDevice arrivals
// and (re)bind the contact callback whenever one appears. IOServiceAddMatching-
// Notification also delivers the already-connected device the moment we arm it, so
// cold start and reconnect run the IDENTICAL path — nothing extra to test, and no
// external watcher/relaunch (which would drop our event tap and re-trip TCC).
// Arrival fires once per device, so there's no double-binding. A device that leaves
// is just left to fall silent; we don't chase the stale handle (negligible over any
// realistic number of reconnects).
static void mtMatched(void *cb, io_iterator_t it) {
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        MTDeviceRef dev = MTDeviceCreateFromService(s);
        if (dev && !auxpadClassify(dev, "reanchor")) {
            MTRegisterContactFrameCallback(dev, (MTContactCallbackFunction)cb);
            MTDeviceStart(dev, 0);
        }
        IOObjectRelease(s);
    }
}
static void startMultitouchHotplug(MTContactCallbackFunction cb) {
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
    io_iterator_t it;
    if (IOServiceAddMatchingNotification(port, kIOMatchedNotification,
            IOServiceMatching("AppleMultitouchDevice"), mtMatched, (void *)cb, &it)
        == KERN_SUCCESS)
        mtMatched((void *)cb, it);   // drain the already-connected device(s) AND arm future arrivals
}

int main(void) {
    gAXQueue = dispatch_queue_create("reanchor.ax", DISPATCH_QUEUE_SERIAL);
    gNetQ = dispatch_queue_create("reanchor.max", DISPATCH_QUEUE_SERIAL);
    navLoadPrint();
    navPinSet(false, false, CGPointZero);    // a word left "ours" by a killed run would mute remapd's pin
    startMultitouchHotplug(touchCallback);   // bind now AND re-bind on every trackpad reconnect

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventFlagsChanged) |
                       CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventScrollWheel);     // 2-finger scroll over 3ds Max (swallowed: it orbits)

    CFMachPortRef tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        eventCallback,
        NULL
    );
    if (!tap) return 1;
    gTap = tap;

    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    warmCAD();   // absorb the one-time ~150ms cold-call cost before any gesture
    watchCadHoverStaleness();
    // Don't inherit whatever a previous run left in Karabiner: claim "on" so the
    // first read always reaches Karabiner (setCadHover only sends changes).
    atomic_store(&cadHoverState, true);
    refreshCadHover();

    CFRunLoopRun();
    return 0;
}

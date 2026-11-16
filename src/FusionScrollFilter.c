/*
 * FusionScrollFilter.c — custom trackpad zoom for Fusion 360 (macOS).
 *
 * A CGEventTap that reshapes the trackpad zoom over Fusion's canvas into a
 * SketchUp-like zoom. Since 2026-10-18 the zoom is reanchor's THUMB PINCH (thumb +
 * two fingers), posted as phased scrolls tagged NAV_ZOOM_MARK; a real 2-finger
 * scroll over the canvas is swallowed (two fingers orbit, in reanchor). The zoom is: a base curve, a velocity boost for
 * fast swipes, a distance-aware slow-down near the model and far from the origin,
 * and a "fling" gesture that jumps the camera to a boundary.
 *
 * ── Two-process design ───────────────────────────────────────────────────────
 * This filter only sees scroll *pixels*; it has no idea where the camera is. The
 * companion Fusion add-in "+ Cursor Probe" runs inside Fusion (full camera/API
 * access) and exchanges live values with this filter via /tmp files:
 *     reads:  PIVOT_FILE      eye→pivot distance, cm (geometry under cursor / orbit centre)
 *             ORIGIN_FILE     eye→world-origin distance, cm
 *             ORBIT_GEN_FILE  integer that bumps when the orbit centre moves to new geometry
 *             ZOOM_GAIN_FILE  pinch-zoom multiplier over empty space (§ Empty-space gain)
 *     writes: FLING_FILE      "in"/"out" when a fling triggers — the probe does the jump
 *             SIGN_FILE       the learned "which delta sign means zoom-in" (persisted)
 *             VEL_FILE        live velocity + gain (calibration aid; nothing reads it)
 *
 * This process runs PERSISTENTLY (started on first Fusion focus, then left alive
 * like reanchor — NOT killed on blur). It must already be running when a 2-finger
 * scroll BEGINS over an unfocused Fusion (reanchor activates Fusion on that touch),
 * so it catches the gesture from phase==1 and its activation-grace window can hold
 * the first zoom; a filter started mid-gesture would miss the begin and let Fusion
 * zoom the flick natively. There is no frontmost-app check — cursorOverCAD() (which
 * matches Fusion ONLY) is the gate that keeps it inert everywhere else.
 *
 * Build & deploy (PREFER `bin/build.sh` — it builds AND code-signs every nav binary):
 *   clang -O2 -Wall -o ~/Code/Scripts/FusionScrollFilter ~/bin/FusionScrollFilter.c \
 *     -framework ApplicationServices -framework CoreFoundation -framework IOKit \
 *     -F/System/Library/PrivateFrameworks -framework MultitouchSupport -lm
 *   codesign -f -s "Apple Development: you@example.com" -i com.josh.FusionScrollFilter \
 *     ~/Code/Scripts/FusionScrollFilter
 *   then restart it:  pkill -x FusionScrollFilter; ~/Code/Scripts/BetterTouchTool/fusion_scroll.sh on
 * The codesign step is MANDATORY: elementIsCanvas() (the canvas gate) calls the AX
 * API, checked by macOS TCC against THIS binary's code identity. Unsigned → the grant
 * is dropped on every rebuild → the AX query fails → the gate fails OPEN and the zoom
 * reshaper runs over chrome/menus. A stable signature keeps the one-time grant.
 * The launching app (BTT) must also hold Accessibility (it's the responsible process).
 *
 * ── Non-obvious decisions (please don't "fix" these without re-reading) ───────
 *  • The fling fires on the LIFT event (scroll phase 4), NOT on momentum-begin.
 *    Momentum-begin lags (the OS spins inertia up) and felt delayed; the lift
 *    event is immediate. "Real inertia flick" is detected at lift from peak speed
 *    + a tiny gap since the last finger movement (fingers still moving at lift-off)
 *    + a release/peak ratio (a fast swipe you ease off has little real inertia).
 *  • We do NOT gate the fling on fingerCount==0: the multitouch finger count lags
 *    the lift event, so requiring 0 re-introduced the momentum-era delay.
 *  • The zoom-in delta sign is LEARNED (not hard-coded) so it survives Fusion's
 *    natural-scroll-direction preference; cached to SIGN_FILE across launches.
 *  • The velocity boost is a deliberately low plateau and fades to nothing near
 *    the walls, so a fast swipe can't punch through them; going to a boundary is
 *    the explicit fling instead.
 *  • Activation grace (see the sGrace block): a 2-finger zoom that BEGINS while
 *    Fusion is still in the background has a stale camera feed (the probe only
 *    runs while Fusion is active). We swallow the zoom until the just-focused
 *    probe writes a fresh pivot, and suppress that gesture's fling — so an eager
 *    zoom-on-activate no longer flings the camera to a stale orbit centre. This
 *    is keyed on pivot-file staleness, NOT a focus check, so an already-active
 *    Fusion (feed always fresh at 20Hz) is completely unaffected.
 */

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>                           /* trackpad hot-plug notifications */
#include <stdio.h>
#include <math.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

/* ── Multitouch finger tracking ──────────────────────────────────────────── */
typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint pos, vel; } mtReadout;
typedef struct {
    int frame; double timestamp;
    int identifier, state, foo3, foo4;
    mtReadout normalized; float size; int zero1;
    float angle, majorAxis, minorAxis;
    mtReadout mm; int zero2[2]; float unk2;
} Finger;
typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int, Finger *, int, double, int);
MTDeviceRef MTDeviceCreateDefault(void);
MTDeviceRef MTDeviceCreateFromService(io_service_t);   /* bind a SPECIFIC trackpad (hot-plug) */
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);

/* ── Trackpad hot-plug (survive a Bluetooth disconnect/reconnect) ───────────
 * MTDeviceCreateDefault() grabs the trackpad ONCE. When a Magic Trackpad sleeps,
 * runs flat, or drops Bluetooth, macOS re-publishes it under a NEW device handle
 * and the old one goes silent — the filter keeps running but its finger tracking
 * never fires again (the "dead battery silently killed scrolling" failure). So
 * rather than acquire the device once, watch IOKit for AppleMultitouchDevice
 * arrivals and (re)bind the contact callback whenever one appears. IOServiceAdd-
 * MatchingNotification also delivers the already-connected device the moment we
 * arm it, so cold start and reconnect run the IDENTICAL path. Arrival fires once
 * per device, so no double-binding; a device that leaves is left to fall silent. */
static void mtMatched(void *cb, io_iterator_t it) {
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        MTDeviceRef dev = MTDeviceCreateFromService(s);
        if (dev) {
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
        mtMatched((void *)cb, it);   /* drain the connected device(s) AND arm future arrivals */
}

static atomic_int  sFingerCount = 0;
static atomic_bool sAllLifted   = true;   /* the pad was clear since the last 3+-finger touch (touchCallback) */
static atomic_bool sZoomLock    = false;  /* armed when ≥4 fingers touch; cleared only when ALL lift. Unread since 2026-10-18 (only the thumb pinch zooms) */
static atomic_bool sPassThrough = false;  /* this gesture started off a CAD window → don't touch it */
static atomic_bool sNoHoriz     = false;  /* …but over Fusion's own chrome: drop its sideways part */

/* Double-click pairing state (see the left-down handler): only a SYNTHETIC pair
 * from the SAME posting process — i.e. BTT's 3-finger-tap double-click — may form
 * a double-click. */
static _Atomic long long sLastClickMs        = 0;
static _Atomic bool      sLastClickSynthetic = false;
static _Atomic long long sLastClickPid       = -1;
static double            sLastClickX = 0, sLastClickY = 0;

/* Where/when the last real left-down landed, for the drag test on left-up. Kept
   separate from the sLastClick* pair above: those are the double-click pairing
   state and are deliberately cleared when a pair is consumed. */
static double            sDownX = 0, sDownY = 0;
static _Atomic long long sDownMs = 0;
/* What the last left-down will report as a click gesture on its paired left-up
   (see writeClickEvent): its modifiers, whether it landed on the canvas, and
   whether it was the second half of a three-finger tap (already reported). */
static char              sDownMods[48] = "-";
static bool              sDownCanvas = false;
static bool              sDownWasTap3 = false;
static bool              sDownSynthetic = false;   /* posted by a process (BTT, reanchor), not the hardware */

#define ZOOM_LOCK_FINGERS 4   /* ≥ this many fingers fully disables zoom until all are lifted */
#define MT_MAX_DEVS       4   /* pads told apart for sAllLifted (main + keyboard pad + spares) */

static int touchCallback(int device, Finger *data, int nFingers, double timestamp, int frame) {
    /* Touching contacts only (make-touch / touching): hovering and lifting ones made a
       quick 2-finger re-scroll read as 3+ and dropped as a swipe (2026-10-18). */
    int touching = 0;
    for (int i = 0; i < nFingers; i++) if (data[i].state >= 4 && data[i].state <= 5) touching++;
    nFingers = touching;
    atomic_store(&sFingerCount, nFingers);
    /* sAllLifted per PAD: both pads call in here, and the left (keyboard) pad's empty
       frames used to clear it while the right hand was still mid-swipe (2026-10-20). */
    static _Atomic int devs[MT_MAX_DEVS];
    static atomic_uint had3 = 0;           /* bit per pad: 3+ touching since it was last clear */
    int slot = MT_MAX_DEVS;
    for (int i = 0; i < MT_MAX_DEVS && slot == MT_MAX_DEVS; i++) {
        int want = 0;
        if (atomic_load(&devs[i]) == device
                || atomic_compare_exchange_strong(&devs[i], &want, device)) slot = i;
    }
    unsigned bit = 1u << slot;             /* past MT_MAX_DEVS pads: one shared bit */
    if (nFingers == 0) atomic_fetch_and(&had3, ~bit);
    else if (nFingers >= 3) atomic_fetch_or(&had3, bit);
    atomic_store(&sAllLifted, atomic_load(&had3) == 0);
    /* Four-finger kill switch: a 4-finger swipe is the space-switch gesture, and
     * its residual scroll/momentum must never zoom Fusion. The moment ≥4 fingers
     * are down, latch zoom off; release ONLY when every finger has lifted (count
     * back to 0). Latching on the peak count and releasing on 0 rides out the
     * finger-count flicker during touchdown/liftoff (e.g. a transient read of 2). */
    if (nFingers >= ZOOM_LOCK_FINGERS)
        atomic_store(&sZoomLock, true);
    else if (nFingers == 0)
        atomic_store(&sZoomLock, false);
    return 0;
}

/* ════════════════════════ Tuning knobs ════════════════════════════════════ */

/* IPC files (see the header for who reads/writes each). */
#define PIVOT_FILE      "/tmp/fusion_pivot_distance"   /* in:  eye→pivot dist, cm   */
#define ORIGIN_FILE     "/tmp/fusion_origin_distance"  /* in:  eye→origin dist, cm  */
#define ZOOM_GAIN_FILE  "/tmp/fusion_zoom_gain"        /* in:  pinch multiplier over empty space (Cursor Probe § Empty-space gain) */
#define ORBIT_GEN_FILE  "/tmp/fusion_orbit_gen"        /* in:  bumps when orbit centre set on NEW geometry */
#define FLING_FILE      "/tmp/fusion_fling"            /* out: "in"/"out" fling request */
#define SIGN_FILE       "/tmp/fusion_zoom_in_sign"     /* out: learned zoom-in delta sign */
#define VEL_FILE        "/tmp/fusion_scroll_vel"       /* out: live vel+gain (calibration only) */
#define CLICK_CMD_FILE  "/tmp/fusion_click_cmd"        /* out: "<epoch_ms> <0|1>" — ⌘ state of the last left-click over Fusion (Browser add-in reads it: plain click enters a sketch, ⌘-click just selects) */
#define CLICK_EVENT_FILE "/tmp/fusion_click_event"     /* out: "<epoch_ms> <gesture> <mods> <synthetic>" — the last click GESTURE over the canvas: click (a stationary left click, written on its UP), tap2 (a right-click / two-finger tap we consumed), tap3 (BTT's three-finger-tap pair). mods: comma list of space,shift,cmd,alt,ctrl or "-". synthetic: 1 when a process posted the click (only such a click can be the first half of a tap3, so only it has to wait for one). The Click Actions add-in reads it and runs whatever fusion_ui/clicks.json binds to it. */
#define DBLCLICK_FILE   "/tmp/fusion_dblclick"         /* out: "<epoch_ms>" — a double-click over the CANVAS (debug trail only now; the gesture itself goes out as tap3 in CLICK_EVENT_FILE) */
#define KC_F20          90                             /* Karabiner reports a HELD space as F20 down (remap/karabiner_layers.py HOLD_REPORT); remapd swallows the key event, but the HID state still shows it held */
#define DBLCLICK_MS     60                             /* two left-downs within this many ms … */
#define DBLCLICK_PX     8                              /* … and this many px apart, BOTH posted by the same synthetic source = the BTT 3-finger tap. BTT posts its pair in one burst (measured gap 0–2ms), so this window is deliberately far BELOW a human double-click: a person's two clicks can never land inside it. */
#define CLICK_DRAG_FILE "/tmp/fusion_click_drag"       /* out: "<epoch_ms>" — the left-DOWN stamp of a click whose UP landed CLICK_DRAG_PX away, i.e. a DRAG (window/box select, dragging geometry). Click To Descend / Browser read it to leave drags to native selection: only a stationary click is a navigation gesture. */
#define CLICK_DRAG_PX   5                              /* px between down and up above which the gesture counts as a drag. Fusion starts its selection rectangle at ~4px, and hand jitter inside a real click stays well under this. */
#define NAV_ZOOM_MARK   0x7a6f6f6d                     /* event-source user data on reanchor's thumb-PINCH zoom scrolls (2026-10-18) — keep in sync with reanchor.m / remapd.m. Only these zoom; our own output carries it too so remapd lets it through */
#define CURSOR_PROBE_MARKER 0xCBEEF                    /* event-source user data the "Cursor Probe" add-in tags its synthetic orbit-centre click with (_CURSOR_PROBE_MARKER there) — keep the two in sync; we ignore those clicks entirely */
#define SELECTMODE_FILE "/tmp/fusion_selectmode"       /* in:  "<epoch_ms> <0|1>" — Browser add-in writes 1 when idle (activeCommand==SelectCommand). We only swallow right-clicks while idle, so right-click still confirms a running command's menu. */

/* Overlay curves from the graphical curve editor (a separate web app — see the
 * "Scroll Curve Editor" add-in).  Each is a USER-DRAWN MULTIPLIER applied on top
 * of the built-in curves below: velGain() is scaled by a velocity curve (vs speed),
 * proximityFactor() by a proximity curve (vs eye→pivot distance).  There is a
 * SEPARATE curve per zoom DIRECTION (in vs out), so four files total.  Alongside
 * them sits MGAIN_FILE, a single MASTER multiplier applied to the finished output —
 * the knob for "everything, twice as fast" without redrawing a curve.  The default
 * (and any absent / unparseable file) is a flat 1.0 everywhere, i.e. behaves EXACTLY
 * as if the file didn't exist.  They never bypass the safety walls — the multiply
 * happens before the hard stops in the callback. */
/* These are PERSISTENT config (not /tmp): they live next to the curve editor so
 * the settings survive reboots / tmp cleanup and are re-applied on every filter
 * launch even if the editor is never opened. The editor writes them. */
#define STATE_DIR         "/Users/josh/Code/Scripts/scroll_curve_editor/state"
#define VEL_ADJ_IN_FILE   STATE_DIR "/vel_adjust_in"    /* in:  mult vs speed,  zoom IN  */
#define VEL_ADJ_OUT_FILE  STATE_DIR "/vel_adjust_out"   /* in:  mult vs speed,  zoom OUT */
#define PROX_ADJ_IN_FILE  STATE_DIR "/prox_adjust_in"   /* in:  mult vs dist,   zoom IN  */
#define PROX_ADJ_OUT_FILE STATE_DIR "/prox_adjust_out"  /* in:  mult vs dist,   zoom OUT */
#define NEAR_FILE         STATE_DIR "/near_dist"        /* in:  user inner-wall distance, cm */
#define MGAIN_FILE        STATE_DIR "/master_gain"     /* in:  master output multiplier (see readMasterGain) */
#define SDEBUG_FLAG     "/tmp/fusion_scroll_debug"     /* in:  touch this file to turn the scroll trace ON */
#define SDEBUG_LOG      "/tmp/fusion_scroll_debug.log" /* out: one line per scroll event while tracing */

/* Base curve: per-event delta → pixels.  result = sign·|delta|^POWER·SCALE,
 * clamped to ±MAX_DELTA.  cmd-held swaps to a slow linear precision mode. */
#define POWER       1.6
#define SCALE       0.021665   /* overall zoom sensitivity                       */
#define SCALE_SLOW  0.0010835  /* cmd-held precision (keeps SCALE_SLOW/SCALE ratio) */
#define MAX_DELTA   50.0       /* clamp on the curved per-event value            */

/* Proximity slow-down from the eye→pivot distance (cm):
 *   d >= SLOW_DIST → FAR_FACTOR (full speed)
 *   NEAR..SLOW     → LINEAR taper (in distance) from FAR_FACTOR down to CLOSE_FACTOR
 *   d <= NEAR_DIST → CLOSE_FACTOR floor
 * The taper applies to BOTH directions, but the two hard stops are zoom-IN only
 * (applied in the callback, not here): the inner-wall LOCK at NEAR_DIST, and a
 * →0 safety below HALT_DIST.  Zoom-OUT must NEVER hit 0 here or you'd be trapped
 * against the pivot — it only ever bottoms out at CLOSE_FACTOR.
 * Absent/stale pivot file → FAR_FACTOR (behaves as if far). */
#define HALT_DIST    1.0    /* cm — zoom-in →0 safety stop (in only)            */
#define NEAR_DIST_DEFAULT 3.0  /* cm — inner wall (lock engages); speed floor here.
                                * User-settable at runtime via NEAR_FILE → sNearDist;
                                * this is just the fallback when no file is present. */
#define NEAR_MIN     0.5   /* cm — clamp on a user-set inner wall (sane lower bound) */
#define NEAR_MAX     45.0  /* cm — clamp (must stay below SLOW_DIST and GAIN_FADE_IN) */
#define SLOW_DIST    50.0   /* cm — within this the slow-down begins            */
#define FAR_FACTOR   0.30   /* full speed (30%) beyond SLOW_DIST — the ceiling  */
#define CLOSE_FACTOR 0.045  /* floor at the inner wall: 15% of FAR_FACTOR (85% reduction) */

/* Far-out clamp from the eye→origin distance (cm), applied only when zooming OUT:
 *   D <= FAR_OUT → full;  FAR_OUT..STOP_OUT → smooth ramp to 0;  D >= STOP_OUT → 0.
 * Plus hysteresis: once stopped at STOP_OUT it stays fully off until back within
 * RESUME_OUT (so a fast swipe can't nibble through the wall). */
#define FAR_OUT     500.0   /* cm — zoom-out clamp starts 5 m from origin        */
#define STOP_OUT    1000.0  /* cm — zoom-out fully stops 10 m from origin        */
#define RESUME_OUT  900.0   /* cm — stays stopped until back within 9 m          */

/* Velocity boost: faster swipes zoom harder.  gain is flat 1.0 up to ACCEL_KNEE,
 * smooth-ramps to ACCEL_MAX by ACCEL_FLAT, then flat (a low plateau on purpose,
 * so it can't punch the walls — use a fling to reach a boundary).  The boost is
 * faded out near either wall (GAIN_FADE_*) so a fast swipe can't blast across the
 * slow-down zone before the distance feed updates.  Velocity is an EMA of
 * |delta|/dt; a gap > ACCEL_GAP restarts it.
 * Measured speeds (this trackpad): p50≈4100 p80≈7100 p90≈8600 p95≈14000 max≈52000 px/s. */
#define ACCEL_KNEE    8600.0  /* px/sec — below this, no boost (≈ p90)           */
#define ACCEL_FLAT    14000.0 /* px/sec — gain reaches ACCEL_MAX here, flat above */
#define ACCEL_MAX     5.0     /* plateau gain                                    */
#define ACCEL_SMOOTH  0.30    /* velocity EMA factor (higher = snappier)         */
#define ACCEL_GAP     0.12    /* s — inter-event gap that restarts the gesture   */
#define PINCH_WIN_NS  60000000ULL  /* ns — reanchor's pinch: speed over this window (see the callback) */
#define GAIN_FADE_IN  60.0    /* cm — boost fades from here down to NEAR_DIST     */
#define GAIN_FADE_OUT 200.0   /* cm — boost fades over this band before FAR_OUT   */

/* Fling: a deliberate fast inertia flick jumps the camera to a boundary (the
 * probe does the move: out → 5 m back centred under the cursor; in → 3 cm from
 * the last orbit centre).  Triggered at the lift event when peak speed exceeds
 * the (direction-specific) threshold, the fingers were still moving at lift
 * (gap ≤ FLING_LIFT_GAP), and the release/peak ratio shows real inertia. */
#define FLING_VEL_IN        20000.0     /* px/sec — peak speed to fling IN        */
#define FLING_VEL_OUT       10000.0     /* px/sec — peak speed to fling OUT (easier) */
#define FLING_RELEASE_RATIO 0.6         /* release÷peak min (rejects eased-off lifts) */
#define FLING_LIFT_GAP_NS   80000000ULL /* ns — max gap last-move→lift to count as inertia (80ms) */

/* Double-flick: a single fast flick is easy to do by accident, so the boundary
 * jump only fires on the SECOND qualifying flick in the same direction within
 * this window. The first flick just zooms normally and arms; a flick in the
 * other direction (or letting the window lapse) re-arms from scratch. */
#define DOUBLE_FLING_WINDOW_NS 600000000ULL  /* ns — max gap between the two flicks (600ms) */

#define PIVOT_STALE 2.0     /* s — ignore a distance file older than this        */

/* ── Globals ─────────────────────────────────────────────────────────────── */
static CFMachPortRef sTap         = NULL;
static double        sAccum       = 0.0;
static bool          sSwallowNext = false;
static double        sVel         = 0.0;   /* smoothed scroll speed (px/sec)     */
static int           sLastDir     = 0;     /* last touch-phase zoom delta sign    */
static double        sPeakVel     = 0.0;   /* peak smoothed speed this gesture     */
static double        sPeakInst    = 0.0;   /* peak INSTANTANEOUS speed this gesture (catches short flicks) */
static double        sLastInst    = 0.0;   /* instantaneous speed of last movement (release vel) */
static uint64_t      sLastMoveTs  = 0;     /* ns of last real (nonzero-delta) move */
static uint64_t      sArmedFlingTs = 0;    /* ns of the first qualifying flick (double-flick arm) */
static int           sArmedFlingDir = 0;   /* direction of the armed first flick (0=none) */
static bool          sInLocked    = false; /* inner wall hit: zoom-in dead until a zoom-out */
static bool          sOutLatched  = false; /* outer wall hit: zoom-out dead until back within RESUME_OUT */
static uint64_t      sLastTs      = 0;     /* ns timestamp of previous event     */
static uint64_t      sLastVelLog  = 0;     /* ns of last VEL_FILE write (throttle)*/
static int           sInSign      = 0;     /* delta sign that means zoom-IN (0=unknown) */
static int           sVote        = 0;     /* running evidence for sInSign       */
static double        sPrevPivot   = -1.0;  /* last distinct pivot dist (learning)*/

/* ── Activation grace (zoom-after-activate) ──────────────────────────────────
 * The Cursor Probe add-in only runs while Fusion is the active app, so when a
 * 2-finger zoom BEGINS on a Fusion that is still in the background (the BTT
 * trigger focuses it on the same touch), the pivot/orbit feed is stale: zoom
 * would run at full far-speed with no proximity taper, and a fast first flick
 * would FLING the camera to a stale orbit centre — the "jumps to a weird place"
 * the user has to avoid by holding their fingers still for a second.
 *
 * We automate that hold: if the pivot feed is stale at gesture begin, swallow
 * the zoom until the now-awake probe writes a FRESH pivot sample (mtime moves
 * off the begin snapshot), then resume normally — and suppress the fling for
 * that whole gesture. A hard cap stops us holding forever if the probe is dead.
 * When Fusion is already active the feed is always fresh (probe writes at 20Hz),
 * so sGraceGesture is false and behaviour is unchanged. */
#define GRACE_STALE_NS 250000000ULL  /* feed older than this at begin → enter grace */
#define GRACE_MAX_NS   600000000ULL  /* stop holding after this even with no feed    */
static atomic_bool sGrace            = false; /* currently holding this gesture's zoom */
static bool        sGraceGesture     = false; /* gesture began stale → suppress its fling */
static uint64_t    sBeginPivotMtime  = 0;     /* pivot-file mtime snapshot at begin    */
static uint64_t    sGraceBeginWallNs = 0;     /* wall-clock ns at gesture begin        */

/* Is a Fusion companion window frontmost? reanchor.m mirrors that into this file
 * on every app activation ("1"/"0"). Absent/unreadable → false (old behaviour). */
static bool companionFront(void) {
    FILE *f = fopen("/tmp/fusion_companion_front", "r");
    if (!f) return false;
    int c = fgetc(f);
    fclose(f);
    return c == '1';
}

/* Wall-clock now in ns (same domain as a file mtime — NOT mach event time). */
static uint64_t wallNowNs(void) {
    struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
/* Pivot-file mtime in ns, or 0 if it doesn't exist. */
static uint64_t pivotMtimeNs(void) {
    struct stat st;
    if (stat(PIVOT_FILE, &st) != 0) return 0;
    return (uint64_t)st.st_mtimespec.tv_sec * 1000000000ULL
         + (uint64_t)st.st_mtimespec.tv_nsec;
}

/* Base curve: signed |delta|^power · SCALE, clamped to ±MAX_DELTA. */
static double applyCurve(int64_t delta, double power) {
    if (delta == 0) return 0.0;
    double sign   = delta > 0 ? 1.0 : -1.0;
    double result = sign * pow(fabs((double)delta), power) * SCALE;
    if (result >  MAX_DELTA) result =  MAX_DELTA;
    if (result < -MAX_DELTA) result = -MAX_DELTA;
    return result;
}

static double smoothstep(double u);   /* defined below */

/* Velocity → amplification gain (see ACCEL_* constants): flat 1.0 below KNEE,
 * smooth ramp to ACCEL_MAX at ACCEL_FLAT, then flat at ACCEL_MAX above. */
static double velGain(double vel) {
    if (vel <= ACCEL_KNEE) return 1.0;
    if (vel >= ACCEL_FLAT) return ACCEL_MAX;
    return 1.0 + (ACCEL_MAX - 1.0) * smoothstep((vel - ACCEL_KNEE) / (ACCEL_FLAT - ACCEL_KNEE));
}

/* Smoothstep 0→1 over [0,1] — zero slope at both ends (soft, gentle). */
static double smoothstep(double u) {
    if (u <= 0.0) return 0.0;
    if (u >= 1.0) return 1.0;
    return u * u * (3.0 - 2.0 * u);
}

/* Proximity speed factor from the eye→pivot distance (cm): FAR_FACTOR beyond
 * SLOW_DIST, a LINEAR taper down to CLOSE_FACTOR at the inner wall `near`, then
 * that floor.  Never returns 0 — the zoom-in hard stops (lock + HALT) are applied
 * by the caller so they don't trap zoom-OUT. Same value for both directions. */
static double proximityFactor(double d, double near) {
    if (d >= SLOW_DIST) return FAR_FACTOR;
    if (d <= near) return CLOSE_FACTOR;
    double frac = (d - near) / (SLOW_DIST - near);  /* 0 at wall .. 1 at SLOW */
    return CLOSE_FACTOR + (FAR_FACTOR - CLOSE_FACTOR) * frac;
}

/* Zoom-out clamp from the eye→origin distance (cm): 1.0 → 0 over FAR_OUT..STOP_OUT. */
static double originClamp(double D) {
    if (D <= FAR_OUT)  return 1.0;
    if (D >= STOP_OUT) return 0.0;
    return 1.0 - smoothstep((D - FAR_OUT) / (STOP_OUT - FAR_OUT));
}

/* Read a probe distance file (cheap: re-parse only when its mtime changes).
 * Returns the distance in cm, or -1.0 when absent / stale / unparseable.
 * The mtime cache is held in caller-supplied statics (one set per file). */
static double readDist(const char *path, long *psec, long *pnsec, double *pcached) {
    struct stat st;
    if (stat(path, &st) != 0) return -1.0;
    if (time(NULL) - st.st_mtimespec.tv_sec > (time_t)PIVOT_STALE) return -1.0;
    if (st.st_mtimespec.tv_sec != *psec || st.st_mtimespec.tv_nsec != *pnsec) {
        *psec  = st.st_mtimespec.tv_sec;
        *pnsec = st.st_mtimespec.tv_nsec;
        FILE *f = fopen(path, "r");
        if (f) {
            double d;
            *pcached = (fscanf(f, "%lf", &d) == 1 && d > 0.0) ? d : -1.0;
            fclose(f);
        }
    }
    return *pcached;
}

static double readPivotDist(void) {
    static long sec = 0, nsec = -1; static double cached = -1.0;
    return readDist(PIVOT_FILE, &sec, &nsec, &cached);
}
static double readOriginDist(void) {
    static long sec = 0, nsec = -1; static double cached = -1.0;
    return readDist(ORIGIN_FILE, &sec, &nsec, &cached);
}
/* Over empty space Fusion zooms at the camera target's depth, which shrinks every
 * step (the zoom ground to a halt, 2026-10-19); the probe writes how much faster to
 * go for the zoom to move as if the last geometry / model centre were under the
 * pointer. 1 over geometry, or when absent / stale. */
static double readZoomGain(void) {
    static long sec = 0, nsec = -1; static double cached = -1.0;
    double g = readDist(ZOOM_GAIN_FILE, &sec, &nsec, &cached);
    return g > 0.0 ? g : 1.0;
}

/* User-settable inner-wall distance (cm). Like the overlay curves it's persistent
 * config (no staleness expiry); absent/invalid file → NEAR_DIST_DEFAULT. mtime-cached.
 * Clamped to [NEAR_MIN, NEAR_MAX] so it can't break proximityFactor / the gain fade. */
static double sNearDist = NEAR_DIST_DEFAULT;
static void readNearDist(void) {
    static long sec = 0, nsec = -1;
    struct stat st;
    if (stat(NEAR_FILE, &st) != 0) { sNearDist = NEAR_DIST_DEFAULT; sec = 0; nsec = -1; return; }
    if (st.st_mtimespec.tv_sec == sec && st.st_mtimespec.tv_nsec == nsec) return;
    sec = st.st_mtimespec.tv_sec; nsec = st.st_mtimespec.tv_nsec;
    FILE *f = fopen(NEAR_FILE, "r");
    if (f) {
        double d;
        if (fscanf(f, "%lf", &d) == 1 && d > 0.0) {
            if (d < NEAR_MIN) d = NEAR_MIN;
            if (d > NEAR_MAX) d = NEAR_MAX;
            sNearDist = d;
        }
        fclose(f);
    }
}

/* ── Scroll trace (diagnostic, off unless SDEBUG_FLAG exists) ────────────────
 * Answers the only question that matters when the zoom "feels wrong": is this
 * filter actually reshaping the gesture, or silently passing it through to
 * Fusion's native zoom? Costs one stat() per scroll event when off. */
static bool sdebugOn(void) { struct stat st; return stat(SDEBUG_FLAG, &st) == 0; }
static char sLastRole[64] = "?";      /* AX role seen by the last elementIsCanvas() */
static int  sLastRoleMain = -1;       /* its AXMain: 1/0, or -1 if unreadable       */
static void sdlog(const char *fmt, ...) {
    FILE *f = fopen(SDEBUG_LOG, "a");
    if (!f) return;
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(f, "%lld.%03d ", (long long)ts.tv_sec, (int)(ts.tv_nsec / 1000000));
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* Master gain: ONE absolute multiplier on the filter's final per-event output.
 * This is the "make everything faster/slower" knob — it scales the finished value
 * uniformly, so the four drawn overlay curves keep their exact shape and meaning
 * (2.0 doubles every zoom without touching a single graph). Deliberately applied
 * LAST, after the proximity factor and after every wall has had its say: the inner
 * lock returns early and the other stops work by zeroing the factor, so 0 x gain is
 * still 0 and no multiplier can punch through a boundary.
 * Persistent config like the curves (no staleness expiry); absent/invalid → 1.0.
 * Written by the curve editor, or by hand:  echo 2 > .../state/master_gain */
#define MGAIN_DEFAULT 1.0
#define MGAIN_MIN     0.05   /* clamps: a typo can't zero the zoom or make it wild */
#define MGAIN_MAX     10.0
static double sMasterGain = MGAIN_DEFAULT;
static void readMasterGain(void) {
    static long sec = 0, nsec = -1;
    struct stat st;
    if (stat(MGAIN_FILE, &st) != 0) { sMasterGain = MGAIN_DEFAULT; sec = 0; nsec = -1; return; }
    if (st.st_mtimespec.tv_sec == sec && st.st_mtimespec.tv_nsec == nsec) return;
    sec = st.st_mtimespec.tv_sec; nsec = st.st_mtimespec.tv_nsec;
    FILE *f = fopen(MGAIN_FILE, "r");
    if (f) {
        double g;
        if (fscanf(f, "%lf", &g) == 1 && g > 0.0) {
            if (g < MGAIN_MIN) g = MGAIN_MIN;
            if (g > MGAIN_MAX) g = MGAIN_MAX;
            sMasterGain = g;
        }
        fclose(f);
    }
}

/* ── Overlay curves (user-drawn multipliers) ─────────────────────────────────
 * File format written by the curve editor (plain text, two lines):
 *     <xmin> <xmax> <n> <scale:0=linear|1=log>
 *     m0 m1 m2 ... m(n-1)
 * n evenly spaced multiplier samples across the x-domain (≤ CURVE_MAX).  curveAdjust()
 * clamps x to [xmin,xmax], maps it to a fractional sample index (linear, or in log-x
 * when scale=1), and linearly interpolates.  An invalid / unloaded curve yields 1.0.
 * Cheap: re-parsed only when the file's mtime changes (statics held per Curve). */
#define CURVE_MAX 256
typedef struct {
    bool   valid;
    double xmin, xmax;
    int    n, logScale;
    double m[CURVE_MAX];
    long   sec, nsec;        /* mtime cache */
} Curve;

static void readCurve(const char *path, Curve *c) {
    struct stat st;
    if (stat(path, &st) != 0) { c->valid = false; c->sec = 0; c->nsec = -1; return; }
    /* NB: no staleness check here (unlike the live distance feeds) — these curves
     * are persistent config written only when the user drags a point; they must
     * stay in effect indefinitely, not expire after PIVOT_STALE seconds. */
    if (st.st_mtimespec.tv_sec == c->sec && st.st_mtimespec.tv_nsec == c->nsec) return; /* unchanged */
    c->sec = st.st_mtimespec.tv_sec; c->nsec = st.st_mtimespec.tv_nsec;
    c->valid = false;
    FILE *f = fopen(path, "r");
    if (!f) return;
    double xmin, xmax; int n, sc;
    if (fscanf(f, "%lf %lf %d %d", &xmin, &xmax, &n, &sc) == 4
            && n >= 2 && n <= CURVE_MAX && xmax > xmin) {
        int i, ok = 1;
        for (i = 0; i < n; i++) if (fscanf(f, "%lf", &c->m[i]) != 1) { ok = 0; break; }
        if (ok) {
            c->xmin = xmin; c->xmax = xmax; c->n = n; c->logScale = sc;
            c->valid = true;
        }
    }
    fclose(f);
}

/* Interpolated multiplier for input x; 1.0 when the curve isn't loaded. */
static double curveAdjust(const Curve *c, double x) {
    if (!c->valid) return 1.0;
    double lo = c->xmin, hi = c->xmax, v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    double t;
    if (c->logScale) {
        double l0 = log(lo > 1e-9 ? lo : 1e-9);
        t = (log(v > 1e-9 ? v : 1e-9) - l0) / (log(hi) - l0);
    } else {
        t = (v - lo) / (hi - lo);
    }
    double fi = t * (c->n - 1);
    int    i  = (int)fi;
    if (i < 0) i = 0;
    if (i >= c->n - 1) return c->m[c->n - 1];
    double frac = fi - i;
    return c->m[i] + (c->m[i + 1] - c->m[i]) * frac;
}

/* dir: +1 = zoom in, -1 = zoom out, 0 = unknown (no overlay yet → 1.0). */
static double readVelAdjust(double vel, int dir) {
    static Curve ci = { .valid = false, .sec = 0, .nsec = -1 };
    static Curve co = { .valid = false, .sec = 0, .nsec = -1 };
    if (dir > 0) { readCurve(VEL_ADJ_IN_FILE,  &ci); return curveAdjust(&ci, vel); }
    if (dir < 0) { readCurve(VEL_ADJ_OUT_FILE, &co); return curveAdjust(&co, vel); }
    return 1.0;
}
static double readProxAdjust(double dist, int dir) {
    static Curve ci = { .valid = false, .sec = 0, .nsec = -1 };
    static Curve co = { .valid = false, .sec = 0, .nsec = -1 };
    if (dir > 0) { readCurve(PROX_ADJ_IN_FILE,  &ci); return curveAdjust(&ci, dist); }
    if (dir < 0) { readCurve(PROX_ADJ_OUT_FILE, &co); return curveAdjust(&co, dist); }
    return 1.0;
}

/* The probe's "orbit generation": it bumps the integer in ORBIT_GEN_FILE each
 * time the orbit centre is set on NEW geometry (a meaningfully different point).
 * The inner-wall lock releases when this changes (you've targeted somewhere new).
 * Returns sSeenGen (= no change) when the file is missing/unparseable. */
static int sSeenGen = 0;
static int readOrbitGen(void) {
    FILE *f = fopen(ORBIT_GEN_FILE, "r");
    if (!f) return sSeenGen;
    int g, n = fscanf(f, "%d", &g);
    fclose(f);
    return (n == 1) ? g : sSeenGen;
}

/* Hand a fling off to the probe: write "in"/"out" (in/out decided against the
 * learned zoom-in sign).  The probe performs the actual camera jump. */
static void emitFling(int dir) {
    FILE *ff = fopen(FLING_FILE, "w");
    if (ff) { fputs((dir == sInSign) ? "in" : "out", ff); fclose(ff); }
}

/* ── Callback ────────────────────────────────────────────────────────────── */
// True iff the topmost on-screen window directly under the pointer is a Fusion
// window. One CGWindowList query, run once per scroll gesture at its phase==1
// begin — never on a timer, so it costs nothing when idle. Lets a scroll over
// Fusion's viewport zoom as usual while a scroll that starts over a floater
// (Finder, etc.) sitting on top passes straight through, even while Fusion is
// focused. This is also the gate that makes the filter safe to run PERSISTENTLY
// (see the header): over any non-Fusion window — including SketchUp, which has
// its own native zoom — the gesture passes straight through untouched. The first
// call in a process is ~150ms cold; warmCAD() (called at startup) pays that once.
static bool cursorOverCAD(void) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    CFArrayRef wins = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!wins) return false;
    bool result = false;
    CFIndex n = CFArrayGetCount(wins);
    for (CFIndex i = 0; i < n; i++) {                 // front-to-back
        CFDictionaryRef info = CFArrayGetValueAtIndex(wins, i);
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 1;
        if (layerRef) CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        if (layer != 0) continue;                     // skip menubar/overlay layers
        CFDictionaryRef b = CFDictionaryGetValue(info, kCGWindowBounds);
        CGRect r;
        if (!b || !CGRectMakeWithDictionaryRepresentation(b, &r)) continue;
        if (!CGRectContainsPoint(r, p)) continue;     // not under the pointer
        CFStringRef owner = CFDictionaryGetValue(info, kCGWindowOwnerName);
        result = owner &&
            CFStringCompare(owner, CFSTR("Fusion"), 0) == kCFCompareEqualTo;
        break;                                         // topmost window at point decides
    }
    CFRelease(wins);
    return result;
}

// True iff the accessibility element directly under the pointer is Fusion's 3D
// viewport canvas — identified as the app's MAIN window (role AXWindow +
// kAXMainAttribute==true). Toolbar/timeline buttons report AXButton, menu items
// AXMenuItem; Fusion's own dialogs/panels (Preferences, etc.) are windows too but
// are NOT the main window (AXMain=false) EVEN WHEN LARGE — all rejected. This is
// what narrows the custom zoom to the canvas, leaving a 2-finger scroll that
// begins over a menu/dialog/panel to scroll natively. (Gating on AXMain, not
// subrole/size: the old "AXDialog && size>600x400" test took big dialogs for the
// canvas and zoomed instead of scrolling them.) Fails OPEN (true) on any AX error
// so a missing permission never disables zoom. One AXUIElementCopyElementAtPosition
// call, run once per gesture at its phase==1 begin — never on a timer.
static bool elementIsCanvas(void) {
    static AXUIElementRef sys = NULL;
    if (!sys) sys = AXUIElementCreateSystemWide();
    if (!sys) return true;
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    AXUIElementRef el = NULL;
    if (AXUIElementCopyElementAtPosition(sys, p.x, p.y, &el) != kAXErrorSuccess || !el)
        return true;                                   // AX unavailable → fail open
    // ⚠ FAIL-OPEN TRAP: "true" means "treat as canvas", so if this binary loses its
    // Accessibility grant the AX query fails and the zoom-reshaper runs EVERYWHERE
    // (zooming instead of scrolling dialogs/panels). An unsigned rebuild silently
    // drops the grant — build.sh code-signs with a STABLE identity to prevent it.
    bool canvas = false;
    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
    /* diagnostic: remember what the AX layer reported, so the trace can say WHY */
    snprintf(sLastRole, sizeof(sLastRole), "%s", "<none>");
    sLastRoleMain = -1;
    if (role && CFGetTypeID(role) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)role, sLastRole, sizeof(sLastRole), kCFStringEncodingUTF8);
    if (role && CFGetTypeID(role) == CFStringGetTypeID() &&
        CFEqual(role, kAXWindowRole)) {
        CFBooleanRef mainRef = NULL;
        bool gotMain = (AXUIElementCopyAttributeValue(el, kAXMainAttribute,
                            (CFTypeRef *)&mainRef) == kAXErrorSuccess) &&
                       mainRef && CFGetTypeID(mainRef) == CFBooleanGetTypeID();
        if (gotMain) sLastRoleMain = CFBooleanGetValue(mainRef) ? 1 : 0;
        if (gotMain && CFBooleanGetValue(mainRef)) {
            canvas = true;
        } else {
            // AXMain unreadable OR false: the borderless canvas fills the whole display.
            // Fusion can report its only (canvas) window as AXMain=false (seen
            // 2026-10-05, same fix in reanchor.m); a real dialog never covers ~the
            // entire screen, so this never admits one.
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

// Prime the WindowServer + AX queries so the first real gesture doesn't pay the
// cold ~150ms first-call cost. Once warm, every later call is sub-millisecond.
static void warmCAD(void) { (void)cursorOverCAD(); (void)elementIsCanvas(); }

/* True when the Browser add-in most recently reported Fusion idle (activeCommand ==
   SelectCommand) within the last ~1.5s. We only swallow a right-click while idle so a
   right-click that confirms/cancels a running command's menu still reaches Fusion.
   Absent/stale flag → NOT idle (fail safe: pass the right-click through). */
static int fusionIsIdle(void) {
    FILE *f = fopen(SELECTMODE_FILE, "r");
    if (!f) return 0;
    long long ms = 0; int flag = 0;
    int n = fscanf(f, "%lld %d", &ms, &flag);
    fclose(f);
    if (n != 2 || flag != 1) return 0;
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    long long now = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return (now - ms) <= 1500;
}

/* The modifiers a click gesture reports, as the Click Actions add-in spells them.
   Space is the HID state of F20 (Karabiner's held-space report); in Fusion that
   report also carries Option, so Option under a held space is the space itself,
   not a second modifier. */
static void clickMods(CGEventFlags fl, char *out, size_t n) {
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

/* One gesture → CLICK_EVENT_FILE ("<ms> <gesture> <mods> <synthetic 0|1>"), written whole (tmp + rename) so the add-in's
   poller can never read half a line. */
static void writeClickEvent(long long ms, const char *gesture, const char *mods, bool synthetic) {
    const char *tmp = CLICK_EVENT_FILE ".tmp";
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%lld %s %s %d", ms, gesture, mods, synthetic ? 1 : 0);
    fclose(f);
    rename(tmp, CLICK_EVENT_FILE);
}

static CGEventRef callback(CGEventTapProxy proxy,
                            CGEventType    type,
                            CGEventRef     event,
                            void          *refcon)
{
    /* Re-enable if the system timed us out. */
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (sTap) CGEventTapEnable(sTap, true);
        return event;
    }

    /* Right-click (a two-finger tap) over the CANVAS while idle → CONSUME it (suppress
       Fusion's context / marking menu) and report it as a tap2 gesture; the Click
       Actions add-in runs whatever fusion_ui/clicks.json binds to it (Go Up a Level by
       default). Swallow the paired mouse-UP too so no menu slips through. When NOT idle
       (a command is running) or not over the canvas, pass it through so command menus
       still work. */
    static int sSwallowRightUp = 0;
    if (type == kCGEventRightMouseDown) {
        if (fusionIsIdle() && cursorOverCAD() && elementIsCanvas()) {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
            long long ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
            char mods[48];
            clickMods(CGEventGetFlags(event), mods, sizeof mods);
            writeClickEvent(ms, "tap2", mods, false);
            sSwallowRightUp = 1;
            return NULL;            /* eat the down → no context menu */
        }
        sSwallowRightUp = 0;
        return event;
    }
    if (type == kCGEventRightMouseUp) {
        if (sSwallowRightUp) { sSwallowRightUp = 0; return NULL; }
        return event;
    }

    /* Left-click: only OBSERVE it — stamp whether ⌘ was held plus a timestamp, then
       pass the event through completely unchanged. The Browser add-in reads this so a
       plain click on a sketch in the viewport enters it while a ⌘-click just selects.
       (The tap only runs while Fusion is focused, so these are canvas clicks.) */
    if (type == kCGEventLeftMouseDown) {
        /* The Cursor Probe (inside Fusion) posts a synthetic click to set the orbit
           centre on the geometry under the cursor, tagging its event source with
           CURSOR_PROBE_MARKER. That is NOT a user click, so it must leave no trace in
           the click bookkeeping below: stamping it made every orbit-centre set look
           like "the user just clicked", which blanked the Browser's selection mirror
           for a tick (the grey highlight flashing off and back) and fed the
           click-backed gates that decide jump-down and descend. Pass the event
           through completely untouched — just don't record it. */
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == CURSOR_PROBE_MARKER)
            return event;
        int64_t spid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        long long ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
        /* EVERY left-down that reaches Fusion stamps CLICK_CMD_FILE — real clicks,
           reanchor pass-through taps, BTT synthetic clicks alike. The Browser/CTD
           "click-backed selection" gates read this to tell user clicks from
           programmatic selection re-adds; skipping any click there makes descends
           silently miss (the old fc>=3 exclusion dropped real clicks landing inside
           the finger-count's lift lag right after a 3-finger gesture). */
        CGEventFlags fl = CGEventGetFlags(event);
        int cmd = (fl & kCGEventFlagMaskCommand) ? 1 : 0;
        FILE *cf = fopen(CLICK_CMD_FILE, "w");
        if (cf) { fprintf(cf, "%lld %d", ms, cmd); fclose(cf); }
        {   /* Remember where this click started so the paired left-up can tell a
               stationary click from a drag (see the left-up handler), and what it
               will report as a gesture there. The canvas test is made HERE, where
               the click landed, not on the up — by then the pointer may be over a
               panel it was dragged to. */
            CGPoint dn = CGEventGetLocation(event);
            sDownX = dn.x; sDownY = dn.y;
            atomic_store(&sDownMs, ms);
            clickMods(fl, sDownMods, sizeof sDownMods);
            sDownCanvas = cursorOverCAD() && elementIsCanvas();
            sDownWasTap3 = false;
            sDownSynthetic = spid != 0;
        }
        /* Double-click over the CANVAS → stamp DBLCLICK_FILE → Browser fires Go to
           Top Level + deselect. The gesture is a 3-finger tap that BetterTouchTool
           turns into two SYNTHETIC clicks, and NOTHING else may trigger it, so a
           pair requires all three of:
             • both left-downs synthetic (sourceUnixProcessID != 0), and
             • both from the SAME posting process, and
             • ≤ DBLCLICK_MS apart (60ms — BTT posts its pair in one burst, gap 0–2ms).
           Each condition kills a real false-positive seen in the wild:
             • a HARDWARE click (pid 0) landing shortly after a synthetic one — this
               is the common one: Fusion itself posts clicks, and your next genuine
               pick 150–450ms later paired with it, so a single click on an edge
               inside a component yanked the view to top and dropped the selection;
             • two clicks from DIFFERENT processes pairing by coincidence;
             • the old 450ms window, wide enough to swallow ordinary CAD picking
               (click a body to descend, then click a face on it without moving).
           Real physical double-clicks (dimension edit) are Fusion-native and need no
           stamp. clickState is logged but not used for the decision: it is a system
           heuristic with the same generous timing we're deliberately rejecting. */
        CGPoint pt = CGEventGetLocation(event);
        long long last    = atomic_load(&sLastClickMs);
        long long lastPid = atomic_load(&sLastClickPid);
        int lastSyn = atomic_load(&sLastClickSynthetic);
        double dx = pt.x - sLastClickX, dy = pt.y - sLastClickY;
        int near = (dx*dx + dy*dy) <= (DBLCLICK_PX * DBLCLICK_PX);
        int isDouble = (spid != 0) && lastSyn && (spid == lastPid) &&
                       (last != 0 && (ms - last) <= DBLCLICK_MS && near);
        int stamped = 0;
        if (isDouble) {
            if (sDownCanvas) {
                FILE *df = fopen(DBLCLICK_FILE, "w");
                if (df) { fprintf(df, "%lld", ms); fclose(df); stamped = 1; }
                /* Reported as ONE gesture: the first click's up already went out as
                   a click (the add-in defers clicks long enough for this to cancel
                   it), and this second click's up must not go out at all. */
                writeClickEvent(ms, "tap3", sDownMods, true);
                sDownWasTap3 = true;
            }
            atomic_store(&sLastClickMs, 0);   /* consume the pair so a 3rd click isn't another double */
            atomic_store(&sLastClickPid, -1);
        } else {
            atomic_store(&sLastClickMs, ms);
            atomic_store(&sLastClickSynthetic, spid != 0);
            atomic_store(&sLastClickPid, (long long)spid);
            sLastClickX = pt.x; sLastClickY = pt.y;
        }
        FILE *dl = fopen("/tmp/fusion_dblclick_debug.log", "a");
        if (dl) {
            fprintf(dl, "%lld down pid=%lld prevpid=%lld cs=%lld gap=%lld near=%d %s\n",
                    ms, (long long)spid, lastPid,
                    (long long)CGEventGetIntegerValueField(event, kCGMouseEventClickState),
                    last ? ms - last : -1, near,
                    isDouble ? (stamped ? "DOUBLE→stamped" : "DOUBLE (off-canvas)") : "single");
            fclose(dl);
        }
        return event;
    }

    /* Left-UP: was that click a DRAG? A window/box select (or dragging a sketch
       point) fires exactly the same selection events in Fusion as a pick, so the
       "a click acts" add-ins descended into / jumped down to whatever the rubber
       band caught. The tap is the only place that can tell them apart — it sees
       both ends of the gesture — so stamp the DOWN timestamp of a moved click into
       CLICK_DRAG_FILE and let the add-ins veto that exact click. Stamped only for
       drags, so a plain click leaves the file stale and keyed to an older click. */
    if (type == kCGEventLeftMouseUp) {
        long long downMs = atomic_load(&sDownMs);
        if (downMs &&
            CGEventGetIntegerValueField(event, kCGEventSourceUserData) != CURSOR_PROBE_MARKER) {
            CGPoint up = CGEventGetLocation(event);
            double dx = up.x - sDownX, dy = up.y - sDownY;
            if (dx*dx + dy*dy > (double)CLICK_DRAG_PX * CLICK_DRAG_PX) {
                FILE *gf = fopen(CLICK_DRAG_FILE, "w");
                if (gf) { fprintf(gf, "%lld", downMs); fclose(gf); }
            } else if (sDownCanvas && !sDownWasTap3) {
                /* A stationary click on the canvas: a click gesture. Written on the
                   UP so a drag is never reported, and so Fusion has made its pick. */
                writeClickEvent(downMs, "click", sDownMods, sDownSynthetic);
            }
            atomic_store(&sDownMs, 0);   /* one verdict per down */
        }
        return event;
    }

    if (type != kCGEventScrollWheel) return event;

    int64_t delta    = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t phase    = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    int64_t momentum = CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase);
    int     fc       = atomic_load(&sFingerCount);

    /* Non-trackpad device (no phase, no momentum): pass through unchanged. */
    if (phase == 0 && momentum == 0) return event;

    /* Cursor gate: decide ONCE per gesture, at its begin (phase==1), whether the
     * pointer is over a CAD window. If not — it's over a floater (Finder, etc.)
     * sitting on top, even while Fusion is focused — mark the whole gesture
     * pass-through so every event of it, including the momentum tail (phase==0,
     * momentum!=0), flows untouched and the floater scrolls normally. The flag
     * persists until the next gesture begin re-decides it. One hit-test/gesture. */
    /* Since 2026-10-18 two fingers ORBIT Fusion (reanchor reads the touches) and the zoom
     * is the thumb pinch: reanchor posts it as phased scrolls tagged NAV_ZOOM_MARK, already
     * gated on the canvas. Only those zoom; a real 2-finger scroll is judged below and,
     * over the canvas, swallowed whole (momentum tail too). */
    int64_t ud = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    bool pinch = (ud >> 32) == NAV_ZOOM_MARK;
    /* The amount rides in the user data's low half: macOS zeroes these events' delta
       fields while fingers are on the pad (most of them, 2026-10-18). */
    if (pinch) delta = (int32_t)(uint32_t)(ud & 0xffffffff);
    bool dbg = sdebugOn();
    if (dbg && pinch) sdlog("PINCH  delta=%lld phase=%lld grace=%d inLocked=%d",
                            (long long)delta, (long long)phase, (int)atomic_load(&sGrace), sInLocked);
    /* A 3+-finger swipe (remapd's Space / app switches) sends phased scrolls too. Begun
     * over another app they used to pass through, and their tail — still moving after
     * the switch, then momentum with no fingers — landed on Fusion's canvas as a native
     * zoom (2026-10-18). Swallow every scroll of such a touch, momentum included, until
     * a gesture begins with fewer than 3 fingers after a full lift. The lift is read off
     * the touch frames (sAllLifted): judged from scroll events, a swipe that ended with
     * no momentum never saw fc==0, and the NEXT 2-finger scroll — in any app — was
     * dropped whole (2026-10-18).
     * The swipe is read off the touch frames too (!sAllLifted), not only off a scroll
     * that saw 3+ fingers: a swipe's scroll can carry 2 the whole way — begun before the
     * 3rd finger landed, or begun by the last two fingers lifting — and then it passed
     * (begun over the old app) and landed on Fusion once the Space flipped. A Space not
     * visited for a while flips slowly, so more of the tail landed: the "big zoom on
     * switching to Fusion, only after a while, then it stops" (2026-10-20). */
    static bool sSwipe = false;
    static int  sSwipeDrops = 0, sSwipeLeaks = 0;   /* this swipe's drops; ...the old rule passed */
    static bool sSwipeSaw3 = false;                 /* a scroll of it saw 3+ (the old rule) */
    if (!pinch) {
        if (fc >= 3 || !atomic_load(&sAllLifted)) {
            sSwipe = true;
            if (fc >= 3) sSwipeSaw3 = true;
        } else if (phase == 1) {
            if (sSwipeDrops)
                fprintf(stderr, "%ld swipe tail over Fusion: %d scrolls dropped, %d of them by the touch-frame rule\n",
                        (long)time(NULL), sSwipeDrops, sSwipeLeaks);
            sSwipe = sSwipeSaw3 = false;
            sSwipeDrops = sSwipeLeaks = 0;
        }
        /* Only over Fusion: everywhere else a scroll is the app's own, untouched — the
           finger count also hears the left (keyboard) pad, and dropping there ate
           quick successive scrolls in every app (2026-10-18). */
        if (sSwipe && cursorOverCAD()) {
            if (dbg) sdlog("  SWIPE drop delta=%lld phase=%lld mom=%lld fingers=%d",
                           (long long)delta, (long long)phase, (long long)momentum, fc);
            sSwipeDrops++;
            if (!sSwipeSaw3) sSwipeLeaks++;
            return NULL;
        }
    }
    if (phase == 1 && !pinch) {
        bool overCAD = cursorOverCAD();
        /* AX only over Fusion: hit-testing Chrome / Electron (Claude) wakes their
           accessibility tree, which slows them — and it held every scroll's begin. */
        bool isCanvas = overCAD && elementIsCanvas();
        atomic_store(&sPassThrough, !(overCAD && isCanvas));
        atomic_store(&sNoHoriz, overCAD && !isCanvas);
        if (dbg) sdlog("BEGIN  overCAD=%d isCanvas=%d role=%s axMain=%d fingers=%d -> %s",
                       overCAD, isCanvas, sLastRole, sLastRoleMain, fc,
                       (overCAD && isCanvas) ? "RESHAPE" : "PASS-THROUGH (Fusion native zoom)");
    }
    if (!pinch && atomic_load(&sPassThrough)) {
        if (dbg) sdlog("  pass  delta=%lld phase=%lld mom=%lld fingers=%d", 
                       (long long)delta, (long long)phase, (long long)momentum, fc);
        /* Fusion's panels/dialogs scroll vertically only. Was LinearMouse's one live
         * rule (com.autodesk.fusion360: horizontal acceleration 0); LinearMouse's own
         * HID tap on every click/drag lagged the cursor (2026-10-13), so it's here now. */
        if (atomic_load(&sNoHoriz)) {
            CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, 0);
            CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, 0);
            CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, 0.0);
        }
        return event;
    }

    /* A real 2-finger scroll over the canvas: reanchor's orbit — never a zoom. */
    if (!pinch) {
        if (dbg) sdlog("  DROP  delta=%lld phase=%lld mom=%lld fingers=%d  <- 2-finger scroll = orbit",
                       (long long)delta, (long long)phase, (long long)momentum, fc);
        return NULL;
    }

    /* Momentum scrolling (inertia after lift): never let it zoom Fusion — the
     * fling is already decided at the lift event below — so just swallow it. */
    if (momentum != 0) return NULL;

    /* Lift / cancel (scroll phase 4 / 8 / 128).  The lift (4) fires immediately,
     * so we decide the fling here (see header for why not momentum / fingerCount).
     * Fire when: direction is known, it was a fast swipe (peak ≥ direction's
     * threshold), the fingers were still moving at lift (small gap since the last
     * real move), and the release/peak ratio shows real inertia (not an eased-off
     * lift).  A zoom-IN fling is blocked while the inner wall is locked, same as
     * regular zoom-in (released by a zoom-out or a new orbit centre). */
    if (phase == 4 || phase == 8 || phase == 128) {
        if (phase == 4 && sInSign != 0 && sLastDir != 0 && !sGraceGesture) {
            double gap_ms = (double)(CGEventGetTimestamp(event) - sLastMoveTs) / 1e6;
            double thr    = (sLastDir == sInSign) ? FLING_VEL_IN : FLING_VEL_OUT;
            /* Use the higher of smoothed/instantaneous peak: a SHORT fast flick has
             * few events, so the smoothed EMA never reaches its true speed — the
             * instantaneous peak does, so short flicks are no longer missed. The
             * release ratio still uses the smoothed peak (low for short flicks, so
             * it passes) so eased-off lifts are still rejected. */
            double peak   = (sPeakInst > sPeakVel) ? sPeakInst : sPeakVel;
            double ratio  = (sPeakVel > 1.0) ? (sLastInst / sPeakVel) : 1.0;
            bool   isIn   = (sLastDir == sInSign);
            if (sdebugOn()) {
                uint64_t nw = CGEventGetTimestamp(event);
                double armed_ms = sArmedFlingDir ? (double)(nw - sArmedFlingTs) / 1e6 : -1.0;
                sdlog("LIFT   dir=%s peak=%.0f thr=%.0f gap=%.1fms ratio=%.2f "
                      "inLocked=%d | %s%s%s%s | armed=%s age=%.0fms",
                      isIn ? "IN" : "OUT", peak, thr, gap_ms, ratio, sInLocked,
                      peak  >= thr                       ? "" : "FAIL:slow ",
                      gap_ms <= (double)FLING_LIFT_GAP_NS/1e6 ? "" : "FAIL:gap ",
                      ratio >= FLING_RELEASE_RATIO       ? "" : "FAIL:eased ",
                      !(isIn && sInLocked)               ? "" : "FAIL:wall ",
                      sArmedFlingDir == 0 ? "none" : (sArmedFlingDir == sLastDir ? "SAME-DIR" : "other-dir"),
                      armed_ms);
            }
            if (peak >= thr
                    && gap_ms <= (double)FLING_LIFT_GAP_NS / 1e6
                    && ratio  >= FLING_RELEASE_RATIO
                    && !(isIn && sInLocked)) {    /* blocked at the wall like regular zoom-in */
                /* Double-flick gate: this is a real flick, but only jump to the
                 * boundary if it's the SECOND one in the same direction within the
                 * window. Otherwise just arm and wait for the partner flick. */
                uint64_t now = CGEventGetTimestamp(event);
                if (sArmedFlingDir == sLastDir
                        && (now - sArmedFlingTs) <= DOUBLE_FLING_WINDOW_NS) {
                    if (sdebugOn()) sdlog("  FLING FIRED (%s) — second flick %.0fms after the first",
                                          (sLastDir == sInSign) ? "in" : "out",
                                          (double)(now - sArmedFlingTs) / 1e6);
                    emitFling(sLastDir);
                    sArmedFlingDir = 0; sArmedFlingTs = 0;     /* consumed */
                } else {
                    if (sdebugOn()) sdlog("  qualified -> ARMED (waiting %.0fms for a partner flick)",
                                          (double)DOUBLE_FLING_WINDOW_NS / 1e6);
                    sArmedFlingDir = sLastDir; sArmedFlingTs = now;  /* arm the first flick */
                }
            }
        }
        sAccum  = 0.0;
        sVel    = 0.0;
        sLastTs = 0;
        return NULL;
    }

    /* Began (phase 1): swallow this event and arm the flag.
     * Replicates the Python: set _swallow_next then immediately check it,
     * which causes the began event itself to be swallowed. */
    if (phase == 1) {
        sSwallowNext = true;
        sVel        = 0.0;
        sLastTs     = CGEventGetTimestamp(event);  /* seed velocity clock        */
        sLastMoveTs = CGEventGetTimestamp(event);
        sPrevPivot  = -1.0;                         /* don't vote across gestures */
        sLastDir    = 0;
        sPeakVel    = 0.0;
        sPeakInst   = 0.0;
        sLastInst   = 0.0;
        /* Activation grace: snapshot the pivot feed. Stale ⇒ Fusion was in the
         * background and the probe is asleep — hold zoom + suppress fling until
         * the probe (woken by the focus this same touch triggers) writes fresh. */
        sBeginPivotMtime  = pivotMtimeNs();
        sGraceBeginWallNs = wallNowNs();
        sGraceGesture     = (sBeginPivotMtime == 0)
                         || (sGraceBeginWallNs - sBeginPivotMtime) > GRACE_STALE_NS;
        /* A Fusion companion window (FusionValue etc.) holding focus: reanchor does
         * not activate Fusion over it, so no fresh pivot is coming — holding would
         * only swallow the zoom for the full cap. The last pivot is seconds old at
         * worst, which beats a jump. */
        if (sGraceGesture && companionFront()) {
            if (dbg) sdlog("  GRACE skipped: a Fusion companion window is frontmost");
            sGraceGesture = false;
        }
        if (sGraceGesture && dbg) sdlog("  GRACE holding zoom: pivot feed stale at begin");
        atomic_store(&sGrace, sGraceGesture);
    }
    if (sSwallowNext) {
        sSwallowNext = false;
        return NULL;
    }

    /* Hold the zoom while in activation grace: swallow every event until the
     * probe writes a fresh pivot (mtime moved off the begin snapshot) or the
     * hard cap elapses. Then release and let this and later events zoom. */
    if (atomic_load(&sGrace)) {
        uint64_t pm = pivotMtimeNs();
        if ((pm != 0 && pm != sBeginPivotMtime)
                || (wallNowNs() - sGraceBeginWallNs) > GRACE_MAX_NS) {
            atomic_store(&sGrace, false);   /* probe awake, or gave up holding */
        } else {
            return NULL;                    /* still stale — swallow */
        }
    }

    /* Update smoothed gesture velocity from the inter-event time. */
    {
        uint64_t ts = CGEventGetTimestamp(event);   /* nanoseconds */
        /* The pinch's ticks arrive bunched (pairs 0.1 ms apart, then a 25 ms gap), so
         * |delta|/dt read 10–80k px/s and the velocity curve fired at random (2026-10-18).
         * Pinch speed = the px of the last PINCH_WIN, over PINCH_WIN. */
        static uint64_t wTs[64]; static double wD[64]; static int wN = 0;
        if (pinch && phase != 1) {
            int k = 0;
            for (int i = 0; i < wN; i++)
                if (ts - wTs[i] < PINCH_WIN_NS) { wTs[k] = wTs[i]; wD[k] = wD[i]; k++; }
            wN = k;
            if (wN < 64) { wTs[wN] = ts; wD[wN] = fabs((double)delta); wN++; }
            double sum = 0;
            for (int i = 0; i < wN; i++) sum += wD[i];
            sVel = sum / (PINCH_WIN_NS / 1e9);
            if (delta != 0) {
                sLastInst = sVel;
                if (sVel > sPeakInst) sPeakInst = sVel;
            }
        } else if (sLastTs != 0) {
            double dt = (double)(ts - sLastTs) / 1e9;
            if (dt <= 0.0 || dt > ACCEL_GAP) {
                sVel = 0.0;                          /* new burst */
            } else {
                double inst = fabs((double)delta) / dt;
                sVel += ACCEL_SMOOTH * (inst - sVel);
                if (delta != 0) {
                    sLastInst = inst;                    /* release-velocity sample */
                    if (inst > sPeakInst) sPeakInst = inst;  /* peak instantaneous (short-flick detector) */
                }
            }
        }
        sLastTs = ts;
        if (sVel > sPeakVel) sPeakVel = sVel;            /* peak speed this gesture */
        if (delta != 0) {
            sLastDir    = (delta > 0) ? 1 : -1;          /* zoom direction so far  */
            sLastMoveTs = ts;                            /* time of last real move */
        }

        /* Mirror velocity + gain to a file for calibration, throttled to ~20 Hz. */
        if (ts - sLastVelLog > 50000000ULL) {        /* 50 ms */
            sLastVelLog = ts;
            FILE *vf = fopen(VEL_FILE, "w");
            if (vf) { fprintf(vf, "vel=%.0f gain=%.2f", sVel, velGain(sVel)); fclose(vf); }
        }
    }

    /* Modifier flags. */
    CGEventFlags flags   = CGEventGetFlags(event);
    bool         cmdHeld = (flags & (CGEventFlags)0x100000) != 0;

    /* ── Distance-aware state ────────────────────────────────────────────────
     * Read live distances and learn which scroll-delta sign means "zoom in" by
     * correlating delta sign with the pivot distance falling. */
    readNearDist();                      /* refresh the user-set inner wall (sNearDist) */
    readMasterGain();                    /* refresh the master output multiplier   */
    double dPivot  = readPivotDist();    /* eye→pivot  (cm) or -1 */
    double dOrigin = readOriginDist();   /* eye→origin (cm) or -1 */
    int    dsign   = (delta > 0) ? 1 : -1;

    /* Outer-wall hysteresis: latch zoom-out off once we reach STOP_OUT, and keep
     * it off (regardless of zoom direction) until we're back within RESUME_OUT. */
    if (dOrigin >= 0.0) {
        if (dOrigin >= STOP_OUT)        sOutLatched = true;
        else if (dOrigin <= RESUME_OUT) sOutLatched = false;
    }

    if (dPivot >= 0.0 && sPrevPivot >= 0.0) {
        double dd = dPivot - sPrevPivot;
        if (fabs(dd) > 0.05) {                       /* real eye movement */
            sVote += (dd < 0.0 ? dsign : -dsign);    /* falling ⇒ this sign is "in" */
            if (sVote >  12) sVote =  12;
            if (sVote < -12) sVote = -12;
            if (sInSign == 0 && (sVote >= 4 || sVote <= -4)) {
                sInSign = (sVote > 0) ? 1 : -1;
                FILE *sf = fopen(SIGN_FILE, "w");    /* persist for next launch */
                if (sf) { fprintf(sf, "%d", sInSign); fclose(sf); }
            }
        }
    }
    if (dPivot >= 0.0) sPrevPivot = dPivot;

    bool zoomingIn  = (sInSign != 0) && (dsign ==  sInSign);
    bool zoomingOut = (sInSign != 0) && (dsign == -sInSign);
    int  zdir       = zoomingIn ? 1 : (zoomingOut ? -1 : 0);  /* overlay-curve selector */

    /* Inner-wall lock: once a zoom-in reaches the inner wall (NEAR_DIST), block
     * ALL further zoom-in (regular scroll AND flings) — even if the cursor moves
     * — until released by EITHER a zoom-out OR a new orbit centre set over
     * geometry (the probe bumps ORBIT_GEN_FILE when the orbit point moves). */
    {
        int gen = readOrbitGen();
        if (gen != sSeenGen) { sSeenGen = gen; sInLocked = false; }  /* new orbit → unlock */
    }
    if (zoomingOut) {
        sInLocked = false;
    } else if (zoomingIn) {
        if (dPivot >= 0.0 && dPivot <= sNearDist) sInLocked = true;
        if (sInLocked) return NULL;            /* blocked — at/over the inner wall */
    }

    /* Suppress the velocity boost as we approach either wall, so a fast swipe
     * can't blast across the slow-down zone before the distance feed updates.
     * gm: 1 = full boost, 0 = no boost. */
    double gm = 1.0;
    if (zoomingIn && dPivot >= 0.0)
        gm = smoothstep((dPivot - sNearDist) / (GAIN_FADE_IN - sNearDist));
    if (zoomingOut && dOrigin >= 0.0) {
        double g2 = smoothstep((FAR_OUT - dOrigin) / GAIN_FADE_OUT);
        if (g2 < gm) gm = g2;
    }

    /* Apply curve + modifier scaling. Shift is ignored intentionally. */
    double curved;
    if (cmdHeld) {
        curved  = applyCurve(delta, 1.0);              /* linear when cmd held */
        curved *= (SCALE_SLOW / SCALE);                /* 0.05x */
    } else {
        curved  = applyCurve(delta, POWER);
        /* Built-in velocity gain, scaled by the user's overlay curve (1.0 = no
         * change). The wall fade (gm) still applies to the combined boost. */
        double gain = velGain(sVel) * readVelAdjust(sVel, zdir);
        curved *= 1.0 + (gain - 1.0) * gm;             /* boost fades near walls */
    }

    /* Proximity slow-down (floored at CLOSE_FACTOR) applies the same both ways,
     * scaled by the user's overlay curve (1.0 = no change). The hard safety stops
     * below (HALT, inner-wall lock, far-out clamp) are applied AFTER this, so an
     * overlay edit can never punch through a wall. */
    double f = (dPivot >= 0.0) ? proximityFactor(dPivot, sNearDist) : FAR_FACTOR;
    if (dPivot >= 0.0) f *= readProxAdjust(dPivot, zdir);
    if (f < 0.0) f = 0.0;
    /* Zoom-IN only: a →0 safety stop below HALT_DIST (backs up the inner-wall
     * lock against any feed lag).  Never do this for zoom-OUT or you'd be trapped
     * against the pivot with no way to escape. */
    if (zoomingIn && dPivot >= 0.0 && dPivot <= HALT_DIST) f = 0.0;
    /* Far-out clamp resists only zooming OUT past FAR_OUT from the origin. */
    if (zoomingOut && dOrigin >= 0.0)
        f *= sOutLatched ? 0.0 : originClamp(dOrigin);   /* latched off until within RESUME_OUT */

    curved *= f;

    /* Master gain LAST: a uniform scale on the finished value. Every wall above
     * has already applied (inner lock returned early; the rest zeroed f), so this
     * scales real motion only and can never restore a stopped zoom. */
    curved *= sMasterGain;
    double zg = pinch ? readZoomGain() : 1.0;   /* empty space: as if geometry were there */
    curved *= zg;

    /* Accumulate sub-pixel remainder. */
    sAccum += curved;
    int32_t newDelta = (int32_t)sAccum;
    sAccum -= (double)newDelta;

    if (dbg) sdlog("  post  in=%lld -> out=%d  (curved=%.3f f=%.3f gain=%.2fx empty=%.2fx vel=%.0f pivot=%.1f)",
                   (long long)delta, newDelta, curved, f, sMasterGain, zg, sVel, dPivot);
    if (newDelta == 0) return NULL;  /* not enough accumulated yet, swallow */

    /* Post a fresh pixel-unit event and swallow the original. */
    CGEventRef newEvent = CGEventCreateScrollWheelEvent(
        NULL, kCGScrollEventUnitPixel, 1, newDelta);
    CGEventSetIntegerValueField(newEvent, kCGEventSourceUserData, NAV_ZOOM_MARK);
    /* At the pinch's own spot: the pointer is frozen for it, and a frozen pointer's read
       position follows the fingers unseen — a scroll posted there warped it. */
    CGEventSetLocation(newEvent, CGEventGetLocation(event));
    CGEventPost(kCGSessionEventTap, newEvent);
    CFRelease(newEvent);

    return NULL;
}

/* ── Main ────────────────────────────────────────────────────────────────── */
int main(void) {
    /* Restore the learned zoom-in delta sign from a previous run, if any. */
    {
        FILE *sf = fopen(SIGN_FILE, "r");
        if (sf) { int s; if (fscanf(sf, "%d", &s) == 1 && (s == 1 || s == -1)) sInSign = s; fclose(sf); }
    }

    startMultitouchHotplug(touchCallback);   /* bind now AND re-bind on every trackpad reconnect */

    CGEventMask mask = CGEventMaskBit(kCGEventScrollWheel) | CGEventMaskBit(kCGEventLeftMouseDown)
                     | CGEventMaskBit(kCGEventLeftMouseUp)
                     | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp);

    sTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        callback,
        NULL
    );

    if (!sTap) {
        fprintf(stderr,
            "FusionScrollFilter: could not create event tap.\n"
            "Grant Accessibility access to Terminal (or this binary) in\n"
            "System Settings → Privacy & Security → Accessibility.\n");
        return 1;
    }

    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault, sTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(sTap, true);

    readNearDist();   /* so the banner shows the user-set wall, not just the default */
    readMasterGain(); /* ditto for the master multiplier */
    fprintf(stdout,
        "[FusionScrollFilter] running  scale=%.3f  gain=%.2fx  "
        "pivot=[wall@%.1fcm %.0f%%→%.0f%%@%.0fcm]  "
        "farout=[%.0f→%.0fm]  zoomInSign=%d\n",
        (double)SCALE, sMasterGain,
        sNearDist, (double)(CLOSE_FACTOR * 100.0),
        (double)(FAR_FACTOR * 100.0), (double)SLOW_DIST,
        (double)(FAR_OUT / 100.0), (double)(STOP_OUT / 100.0), sInSign);
    fflush(stdout);

    warmCAD();   // absorb the one-time ~150ms cold-call cost before any gesture

    CFRunLoopRun();
    return 0;
}

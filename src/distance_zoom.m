// distance_zoom.m — UI Zoom follows how far you are from the screen, seen by a camera.
//
//   distance_zoom            run (com.josh.distance-zoom agent; ui_zoom/distance.sh on|off)
//   distance_zoom --debug    the same, every sample printed to stderr
//
// The camera (the MacBook's own by default; config/distance_zoom.json "camera" picks any
// whose name contains it — "iPhone" for Continuity Camera) is read at 8 Hz. Vision's
// foreground mask gives your silhouette (§ Measuring), and its width along the band of
// rows at the camera's own eye level (config band_top/band_bottom, share of the frame's
// height) is the measure. Whatever height the camera is at, that band crosses the same
// part of you near or far — here, under the desk, your hips — and nothing above the
// camera (the desk's underside hides everything above the belt) matters. Face and
// body-pose cues were tried and dropped: from under the desk they never fire.
//
// factor = seat width / width now = how many times further away you are than your seat.
// `ui_zoom/distance.sh calibrate` (at your normal spot) records the seat width; until
// then it is a guess (0.60 — standing at the desk, 2026-10-20).
//
// Level = base × (1 + gain·(factor − 1)), in 5% steps, 100–max: gain 0.75 = three
// quarters of the zoom that would keep things their seat size (full was too much,
// 2026-10-20). Near the seat (factor < deadband) it is the base. The median of the last
// WINDOW_S has to stay off the current level, the same way, for HOLD_S (a one-step change:
// HOLD1_S) before the level is asked for (gliding 0.35 s, quicker than a press); a
// walk that keeps going the same way follows on as each glide lands. A step back toward
// the level restarts the wait — so shifting about doesn't pump. (The wait used to
// restart on every new step, so it never fired until you stood still: slow.) Nobody in
// view: the level holds.
//
// The base is the level you set by hand: an ⌘+/⌘− press while this runs becomes
// the new base (level ÷ the factor at that moment).
//
// The curve (§ Curve) replaces that formula once it has two points: `distance.sh curve`
// opens a panel (§ Calibration panel) with the camera's view, a zoom slider that zooms
// live, and Record (Space). Stand somewhere, slide to the zoom you want there, Record —
// 2 s of readings + the slider's level become a point; do it at several distances. The
// points, made monotonic (further never zooms less), are joined into a piecewise-linear
// curve of level against distance, flat past the ends. A hand press then trims the
// curve (level ÷ the curve's level there, config "trim"); re-recording clears the trim.
//
// Smooth (the panel's slider, [ / ]): 0 = through every point, up to one straight line
// (§ Curve).
//
// Steps (§ Steps) replace both whenever config/distance_zoom_steps.json has any: a few
// fixed levels (Normal, Medium, High…), each entered past its "up" distance and left
// only back below its "down" one, and only once the reading has stayed over the line
// for "hold" seconds — so standing on a threshold never flickers. Edited on Control
// Room ▸ Miscellaneous ▸ Distance Zoom (remap/distance_zoom.js), re-read on mtime.
//
// Hands: Vision's hand pose finds up to two hands; a hand's size (palm length, or 1.4 ×
// the knuckle span, whichever is less foreshortened) is a second distance cue. The curve's
// points tie hand size to body width ("hand_seat"); "hand_share" is how much they count,
// whichever share best predicts your points. A hand much nearer or further than the body
// says (reaching out) is ignored. Hands also gate the zoom (§ The gate): it only changes
// when the body moves and, if hands are in view, they move with it — hands moving on
// their own never zoom.
//
// The level is set by remapd, not here: this writes it to /tmp/remapd_uizoom_req and posts
// com.josh.remapd.uizoom, and remapd runs `ui_zoom.sh set` (bin/remapd.m). The screen
// glide re-fits windows over AX and snapshots them for its stand-ins, and run from here
// it had only this binary's grants: without Accessibility the windows stayed put, and
// each snapshot waited on a screen-capture consent alert macOS keeps for unbundled tools
// (replayd "requireAlert"; ~20 s a zoom, 2026-10-20). remapd's grants cover both.
// "Busy" = ui_zoom.sh holds its lock (/tmp/.ui_zoom.lock, flock via lockf), so a walk's
// next level waits for the glide to land rather than queueing behind it.
//
// Screen locked: the camera is released (its green light goes out) until unlocked.
// Cost: ~25% of one core, mostly the camera pipeline (macOS's hand-gesture Reactions are
// opted out in the Info.plist; they were more than half of it).
//
// The camera grant is keyed to this binary's signed identity (com.josh.distance_zoom);
// the Info.plist with NSCameraUsageDescription is linked in (distance_zoom.plist), so the
// first run under launchd asks once. That is also why the calibration panel lives in this
// process (an accessory app: no Dock icon) — nothing else may look through the camera.
//
// build: bin/build.sh distance_zoom
// log: /tmp/distance_zoom.log · state (last sample, for a glance): /tmp/distance_zoom.state

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <notify.h>
#include <sys/file.h>

static NSString *const CONFIG = @"/Users/josh/Code/Scripts/config/distance_zoom.json";
static NSString *const LEVEL_FILE = @"/Users/josh/Code/Scripts/config/ui_zoom_level";
static NSString *const STATE = @"/tmp/distance_zoom.state";

static const double SAMPLE_S = 0.125;   // Vision at most this often (8 Hz)
static const double WINDOW_S = 0.5;     // the median is over this much
static const double HOLD_S = 0.3;       // off the level, one way, this long…
static const double HOLD1_S = 0.8;      // …this long when it is a small move (§ decide)
static const double SURE_S = 1.5;       // zooming up: sure of you (§ Sure) this long first
static const double DOUBT_S = 2.0;      // not sure: back to the first step after this long
static const double EDGE = 0.02;        // a run this near the frame's side is cut off by it
static const double CALIB_S = 2.0;      // calibrate: average this long
static const double REC_WAIT_S = 0.5;   // Record: settle after the press this long…
static const double REC_S = 2.0;        // …then read this long
static const int STEP = 5;
static const int MAX_PCT = 300;         // ui_zoom.sh's own ceiling

static BOOL debugOn;

// ── Config ────────────────────────────────────────────────────────────────────
// "base" is written here (the level at your seat — a restart must not take a level we
// zoomed to as the base). Touched only on the Watcher's queue.
// { "camera": "FaceTime", "seat": 0.60, "base": 100, "gain": 0.75, "deadband": 1.15, "max": 250,
//   "band_top": 0.45, "band_bottom": 0.60, "hands": true,
//   "curve": [ { "body": 0.31, "hand": 0.045, "level": 150, … } ], "trim": 1,
//   "hand_seat": 0.07, "hand_share": 0.3 }      (the last two: worked out from "curve")
static NSMutableDictionary *cfg;

static double num(NSString *k, double dflt) {
    id v = cfg[k];
    return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : dflt;
}
static void loadConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:CONFIG];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    cfg = [j isKindOfClass:NSDictionary.class] ? j : [NSMutableDictionary new];
}
static void saveConfig(void) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:cfg
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [d writeToFile:CONFIG atomically:YES];
}

static void logf_(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logf_(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss";
    fprintf(stderr, "%s %s\n", [f stringFromDate:NSDate.date].UTF8String, s.UTF8String);
}

static double median(NSArray<NSNumber *> *a) {
    if (!a.count) return NAN;
    NSArray *v = [a sortedArrayUsingSelector:@selector(compare:)];
    return [v[v.count / 2] doubleValue];
}
// Spread as a share of the median (robust: median absolute deviation × 1.4826).
static double relSpread(NSArray<NSNumber *> *a) {
    double m = median(a);
    if (!(m > 0)) return NAN;
    NSMutableArray *dev = [NSMutableArray new];
    for (NSNumber *v in a) [dev addObject:@(fabs(v.doubleValue - m))];
    return 1.4826 * median(dev) / m;
}

// ── Level ─────────────────────────────────────────────────────────────────────
static int readLevel(void) {
    NSString *s = [NSString stringWithContentsOfFile:LEVEL_FILE encoding:NSUTF8StringEncoding error:nil];
    int p = s ? (int)lround(s.doubleValue * 100) : 100;
    return p < 100 ? 100 : p;
}

static int lastSet = -1;                // the level we last asked for
static double base = 0;                 // the level at the seat, percent
static double appliedFactor = 1;        // the distance behind lastSet (NAN: not known)

static void setBase(double b) {
    base = MAX(100, b);
    if (lround(num(@"base", -1)) != lround(base)) { cfg[@"base"] = @(lround(base)); saveConfig(); }
}

static double boost(double f) { return 1 + num(@"gain", 0.75) * (MAX(f, 1) - 1); }

static double askedAt = -1;             // when we last asked remapd for a level
static BOOL busy(void) {
    double now = CACurrentMediaTime();
    if (askedAt >= 0 && now - askedAt < 0.3) return YES;   // remapd hasn't taken the lock yet
    BOOL held = NO;
    int fd = open("/tmp/.ui_zoom.lock", O_RDONLY);
    if (fd >= 0) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) flock(fd, LOCK_UN); else held = errno == EWOULDBLOCK;
        close(fd);
    }
    if (!held && askedAt >= 0) { logf_(@"  set took %.2f s", now - askedAt); askedAt = -1; }
    return held;
}
static void setLevel(int pct) {
    [[NSString stringWithFormat:@"%d\n", pct] writeToFile:@"/tmp/remapd_uizoom_req" atomically:YES
                                                  encoding:NSUTF8StringEncoding error:nil];
    notify_post("com.josh.remapd.uizoom");
    lastSet = pct;
    askedAt = CACurrentMediaTime();
}

// ── Measuring ─────────────────────────────────────────────────────────────────
// Your silhouette's width along the eye-level band, as a share of the frame's width:
// per row the widest run of one subject, then the median row. NAN = nothing there.
//
// The subject comes from Vision's foreground instance mask (the "lift subject" model),
// not its person segmentation: from under the desk the camera sees a headless torso in
// dark clothes, which person segmentation reads as nobody (0% for a true 38%) — the
// foreground model finds it every time (2026-10-20, near and far frames). Its catch: it
// always finds SOME subject, so an empty room measures the chair; nothing to see then,
// and the level is right again a second after you're back.
//
// Hands (§ Hands, at the top): hand size as a share of the frame's width, the biggest
// hand seen (the least foreshortened). NAN = none.
typedef struct {
    double body, hand;
    int hands;
    double runX0, runX1, runY;          // the median row's run (shares; y from the top)
} Reading;

static CVPixelBufferRef lastMask;       // for a snap

static double bodyWidth(VNGenerateForegroundInstanceMaskRequest *fg, Reading *r) {
    CVPixelBufferRef mask = fg.results.firstObject.instanceMask;   // 0 = background, else instance
    if (!mask) return NAN;
    CVPixelBufferRelease(lastMask); lastMask = CVPixelBufferRetain(mask);

    CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
    const uint8_t *px = CVPixelBufferGetBaseAddress(mask);
    size_t mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask),
           stride = CVPixelBufferGetBytesPerRow(mask);
    NSMutableArray<NSArray *> *runs = [NSMutableArray new];   // [width, start, row]
    for (size_t y = (size_t)(num(@"band_top", 0.45) * mh); y < (size_t)(num(@"band_bottom", 0.60) * mh); y++) {
        const uint8_t *row = px + y * stride;
        size_t best = 0, bestStart = 0, run = 0;
        for (size_t x = 0; x < mw; x++) {
            run = row[x] && x && row[x] == row[x - 1] ? run + 1 : (row[x] ? 1 : 0);
            if (run > best) { best = run; bestStart = x + 1 - run; }
        }
        [runs addObject:@[ @((double)best / mw), @((double)bestStart / mw), @((double)y / mh) ]];
    }
    CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
    if (!runs.count) return NAN;
    [runs sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    NSArray *m = runs[runs.count / 2];
    double w = [m[0] doubleValue];
    r->runX0 = [m[1] doubleValue]; r->runX1 = r->runX0 + w; r->runY = [m[2] doubleValue];
    return w > 0.03 ? w : NAN;
}

static BOOL sure(VNRecognizedPoint *p) { return p && p.confidence > 0.3; }
static double handSize(NSArray<VNHumanHandPoseObservation *> *obs, double W, double H,
                       int *count, NSMutableArray *pts) {
    double best = NAN; int n = 0;
    for (VNHumanHandPoseObservation *o in obs) {
        NSDictionary<VNHumanHandPoseObservationJointName, VNRecognizedPoint *> *j =
            [o recognizedPointsForJointsGroupName:VNHumanHandPoseObservationJointsGroupNameAll error:nil];
        if (!j) continue;
        for (VNRecognizedPoint *p in j.allValues)
            if (sure(p)) [pts addObject:[NSValue valueWithPoint:NSMakePoint(p.location.x, p.location.y)]];
        VNRecognizedPoint *wr = j[VNHumanHandPoseObservationJointNameWrist],
                          *mid = j[VNHumanHandPoseObservationJointNameMiddleMCP],
                          *idx = j[VNHumanHandPoseObservationJointNameIndexMCP],
                          *lit = j[VNHumanHandPoseObservationJointNameLittleMCP];
        double (^d)(VNRecognizedPoint *, VNRecognizedPoint *) = ^double(VNRecognizedPoint *a, VNRecognizedPoint *b) {
            return hypot((a.location.x - b.location.x) * W, (a.location.y - b.location.y) * H) / W;
        };
        double palm = sure(wr) && sure(mid) ? d(wr, mid) : 0;
        double span = sure(idx) && sure(lit) ? d(idx, lit) : 0;
        double s = MAX(palm, 1.4 * span);   // a palm is ~1.4 knuckle spans long
        if (s <= 0.01) continue;
        n++;
        if (isnan(best) || s > best) best = s;
    }
    *count = n;
    return best;
}

static Reading look(CVPixelBufferRef pb, BOOL hands, NSMutableArray *pts) {
    Reading r = { NAN, NAN, 0, 0, 0, 0 };
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    VNGenerateForegroundInstanceMaskRequest *fg = [VNGenerateForegroundInstanceMaskRequest new];
    VNDetectHumanHandPoseRequest *hp = nil;
    NSMutableArray *reqs = [NSMutableArray arrayWithObject:fg];
    if (hands) { hp = [VNDetectHumanHandPoseRequest new]; hp.maximumHandCount = 2; [reqs addObject:hp]; }
    [h performRequests:reqs error:nil];     // one failing leaves the other's results
    r.body = bodyWidth(fg, &r);
    if (hp) r.hand = handSize(hp.results, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), &r.hands, pts);
    return r;
}

// ── Distance ──────────────────────────────────────────────────────────────────
// How many times further than the seat: from the body, from the hands, and the two put
// together (a weighted mean in log space — the cues are ratios).
static double xBody(double w) { return num(@"seat", 0.60) / w; }
static double xHand(double h) {
    double ref = num(@"hand_seat", NAN);
    return isnan(ref) || isnan(h) ? NAN : ref / h;
}
static double fuseX(double b, double k, double share) {
    if (isnan(k)) return b;
    if (isnan(b)) return k;
    if (fabs(log(k / b)) > log(1.5)) return b;   // a hand held out (or back): the body's word
    return exp((1 - share) * log(b) + share * log(k));
}
static double fuse(double w, double h) { return fuseX(xBody(w), xHand(h), num(@"hand_share", 0.3)); }

// ── Curve ─────────────────────────────────────────────────────────────────────
// cfg "curve" holds the recorded points; knots is the fit: [[distance, level]…],
// ascending, the level never falling (pool-adjacent-violators: a stretch that wants less
// zoom further away is levelled to its average).
//
// Smoothness (cfg "smooth", 0–1, the panel's Smooth slider): 0 = the curve goes through
// every point; above it, a local-linear fit with a Gaussian kernel over log distance,
// 0.02 × 100^smooth wide — 0.3 ≈ ±8% distance, 0.5 ≈ ±20%, 1 ≈ one straight line
// through all the points.
//
// hand_share: tried 0, 0.1 … 1, keeping the one whose curve best predicts each point
// from the others (leave-one-out) — how much the hands help is whatever your points
// show. (Jitter within a recording said nothing: the body mask's width is coarse, so
// its spread read 0 and hands always lost; the 16 points of 2026-10-20 agree on 0.)
static NSArray<NSArray<NSNumber *> *> *knots;

static BOOL curveOn(void) { return [cfg[@"curve"] count] >= 2 && knots.count; }

static double smoothH(void) {
    double s = MAX(0, MIN(1, num(@"smooth", 0.3)));
    return s < 0.005 ? 0 : 0.02 * pow(100, s);
}

// The kernel fit at `at`, leaving out point `skip` (-1: none). Weight on one place only:
// the weighted mean there.
static double localLinear(const double *u, const double *y, int n, double at, double h, int skip) {
    double minD = INFINITY;
    for (int i = 0; i < n; i++) if (i != skip) minD = MIN(minD, (u[i] - at) * (u[i] - at));
    double S0 = 0, S1 = 0, S2 = 0, T0 = 0, T1 = 0;
    for (int i = 0; i < n; i++) {
        if (i == skip) continue;
        double d = u[i] - at, w = exp(-(d * d - minD) / (2 * h * h));   // nearest weighs 1
        S0 += w; S1 += w * d; S2 += w * d * d; T0 += w * y[i]; T1 += w * d * y[i];
    }
    if (S0 <= 0) return NAN;
    double det = S0 * S2 - S1 * S1;
    return det <= 1e-9 * S0 * S2 ? T0 / S0 : (S2 * T0 - S1 * T1) / det;
}

static void monotone(double *y, int n) {      // pool adjacent violators, in place
    double v[n]; int c[n], k = 0;
    for (int i = 0; i < n; i++) {
        v[k] = y[i]; c[k] = 1; k++;
        while (k >= 2 && v[k - 1] < v[k - 2]) {
            v[k - 2] = (v[k - 2] * c[k - 2] + v[k - 1] * c[k - 1]) / (c[k - 2] + c[k - 1]);
            c[k - 2] += c[k - 1]; k--;
        }
    }
    for (int b = 0, i = 0; b < k; b++) for (int j = 0; j < c[b]; j++) y[i++] = v[b];
}

static void fitCurve(void) {
    NSArray<NSDictionary *> *pts = cfg[@"curve"];
    int n = (int)pts.count;
    double seat = num(@"seat", 0.60), h = smoothH();
    if (!n) { knots = @[]; [cfg removeObjectForKey:@"hand_seat"]; [cfg removeObjectForKey:@"hand_share"]; return; }
    // Hands: the hand size that means the seat distance.
    NSMutableArray *ratios = [NSMutableArray new];
    for (NSDictionary *p in pts)
        if ([p[@"hand"] isKindOfClass:NSNumber.class])
            [ratios addObject:@(log([p[@"hand"] doubleValue] * seat / [p[@"body"] doubleValue]))];
    if (ratios.count) cfg[@"hand_seat"] = @(exp(median(ratios)));
    else { [cfg removeObjectForKey:@"hand_seat"]; [cfg removeObjectForKey:@"hand_share"]; }

    double xb[n], xk[n], lv[n], u[n];
    for (int i = 0; i < n; i++) {
        NSDictionary *p = pts[i];
        xb[i] = xBody([p[@"body"] doubleValue]);
        xk[i] = [p[@"hand"] isKindOfClass:NSNumber.class] ? xHand([p[@"hand"] doubleValue]) : NAN;
        lv[i] = [p[@"level"] doubleValue];
    }
    // Hands: how much they count — the share whose curve best predicts each point.
    if (ratios.count >= 4 && n >= 4) {
        double bestS = 0, bestE = INFINITY;
        for (int k = 0; k <= 10; k++) {
            double s = k / 10.0, e = 0;
            for (int i = 0; i < n; i++) u[i] = log(fuseX(xb[i], xk[i], s));
            for (int i = 0; i < n; i++) e += pow(lv[i] - localLinear(u, lv, n, u[i], MAX(h, 0.1), i), 2);
            if (e < bestE - 1e-6) { bestE = e; bestS = s; }
        }
        cfg[@"hand_share"] = @(bestS);
    } else if (ratios.count) cfg[@"hand_share"] = @0.3;    // too few points to tell

    double share = num(@"hand_share", 0.3);
    NSMutableArray<NSArray *> *xy = [NSMutableArray new];
    for (int i = 0; i < n; i++) {
        double x = fuseX(xb[i], xk[i], share);
        if (isfinite(x) && x > 0) [xy addObject:@[ @(log(x)), @(lv[i]) ]];
    }
    [xy sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    int m = (int)xy.count;
    if (!m) { knots = @[]; return; }
    for (int i = 0; i < m; i++) { u[i] = [xy[i][0] doubleValue]; lv[i] = [xy[i][1] doubleValue]; }
    NSMutableArray *k = [NSMutableArray new];
    if (h == 0 || m < 2 || u[m - 1] - u[0] < 1e-6) {
        monotone(lv, m);
        for (int i = 0; i < m; i++) [k addObject:@[ @(exp(u[i])), @(lv[i]) ]];
    } else {
        enum { G = 40 };
        double g[G], gy[G], lo = INFINITY, hi = -INFINITY;
        for (int i = 0; i < m; i++) { lo = MIN(lo, lv[i]); hi = MAX(hi, lv[i]); }
        for (int j = 0; j < G; j++) {
            g[j] = u[0] + (u[m - 1] - u[0]) * j / (G - 1);
            gy[j] = MAX(lo, MIN(hi, localLinear(u, lv, m, g[j], h, -1)));
        }
        monotone(gy, G);
        for (int j = 0; j < G; j++) [k addObject:@[ @(exp(g[j])), @(gy[j]) ]];
    }
    knots = k;
}

static double curveAt(double x) {
    if (!knots.count || isnan(x)) return NAN;
    if (x <= [knots[0][0] doubleValue]) return [knots[0][1] doubleValue];
    for (NSUInteger i = 1; i < knots.count; i++) {
        double x1 = [knots[i][0] doubleValue];
        if (x > x1) continue;
        double x0 = [knots[i - 1][0] doubleValue], y0 = [knots[i - 1][1] doubleValue], y1 = [knots[i][1] doubleValue];
        return x1 > x0 ? y0 + (y1 - y0) * (x - x0) / (x1 - x0) : y1;
    }
    return [knots.lastObject[1] doubleValue];
}

// ── Steps ─────────────────────────────────────────────────────────────────────
// config/distance_zoom_steps.json, written by the Control Room only (the cfg file is
// this process's: a save from here would clobber an edit there):
//   { "hold": 1.5, "steps": [ { "level": 100 }, { "level": 140, "up": 2.6, "down": 2.3 }, … ] }
// Sorted by "up"; the first step has none (it is where you start). Walking away, step i
// is entered once the distance reaches its up; walking back it is left only below its
// down (≤ up) — the gap is the hysteresis. Either way the change waits until the
// reading has wanted it for "hold" seconds, one way (a walk past two lines keeps the
// clock; turning back restarts it). A ⌘+/⌘− press stands until the next step change.
// The first step is the default: a step up also needs SURE_S of being sure of you
// (centred, all in view, steady — § Sure in captureOutput); not sure (off to one side,
// nobody) reads as the seat, and falls back to the first step after DOUBT_S (2026-10-26:
// standing to the side read narrow, i.e. far, and zoomed).
static NSString *const STEPS = @"/Users/josh/Code/Scripts/config/distance_zoom_steps.json";
static NSString *const LIVE = @"/tmp/distance_zoom.live.json";   // the page's live marker
static NSArray<NSDictionary *> *steps;  // nil: no steps, the curve / formula decide
static double stepHold = 1.5;
static double stepsMtime = -1;

static BOOL loadSteps(void) {           // YES when the file changed
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:STEPS error:nil];
    double m = a ? a.fileModificationDate.timeIntervalSince1970 : 0;
    if (m == stepsMtime) return NO;
    stepsMtime = m;
    NSData *d = [NSData dataWithContentsOfFile:STEPS];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSMutableArray *v = [NSMutableArray new];
    if ([j isKindOfClass:NSDictionary.class] && [j[@"steps"] isKindOfClass:NSArray.class])
        for (id s in j[@"steps"])
            if ([s isKindOfClass:NSDictionary.class] && [s[@"level"] isKindOfClass:NSNumber.class]) [v addObject:s];
    [v sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([a[@"up"] doubleValue]) compare:@([b[@"up"] doubleValue])];
    }];
    steps = v.count ? v : nil;
    id h = [j isKindOfClass:NSDictionary.class] ? j[@"hold"] : nil;
    stepHold = [h isKindOfClass:NSNumber.class] ? MAX(0, [h doubleValue]) : 1.5;
    logf_(@"steps: %@", steps ? [NSString stringWithFormat:@"%lu, hold %.1f s", (unsigned long)steps.count, stepHold] : @"none");
    return YES;
}
static double stepUp(int i) { return i ? [steps[i][@"up"] doubleValue] : 0; }
static double stepDown(int i) {
    id d = steps[i][@"down"];
    return i ? MIN([d isKindOfClass:NSNumber.class] ? [d doubleValue] : INFINITY, stepUp(i)) : 0;
}
static int stepLevel(int i) {
    int l = (int)lround([steps[i][@"level"] doubleValue] / STEP) * STEP;
    return MAX(100, MIN(MAX_PCT, l));
}
// The step for distance x, coming from step `from` (-1: none yet — by the up lines alone).
static int stepFor(double x, int from) {
    int n = (int)steps.count, i = from < 0 || from >= n ? 0 : from;
    while (i + 1 < n && x >= stepUp(i + 1)) i++;
    if (from >= 0) while (i > 0 && x < stepDown(i)) i--;
    return i;
}

// ── Calibration panel (views) ────────────────────────────────────────────────
// The camera's view with what was found drawn on it: the band (grey), the body's width
// across it (green), hand joints (yellow).
@interface Overlay : NSView
@property NSDictionary *live;
@end
@implementation Overlay
- (void)drawRect:(NSRect)dirty {
    NSDictionary *l = _live;
    if (!l) return;
    double W = self.bounds.size.width, H = self.bounds.size.height;
    double bt = [l[@"band_top"] doubleValue], bb = [l[@"band_bottom"] doubleValue];
    [[NSColor colorWithWhite:1 alpha:0.15] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, H * (1 - bb), W, H * (bb - bt)), NSCompositingOperationSourceOver);
    NSArray *run = l[@"run"];
    if (run) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        double y = H * (1 - [run[2] doubleValue]);
        [p moveToPoint:NSMakePoint(W * [run[0] doubleValue], y)];
        [p lineToPoint:NSMakePoint(W * [run[1] doubleValue], y)];
        p.lineWidth = 4; p.lineCapStyle = NSLineCapStyleRound;
        [NSColor.systemGreenColor setStroke]; [p stroke];
    }
    [NSColor.systemYellowColor setFill];
    for (NSValue *v in l[@"pts"]) {
        NSPoint q = v.pointValue;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(q.x * W - 2.5, q.y * H - 2.5, 5, 5)] fill];
    }
}
@end

// Level against distance: the recorded points (white; filled = hands were seen), the
// fitted curve (blue), where you are now (orange line) and the slider's level there
// (orange dot — where Record would put a point).
@interface Plot : NSView
@property NSArray *points, *knots;      // [x, level, hasHand] · [x, level]
@property double liveX, liveLevel;
@end
@implementation Plot
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [[NSColor colorWithWhite:0.1 alpha:1] setFill]; NSRectFill(b);
    double lo = 1, hi = 2, top = 200;
    for (NSArray *p in _points) {
        lo = MIN(lo, [p[0] doubleValue]); hi = MAX(hi, [p[0] doubleValue]); top = MAX(top, [p[1] doubleValue]);
    }
    if (isfinite(_liveX)) { lo = MIN(lo, _liveX); hi = MAX(hi, _liveX); }
    top = MAX(top, _liveLevel);
    double x0 = lo * 0.9, x1 = hi * 1.1, y0 = 100, y1 = ceil((top + 10) / 50) * 50;
    double L = 40, R = 10, B = 22, T = 10;
    double (^px)(double) = ^double(double x) { return L + (x - x0) / (x1 - x0) * (b.size.width - L - R); };
    double (^py)(double) = ^double(double y) { return B + (y - y0) / (y1 - y0) * (b.size.height - B - T); };
    NSDictionary *ta = @{ NSFontAttributeName: [NSFont systemFontOfSize:10],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:0.6 alpha:1] };
    [[NSColor colorWithWhite:1 alpha:0.08] setStroke];
    for (double y = y0; y <= y1 + 0.1; y += 50) {
        [NSBezierPath strokeLineFromPoint:NSMakePoint(L, py(y)) toPoint:NSMakePoint(b.size.width - R, py(y))];
        [[NSString stringWithFormat:@"%.0f%%", y] drawAtPoint:NSMakePoint(4, py(y) - 6) withAttributes:ta];
    }
    double xs = (x1 - x0) > 3 ? 1 : 0.5;
    for (double x = ceil(x0 / xs) * xs; x <= x1; x += xs) {
        [NSBezierPath strokeLineFromPoint:NSMakePoint(px(x), B) toPoint:NSMakePoint(px(x), b.size.height - T)];
        [[NSString stringWithFormat:@"×%g", x] drawAtPoint:NSMakePoint(px(x) - 8, 4) withAttributes:ta];
    }
    if (_knots.count) {
        NSBezierPath *c = [NSBezierPath bezierPath];
        [c moveToPoint:NSMakePoint(px(x0), py([_knots[0][1] doubleValue]))];
        for (NSArray *k in _knots) [c lineToPoint:NSMakePoint(px([k[0] doubleValue]), py([k[1] doubleValue]))];
        [c lineToPoint:NSMakePoint(px(x1), py([_knots.lastObject[1] doubleValue]))];
        c.lineWidth = 2; [NSColor.systemBlueColor setStroke]; [c stroke];
    }
    for (NSArray *p in _points) {
        NSBezierPath *o = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(px([p[0] doubleValue]) - 4, py([p[1] doubleValue]) - 4, 8, 8)];
        [NSColor.whiteColor set];
        if ([p[2] boolValue]) [o fill]; else { o.lineWidth = 1.5; [o stroke]; }
    }
    if (isfinite(_liveX)) {
        [NSColor.systemOrangeColor set];
        NSBezierPath *v = [NSBezierPath bezierPath];
        [v moveToPoint:NSMakePoint(px(_liveX), B)]; [v lineToPoint:NSMakePoint(px(_liveX), b.size.height - T)];
        CGFloat dash[] = { 3, 3 }; [v setLineDash:dash count:2 phase:0]; [v stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(px(_liveX) - 5, py(_liveLevel) - 5, 10, 10)] fill];
    }
}
@end

// ── The loop ──────────────────────────────────────────────────────────────────
@class Calib;
@interface Watcher : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property AVCaptureSession *session;
@property dispatch_queue_t q;
@property Calib *ui;                    // strong: main's local would not keep it alive
- (void)beginCurve; - (void)endCurve;
- (void)want:(int)level; - (void)record:(int)level; - (void)undoPoint; - (void)clearPoints; - (void)tick;
- (void)smooth:(double)s;
@end

// ── Calibration panel ────────────────────────────────────────────────────────
// `distance.sh curve`. Keys while it is in front: ←/→ (or −/=) zoom 5%, Space/Return
// Record, ⌫ drop the last point, [ / ] smoothness, Esc done. ⌘+/⌘− work too (the slider follows them).
// Top-left of the screen the pointer is on: the screen zoom is pinned there, so the
// panel stays in view at any level (640 × 380 fits the 300% view of the 3440 × 1440).
@interface Calib : NSObject <NSWindowDelegate>
@property (weak) Watcher *w;
- (void)show:(int)level;
- (void)live:(NSDictionary *)d;
- (void)curve:(NSDictionary *)d;
- (void)follow:(int)level;
- (void)say:(NSString *)s;
@end
@implementation Calib {
    NSPanel *panel; NSView *preview; Overlay *overlay; Plot *plot;
    NSSlider *slider, *smoothSlider; NSTextField *levelLabel, *readout, *status, *smoothLabel;
    id keyMon; NSTimer *timer;
    int level; double clearArmed;
}

static NSTextField *label(NSRect r, CGFloat size, NSView *in) {
    NSTextField *t = [NSTextField labelWithString:@""];
    t.frame = r; t.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular];
    t.textColor = NSColor.labelColor; t.lineBreakMode = NSLineBreakByTruncatingTail;
    [in addSubview:t];
    return t;
}
- (NSButton *)button:(NSString *)title at:(NSRect)r action:(SEL)a in:(NSView *)v {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:a];
    b.frame = r; b.refusesFirstResponder = YES;   // Space is ours, not the button's
    [v addSubview:b];
    return b;
}

- (void)build {
    NSRect frame = NSMakeRect(0, 0, 640, 380);
    panel = [[NSPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Distance Zoom — stand, slide, Record";
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;   // slots switch spaces
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.delegate = self;
    NSView *v = panel.contentView;

    preview = [[NSView alloc] initWithFrame:NSMakeRect(16, 184, 240, 180)];
    preview.wantsLayer = YES;
    preview.layer.backgroundColor = NSColor.blackColor.CGColor;
    preview.layer.contentsGravity = kCAGravityResizeAspectFill;
    preview.layer.masksToBounds = YES;
    [v addSubview:preview];
    overlay = [[Overlay alloc] initWithFrame:preview.bounds];
    [preview addSubview:overlay];
    plot = [[Plot alloc] initWithFrame:NSMakeRect(268, 184, 356, 180)];
    plot.liveX = NAN; plot.liveLevel = 100;
    [v addSubview:plot];

    readout = label(NSMakeRect(16, 148, 608, 24), 15, v);
    slider = [NSSlider sliderWithValue:100 minValue:100 maxValue:MAX_PCT target:self action:@selector(slid:)];
    slider.frame = NSMakeRect(16, 102, 480, 28);
    slider.continuous = YES; slider.refusesFirstResponder = YES;
    [v addSubview:slider];
    levelLabel = label(NSMakeRect(508, 94, 116, 44), 34, v);
    levelLabel.font = [NSFont monospacedDigitSystemFontOfSize:34 weight:NSFontWeightSemibold];
    levelLabel.alignment = NSTextAlignmentRight;

    [self button:@"Record (Space)" at:NSMakeRect(12, 52, 150, 32) action:@selector(recordPressed:) in:v];
    [self button:@"Undo (⌫)" at:NSMakeRect(166, 52, 100, 32) action:@selector(undoPressed:) in:v];
    [self button:@"Clear" at:NSMakeRect(270, 52, 80, 32) action:@selector(clearPressed:) in:v];
    smoothLabel = label(NSMakeRect(354, 58, 76, 20), 12, v);
    smoothLabel.textColor = NSColor.secondaryLabelColor;
    smoothSlider = [NSSlider sliderWithValue:0.3 minValue:0 maxValue:1 target:self action:@selector(smoothed:)];
    smoothSlider.frame = NSMakeRect(430, 56, 88, 24);
    smoothSlider.continuous = YES; smoothSlider.refusesFirstResponder = YES;
    smoothSlider.toolTip = @"Smoothness: left = through every point, right = one straight line ( [ and ] )";
    [v addSubview:smoothSlider];
    [self button:@"Done (Esc)" at:NSMakeRect(524, 52, 104, 32) action:@selector(donePressed:) in:v];
    status = label(NSMakeRect(16, 16, 608, 22), 14, v);
    status.textColor = NSColor.secondaryLabelColor;
}

- (void)place {
    NSScreen *on = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(NSEvent.mouseLocation, s.frame, NO)) on = s;
    NSRect vf = on.visibleFrame;
    [panel setFrameTopLeftPoint:NSMakePoint(vf.origin.x + 16, NSMaxY(vf) - 16)];
}

- (void)show:(int)lv {
    if (!panel) [self build];
    if (!panel.visible) [self place];
    [self follow:lv];
    [self say:@"Stand where you want a point, slide to the zoom you like there, press Record and hold still."];
    if (@available(macOS 14, *)) [NSApp activate]; else [NSApp activateIgnoringOtherApps:YES];
    [panel makeKeyAndOrderFront:nil];
    if (!keyMon) keyMon = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        return [self key:e] ? nil : e;
    }];
    if (!timer) timer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) { [self.w tick]; }];
}

- (BOOL)key:(NSEvent *)e {
    if (e.window != panel || (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) return NO;
    NSString *c = e.charactersIgnoringModifiers;
    switch (e.keyCode) {
        case 123: case 125: [self nudge:-STEP]; return YES;   // ← ↓
        case 124: case 126: [self nudge:STEP]; return YES;    // → ↑
        case 49: case 36: case 76: [self recordPressed:nil]; return YES;   // Space, Return, Enter
        case 51: case 117: [self undoPressed:nil]; return YES;            // ⌫, ⌦
        case 53: [self donePressed:nil]; return YES;                       // Esc
    }
    if ([c isEqualToString:@"-"] || [c isEqualToString:@"_"]) { [self nudge:-STEP]; return YES; }
    if ([c isEqualToString:@"="] || [c isEqualToString:@"+"]) { [self nudge:STEP]; return YES; }
    if ([c isEqualToString:@"["] || [c isEqualToString:@"]"]) {
        smoothSlider.doubleValue = MAX(0, MIN(1, smoothSlider.doubleValue + ([c isEqualToString:@"]"] ? 0.05 : -0.05)));
        [self smoothed:smoothSlider]; return YES;
    }
    return NO;
}

- (void)showLevel { slider.intValue = level; levelLabel.stringValue = [NSString stringWithFormat:@"%d%%", level]; plot.liveLevel = level; plot.needsDisplay = YES; }
- (void)follow:(int)lv { level = lv; [self showLevel]; }
- (void)nudge:(int)d { level = MAX(100, MIN(MAX_PCT, level + d)); [self showLevel]; [_w want:level]; }
- (void)slid:(NSSlider *)s {
    int lv = (int)lround(s.doubleValue / STEP) * STEP;
    if (lv == level) return;
    level = lv; [self showLevel]; [_w want:level];
}
- (void)showSmooth:(double)v {
    smoothLabel.stringValue = v < 0.005 ? @"Smooth: off" : [NSString stringWithFormat:@"Smooth %.0f", v * 100];
}
- (void)smoothed:(NSSlider *)s {
    double v = round(s.doubleValue * 100) / 100;
    [self showSmooth:v]; [_w smooth:v];
}
- (void)recordPressed:(id)s { [_w record:level]; }
- (void)undoPressed:(id)s { [_w undoPoint]; }
- (void)clearPressed:(id)s {
    double now = CACurrentMediaTime();
    if (now - clearArmed > 3) { clearArmed = now; [self say:@"Press Clear again to delete every point."]; return; }
    clearArmed = 0; [_w clearPoints];
}
- (void)donePressed:(id)s { [panel close]; }
- (void)windowWillClose:(NSNotification *)n {
    if (keyMon) { [NSEvent removeMonitor:keyMon]; keyMon = nil; }
    [timer invalidate]; timer = nil;
    [_w endCurve];
}

- (void)say:(NSString *)s { status.stringValue = s; }

- (void)live:(NSDictionary *)d {
    if (!panel.visible) return;
    id img = d[@"img"];
    if (img) preview.layer.contents = img;
    overlay.live = d; overlay.needsDisplay = YES;
    double x = [d[@"x"] doubleValue], body = [d[@"body"] doubleValue], hand = [d[@"hand"] doubleValue];
    double cv = [d[@"curve"] doubleValue];
    NSMutableString *s = [NSMutableString new];
    [s appendString:isfinite(x) ? [NSString stringWithFormat:@"Distance ×%.2f", x] : @"Nobody in view"];
    if (isfinite(body)) [s appendFormat:@"  ·  body %.0f%% wide", body * 100];
    int nh = [d[@"hands"] intValue];
    [s appendString:nh ? [NSString stringWithFormat:@"  ·  %d hand%@ (×%@)", nh, nh > 1 ? @"s" : @"",
                          isfinite([d[@"xhand"] doubleValue]) ? [NSString stringWithFormat:@"%.2f", [d[@"xhand"] doubleValue]]
                          : [NSString stringWithFormat:@"%.1f%%", hand * 100]]
                       : @"  ·  no hands"];
    if (isfinite(cv)) [s appendFormat:@"  ·  curve says %.0f%%", cv];
    readout.stringValue = s;
    plot.liveX = x; plot.needsDisplay = YES;
    if (d[@"rec"]) {
        double left = [d[@"rec"] doubleValue];
        [self say:left > REC_S ? @"Hold still…" : [NSString stringWithFormat:@"Recording… %.1f s", left]];
    }
}

- (void)curve:(NSDictionary *)d {
    plot.points = d[@"points"]; plot.knots = d[@"knots"]; plot.needsDisplay = YES;
    if (d[@"smooth"] && !NSEvent.pressedMouseButtons) {
        smoothSlider.doubleValue = [d[@"smooth"] doubleValue]; [self showSmooth:smoothSlider.doubleValue];
    }
    if (d[@"say"]) [self say:d[@"say"]];
}
@end

@implementation Watcher {
    double lastSample;
    NSMutableArray<NSArray *> *recent;  // [time, distance]
    int pendingDir; double pendingSince;   // the median left the level this way, then
    double calibUntil; NSMutableArray<NSNumber *> *calib;
    BOOL snapNext;
    BOOL curving;                       // the calibration panel is open
    int wantLevel;                      // its slider
    double recFrom, recUntil; int recLevel;
    double gateB, gateK, gateX; BOOL gateHeld;   // § gate
    NSMutableArray<NSNumber *> *recBody, *recHand;
    CIContext *ci;
    int curStep, curStepLevel, stepCount;   // § Steps: where we are (-1: not yet), its level as set
    int stepPend, stepPendDir; double stepPendSince;   // the step the reading wants, since
    double sureSince;                   // § Sure: sure of you since (-1: not)
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("distance_zoom", DISPATCH_QUEUE_SERIAL);
        recent = [NSMutableArray new];
        [self resetGate];
        curStep = stepPend = -1;
        sureSince = -1;
    }
    return self;
}

- (void)calibrate {
    dispatch_async(_q, ^{
        self->calib = [NSMutableArray new];
        self->calibUntil = CACurrentMediaTime() + CALIB_S;
        logf_(@"calibrating — hold still at your seat");
    });
}

// `notifyutil -p com.callis.distancezoom.snap`: the next frame → SNAP, to see what the
// camera sees (setting it up; the grant is this binary's, so nothing else can look).
- (void)snap { dispatch_async(_q, ^{ self->snapNext = YES; }); }
static void writeImage(CVPixelBufferRef pb, NSString *path, CFStringRef type) {
    if (!pb) return;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CGImageRef img = [[CIContext context] createCGImage:ci fromRect:ci.extent];
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], type, 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d); CGImageRelease(img);
}
static void writeSnap(CVPixelBufferRef pb, double width) {
    writeImage(pb, @"/tmp/distance_zoom_snap.jpg", CFSTR("public.jpeg"));
    writeImage(lastMask, @"/tmp/distance_zoom_mask.png", CFSTR("public.png"));
    logf_(@"snap → /tmp/distance_zoom_snap.jpg + _mask.png, width %.3f", width);
}

- (BOOL)start {
    if (_session.running) return YES;
    NSString *want = cfg[@"camera"] ?: @"FaceTime";
    AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                           AVCaptureDeviceTypeContinuityCamera,
                                           AVCaptureDeviceTypeExternal ]
                              mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
    AVCaptureDevice *dev = nil;
    for (AVCaptureDevice *d in ds.devices)
        if ([d.localizedName rangeOfString:want options:NSCaseInsensitiveSearch].location != NSNotFound) { dev = d; break; }
    if (!dev) dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!dev) { logf_(@"no camera"); return NO; }

    AVCaptureSession *s = [AVCaptureSession new];
    s.sessionPreset = AVCaptureSessionPreset640x480;  // the mask model's own input is smaller
    NSError *err = nil;
    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!in || ![s canAddInput:in]) { logf_(@"camera %@: %@", dev.localizedName, err); return NO; }
    [s addInput:in];
    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.alwaysDiscardsLateVideoFrames = YES;
    [out setSampleBufferDelegate:self queue:_q];
    [s addOutput:out];
    // ~10 fps (we look at 8), clamped into a range the format has; an unsupported one throws.
    double fps = 1e9;
    for (AVFrameRateRange *r in dev.activeFormat.videoSupportedFrameRateRanges)
        fps = MIN(fps, MIN(MAX(r.minFrameRate, 10), r.maxFrameRate));
    if (fps < 1e9 && [dev lockForConfiguration:nil]) {
        @try {
            dev.activeVideoMinFrameDuration = CMTimeMake(1000, (int32_t)(fps * 1000));
            dev.activeVideoMaxFrameDuration = CMTimeMake(1000, (int32_t)(fps * 1000));
        } @catch (NSException *e) { logf_(@"frame rate %.0f: %@", fps, e.reason); }
        [dev unlockForConfiguration];
    }
    [s startRunning];
    _session = s;
    logf_(@"watching through %@", dev.localizedName);
    return YES;
}

- (void)stop {
    if (!_session) return;
    [_session stopRunning];
    _session = nil;
    dispatch_async(_q, ^{ [self->recent removeAllObjects]; [self resetGate]; self->pendingDir = 0; });
    logf_(@"camera released");
}

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)c {
    double now = CACurrentMediaTime();
    if (now - lastSample < SAMPLE_S) return;
    lastSample = now;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    BOOL hands = num(@"hands", 1) != 0;   // always: they witness whether you moved (§ gate)
    NSMutableArray *pts = curving ? [NSMutableArray new] : nil;
    Reading r = look(pb, hands, pts);
    double width = r.body;
    if (snapNext) { snapNext = NO; writeSnap(pb, width); }

    if (calib) { [self collect:width now:now]; return; }
    if (curving) { [self curveSample:r pb:pb pts:pts now:now]; return; }
    if (loadSteps() && (int)steps.count != stepCount) { stepCount = (int)steps.count; curStep = stepPend = -1; }

    // § Sure: the width only means distance when all of you is in view, in the middle.
    // Off to one side (part of you past the frame's edge, or seen at an angle) you read
    // narrow — as if far. So: the run clear of both edges, its centre within "centre"
    // (config, default 0.2) of the middle.
    BOOL mid = isfinite(r.body) && r.runX0 > EDGE && r.runX1 < 1 - EDGE
               && fabs((r.runX0 + r.runX1) / 2 - 0.5) <= num(@"centre", 0.2);
    [recent addObject:@[ @(now), @(xBody(r.body)), @(r.hand), @(mid) ]];   // NAN when nobody / no hands
    while (recent.count && now - [recent[0][0] doubleValue] > WINDOW_S) [recent removeObjectAtIndex:0];
    NSMutableArray *bs = [NSMutableArray new], *hs = [NSMutableArray new];
    int off = 0;
    for (NSArray *e in recent) {
        if (!isnan([e[1] doubleValue])) [bs addObject:e[1]];
        if (!isnan([e[2] doubleValue])) [hs addObject:e[2]];
        if (![e[3] boolValue]) off++;
    }
    BOOL seen = bs.count >= MAX(2, recent.count / 2);
    if (!seen && !steps) {                       // nobody (or mostly nobody) in view: hold
        if (debugOn || !access("/tmp/distance_zoom.debug", F_OK)) logf_(@"nobody");
        pendingDir = 0; stepPend = -1; [self writeState:@"nobody" factor:NAN];
        return;
    }
    // Sure = every sample of the window in the middle, and steady ("spread", default 10%).
    // With steps, not sure reads as the seat: the first step is the default, and only a
    // sure reading zooms up (§ Steps).
    BOOL sure = seen && !off && relSpread(bs) <= num(@"spread", 0.1);
    if (!sure) sureSince = -1; else if (sureSince < 0) sureSince = now;
    double hand = hs.count >= MAX(2, bs.count / 2) ? median(hs) : NAN;
    double x;
    if (sure || !steps) x = [self gate:median(bs) hand:hand];
    else { [self resetGate]; x = 1; }           // the gate starts afresh once you're sure again
    if (steps) [self step:x now:now sure:sure]; else [self decide:x now:now width:width hand:hand];
}

// § Steps, each sample.
- (void)step:(double)x now:(double)now sure:(BOOL)sure {
    int level = readLevel();
    if (!busy() && lastSet > 0 && level != lastSet) {
        logf_(@"hand press → %d%% (stands until the next step)", level);
        lastSet = level;
    }
    if (curStep >= 0 && stepLevel(curStep) != curStepLevel && !busy()) {   // its level was edited
        curStepLevel = stepLevel(curStep);
        logf_(@"step %d is now %d%%", curStep + 1, curStepLevel);
        if (curStepLevel != lastSet) setLevel(curStepLevel);
    }
    int want = stepFor(x, curStep);
    if (want == curStep) stepPend = -1;
    else {
        int dir = curStep < 0 ? 0 : want > curStep ? 1 : -1;
        if (stepPend < 0 || dir != stepPendDir || (!dir && want != stepPend)) { stepPendDir = dir; stepPendSince = now; }
        stepPend = want;
        // Up only once sure of you for SURE_S; back down for doubt only after DOUBT_S
        // (far away the mask can blink for a moment).
        BOOL up = want > MAX(curStep, 0);
        double hold = !up && !sure ? MAX(stepHold, DOUBT_S) : stepHold;
        BOOL ready = now - stepPendSince >= hold && (!up || (sureSince >= 0 && now - sureSince >= SURE_S));
        if (ready && !busy()) {
            logf_(@"×%.2f → step %d (%d%%)%s", x, want + 1, stepLevel(want), sure ? "" : " — not sure where you are");
            curStep = want; stepPend = -1;
            curStepLevel = stepLevel(want);
            if (curStepLevel != lastSet) setLevel(curStepLevel);
        }
    }
    if (debugOn || !access("/tmp/distance_zoom.debug", F_OK))
        logf_(@"×%.2f step %d want %d (at %d)%s%s", x, curStep + 1, want + 1, lastSet, sure ? "" : " unsure", busy() ? " busy" : "");
    [self writeState:[NSString stringWithFormat:@"%d", curStep >= 0 ? curStepLevel : lastSet] factor:x];
}

// ── The gate: hands alone don't zoom ─────────────────────────────────────────
// The distance only moves on when you do. The body's reading (window median) has to
// leave where it was last taken by "move" (config, default 6%); if hands are in view
// they have to agree — their size changing the same way, by at least half that. Hands
// moving while the body stays put (gesturing, reaching for the trackpad) change
// nothing, and nor does the silhouette widening as an arm swings out while the hands
// stay the same size. While the body stays well inside the threshold the hands' own
// reference follows them, so wherever they wandered to is where they start from when
// you walk. Accepted: the distance is the body/hands mix (§ Distance). No hands in view:
// the body alone, as before.
- (double)gate:(double)b hand:(double)h {
    double move = log(1 + num(@"move", 0.06));
    double k = isnan(h) ? NAN : 1 / h;            // the hands' distance, up to a constant
    if (isnan(gateB)) { gateB = b; gateK = k; gateX = fuseX(b, xHand(h), num(@"hand_share", 0.3)); return gateX; }
    double db = log(b / gateB), dk = isnan(k) || isnan(gateK) ? NAN : log(k / gateK);
    if (fabs(db) > move && (isnan(dk) || (dk * db > 0 && fabs(dk) > move / 2))) {
        gateB = b; gateK = k;
        gateX = fuseX(b, xHand(h), num(@"hand_share", 0.3));
        if (gateHeld) { gateHeld = NO; if (debugOn) logf_(@"gate: moving (hands agree)"); }
    } else {
        if (fabs(db) > move && !gateHeld) {
            gateHeld = YES;
            logf_(@"gate: body ×%.2f but hands ×%.2f — holding", exp(db), exp(dk));
        }
        if (fabs(db) < move / 2 || isnan(gateK)) gateK = k;   // still: let the hands wander
    }
    return gateX;
}
- (void)resetGate { gateB = gateK = gateX = NAN; gateHeld = NO; }

- (void)collect:(double)width now:(double)now {
    if (!isnan(width)) [calib addObject:@(width)];
    if (now < calibUntil) return;
    NSArray *v = [calib sortedArrayUsingSelector:@selector(compare:)];
    calib = nil;
    if (v.count < 5) { logf_(@"calibrate: nobody in view"); return; }
    cfg[@"seat"] = v[v.count / 2];
    if (cfg[@"curve"]) fitCurve();      // the curve's distances are relative to the seat
    saveConfig();
    [self resetGate];
    // You are at the seat now: whatever we added for distance comes off.
    setBase(lround(readLevel() / boost(appliedFactor) / STEP) * STEP);
    appliedFactor = 1;
    if (!curveOn() && (int)base != readLevel() && !busy()) setLevel((int)base);
    logf_(@"calibrated: seat %.3f — base %.0f%%", [v[v.count / 2] doubleValue], base);
}

- (void)decide:(double)x now:(double)now width:(double)width hand:(double)hand {
    // A hand press since our last set: that level, at today's distance, is the new base
    // (with a curve: the new trim).
    BOOL curve = curveOn();
    int level = readLevel();
    if (!busy() && lastSet > 0 && level != lastSet) {
        if (curve) {
            double at = curveAt(isnan(appliedFactor) ? x : appliedFactor);
            cfg[@"trim"] = @(round(1000.0 * level / at) / 1000); saveConfig();
            logf_(@"hand press → %d%%, curve trim now ×%.2f", level, num(@"trim", 1));
        } else {
            setBase(level / boost(isnan(appliedFactor) ? 1 : appliedFactor));
            logf_(@"hand press → %d%%, base now %.0f%%", level, base);
        }
        lastSet = level;
    }
    double f, want;
    int maxPct;
    if (curve) {
        f = x; want = curveAt(x) * num(@"trim", 1); maxPct = MAX_PCT;
    } else {
        f = x < num(@"deadband", 1.15) ? 1 : x; want = base * boost(f); maxPct = (int)num(@"max", 250);
    }
    int target = (int)lround(want / STEP) * STEP;
    target = MAX(100, MIN(maxPct, curve ? target : MAX(target, (int)base)));
    if (debugOn || !access("/tmp/distance_zoom.debug", F_OK))   // touch it: every sample logged
        logf_(@"width %.3f hand %.3f ×%.2f → %d%% (at %d)%s", width, hand, x, target, lastSet, busy() ? " busy" : "");
    [self writeState:[NSString stringWithFormat:@"%d", target] factor:x];

    int dir = (target > lastSet) - (target < lastSet);
    if (!dir) { pendingDir = 0; return; }
    if (dir != pendingDir) { pendingDir = dir; pendingSince = now; return; }
    // Small moves wait longer: within 6% of the level (one step at 100%, two at 230%) —
    // far away the width is a few pixels and the reading wanders more.
    double hold = abs(target - lastSet) <= MAX(STEP, 0.06 * lastSet) ? HOLD1_S : HOLD_S;
    if (now - pendingSince < hold || busy()) return;
    logf_(@"×%.2f → %d%%", x, target);
    appliedFactor = f;
    setLevel(target);                   // pendingDir stays: still walking → the next step follows
}

- (void)writeState:(NSString *)target factor:(double)factor {
    // base: what distance.sh off puts back — with steps, the first one's level.
    NSString *s = [NSString stringWithFormat:@"factor %.2f target %@ level %d base %.0f%@\n",
                   factor, target, lastSet, steps ? (double)stepLevel(0) : base,
                   steps ? [NSString stringWithFormat:@" step %d of %lu", curStep + 1, (unsigned long)steps.count]
                   : curveOn() ? [NSString stringWithFormat:@" curve %lu trim %.2f", (unsigned long)[cfg[@"curve"] count], num(@"trim", 1)] : @""];
    [s writeToFile:STATE atomically:NO encoding:NSUTF8StringEncoding error:nil];
    double left = stepPend >= 0 ? MAX(0, stepHold - (CACurrentMediaTime() - stepPendSince)) : 0;
    NSDictionary *live = @{ @"t": @(NSDate.date.timeIntervalSince1970), @"pid": @(getpid()),
                            @"x": isfinite(factor) ? @(factor) : NSNull.null, @"level": @(lastSet),
                            @"step": @(steps ? curStep : -1), @"pend": @(steps ? stepPend : -1), @"left": @(left) };
    [[NSJSONSerialization dataWithJSONObject:live options:0 error:nil] writeToFile:LIVE atomically:YES];
}

// ── The curve, from the panel ────────────────────────────────────────────────
- (void)beginCurve {
    dispatch_async(_q, ^{
        self->curving = YES;
        self->calib = nil;
        self->recUntil = 0;
        self->wantLevel = lastSet;      // a press since: tick adopts it
        if (!self->ci) self->ci = [CIContext contextWithOptions:nil];
        int lv = lastSet;
        NSDictionary *c = [self curveInfo:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.ui show:lv]; [self.ui curve:c]; });
        logf_(@"curve panel open (%lu points)", (unsigned long)[cfg[@"curve"] count]);
    });
}

- (void)endCurve {
    dispatch_async(_q, ^{
        if (!self->curving) return;
        self->curving = NO;
        self->recUntil = 0;
        [cfg removeObjectForKey:@"trim"];
        saveConfig();
        [self->recent removeAllObjects];
        [self resetGate];
        self->pendingDir = 0;
        self->curStep = self->stepPend = -1;   // the slider's level isn't a step's: pick again
        appliedFactor = NAN;            // the slider's level isn't the curve's: let it move
        logf_(@"curve panel closed — %@", curveOn() ? [NSString stringWithFormat:@"following the curve (%lu points)",
              (unsigned long)[cfg[@"curve"] count]] : @"under 2 points, the formula stays");
    });
}

- (void)want:(int)lv { dispatch_async(_q, ^{ self->wantLevel = lv; }); }

- (void)smooth:(double)v {
    dispatch_async(_q, ^{
        cfg[@"smooth"] = @(v);
        fitCurve(); saveConfig();
        [self tellCurve:nil];
    });
}

// Every 0.15 s while the panel is open: the slider's level goes out when the last glide
// has landed; a level changed elsewhere (⌘+/⌘−) moves the slider.
- (void)tick {
    dispatch_async(_q, ^{
        if (!self->curving || busy()) return;
        if (self->wantLevel != lastSet) { setLevel(self->wantLevel); return; }
        int lv = readLevel();
        if (lv != lastSet) {
            lastSet = self->wantLevel = lv;
            dispatch_async(dispatch_get_main_queue(), ^{ [self.ui follow:lv]; });
        }
    });
}

- (void)record:(int)lv {
    dispatch_async(_q, ^{
        double now = CACurrentMediaTime();
        self->recFrom = now + REC_WAIT_S; self->recUntil = self->recFrom + REC_S;
        self->recLevel = lv;
        self->recBody = [NSMutableArray new]; self->recHand = [NSMutableArray new];
    });
}

- (void)undoPoint {
    dispatch_async(_q, ^{
        NSMutableArray *pts = cfg[@"curve"];
        if (!pts.count) { [self tellCurve:@"No points to undo."]; return; }
        NSDictionary *gone = pts.lastObject;
        [pts removeLastObject];
        if (!pts.count) [cfg removeObjectForKey:@"curve"];
        fitCurve(); saveConfig();
        [self tellCurve:[NSString stringWithFormat:@"Dropped the %@%% point.", gone[@"level"]]];
    });
}

- (void)clearPoints {
    dispatch_async(_q, ^{
        [cfg removeObjectForKey:@"curve"];
        fitCurve(); saveConfig();
        [self tellCurve:@"Every point deleted — back to the formula until you record two."];
    });
}

- (NSDictionary *)curveInfo:(NSString *)say {
    NSMutableArray *pts = [NSMutableArray new];
    for (NSDictionary *p in cfg[@"curve"]) {
        BOOL h = [p[@"hand"] isKindOfClass:NSNumber.class];
        double x = fuse([p[@"body"] doubleValue], h ? [p[@"hand"] doubleValue] : NAN);
        [pts addObject:@[ @(x), p[@"level"], @(h) ]];
    }
    NSMutableDictionary *d = [@{ @"points": pts, @"knots": knots ?: @[], @"smooth": @(num(@"smooth", 0.3)) } mutableCopy];
    if (say) d[@"say"] = say;
    return d;
}
- (void)tellCurve:(NSString *)say {
    NSDictionary *d = [self curveInfo:say];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.ui curve:d]; });
}

- (void)curveSample:(Reading)r pb:(CVPixelBufferRef)pb pts:(NSArray *)pts now:(double)now {
    double x = fuse(r.body, r.hand);
    NSMutableDictionary *d = [@{
        @"body": @(r.body), @"hand": @(r.hand), @"hands": @(r.hands), @"x": @(x),
        @"xhand": @(xHand(r.hand)), @"curve": @(curveOn() ? curveAt(x) : NAN),
        @"band_top": @(num(@"band_top", 0.45)), @"band_bottom": @(num(@"band_bottom", 0.60)),
        @"pts": pts ?: @[],
    } mutableCopy];
    if (isfinite(r.body)) d[@"run"] = @[ @(r.runX0), @(r.runX1), @(r.runY) ];
    CIImage *im = [CIImage imageWithCVPixelBuffer:pb];
    CGImageRef cg = [ci createCGImage:im fromRect:im.extent];
    if (cg) d[@"img"] = CFBridgingRelease(cg);

    if (recUntil > 0) {
        d[@"rec"] = @(recUntil - now);
        if (now >= recFrom) {
            if (isfinite(r.body)) [recBody addObject:@(r.body)];
            if (isfinite(r.hand)) [recHand addObject:@(r.hand)];
        }
        if (now >= recUntil) { recUntil = 0; [d removeObjectForKey:@"rec"]; [self finishRecording]; }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self.ui live:d]; });
}

- (void)finishRecording {
    int frames = (int)lround(REC_S / SAMPLE_S);
    if ((int)recBody.count < frames / 2) {
        [self tellCurve:@"Couldn't see you for long enough — not recorded. Stay in view and try again."];
        return;
    }
    NSMutableDictionary *p = [@{ @"body": @(median(recBody)), @"body_cv": @(round(1000 * relSpread(recBody)) / 1000),
                                 @"level": @(recLevel) } mutableCopy];
    BOOL hands = (int)recHand.count >= frames / 2;
    if (hands) { p[@"hand"] = @(median(recHand)); p[@"hand_cv"] = @(round(1000 * relSpread(recHand)) / 1000); }
    NSMutableArray *pts = cfg[@"curve"] ?: [NSMutableArray new];
    [pts addObject:p];
    cfg[@"curve"] = pts;
    fitCurve(); saveConfig();
    double x = fuse([p[@"body"] doubleValue], hands ? [p[@"hand"] doubleValue] : NAN);
    logf_(@"curve point %lu: ×%.2f → %d%% (body %.3f%@)", (unsigned long)pts.count, x, recLevel,
          [p[@"body"] doubleValue], hands ? [NSString stringWithFormat:@", hand %.3f", [p[@"hand"] doubleValue]] : @"");
    NSString *more = pts.count < 2 ? @" One more at another distance and the curve is on."
                   : [NSString stringWithFormat:@" Hands count for %.0f%% of the reading.", 100 * num(@"hand_share", 0)];
    if (!cfg[@"hand_seat"]) more = pts.count < 2 ? more : @" Body only (no hands seen in the points).";
    [self tellCurve:[NSString stringWithFormat:@"Point %lu: ×%.2f → %d%%%@.%@", (unsigned long)pts.count, x, recLevel,
                     hands ? @" with hands" : @"", more]];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        debugOn = argc > 1 && !strcmp(argv[1], "--debug");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        loadConfig();
        fitCurve();
        lastSet = readLevel();
        setBase(num(@"base", lastSet));
        appliedFactor = curveOn() ? NAN : 1 + (MAX(1.0, lastSet / base) - 1) / num(@"gain", 0.75);

        Watcher *w = [Watcher new];
        Calib *ui = [Calib new];
        w.ui = ui; ui.w = w;
        void (^go)(void) = ^{
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL ok) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!ok) { logf_(@"no camera permission (System Settings ▸ Privacy & Security ▸ Camera)"); exit(3); }
                    if (![w start]) exit(4);
                });
            }];
        };
        go();

        // `ui_zoom/distance.sh snap | calibrate | curve`
        int tok;
        notify_register_dispatch("com.callis.distancezoom.snap", &tok, dispatch_get_main_queue(),
                                 ^(int t) { [w snap]; });
        notify_register_dispatch("com.callis.distancezoom.calibrate", &tok, dispatch_get_main_queue(),
                                 ^(int t) { [w calibrate]; });
        notify_register_dispatch("com.callis.distancezoom.curve", &tok, dispatch_get_main_queue(),
                                 ^(int t) { [w beginCurve]; });
        // Locked: let go of the camera; unlocked: take it back.
        NSDistributedNotificationCenter *dnc = NSDistributedNotificationCenter.defaultCenter;
        [dnc addObserverForName:@"com.apple.screenIsLocked" object:nil queue:NSOperationQueue.mainQueue
                     usingBlock:^(NSNotification *n) { [w stop]; }];
        [dnc addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:NSOperationQueue.mainQueue
                     usingBlock:^(NSNotification *n) { [w start]; }];

        [NSApp run];
    }
    return 0;
}

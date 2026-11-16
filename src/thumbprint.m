/* thumbprint — learn how to tell the thumb from a finger on a trackpad, for the trackpad keyboard.

   A thumb alone on the pad can't be told by where it is on the pad, so remapd judges
   a lone contact two ways (bin/auxgest.h agLoneThumb):
   - SHAPE: the thumb's edge is a long, skinny, slanted footprint, a fingertip a rounder one;
   - CONTEXT: where it landed relative to the fingers' landings of the last few seconds
     (far off to the thumb's side = thumb; back where a swipe began = a finger coming
     back to repeat it).
   This runs a guided session of REAL gestures in sequence — taps, swipes, repeated
   swipes, multi-finger swipes, thumb taps and swipes — so the context is the one you
   type in, then writes both models to remap/thumbprint.json; remapd reloads it.
   While it runs the pads neither point nor type (/tmp/remapd_calibrating, kept fresh),
   and a gesture that isn't the one asked for (wrong way, a tap for a swipe) is
   dropped and asked for again.

     thumbprint left     the aux pad (left hand)        [default]
     thumbprint right    the main pad (right hand)
     thumbprint left|right group   the thumb swiping WITH fingers (pinched / bunched / apart)
     thumbprint left|right roll [3L] finger ROLLS vs taps (3L: mostly 3-finger rolls ←) (rolls read as a 2-finger tap / right-click)
     thumbprint right spread   thumb + 3 spreading / pinching vs 4-finger swipes: replays each through auxgest, logs frames
     thumbprint left|right thumbtap   taps by a resting thumb (thumbtap<n>): replays each through auxgest, learns <side>.rest
     thumbprint left|right thumbtap refit <frames.jsonl> [drop 3,32]   refit from a recorded session, no pads
     thumbprint left hold    what RESTS on the left pad (right-pad modifier): fingertips / thumb / knuckles / palm; learns left.hold
     thumbprint left hold refit <hold_calib_left.jsonl>   refit from a recorded session, no pads
     thumbprint left idle [seconds]   the hand just RESTING on the left pad while you use the right (120 s): learnt as nothing
     thumbprint left combo [1 2 3 3t 4 4t]   hold a combination on the left while using the right pad: every right touch is a positive
     thumbprint left|right rest   FINGERS resting on the pad + others tapping / swiping by them, and the
                             thumb resting (rest<r>:…, restthumb:…): records where each digit lands
                             relative to the resting ones (THE LAYOUT), learns <side>.restsec
     thumbprint left|right rest refit <rest_calib.jsonl>   refit from a recorded session, no pads
     thumbprint right lone   the thumb ALONE: swipes ← → and taps vs one finger's; learns <side>.lone
                             (the left pad mirrors the right's unless `thumbprint left lone` is run)

   Build: bin/build.sh thumbprint  (→ ~/bin/thumbprint) */
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <sys/time.h>

typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint pos, vel; } mtReadout;
typedef struct {
    int frame; double timestamp; int identifier, state, foo3, foo4;
    mtReadout normalized; float size; int zero1;
    float angle, majorAxis, minorAxis; mtReadout mm; int zero2[2]; float unk2;
} Finger;
typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, Finger *, int, double, int);
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
#include "auxpad.h"
#include "auxgest.h"

#define WINDOW   3.0    // seconds a finger landing counts as context
#define MAXS     128
#define MAXT     12

/* ── Touches: the gesture under way, handed over once every contact has been off a moment ── */
typedef struct { int id; float x0, y0, x, y, pk[4], move, sz0, szMax; double t0, t1; int frames; bool live; AgSettle st; } Tr;
// A contact's SETTLED shape (auxgest.h agSettleFrame), as remapd's hold reads it.
#define TSH(t) (t).st.major, (t).st.minor, (t).st.angle, (t).st.size
static pthread_mutex_t gMu = PTHREAD_MUTEX_INITIALIZER;
static Tr gTr[MAXT]; static int gNT = 0;
static double gLift = 0;          // when the last contact lifted (0 = a gesture is under way / none)
static bool gArmed = false;       // the session wants gestures
static bool gPrune = false;       // hold session: only LIVE contacts kept (a palm may never lift)
static double gChange = 0;        // hold session: when a contact last landed or lifted

// Every contact frame of the gesture under way (spread session only).
#define MAXF 4000
typedef struct { double t; int n; AgContact c[AG_MAX]; } RecF;
static RecF gF[MAXF]; static int gNF = 0;
static bool gRec = false;
static RecF gFOut[MAXF]; static int gNFOut = 0;   // the last gesture's frames, taken by nextGesture

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

// The OTHER pad (combo session): how many contacts are on it right now.
static _Atomic int gOtherN = 0;
static int otherTouch(MTDeviceRef dev, Finger *f, int n, double ts, int frame) {
    (void)dev; (void)ts; (void)frame;
    int live = 0;
    for (int i = 0; i < n; i++) live += f[i].state >= 4 && f[i].state <= 5;
    atomic_store(&gOtherN, live);
    return 0;
}
static int touch(MTDeviceRef dev, Finger *f, int n, double ts, int frame) {
    (void)dev; (void)ts; (void)frame;   // only that side's devices are registered
    double t = now();
    pthread_mutex_lock(&gMu);
    if (!gArmed) { pthread_mutex_unlock(&gMu); return 0; }
    for (int j = 0; j < gNT; j++) gTr[j].live = false;
    int live = 0;
    for (int i = 0; i < n; i++) {
        if (f[i].state < 4 || f[i].state > 5) continue;
        live++;
        Tr *tr = NULL;
        for (int j = 0; j < gNT; j++) if (gTr[j].id == f[i].identifier && gTr[j].t1 >= t - 0.05) tr = &gTr[j];
        if (!tr) {
            if (gNT >= MAXT) continue;
            if (!gNT) { printf("   ·"); fflush(stdout); gNF = 0; }   // a touch arrived
            tr = &gTr[gNT++];
            *tr = (Tr){ .id = f[i].identifier, .x0 = f[i].normalized.pos.x, .y0 = f[i].normalized.pos.y, .t0 = t };
            gChange = t;
        }
        agSettleFrame(&tr->st, !tr->frames, f[i].normalized.pos.x, f[i].normalized.pos.y, f[i].majorAxis, f[i].minorAxis, f[i].angle, f[i].size, t);
        if (!tr->frames) tr->sz0 = f[i].size;   // for the roll session's landing speed (agLand)
        tr->szMax = fmaxf(tr->szMax, f[i].size);
        tr->x = f[i].normalized.pos.x; tr->y = f[i].normalized.pos.y; tr->t1 = t; tr->live = true; tr->frames++;
        float mv = hypotf(tr->x - tr->x0, tr->y - tr->y0);
        tr->move = fmaxf(tr->move, mv);
        if (agShapeFrame(tr->frames, mv) && f[i].size >= tr->pk[3]) {   // remapd reads it the same way
            tr->pk[0] = f[i].majorAxis; tr->pk[1] = f[i].minorAxis; tr->pk[2] = f[i].angle; tr->pk[3] = f[i].size;
        }
    }
    if (gRec && gNT && gNF < MAXF) {   // the spread session replays every frame through auxgest
        RecF *rf = &gF[gNF++];
        rf->t = t; rf->n = 0;
        for (int i = 0; i < n && rf->n < AG_MAX; i++)
            if (f[i].state >= 4 && f[i].state <= 5)
                rf->c[rf->n++] = (AgContact){ f[i].identifier, f[i].normalized.pos.x, f[i].normalized.pos.y,
                                              f[i].majorAxis, f[i].minorAxis, f[i].angle, f[i].size };
    }
    if (gPrune) {
        int k = 0;
        for (int j = 0; j < gNT; j++) if (gTr[j].live) gTr[k++] = gTr[j];
        if (k < gNT) gChange = t;
        gNT = k;
    }
    if (live) gLift = 0;
    else if (gNT && !gLift) gLift = t;
    pthread_mutex_unlock(&gMu);
    return 0;
}

// Wait for the next whole gesture (all contacts off for 150 ms) and take it.
static int nextGesture(Tr *out) {
    for (;;) {
        usleep(20000);
        pthread_mutex_lock(&gMu);
        if (gNT && gLift && now() - gLift > 0.15) {
            int n = gNT;
            memcpy(out, gTr, sizeof(Tr) * n);
            if (gRec) { memcpy(gFOut, gF, sizeof(RecF) * gNF); gNFOut = gNF; }
            gNT = 0; gLift = 0;
            pthread_mutex_unlock(&gMu);
            return n;
        }
        pthread_mutex_unlock(&gMu);
    }
}

/* ── The script ── */
enum { K_FINGER = 0, K_THUMB = 1, K_MULTI = 2 };   // a lone finger / the thumb (both samples) / context only
enum { M_TAP, M_LEFT, M_RIGHT, M_UP, M_DOWN, M_SIDE };   // what the gesture must do
typedef struct { int kind, n, mv; char text[96]; } Step;
static Step gSteps[96]; static int gNS = 0;
static void add(int kind, int n, NSString *text) {
    int mv = [text containsString:@"tap"] ? M_TAP : [text containsString:@"sideways"] ? M_SIDE
           : [text containsString:@"LEFT"] ? M_LEFT : [text containsString:@"RIGHT"] ? M_RIGHT
           : [text containsString:@"UP"] ? M_UP : M_DOWN;
    gSteps[gNS] = (Step){ kind, n, mv, "" };
    strlcpy(gSteps[gNS].text, text.UTF8String, sizeof gSteps[gNS].text);
    gNS++;
}
static NSString *dir(void) { return @[@"LEFT", @"RIGHT", @"UP", @"DOWN"][arc4random_uniform(4)]; }
// Units, shuffled: a repeat run stays together (the finger lifting back to swipe again).
static void script(void) {
    NSMutableArray<NSArray *> *units = [NSMutableArray array];
    for (int i = 0; i < 8; i++) [units addObject:@[@[@(K_THUMB), @1, @"THUMB — tap"]]];
    for (int i = 0; i < 8; i++) [units addObject:@[@[@(K_THUMB), @1, @"THUMB — swipe sideways"]]];
    for (int i = 0; i < 4; i++) {
        NSString *d = dir();
        NSString *a = [NSString stringWithFormat:@"1 finger — swipe %@", d];
        NSString *b = [NSString stringWithFormat:@"1 finger — swipe %@ again (lift, go back, repeat)", d];
        [units addObject:@[@[@(K_FINGER), @1, a], @[@(K_FINGER), @1, b], @[@(K_FINGER), @1, b]]];
    }
    for (int i = 0; i < 8; i++)
        [units addObject:@[@[@(K_FINGER), @1, [NSString stringWithFormat:@"1 finger — swipe %@", dir()]]]];
    for (int i = 0; i < 4; i++) [units addObject:@[@[@(K_FINGER), @1, @"1 finger — tap"]]];
    for (int i = 0; i < 8; i++) {
        int n = 2 + (int)arc4random_uniform(3);
        [units addObject:@[@[@(K_MULTI), @(n), [NSString stringWithFormat:@"%d fingers — swipe %@", n, dir()]]]];
    }
    for (NSUInteger i = units.count; i > 1; i--) [units exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    for (NSArray *u in units) for (NSArray *s in u) add([s[0] intValue], [s[1] intValue], s[2]);
}

// Did the gesture do what was asked? NULL = yes, else what it did instead.
static const char *mismatch(const Step *st, const Tr *t, int n) {
    float dx = 0, dy = 0;
    for (int k = 0; k < n; k++) { dx += (t[k].x - t[k].x0) / n; dy += (t[k].y - t[k].y0) / n; }
    float ax = fabsf(dx), ay = fabsf(dy);
    const char *did = fmaxf(ax, ay) < AG_SWIPE ? (fmaxf(ax, ay) < AG_TAP_MOVE ? "a tap" : "too short a swipe")
                    : ax > ay ? (dx < 0 ? "a swipe left" : "a swipe right") : (dy > 0 ? "a swipe up" : "a swipe down");
    bool ok;
    switch (st->mv) {
        case M_TAP:   ok = fmaxf(ax, ay) < AG_TAP_MOVE; break;
        case M_SIDE:  ok = ax >= AG_SWIPE && ax > 1.2f * ay; break;
        case M_LEFT:  ok = dx <= -AG_SWIPE && ax > 1.2f * ay; break;
        case M_RIGHT: ok = dx >= AG_SWIPE && ax > 1.2f * ay; break;
        case M_UP:    ok = dy >= AG_SWIPE && ay > 1.2f * ax; break;
        default:      ok = dy <= -AG_SWIPE && ay > 1.2f * ax; break;
    }
    return ok ? NULL : did;
}

/* ── Samples and the fit ── */
typedef struct { float f[AGF]; bool has; float dx, dy; double age; int c; } Sample;
static Sample gS[MAXS]; static int gN = 0;

// Both models from every sample but `skip` (-1 = none). False = a class too thin to fit.
static bool fit(AgPrint *p, int skip) {
    *p = (AgPrint){ .ok = true, .window = WINDOW };
    for (int c = 0; c < 2; c++) {
        double s[AGF] = {0}, ss[AGF] = {0}, cs[2] = {0}, css[2] = {0}; int n = 0, cn = 0;
        for (int k = 0; k < gN; k++) {
            if (k == skip || gS[k].c != c) continue;
            n++;
            for (int i = 0; i < AGF; i++) { s[i] += gS[k].f[i]; ss[i] += gS[k].f[i] * gS[k].f[i]; }
            if (gS[k].has && gS[k].age < WINDOW) {
                float v[2] = { gS[k].dx, gS[k].dy };
                cn++;
                for (int i = 0; i < 2; i++) { cs[i] += v[i]; css[i] += v[i] * v[i]; }
            }
        }
        if (n < 3) return false;
        for (int i = 0; i < AGF; i++) {
            double mu = s[i] / n;
            p->mu[c][i] = (float)mu;
            p->sd[c][i] = fmaxf(sqrtf((float)fmax(ss[i] / n - mu * mu, 0)), 0.02f);
        }
        if (cn < 4) { p->ctxOk = false; continue; }
        if (c == 0) p->ctxOk = true;
        for (int i = 0; i < 2; i++) {
            double mu = cs[i] / cn;
            p->cmu[c][i] = (float)mu;
            p->csd[c][i] = fmaxf(sqrtf((float)fmax(css[i] / cn - mu * mu, 0)), 0.03f);
        }
    }
    return true;
}

// The pads stay silent in remapd while this file is fresh (remapd.m gCalib).
static const char *kCalibFile = "/tmp/remapd_calibrating";
static void calibOff(void) { unlink(kCalibFile); }
static void calibSig(int sig) { (void)sig; unlink(kCalibFile); _exit(130); }
static void calibOn(void) {
    atexit(calibOff);
    signal(SIGINT, calibSig); signal(SIGTERM, calibSig); signal(SIGHUP, calibSig);
    [NSThread detachNewThreadWithBlock:^{
        for (;;) { int fd = open(kCalibFile, O_CREAT | O_WRONLY, 0644); if (fd >= 0) { futimes(fd, NULL); close(fd); } sleep(1); }
    }];
}

// The LEFT pad only (combo / idle, 2026-10-21): remapd fires none of its gestures (a tap was
// Return — it moved a combo on) and reads no modifier from it; the right pad works plain.
static const char *kCalibLeftFile = "/tmp/remapd_calibrating_left";
static void calibLeftOff(void) { unlink(kCalibLeftFile); }
static void calibLeftSig(int sig) { (void)sig; unlink(kCalibLeftFile); _exit(130); }
static void calibLeftOn(void) {
    atexit(calibLeftOff);
    signal(SIGINT, calibLeftSig); signal(SIGTERM, calibLeftSig); signal(SIGHUP, calibLeftSig);
    [NSThread detachNewThreadWithBlock:^{
        for (;;) { int fd = open(kCalibLeftFile, O_CREAT | O_WRONLY, 0644); if (fd >= 0) { futimes(fd, NULL); close(fd); } sleep(1); }
    }];
    // Wait for remapd to see it (it checks about every second) before anything is read.
    sleep(2);
}

static void session(const char *side) {
    @autoreleasepool {
    script();
    calibOn();
    printf("Thumbprint — the %s pad: %d gestures, one at a time, the way you'd type them.\n", side, gNS);
    printf("Go at a typing pace: what came just before each gesture is part of what it learns.\n");
    printf("The pads don't click or type while this runs (the pointer still moves). Ctrl-C to stop.\n");
    AgHist hist = {0};
    pthread_mutex_lock(&gMu); gArmed = true; pthread_mutex_unlock(&gMu);
    for (int i = 0; i < gNS; ) {
        Step *st = &gSteps[i];
        printf("\n[%2d/%d]  %s\n", i + 1, gNS, st->text); fflush(stdout);
        Tr t[MAXT]; int n = nextGesture(t);
        if (n != st->n) { printf("   got %d contact%s, wanted %d — again\n", n, n == 1 ? "" : "s", st->n); continue; }
        const char *wrong = mismatch(st, t, n);
        if (wrong) { printf("   that was %s — skipped, again\n", wrong); continue; }
        if (st->kind != K_MULTI) {
            if (t[0].frames < 3) { printf("   too quick to read — again\n"); continue; }
            Sample *s = &gS[gN];
            agFeatures(t[0].pk[0], t[0].pk[1], t[0].pk[2], t[0].pk[3], s->f);
            s->has = agHistNearest(&hist, t[0].x0, t[0].y0, t[0].t0, WINDOW, &s->dx, &s->dy, &s->age);
            s->c = st->kind == K_THUMB;
            if (gN < MAXS - 1) gN++;
            printf("   %s  length %.1f width %.1f size %.2f", s->c ? "thumb " : "finger", t[0].pk[0], t[0].pk[1], t[0].pk[3]);
            if (s->has) printf("   from last finger: %+.2f across %+.2f up, %.1fs ago", s->dx, s->dy, s->age);
            printf("\n");
        } else printf("   ok\n");
        if (st->kind != K_THUMB)   // the fingers' landings are the context for what follows
            for (int k = 0; k < n; k++) agHistAdd(&hist, t[k].x0, t[k].y0, t[k].t1);
        fflush(stdout);
        i++;
    }
    pthread_mutex_lock(&gMu); gArmed = false; pthread_mutex_unlock(&gMu);

    // How well it tells them apart: each sample judged by models made without it.
    int shapeRight = 0, bothRight = 0;
    for (int k = 0; k < gN; k++) {
        AgPrint p;
        if (!fit(&p, k)) continue;
        bool want = gS[k].c == 1;
        if ((agPrintScore(&p, gS[k].f) > 0) == want) shapeRight++;
        bool got = agScoreWith(&p, gS[k].f, gS[k].has, gS[k].dx, gS[k].dy, gS[k].age) > 0;
        if (got == want) bothRight++;
        else printf("   would misread sample %d (%s)\n", k + 1, want ? "thumb" : "finger");
    }
    AgPrint p;
    if (!fit(&p, -1)) { fprintf(stderr, "too few samples to fit\n"); exit(1); }
    printf("\nTold apart: %d / %d by shape alone, %d / %d with the recent fingers (each judged without itself).\n",
           shapeRight, gN, bothRight, gN);
    static const char *names[AGF] = { "log length", "log width", "cos 2·angle", "sin 2·angle", "log size" };
    printf("   %-14s %18s %18s\n", "", "finger (mean ± sd)", "thumb (mean ± sd)");
    for (int i = 0; i < AGF; i++)
        printf("   %-14s %10.2f ± %-6.2f %10.2f ± %-6.2f\n", names[i], p.mu[0][i], p.sd[0][i], p.mu[1][i], p.sd[1][i]);
    if (p.ctxOk) {
        static const char *cn[2] = { "from finger →", "from finger ↑" };
        for (int i = 0; i < 2; i++)
            printf("   %-14s %10.2f ± %-6.2f %10.2f ± %-6.2f\n", cn[i], p.cmu[0][i], p.csd[0][i], p.cmu[1][i], p.csd[1][i]);
    } else printf("   (too few gestures with a recent finger before them: context not learnt)\n");

    NSString *path = @"/Users/josh/Code/Scripts/remap/thumbprint.json";
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *doc = d ? [[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:NULL] mutableCopy] : nil;
    if (![doc isKindOfClass:NSMutableDictionary.class]) doc = [NSMutableDictionary dictionary];
    doc[@"_doc"] = @"Thumb vs finger per pad, written by bin/thumbprint: contact SHAPE (bin/auxgest.h agFeatures) and CONTEXT (offset from the nearest finger landing within `window` s, faded by age). remapd reloads it. Re-run `thumbprint left|right` to relearn.";
    NSMutableDictionary *h = [NSMutableDictionary dictionary], *cx = [NSMutableDictionary dictionary];
    NSArray *cls = @[@"finger", @"thumb"];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    for (int c = 0; c < 2; c++) {
        NSMutableArray *mu = [NSMutableArray array], *sd = [NSMutableArray array];
        for (int i = 0; i < AGF; i++) { [mu addObject:r4(p.mu[c][i])]; [sd addObject:r4(p.sd[c][i])]; }
        int n = 0; for (int k = 0; k < gN; k++) n += gS[k].c == c;
        h[cls[c]] = @{ @"mu": mu, @"sd": sd, @"n": @(n) };
        if (p.ctxOk) cx[cls[c]] = @{ @"mu": @[r4(p.cmu[c][0]), r4(p.cmu[c][1])], @"sd": @[r4(p.csd[c][0]), r4(p.csd[c][1])] };
    }
    if (p.ctxOk) { cx[@"window"] = @(WINDOW); h[@"ctx"] = cx; }
    h[@"accuracy"] = [NSString stringWithFormat:@"shape %d/%d, with context %d/%d", shapeRight, gN, bothRight, gN];
    h[@"learnt"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    for (NSString *part in @[@"group", @"roll"])   // learnt apart
        if ([doc[@(side)] isKindOfClass:NSDictionary.class] && doc[@(side)][part]) h[part] = doc[@(side)][part];
    doc[@(side)] = h;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:path atomically:YES]) { fprintf(stderr, "could not write %s\n", path.UTF8String); exit(1); }
    printf("\nSaved → remap/thumbprint.json (%s). remapd picks it up now.\n", side);
    }
    exit(0);
}

/* ── GROUP: the thumb swiping WITH fingers (2026-10-17) ──
   Thumb + 1–3 fingers moving together, pinched or apart, against plain finger swipes of
   the same contact counts. Every contact is a sample (agGroupFeatures: shape + where it
   landed from the others); the thumb in a thumb gesture is the contact furthest to the
   thumb's side (low, and toward the other pad). Saved as <side>.group. */
typedef struct { float f[AGG]; int c, gest; } GSample;
static GSample gG[MAXS * 4]; static int gGN = 0;
static int gThumbAt[MAXS];       // per gesture: the thumb's contact index, -1 = none
static int gGestN[MAXS];         // per gesture: its contact count
static int gGest = 0;

static bool gfit(AgPrint *p, int skip) {
    p->grpOk = true;
    for (int c = 0; c < 2; c++) {
        double s[AGG] = {0}, ss[AGG] = {0}; int n = 0;
        for (int k = 0; k < gGN; k++) {
            if (gG[k].gest == skip || gG[k].c != c) continue;
            n++;
            for (int i = 0; i < AGG; i++) { s[i] += gG[k].f[i]; ss[i] += gG[k].f[i] * gG[k].f[i]; }
        }
        if (n < 4) { p->grpOk = false; return false; }
        for (int i = 0; i < AGG; i++) {
            double mu = s[i] / n;
            p->gmu[c][i] = (float)mu;
            p->gsd[c][i] = fmaxf(sqrtf((float)fmax(ss[i] / n - mu * mu, 0)), i < AGF ? 0.02f : 0.01f);
        }
    }
    return true;
}
// One gesture's contacts → samples (as remapd's agGroupThumb sees them).
static int gAdd(const Tr *t, int n, int thumb) {
    float pk[MAXT][4], xy[MAXT][2];
    for (int i = 0; i < n; i++) { memcpy(pk[i], t[i].pk, sizeof pk[i]); xy[i][0] = t[i].x0; xy[i][1] = t[i].y0; }
    for (int i = 0; i < n && gGN < MAXS * 4; i++) {
        GSample *s = &gG[gGN++];
        agGroupFeatures(pk, xy, n, i, s->f);
        s->c = i == thumb; s->gest = gGest;
    }
    gThumbAt[gGest] = thumb; gGestN[gGest] = n;
    return gGest++;
}
// What the model makes of gesture `gi` (fit without it): the thumb's index or -1.
static int gJudge(const AgPrint *p, int gi) {
    int bi = -1; float bs = 0;
    for (int k = 0, i = 0; k < gGN; k++) {
        if (gG[k].gest != gi) continue;
        float sc = agGroupScore(p, gG[k].f);
        if (sc > bs) { bs = sc; bi = i; }
        i++;
    }
    return bi;
}
static void groupScript(void) {
    NSMutableArray<NSArray *> *u = [NSMutableArray array];
    NSArray *lr = @[@"LEFT", @"RIGHT"];
    for (int i = 0; i < 8; i++) [u addObject:@[@(K_THUMB), @2, [NSString stringWithFormat:@"THUMB + forefinger PINCHED together — swipe %@", lr[i % 2]]]];
    for (int i = 0; i < 4; i++) [u addObject:@[@(K_THUMB), @2, [NSString stringWithFormat:@"THUMB + 1 finger, apart — swipe %@", lr[i % 2]]]];
    for (int i = 0; i < 4; i++) [u addObject:@[@(K_THUMB), @3, [NSString stringWithFormat:@"THUMB + 2 fingers — swipe %@", lr[i % 2]]]];
    for (int i = 0; i < 4; i++) [u addObject:@[@(K_THUMB), @4, [NSString stringWithFormat:@"THUMB + 3 fingers BUNCHED — swipe %@", lr[i % 2]]]];
    for (int i = 0; i < 4; i++) [u addObject:@[@(K_THUMB), @4, [NSString stringWithFormat:@"THUMB + 3 fingers, apart — swipe %@", lr[i % 2]]]];
    for (int i = 0; i < 6; i++) [u addObject:@[@(K_MULTI), @2, [NSString stringWithFormat:@"2 fingers (no thumb) — swipe %@", i < 4 ? lr[i % 2] : dir()]]];
    for (int i = 0; i < 2; i++) [u addObject:@[@(K_MULTI), @2, [NSString stringWithFormat:@"2 fingers TOGETHER (no thumb) — swipe %@", lr[i % 2]]]];
    for (int i = 0; i < 4; i++) [u addObject:@[@(K_MULTI), @3, [NSString stringWithFormat:@"3 fingers (no thumb) — swipe %@", i < 2 ? lr[i % 2] : dir()]]];
    for (int i = 0; i < 6; i++) [u addObject:@[@(K_MULTI), @4, [NSString stringWithFormat:@"4 fingers (no thumb) — swipe %@", i < 4 ? lr[i % 2] : dir()]]];
    for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    for (NSArray *s in u) add([s[0] intValue], [s[1] intValue], s[2]);
}
static void groupSession(const char *side) {
    @autoreleasepool {
    bool left = !strcmp(side, "left");
    groupScript();
    calibOn();
    printf("Thumbprint GROUP — the %s pad: %d swipes with the thumb moving along (or no thumb).\n", side, gNS);
    printf("Do them the way you will for real: pinched, bunched or apart as asked. Ctrl-C to stop.\n");
    pthread_mutex_lock(&gMu); gArmed = true; pthread_mutex_unlock(&gMu);
    for (int i = 0; i < gNS; ) {
        Step *st = &gSteps[i];
        printf("\n[%2d/%d]  %s\n", i + 1, gNS, st->text); fflush(stdout);
        Tr t[MAXT]; int n = nextGesture(t);
        if (n != st->n) { printf("   got %d contact%s, wanted %d — again\n", n, n == 1 ? "" : "s", st->n); continue; }
        const char *wrong = mismatch(st, t, n);
        if (wrong) { printf("   that was %s — skipped, again\n", wrong); continue; }
        bool quick = false;
        for (int k = 0; k < n; k++) if (t[k].frames < 3) quick = true;
        if (quick) { printf("   too quick to read — again\n"); continue; }
        int th = -1;
        if (st->kind == K_THUMB) {   // the thumb: lowest, leaning toward the other pad
            float bs = -1e9f;
            for (int k = 0; k < n; k++) {
                float s = -t[k].y0 + 0.5f * (left ? t[k].x0 : -t[k].x0);
                if (s > bs) { bs = s; th = k; }
            }
        }
        gAdd(t, n, th);
        if (th >= 0) {
            float ox = 0, oy = 0;
            for (int k = 0; k < n; k++) if (k != th) { ox += t[k].x0 / (n - 1); oy += t[k].y0 / (n - 1); }
            printf("   thumb %+.2f across %+.2f up from the fingers, length %.1f width %.1f\n",
                   t[th].x0 - ox, t[th].y0 - oy, t[th].pk[0], t[th].pk[1]);
        } else printf("   ok\n");
        fflush(stdout);
        i++;
    }
    pthread_mutex_lock(&gMu); gArmed = false; pthread_mutex_unlock(&gMu);

    int right = 0;
    for (int gi = 0; gi < gGest; gi++) {
        AgPrint p = {0};
        if (!gfit(&p, gi)) continue;
        int got = gJudge(&p, gi);
        if (got == gThumbAt[gi]) right++;
        else printf("   would misread gesture %d (%d contacts, %s → %s)\n", gi + 1, gGestN[gi],
                    gThumbAt[gi] >= 0 ? "thumb" : "no thumb", got >= 0 ? (gThumbAt[gi] >= 0 ? "wrong contact" : "a thumb") : "no thumb");
    }
    AgPrint p = {0};
    if (!gfit(&p, -1)) { fprintf(stderr, "too few samples to fit\n"); exit(1); }
    printf("\nThumb found right in %d / %d gestures (each judged without itself).\n", right, gGest);

    NSString *path = @"/Users/josh/Code/Scripts/remap/thumbprint.json";
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *doc = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:NULL] : nil;
    if (![doc isKindOfClass:NSMutableDictionary.class]) doc = [NSMutableDictionary dictionary];
    NSMutableDictionary *h = [doc[@(side)] isKindOfClass:NSMutableDictionary.class] ? doc[@(side)] : [NSMutableDictionary dictionary];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    NSMutableDictionary *gp = [NSMutableDictionary dictionary];
    NSArray *cls = @[@"finger", @"thumb"];
    for (int c = 0; c < 2; c++) {
        NSMutableArray *mu = [NSMutableArray array], *sd = [NSMutableArray array];
        for (int i = 0; i < AGG; i++) { [mu addObject:r4(p.gmu[c][i])]; [sd addObject:r4(p.gsd[c][i])]; }
        int n = 0; for (int k = 0; k < gGN; k++) n += gG[k].c == c;
        gp[cls[c]] = @{ @"mu": mu, @"sd": sd, @"n": @(n) };
    }
    gp[@"accuracy"] = [NSString stringWithFormat:@"%d/%d gestures", right, gGest];
    gp[@"learnt"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    h[@"group"] = gp;
    doc[@(side)] = h;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:path atomically:YES]) { fprintf(stderr, "could not write %s\n", path.UTF8String); exit(1); }
    printf("\nSaved → remap/thumbprint.json (%s.group). remapd picks it up now.\n", side);
    }
    exit(0);
}

/* ── ROLL: rolls vs taps (2026-10-17) ──
   Fingers rolled on one after another vs tapped together, plus a few 2-finger swipes
   (a learnt roll must not eat them). Fits the pad's roll rules (auxgest.h AgRoll) —
   the landing gap that splits them, and how slow / drifting / soft a roll may be —
   then judges every recorded gesture with agName, before and after. Saved as <side>.roll. */
enum { R_TAP = 10, R_ROLLR, R_ROLLL, R_SWIPE };
typedef struct { AgTrack t[MAXT]; int k, kind, mv; } RSample;
static RSample gR[128]; static int gRN = 0;

static void toTracks(const Tr *in, int n, AgTrack *out) {
    for (int i = 0; i < n; i++)
        out[i] = (AgTrack){ .id = in[i].id, .x0 = in[i].x0, .y0 = in[i].y0, .x = in[i].x, .y = in[i].y,
                            .move = in[i].move, .t0 = in[i].t0, .t1 = in[i].t1, .frames = in[i].frames,
                            .pkMajor = in[i].pk[0], .pkMinor = in[i].pk[1], .pkAngle = in[i].pk[2], .pkSize = in[i].pk[3],
                            .sz0 = in[i].sz0, .szMax = in[i].szMax };
    qsort(out, n, sizeof *out, agByT0);
}
static double gapMin(const RSample *s) { double g = 1e9; for (int i = 1; i < s->k; i++) g = fmin(g, s->t[i].t0 - s->t[i - 1].t0); return g; }
static double gapMax(const RSample *s) { double g = 0;   for (int i = 1; i < s->k; i++) g = fmax(g, s->t[i].t0 - s->t[i - 1].t0); return g; }
static double durOf(const RSample *s)  { double e = 0;   for (int i = 0; i < s->k; i++) e = fmax(e, s->t[i].t1); return e - s->t[0].t0; }
static float moveOf(const RSample *s)  { float m = 0;    for (int i = 0; i < s->k; i++) m = fmaxf(m, s->t[i].move); return m; }
static bool isRoll(int kind) { return kind == R_ROLLR || kind == R_ROLLL; }

// Is agName's reading what was asked? Fills `got`.
static bool rJudge(const RSample *s, const AgRoll *r, char *got, size_t n) {
    char detail[160];
    agName(s->t, s->k, NULL, r, NULL, got, n, detail, sizeof detail);
    switch (s->kind) {
        case R_TAP:   return !strncmp(got, "tap", 3);
        case R_ROLLR: return !strncmp(got, "rollR", 5);
        case R_ROLLL: return !strncmp(got, "rollL", 5);
        default: {
            static const char *w[] = { [M_LEFT] = "left", [M_RIGHT] = "right", [M_UP] = "up", [M_DOWN] = "down" };
            return !strncmp(got, w[s->mv], strlen(w[s->mv]));
        }
    }
}
static int rScore(const AgRoll *r, bool print) {
    int ok = 0;
    for (int i = 0; i < gRN; i++) {
        char got[32];
        if (rJudge(&gR[i], r, got, sizeof got)) ok++;
        else if (print)
            printf("   misread #%d %s %d fingers → %s  (gaps %.0f–%.0f ms, %.0f ms long, moved %.3f, landing %.2f)\n", i + 1,
                   gR[i].kind == R_TAP ? "tap" : gR[i].kind == R_ROLLR ? "roll →" : gR[i].kind == R_ROLLL ? "roll ←" : "swipe",
                   gR[i].k, got, gapMin(&gR[i]) * 1000, gapMax(&gR[i]) * 1000, durOf(&gR[i]) * 1000, moveOf(&gR[i]), agLandMin(gR[i].t, gR[i].k));
    }
    return ok;
}
// The landing gap that best splits taps (largest gap) from rolls (smallest gap); ties →
// the widest margin.
static float fitGap(void) {
    double v[256]; int nv = 0;
    for (int i = 0; i < gRN; i++) {
        if (gR[i].kind == R_TAP) v[nv++] = gapMax(&gR[i]);
        else if (isRoll(gR[i].kind)) v[nv++] = gapMin(&gR[i]);
    }
    qsort_b(v, nv, sizeof *v, ^int(const void *a, const void *b) { double d = *(double *)a - *(double *)b; return d < 0 ? -1 : d > 0; });
    double best = AG_ROLL_GAP, bestMargin = -1; int bestErr = 1 << 30;
    for (int c = 0; c <= nv; c++) {
        double lo = c ? v[c - 1] : 0, hi = c < nv ? v[c] : lo + 0.02;
        if (hi <= lo) continue;
        double t = (lo + hi) / 2;
        int err = 0;
        for (int i = 0; i < gRN; i++) {
            if (gR[i].kind == R_TAP && gapMax(&gR[i]) >= t) err++;
            if (isRoll(gR[i].kind) && gapMin(&gR[i]) < t) err++;
        }
        if (err < bestErr || (err == bestErr && hi - lo > bestMargin)) { bestErr = err; bestMargin = hi - lo; best = t; }
    }
    return (float)fmin(fmax(best, 0.004), 0.08);
}
static bool gRoll3L = false;   // `roll 3L`: mostly 3-finger rolls ← (2026-10-18, user's misread rolls)
static void rollScript(void) {
    NSMutableArray<NSArray *> *u = [NSMutableArray array];
    if (gRoll3L) {
        for (int i = 0; i < 14; i++) [u addObject:@[@(R_ROLLL), @3, i < 4 ? @"3 fingers — ROLL ←  (quick)" : @"3 fingers — ROLL ←  (right finger first)"]];
        for (int i = 0; i < 4; i++)  [u addObject:@[@(R_ROLLR), @3, @"3 fingers — ROLL →"]];
        for (int i = 0; i < 5; i++)  [u addObject:@[@(R_TAP), @3, @"3 fingers — tap (together)"]];
        for (int i = 0; i < 4; i++)  [u addObject:@[@(R_TAP), @2, @"2 fingers — tap (together)"]];
        for (int i = 0; i < 3; i++)  [u addObject:@[@(R_ROLLL), @2, @"2 fingers — ROLL ←"]];
        for (int i = 0; i < 3; i++)  [u addObject:@[@(R_ROLLR), @2, @"2 fingers — ROLL →"]];
        for (int i = 0; i < 3; i++)  [u addObject:@[@(R_SWIPE), @2, [NSString stringWithFormat:@"2 fingers — swipe %@", @[@"LEFT", @"RIGHT", dir()][i]]]];
        for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
        for (NSArray *s in u) add([s[0] intValue], [s[1] intValue], s[2]);
        return;
    }
    for (int i = 0; i < 10; i++) [u addObject:@[@(R_TAP), @2, @"2 fingers — tap (together)"]];
    for (int i = 0; i < 4; i++)  [u addObject:@[@(R_TAP), @3, @"3 fingers — tap (together)"]];
    for (int i = 0; i < 10; i++) [u addObject:@[@(R_ROLLR), @2, i < 3 ? @"2 fingers — ROLL →  (quick)" : @"2 fingers — ROLL →  (left finger first)"]];
    for (int i = 0; i < 10; i++) [u addObject:@[@(R_ROLLL), @2, i < 3 ? @"2 fingers — ROLL ←  (quick)" : @"2 fingers — ROLL ←  (right finger first)"]];
    for (int i = 0; i < 4; i++)  [u addObject:@[@(R_ROLLR), @3, @"3 fingers — ROLL →"]];
    for (int i = 0; i < 4; i++)  [u addObject:@[@(R_ROLLL), @3, @"3 fingers — ROLL ←"]];
    for (int i = 0; i < 6; i++)  [u addObject:@[@(R_SWIPE), @2, [NSString stringWithFormat:@"2 fingers — swipe %@", i < 4 ? @[@"LEFT", @"RIGHT"][i % 2] : dir()]]];
    for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    for (NSArray *s in u) add([s[0] intValue], [s[1] intValue], s[2]);
}
static void rollSession(const char *side) {
    @autoreleasepool {
    rollScript();
    calibOn();
    printf("Rolls — the %s pad: %d gestures. Roll and tap the way you do for real; mix your speeds.\n", side, gNS);
    printf("ROLL → = fingers land one after another, left to right. The pads don't click or type now. Ctrl-C to stop.\n");
    pthread_mutex_lock(&gMu); gArmed = true; pthread_mutex_unlock(&gMu);
    for (int i = 0; i < gNS; ) {
        Step *st = &gSteps[i];
        printf("\n[%2d/%d]  %s\n", i + 1, gNS, st->text); fflush(stdout);
        Tr t[MAXT]; int n = nextGesture(t);
        if (n != st->n) { printf("   got %d contact%s, wanted %d — again\n", n, n == 1 ? "" : "s", st->n); continue; }
        if (st->kind == R_SWIPE) {
            const char *wrong = mismatch(st, t, n);
            if (wrong) { printf("   that was %s — skipped, again\n", wrong); continue; }
        }
        RSample *s = &gR[gRN];
        *s = (RSample){ .k = n, .kind = st->kind, .mv = st->mv };
        toTracks(t, n, s->t);
        if (gRN < 127) gRN++;
        char got[32]; bool ok = rJudge(s, &agRollDefault, got, sizeof got);
        printf("   gaps %.0f–%.0f ms, %.0f ms long, moved %.3f, landing %.2f — today reads as %s%s\n",
               gapMin(s) * 1000, gapMax(s) * 1000, durOf(s) * 1000, moveOf(s), agLandMin(s->t, n), got, ok ? "" : "  ✗");
        fflush(stdout);
        i++;
    }
    pthread_mutex_lock(&gMu); gArmed = false; pthread_mutex_unlock(&gMu);

    // Fit.
    AgRoll r = agRollDefault;
    r.gap = fitGap();
    float land = 1, dur2 = 0, dur3 = 0, mv = 0;
    for (int i = 0; i < gRN; i++) {
        if (!isRoll(gR[i].kind)) continue;
        land = fminf(land, agLandMin(gR[i].t, gR[i].k));
        if (gR[i].k == 2) dur2 = fmaxf(dur2, durOf(&gR[i])); else dur3 = fmaxf(dur3, durOf(&gR[i]));
        mv = fmaxf(mv, moveOf(&gR[i]));
    }
    r.land = fmaxf(0.5f, fminf(AG_TAP_LAND, land * 0.9f));
    r.dur = fminf(0.8f, fmaxf(agRollDefault.dur, dur2 * 1.25f));
    r.durPer = dur3 > 0 ? fminf(0.3f, fmaxf(AG_TAP_S_PER, dur3 * 1.25f - r.dur)) : AG_TAP_S_PER + r.gap;
    r.move = fminf(0.08f, fmaxf(0.03f, mv * 1.3f));
    // A swipe read as a roll: pull the drift allowance in under it.
    for (int i = 0; i < gRN; i++) {
        char got[32];
        if (gR[i].kind == R_SWIPE && !rJudge(&gR[i], &r, got, sizeof got) && !strncmp(got, "roll", 4))
            r.move = fminf(r.move, moveOf(&gR[i]) * 0.95f);
    }
    if (r.move < AG_SWIPE) r.move = 0;   // too tight to help: the swipe test goes first, as before

    printf("\nBefore (fixed rules): %d / %d read right\n", rScore(&agRollDefault, false), gRN);
    int after = rScore(&r, true);
    printf("After (learnt):       %d / %d read right\n", after, gRN);
    printf("   roll gap %.0f ms (was %.0f) · roll up to %.0f ms (+%.0f/finger) · drift %.3f · landing ≥ %.2f\n",
           r.gap * 1000, AG_ROLL_GAP * 1000, r.dur * 1000, r.durPer * 1000, r.move, r.land);

    NSString *path = @"/Users/josh/Code/Scripts/remap/thumbprint.json";
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *doc = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:NULL] : nil;
    if (![doc isKindOfClass:NSMutableDictionary.class]) doc = [NSMutableDictionary dictionary];
    NSMutableDictionary *h = [doc[@(side)] isKindOfClass:NSMutableDictionary.class] ? doc[@(side)] : [NSMutableDictionary dictionary];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    h[@"roll"] = @{ @"gap": r4(r.gap), @"dur": r4(r.dur), @"durPer": r4(r.durPer), @"move": r4(r.move), @"land": r4(r.land),
                    @"accuracy": [NSString stringWithFormat:@"%d/%d (fixed rules %d/%d)", after, gRN, rScore(&agRollDefault, false), gRN],
                    @"learnt": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date] };
    doc[@(side)] = h;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:path atomically:YES]) { fprintf(stderr, "could not write %s\n", path.UTF8String); exit(1); }
    printf("\nSaved → remap/thumbprint.json (%s.roll). remapd picks it up now.\n", side);
    }
    exit(0);
}

/* ── SPREAD: thumb + 3 spreading / pinching vs 4-finger swipes (2026-10-18) ──
   Records every frame of each gesture, replays it through auxgest exactly as remapd
   runs the main pad (no thumbs, early decisions for right_nav's swipes) and prints what
   it would have fired, with the shape numbers. Frames → remap/spread_calib.jsonl. */
static char gSpGot[64], gSpDet[160];
static void spEmit(const char *name, int phase, int flags, const char *detail, void *ctx) {
    (void)flags; (void)ctx;
    if (phase != AG_TAP || gSpGot[0]) return;
    strlcpy(gSpGot, name, sizeof gSpGot); strlcpy(gSpDet, detail ? detail : "", sizeof gSpDet);
}
static bool spEarly(const char *name, void *ctx) {
    (void)ctx;
    static const char *nav[] = { "left4", "right4", "up4", "down4", "left5", "right5", "pinch5", "spread5", "pinch3" };
    for (size_t i = 0; i < sizeof nav / sizeof *nav; i++) if (!strcmp(name, nav[i])) return true;
    return false;
}
static void spreadSession(const char *side) {
    @autoreleasepool {
    NSMutableArray *u = [NSMutableArray array];
    for (int i = 0; i < 10; i++) [u addObject:@"SPREAD — thumb + 3 fingers, start close, open out"];
    for (int i = 0; i < 6; i++)  [u addObject:@"PINCH — thumb + 3 fingers, start apart, close in"];
    for (NSString *d in @[@"LEFT", @"RIGHT", @"UP", @"DOWN"])
        for (int i = 0; i < 3; i++) [u addObject:[NSString stringWithFormat:@"SWIPE %@ — 4 fingers", d]];
    for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    calibOn();
    NSString *path = @"/Users/josh/Code/Scripts/remap/spread_calib.jsonl";
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    printf("Spread vs swipe — the %s pad: %lu gestures. The pads don't click or type while this runs.\n", side, (unsigned long)u.count);
    printf("Do each the way you normally would. Ctrl-C to stop (what's done is kept).\n");
    pthread_mutex_lock(&gMu); gArmed = true; gRec = true; pthread_mutex_unlock(&gMu);
    int wrong = 0;
    for (NSUInteger i = 0; i < u.count; i++) {
        NSString *ask = u[i];
        printf("\n[%2lu/%lu]  %s\n", (unsigned long)i + 1, (unsigned long)u.count, ask.UTF8String); fflush(stdout);
        Tr t[MAXT]; int n = nextGesture(t);
        if (n < 3) { printf("   %d contact%s (a scroll?) — ignored, again\n", n, n == 1 ? "" : "s"); i--; continue; }
        int nf = gNFOut;
        // Replay, as remapd's main pad.
        AuxGest g; auxgestInit(&g, spEmit, NULL, NULL);
        g.noThumb = true; g.early = spEarly;
        gSpGot[0] = 0; gSpDet[0] = 0;
        double tEnd = nf ? gFOut[nf - 1].t : 0, earlyAt = -1;
        for (int k = 0; k < nf; k++) {
            auxgestFrame(&g, gFOut[k].c, gFOut[k].n, gFOut[k].t);
            auxgestTick(&g, gFOut[k].t);
            if (gSpGot[0] && earlyAt < 0) earlyAt = gFOut[k].t - gFOut[0].t;
        }
        auxgestFrame(&g, NULL, 0, tEnd + 0.01);
        auxgestTick(&g, tEnd + 1);
        // Shape numbers over the whole gesture.
        float cx0 = 0, cy0 = 0, cx = 0, cy = 0, r0 = 0, r = 0;
        for (int k = 0; k < n; k++) { cx0 += t[k].x0 / n; cy0 += t[k].y0 / n; cx += t[k].x / n; cy += t[k].y / n; }
        for (int k = 0; k < n; k++) { r0 += hypotf(t[k].x0 - cx0, t[k].y0 - cy0) / n; r += hypotf(t[k].x - cx, t[k].y - cy) / n; }
        double first = 1e18, last = 0;
        for (int k = 0; k < n; k++) { first = fmin(first, t[k].t0); last = fmax(last, t[k].t0); }
        bool isSwipe = [ask hasPrefix:@"SWIPE"];
        bool fired = spEarly(gSpGot, NULL);
        bool bad = isSwipe ? !fired : fired;
        wrong += bad;
        printf("   %d contacts, landed over %.0f ms · radius %.3f → %.3f (%+.3f) · centre moved %.3f\n",
               n, (last - first) * 1000, r0, r, r - r0, hypotf(cx - cx0, cy - cy0));
        printf("   → %s%s%s  %s\n", gSpGot[0] ? gSpGot : "(nothing)",
               earlyAt >= 0 ? [NSString stringWithFormat:@" (early, %.0f ms in)", earlyAt * 1000].UTF8String : "",
               bad ? "   ✗ WRONG" : "   ✓", gSpDet);
        fflush(stdout);
        // Log: label, verdict, and per-frame contacts.
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:nf];
        for (int k = 0; k < nf; k++) {
            NSMutableArray *cs = [NSMutableArray array];
            for (int j = 0; j < gFOut[k].n; j++) {
                AgContact *c = &gFOut[k].c[j];
                [cs addObject:@[@(c->id), @(roundf(c->x * 1e4f) / 1e4f), @(roundf(c->y * 1e4f) / 1e4f),
                                @(roundf(c->size * 1e3f) / 1e3f), @(roundf(c->major * 100) / 100), @(roundf(c->minor * 100) / 100), @(roundf(c->angle * 1e3f) / 1e3f)]];
            }
            [frames addObject:@{ @"t": @(round((gFOut[k].t - gFOut[0].t) * 1e4) / 1e4), @"c": cs }];
        }
        NSDictionary *rec = @{ @"ask": ask, @"got": @(gSpGot), @"early": @(earlyAt), @"detail": @(gSpDet), @"frames": frames };
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:rec options:0 error:NULL] mutableCopy];
        [line appendBytes:"\n" length:1];
        [fh writeData:line];
    }
    [fh closeFile];
    printf("\n%d / %lu wrong. Frames → remap/spread_calib.jsonl\n", wrong, (unsigned long)u.count);
    }
    exit(0);
}

/* ── THUMBTAP: fingers tapping by a resting thumb (2026-10-18) ──
   Thumb down, then 1–4 fingers tapping (once; twice with the thumb still down; straight
   after the thumb lands), plus plain taps (no thumb) as the control. Every frame is
   replayed through auxgest as remapd runs the pads (no thumbs, this pad's print + rolls),
   so each line says what remapd would have fired. Then fits the pad's thumb-down rules
   (auxgest.h AgRest) one at a time, replaying everything under each candidate; a rule
   leaves its default only when that reads more right. Saved as <side>.rest; frames →
   remap/thumbtap_calib_<side>.jsonl. */
typedef struct { int n, reps; bool thumb; Tr t[MAXT]; int nt, th; RecF *f; int nf; char ask[96]; } TSample;
static TSample gT[64]; static int gTN = 0;
static int gTTSide = 0;
#define TT_MAXE 8
typedef struct { int ne; char name[TT_MAXE][32], det[TT_MAXE][160]; bool held[TT_MAXE]; } TOut;
static void ttEmit(const char *name, int phase, int flags, const char *detail, void *ctx) {
    (void)flags;
    TOut *o = ctx;
    if (phase == AG_UP || o->ne >= TT_MAXE) return;
    strlcpy(o->name[o->ne], name, sizeof o->name[0]);
    strlcpy(o->det[o->ne], detail ? detail : "", sizeof o->det[0]);
    o->held[o->ne++] = phase == AG_DOWN;
}
// Replay one gesture: did it fire exactly what was asked (thumbtap<n> × reps, or tap<n>)?
static bool ttReplay(const TSample *s, const AgPrint *p, const AgRoll *r, const AgRest *re, TOut *o) {
    *o = (TOut){0};
    AuxGest g; auxgestInit(&g, ttEmit, NULL, o);
    g.noThumb = true; g.print = p; g.roll = r; g.rest = re; g.thumbSide = gTTSide;
    double tEnd = 0;
    for (int k = 0; k < s->nf; k++) {
        auxgestFrame(&g, s->f[k].c, s->f[k].n, s->f[k].t);
        auxgestTick(&g, s->f[k].t);
        tEnd = s->f[k].t;
    }
    auxgestFrame(&g, NULL, 0, tEnd + 0.01);
    auxgestTick(&g, tEnd + 1);
    char want[32]; snprintf(want, sizeof want, s->thumb ? "thumbtap%d" : "tap%d", s->n);
    if (o->ne != (s->thumb ? s->reps : 1)) return false;
    for (int i = 0; i < o->ne; i++) if (o->held[i] || strcmp(o->name[i], want)) return false;
    return true;
}
static int ttScore(const AgPrint *p, const AgRoll *r, const AgRest *re, bool print) {
    int ok = 0;
    for (int i = 0; i < gTN; i++) {
        TOut o;
        if (ttReplay(&gT[i], p, r, re, &o)) { ok++; continue; }
        if (!print) continue;
        printf("   misread #%d %s →", i + 1, gT[i].ask);
        for (int e = 0; e < o.ne; e++) printf(" %s%s", o.held[e] ? "HELD " : "", o.name[e]);
        printf("%s\n", o.ne ? "" : " (nothing)");
    }
    return ok;
}
// This pad's print and rolls as remapd loads them, and its current thumb-down rules.
static NSMutableDictionary *ttLoad(const char *side, AgPrint *p, AgRoll *r, AgRest *re) {
    *p = (AgPrint){0}; *r = agRollDefault; *re = agRestDefault;
    NSData *d = [NSData dataWithContentsOfFile:@"/Users/josh/Code/Scripts/remap/thumbprint.json"];
    NSMutableDictionary *doc = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:NULL] : nil;
    if (![doc isKindOfClass:NSMutableDictionary.class]) doc = [NSMutableDictionary dictionary];
    NSDictionary *h = [doc[@(side)] isKindOfClass:NSDictionary.class] ? doc[@(side)] : nil;
    if (!h) return doc;
    p->ok = true;
    NSArray *cls = @[@"finger", @"thumb"];
    for (int c = 0; c < 2; c++) {
        NSDictionary *s = [h[cls[c]] isKindOfClass:NSDictionary.class] ? h[cls[c]] : nil;
        NSArray *mu = s[@"mu"], *sd = s[@"sd"];
        if (![mu isKindOfClass:NSArray.class] || ![sd isKindOfClass:NSArray.class] || mu.count != AGF || sd.count != AGF) { p->ok = false; break; }
        for (int i = 0; i < AGF; i++) { p->mu[c][i] = [mu[i] floatValue]; p->sd[c][i] = fmaxf([sd[i] floatValue], 0.02f); }
    }
    NSDictionary *rl = [h[@"roll"] isKindOfClass:NSDictionary.class] ? h[@"roll"] : nil;
    if (rl && [rl[@"gap"] floatValue] > 0)
        *r = (AgRoll){ [rl[@"gap"] floatValue], [rl[@"dur"] floatValue], [rl[@"durPer"] floatValue], [rl[@"move"] floatValue], [rl[@"land"] floatValue] };
    NSDictionary *rs = [h[@"rest"] isKindOfClass:NSDictionary.class] ? h[@"rest"] : nil;
    if (rs && [rs[@"lead"] floatValue] > 0)
        *re = (AgRest){ [rs[@"lead"] floatValue], [rs[@"still"] floatValue], [rs[@"land"] floatValue], [rs[@"dur"] floatValue],
                        [rs[@"durPer"] floatValue], [rs[@"gap"] floatValue], [rs[@"shape"] floatValue] };
    return doc;
}
static void ttRules(const char *label, const AgRest *re, const AgRoll *r) {
    printf("   %s thumb rests %.0f ms before the fingers (drift ≤ %.3f, shape > %.0f) · taps ≤ %.0f ms (+%.0f/finger), landing ≥ %.2f · rolls by it: %s\n",
           label, re->lead * 1000, re->still, re->shape, re->dur * 1000, re->durPer * 1000, re->land,
           re->gap >= 1 ? "never" : re->gap > 0 ? [NSString stringWithFormat:@"gap %.0f ms", re->gap * 1000].UTF8String
                                               : [NSString stringWithFormat:@"the pad's (%.0f ms)", r->gap * 1000].UTF8String);
}
static void ttFitSave(const char *side, NSMutableDictionary *doc, const AgPrint *pp, const AgRoll *rp, const AgRest *cp);
// REFIT from a recorded session (no pads): `thumbprint <side> thumbtap refit <frames.jsonl> [drop 3,32]`
// — replays its frames under today's auxgest, leaving out the gestures numbered in `drop`.
static void thumbtapRefit(const char *side, const char *file, const char *drop) {
    @autoreleasepool {
    gTTSide = strcmp(side, "left") ? -1 : 1;
    AgPrint p; AgRoll r; AgRest cur;
    NSMutableDictionary *doc = ttLoad(side, &p, &r, &cur);
    NSString *all = [NSString stringWithContentsOfFile:@(file) encoding:NSUTF8StringEncoding error:NULL];
    if (!all) { fprintf(stderr, "can't read %s\n", file); exit(1); }
    NSSet *skip = [NSSet setWithArray:drop ? [@(drop) componentsSeparatedByString:@","] : @[]];
    int num = 0;
    for (NSString *ln in [all componentsSeparatedByString:@"\n"]) {
        if (!ln.length || gTN >= 64) continue;
        num++;
        if ([skip containsObject:[NSString stringWithFormat:@"%d", num]]) { printf("   (#%d left out)\n", num); continue; }
        NSDictionary *rec = [NSJSONSerialization JSONObjectWithData:[ln dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSArray *frames = rec[@"frames"];
        TSample *s = &gT[gTN];
        *s = (TSample){ .n = [rec[@"n"] intValue], .reps = [rec[@"reps"] intValue], .thumb = [rec[@"thumb"] boolValue], .th = -1,
                        .nf = (int)frames.count };
        snprintf(s->ask, sizeof s->ask, "%s", [rec[@"ask"] UTF8String]);
        s->f = calloc((size_t)s->nf + 1, sizeof(RecF));
        for (int k = 0; k < s->nf; k++) {
            s->f[k].t = [frames[k][@"t"] doubleValue];
            for (NSArray *c in frames[k][@"c"]) {
                if (s->f[k].n >= AG_MAX) break;
                s->f[k].c[s->f[k].n++] = (AgContact){ [c[0] intValue], [c[1] floatValue], [c[2] floatValue],
                                                      [c[4] floatValue], [c[5] floatValue], [c[6] floatValue], [c[3] floatValue] };
            }
        }
        TOut o; bool ok = ttReplay(s, &p, &r, &cur, &o);
        printf("#%-2d %-48s →", num, s->ask);
        for (int e = 0; e < o.ne; e++) printf(" %s%s", o.held[e] ? "HELD " : "", o.name[e]);
        printf("%s   %s\n", o.ne ? "" : " (nothing)", ok ? "✓" : "✗");
        gTN++;
    }
    ttFitSave(side, doc, &p, &r, &cur);
    }
    exit(0);
}
static void thumbtapSession(const char *side) {
    @autoreleasepool {
    gTTSide = strcmp(side, "left") ? -1 : 1;
    AgPrint p; AgRoll r; AgRest cur;
    NSMutableDictionary *doc = ttLoad(side, &p, &r, &cur);
    if (!p.ok) printf("(no thumbprint for the %s pad: every resting contact counts as the thumb — run `thumbprint %s` first)\n", side, side);
    NSMutableArray<NSArray *> *u = [NSMutableArray array];
    for (int n = 1; n <= 4; n++) {
        NSString *f = n == 1 ? @"1 finger" : [NSString stringWithFormat:@"%d fingers", n];
        for (int i = 0; i < 3; i++) [u addObject:@[@(n), @1, @YES, [NSString stringWithFormat:@"THUMB DOWN (rest it), then tap %@", f]]];
        for (int i = 0; i < 2; i++) [u addObject:@[@(n), @2, @YES, [NSString stringWithFormat:@"THUMB DOWN, tap %@ TWICE (thumb stays down)", f]]];
        [u addObject:@[@(n), @1, @YES, [NSString stringWithFormat:@"THUMB DOWN and tap %@ straight away", f]]];
        for (int i = 0; i < 2; i++) [u addObject:@[@(n), @1, @NO, [NSString stringWithFormat:@"%@ — tap, NO thumb", f]]];
    }
    for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    calibOn();
    NSString *path = [NSString stringWithFormat:@"/Users/josh/Code/Scripts/remap/thumbtap_calib_%s.jsonl", side];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    printf("Thumb-down taps — the %s pad: %lu gestures. Do them the way you do for real.\n", side, (unsigned long)u.count);
    printf("Lift EVERYTHING (thumb too) after each one. The pads don't click or type now. Ctrl-C to stop.\n");
    ttRules("today:", &cur, &r);
    pthread_mutex_lock(&gMu); gArmed = true; gRec = true; pthread_mutex_unlock(&gMu);
    int okNow = 0;
    for (NSUInteger i = 0; i < u.count && gTN < 64; ) {
        int n = [u[i][0] intValue], reps = [u[i][1] intValue]; bool thumb = [u[i][2] boolValue];
        NSString *ask = u[i][3];
        printf("\n[%2lu/%lu]  %s\n", (unsigned long)i + 1, (unsigned long)u.count, ask.UTF8String); fflush(stdout);
        Tr t[MAXT]; int nt = nextGesture(t);
        int want = thumb ? 1 + n * reps : n;
        if (nt != want) { printf("   got %d contact%s, wanted %d — again\n", nt, nt == 1 ? "" : "s", want); continue; }
        TSample *s = &gT[gTN];
        *s = (TSample){ .n = n, .reps = reps, .thumb = thumb, .nt = nt, .th = -1, .nf = gNFOut };
        memcpy(s->t, t, sizeof(Tr) * nt);
        strlcpy(s->ask, ask.UTF8String, sizeof s->ask);
        s->f = malloc(sizeof(RecF) * (size_t)(gNFOut ? gNFOut : 1));
        memcpy(s->f, gFOut, sizeof(RecF) * (size_t)gNFOut);
        // The numbers: the thumb = the contact down longest.
        double fFirst = 1e18; float land = 1, drift = 0; double fDur = 0;
        if (thumb) { s->th = 0; for (int k = 1; k < nt; k++) if (t[k].t1 - t[k].t0 > t[s->th].t1 - t[s->th].t0) s->th = k; }
        for (int k = 0; k < nt; k++) {
            if (k == s->th) continue;
            fFirst = fmin(fFirst, t[k].t0);
            land = fminf(land, t[k].szMax > 0 ? t[k].sz0 / t[k].szMax : 1);
            drift = fmaxf(drift, t[k].move); fDur = fmax(fDur, t[k].t1 - t[k].t0);
        }
        if (s->th >= 0) {
            const Tr *th = &t[s->th];
            float f[AGF]; agFeatures(th->pk[0], th->pk[1], th->pk[2], th->pk[3], f);
            printf("   thumb down %+.0f ms before the fingers · drift %.3f · shape %s%+.0f   |   ",
                   (fFirst - th->t0) * 1000, th->move, p.ok ? "" : "(no print) ", p.ok ? agPrintScore(&p, f) : 0);
        } else printf("   ");
        printf("fingers down ≤ %.0f ms, landing ≥ %.2f, drift ≤ %.3f\n", fDur * 1000, land, drift);
        TOut o; bool ok = ttReplay(s, &p, &r, &cur, &o);
        okNow += ok;
        printf("   →");
        for (int e = 0; e < o.ne; e++) printf(" %s%s", o.held[e] ? "HELD " : "", o.name[e]);
        printf("%s   %s\n", o.ne ? "" : " (nothing)", ok ? "✓" : "✗");
        if (!ok) for (int e = 0; e < o.ne; e++) if (o.det[e][0]) printf("      %s: %s\n", o.name[e], o.det[e]);
        fflush(stdout);
        // Log: the ask, today's verdict, and every frame.
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:s->nf], *got = [NSMutableArray array];
        for (int k = 0; k < s->nf; k++) {
            NSMutableArray *cs = [NSMutableArray array];
            for (int j = 0; j < s->f[k].n; j++) {
                AgContact *c = &s->f[k].c[j];
                [cs addObject:@[@(c->id), @(roundf(c->x * 1e4f) / 1e4f), @(roundf(c->y * 1e4f) / 1e4f),
                                @(roundf(c->size * 1e3f) / 1e3f), @(roundf(c->major * 100) / 100), @(roundf(c->minor * 100) / 100), @(roundf(c->angle * 1e3f) / 1e3f)]];
            }
            [frames addObject:@{ @"t": @(round((s->f[k].t - s->f[0].t) * 1e4) / 1e4), @"c": cs }];
        }
        for (int e = 0; e < o.ne; e++) [got addObject:[NSString stringWithFormat:@"%s%s", o.held[e] ? "HELD " : "", o.name[e]]];
        NSDictionary *rec = @{ @"ask": ask, @"n": @(n), @"reps": @(reps), @"thumb": @(thumb), @"got": got, @"ok": @(ok), @"frames": frames };
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:rec options:0 error:NULL] mutableCopy];
        [line appendBytes:"\n" length:1];
        [fh writeData:line];
        gTN++; i++;
    }
    [fh closeFile];
    pthread_mutex_lock(&gMu); gArmed = false; gRec = false; pthread_mutex_unlock(&gMu);

    ttFitSave(side, doc, &p, &r, &cur);
    }
    exit(0);
}
// Fit, one rule at a time from the defaults (twice round): a rule moves only when it reads
// more right. Then save <side>.rest.
static void ttFitSave(const char *side, NSMutableDictionary *doc, const AgPrint *pp, const AgRoll *rp, const AgRest *cp) {
    @autoreleasepool {
    AgPrint p = *pp; AgRoll r = *rp; AgRest cur = *cp;
    if (!gTN) { fprintf(stderr, "no gestures — nothing saved\n"); exit(1); }
    AgRest x = agRestDefault;
    float *fld[] = { &x.lead, &x.still, &x.land, &x.dur, &x.gap, &x.shape };
    static const float cand[][6] = {
        { 0.05f, 0.04f, 0.03f, 0.02f, 0.012f, 0.006f },   // lead
        { 0.05f, 0.08f, 0.12f, 0.05f, 0.05f, 0.05f },     // still
        { 0.78f, 0.70f, 0.62f, 0.55f, 0.78f, 0.78f },     // land
        { 0.25f, 0.32f, 0.40f, 0.50f, 0.25f, 0.25f },     // dur
        { 0, 0.03f, 1, 0, 0, 0 },                         // gap (0 = the pad's, 1 = never)
        { 0, -5, -15, -40, -100, 0 },                     // shape
    };
    int best = ttScore(&p, &r, &x, false);
    for (int pass = 0; pass < 2; pass++)
        for (int f = 0; f < 6; f++)
            for (int c = 0; c < 6; c++) {
                float was = *fld[f];
                *fld[f] = cand[f][c];
                int sc = ttScore(&p, &r, &x, false);
                if (sc > best) best = sc; else *fld[f] = was;
            }
    int before = ttScore(&p, &r, &cur, false);
    printf("\nToday's rules: %d / %d read right\n", before, gTN);
    ttRules("today:", &cur, &r);
    printf("Learnt:        %d / %d read right\n", best, gTN);
    ttRules("learnt:", &x, &r);
    ttScore(&p, &r, &x, true);
    NSMutableDictionary *h = [doc[@(side)] isKindOfClass:NSMutableDictionary.class] ? doc[@(side)] : [NSMutableDictionary dictionary];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    h[@"rest"] = @{ @"lead": r4(x.lead), @"still": r4(x.still), @"land": r4(x.land), @"dur": r4(x.dur), @"durPer": r4(x.durPer),
                    @"gap": r4(x.gap), @"shape": r4(x.shape),
                    @"accuracy": [NSString stringWithFormat:@"%d/%d (rules before %d/%d)", best, gTN, before, gTN],
                    @"learnt": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date] };
    doc[@(side)] = h;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:@"/Users/josh/Code/Scripts/remap/thumbprint.json" atomically:YES]) { fprintf(stderr, "could not write thumbprint.json\n"); exit(1); }
    printf("\nSaved → remap/thumbprint.json (%s.rest). remapd picks it up now. Frames → remap/thumbtap_calib_%s.jsonl\n", side, side);
    }
    exit(0);
}

/* ── LONE: the thumb alone — thumbswipeL / R and thumbtap vs one finger (2026-10-18) ──
   Replays every gesture through auxgest as remapd runs the pad, under candidate rules
   (auxgest.h AgLone), and keeps the ones that read most right — a finger read as the thumb
   counts double (it loses a typed letter / an arrow). Saved as <side>.lone; frames →
   remap/lone_calib_<side>.jsonl. */
typedef struct { char want[16], ask[96]; RecF *f; int nf; float score; } LSample;
static LSample gL[64]; static int gLN = 0;
static void lnEmit(const char *name, int phase, int flags, const char *detail, void *ctx) {
    (void)flags; (void)detail;
    char *o = ctx;
    if (phase == AG_TAP && !o[0]) strlcpy(o, name, 32);
}
static void lnReplay(const LSample *s, const AgPrint *p, const AgRoll *r, const AgRest *re, const AgLone *lo, char got[32]) {
    got[0] = 0;
    AuxGest g; auxgestInit(&g, lnEmit, NULL, got);
    g.noThumb = true; g.print = p; g.roll = r; g.rest = re; g.lone = lo;
    double tEnd = 0;
    for (int k = 0; k < s->nf; k++) { auxgestFrame(&g, s->f[k].c, s->f[k].n, s->f[k].t); auxgestTick(&g, s->f[k].t); tEnd = s->f[k].t; }
    auxgestFrame(&g, NULL, 0, tEnd + 0.01);
    auxgestTick(&g, tEnd + 1);
}
// Right = +1; a finger read as a thumb gesture = −2 (counted as a miss, weighed double).
static int lnScore(const AgPrint *p, const AgRoll *r, const AgRest *re, const AgLone *lo, int *right, bool print) {
    int sc = 0; *right = 0;
    for (int i = 0; i < gLN; i++) {
        char got[32]; lnReplay(&gL[i], p, r, re, lo, got);
        bool ok = !strcmp(got, gL[i].want);
        bool fingerAsThumb = strncmp(gL[i].want, "thumb", 5) && !strncmp(got, "thumb", 5);
        sc += ok ? 1 : fingerAsThumb ? -2 : 0; *right += ok;
        if (print && !ok) printf("   misread #%d %s (shape %+.0f) → %s\n", i + 1, gL[i].ask, gL[i].score, got[0] ? got : "(nothing)");
    }
    return sc;
}
static void loneSession(const char *side) {
    @autoreleasepool {
    AgPrint p; AgRoll r; AgRest re;
    NSMutableDictionary *doc = ttLoad(side, &p, &r, &re);
    if (!p.ok) { fprintf(stderr, "no thumbprint for the %s pad — run `thumbprint %s` first\n", side, side); exit(1); }
    NSMutableArray<NSArray *> *u = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        [u addObject:@[@"thumbswipeL", @"THUMB alone — swipe LEFT"]];
        [u addObject:@[@"thumbswipeR", @"THUMB alone — swipe RIGHT"]];
        [u addObject:@[@"thumbtap", @"THUMB alone — tap"]];
    }
    for (int i = 0; i < 5; i++) {
        [u addObject:@[@"left1", @"ONE FINGER — swipe LEFT"]];
        [u addObject:@[@"right1", @"ONE FINGER — swipe RIGHT"]];
        [u addObject:@[@"tap1", @"ONE FINGER — tap"]];
    }
    for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    calibOn();
    NSString *path = [NSString stringWithFormat:@"/Users/josh/Code/Scripts/remap/lone_calib_%s.jsonl", side];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    printf("Lone thumb — the %s pad: %lu gestures. Do them the way you do for real; lift after each.\n", side, (unsigned long)u.count);
    printf("The pads don't click or type now. Ctrl-C to stop.\n");
    pthread_mutex_lock(&gMu); gArmed = true; gRec = true; pthread_mutex_unlock(&gMu);
    for (NSUInteger i = 0; i < u.count && gLN < 64; ) {
        NSString *ask = u[i][1];
        printf("\n[%2lu/%lu]  %s\n", (unsigned long)i + 1, (unsigned long)u.count, ask.UTF8String); fflush(stdout);
        Tr t[MAXT]; int nt = nextGesture(t);
        if (nt != 1) { printf("   got %d contacts, wanted 1 — again\n", nt); continue; }
        LSample *s = &gL[gLN];
        *s = (LSample){ .nf = gNFOut };
        strlcpy(s->want, [u[i][0] UTF8String], sizeof s->want);
        strlcpy(s->ask, ask.UTF8String, sizeof s->ask);
        s->f = malloc(sizeof(RecF) * (size_t)(gNFOut ? gNFOut : 1));
        memcpy(s->f, gFOut, sizeof(RecF) * (size_t)gNFOut);
        float f[AGF]; agFeatures(t[0].pk[0], t[0].pk[1], t[0].pk[2], t[0].pk[3], f);
        s->score = agPrintScore(&p, f);
        printf("   shape %+.0f · sideways %+.3f · %.0f ms · landing %.2f\n", s->score, t[0].x - t[0].x0,
               (t[0].t1 - t[0].t0) * 1000, t[0].szMax > 0 ? t[0].sz0 / t[0].szMax : 1);
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:s->nf];
        for (int k = 0; k < s->nf; k++) {
            NSMutableArray *cs = [NSMutableArray array];
            for (int j = 0; j < s->f[k].n; j++) {
                AgContact *c = &s->f[k].c[j];
                [cs addObject:@[@(c->id), @(roundf(c->x * 1e4f) / 1e4f), @(roundf(c->y * 1e4f) / 1e4f),
                                @(roundf(c->size * 1e3f) / 1e3f), @(roundf(c->major * 100) / 100), @(roundf(c->minor * 100) / 100), @(roundf(c->angle * 1e3f) / 1e3f)]];
            }
            [frames addObject:@{ @"t": @(round((s->f[k].t - s->f[0].t) * 1e4) / 1e4), @"c": cs }];
        }
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{ @"ask": ask, @"want": @(s->want), @"shape": @(s->score), @"frames": frames }
                                                               options:0 error:NULL] mutableCopy];
        [line appendBytes:"\n" length:1];
        [fh writeData:line];
        gLN++; i++;
    }
    [fh closeFile];
    pthread_mutex_lock(&gMu); gArmed = false; gRec = false; pthread_mutex_unlock(&gMu);
    if (!gLN) { fprintf(stderr, "no gestures — nothing saved\n"); exit(1); }

    // Fit: the shape threshold from the scores seen (between neighbours), then the rest.
    float sc[64]; int ns = 0;
    for (int i = 0; i < gLN; i++) sc[ns++] = gL[i].score;
    for (int a = 0; a < ns; a++) for (int b = a + 1; b < ns; b++) if (sc[b] < sc[a]) { float x = sc[a]; sc[a] = sc[b]; sc[b] = x; }
    AgLone x = { 0, AG_SWIPE, AG_THUMBTAP_S, AG_TAP_LAND };
    int right = 0, best = lnScore(&p, &r, &re, &x, &right, false);
    for (int pass = 0; pass < 2; pass++) {
        for (int a = -1; a < ns; a++) {
            float was = x.shape;
            x.shape = a < 0 ? sc[0] - 1 : a + 1 < ns ? 0.5f * (sc[a] + sc[a + 1]) : sc[a] + 1;
            int v = lnScore(&p, &r, &re, &x, &right, false);
            if (v > best) best = v; else x.shape = was;
        }
        static const float sw[] = { 0.02f, 0.03f, 0.04f, 0.06f }, du[] = { 0.25f, 0.32f, 0.40f, 0.50f }, la[] = { 0.78f, 0.70f, 0.62f, 0.55f };
        for (int c = 0; c < 4; c++) { float w = x.swipe; x.swipe = sw[c]; int v = lnScore(&p, &r, &re, &x, &right, false); if (v > best) best = v; else x.swipe = w; }
        for (int c = 0; c < 4; c++) { float w = x.dur;   x.dur = du[c];   int v = lnScore(&p, &r, &re, &x, &right, false); if (v > best) best = v; else x.dur = w; }
        for (int c = 0; c < 4; c++) { float w = x.land;  x.land = la[c];  int v = lnScore(&p, &r, &re, &x, &right, false); if (v > best) best = v; else x.land = w; }
    }
    lnScore(&p, &r, &re, &x, &right, true);
    printf("\nLearnt: %d / %d read right — thumb when shape > %.0f · swipe ≥ %.3f sideways · tap ≤ %.0f ms, landing ≥ %.2f\n",
           right, gLN, x.shape, x.swipe, x.dur * 1000, x.land);
    NSMutableDictionary *h = [doc[@(side)] isKindOfClass:NSMutableDictionary.class] ? doc[@(side)] : [NSMutableDictionary dictionary];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    h[@"lone"] = @{ @"shape": r4(x.shape), @"swipe": r4(x.swipe), @"dur": r4(x.dur), @"land": r4(x.land),
                    @"accuracy": [NSString stringWithFormat:@"%d/%d", right, gLN],
                    @"learnt": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date] };
    doc[@(side)] = h;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:@"/Users/josh/Code/Scripts/remap/thumbprint.json" atomically:YES]) { fprintf(stderr, "could not write thumbprint.json\n"); exit(1); }
    printf("Saved → remap/thumbprint.json (%s.lone%s). remapd picks it up now.\n", side,
           strcmp(side, "right") ? "" : "; the left pad mirrors it");
    }
    exit(0);
}

/* ── REST: fingers resting on THIS pad, others moving by them (2026-10-28) ──
   1–3 fingers rest, then fingers tap / swipe up / down, or the thumb taps / swipes by them
   (rest<r>:tap<m> …, remapd <hand>_rest_one … _three), plus a resting THUMB with fingers
   tapping (restthumb:tap<m>) and plain taps as the controls. Every gesture is replayed
   through auxgest as remapd runs the pad (restSecs, every section wanted), then the
   resting-finger rules (auxgest.h AgRestSec: lead, still, fingerMM) are fitted one at a
   time — the thumb-down tap rules (<side>.rest) are left alone. Saved as <side>.restsec;
   frames → remap/rest_calib_<side>.jsonl. Refit: `thumbprint right rest refit <file>`. */
// r: the resters (the thumb resting = 1); cls: THE LAYOUT's combination (AG_LAY_THUMB, 1–3;
// -1 = none: the thumb moving, plain taps); off: the first mover from the resters' centre, mm.
typedef struct { char want[32], ask[96]; int r, cls, nt; float off[2], spread; RecF *f; int nf; } QSample;
static QSample gQ[64]; static int gQN = 0;
static bool qWantsAll(const char *n, void *c) { (void)n; (void)c; return true; }   // every section counts here
static void qReplay(const QSample *s, const AgPrint *p, const AgRoll *r, const AgRest *re, const AgLone *lo,
                    const AgRestSec *rq, TOut *o) {
    *o = (TOut){0};
    AuxGest g; auxgestInit(&g, ttEmit, NULL, o);
    g.noThumb = true; g.restSecs = true; g.thumbSide = gTTSide;
    g.print = p; g.roll = r; g.rest = re; g.lone = lo; g.restSec = rq;
    g.wants = qWantsAll;
    double tEnd = 0;
    for (int k = 0; k < s->nf; k++) { auxgestFrame(&g, s->f[k].c, s->f[k].n, s->f[k].t); auxgestTick(&g, s->f[k].t); tEnd = s->f[k].t; }
    auxgestFrame(&g, NULL, 0, tEnd + 0.01);
    auxgestTick(&g, tEnd + 1);
}
static bool qOk(const QSample *s, const TOut *o) { return o->ne == 1 && !o->held[0] && !strcmp(o->name[0], s->want); }
// Where each contact first landed (frames), in landing order: the resters are the first r,
// the first mover the next. Fills off / spread (the resters' widest pair, mm).
static void qLayout(QSample *s) {
    int ids[AG_MAX * 2], n = 0; float x[AG_MAX * 2], y[AG_MAX * 2];
    for (int k = 0; k < s->nf; k++)
        for (int j = 0; j < s->f[k].n && n < AG_MAX * 2; j++) {
            int id = s->f[k].c[j].id, seen = 0;
            for (int i = 0; i < n && !seen; i++) seen = ids[i] == id;
            if (!seen) { ids[n] = id; x[n] = s->f[k].c[j].x; y[n] = s->f[k].c[j].y; n++; }
        }
    s->off[0] = s->off[1] = NAN; s->spread = 0;
    if (s->r < 1 || n <= s->r) return;
    float cx = 0, cy = 0;
    for (int i = 0; i < s->r; i++) {
        cx += x[i] / s->r; cy += y[i] / s->r;
        for (int j = i + 1; j < s->r; j++)
            s->spread = fmaxf(s->spread, hypotf((x[j] - x[i]) * AG_PAD_W_MM, (y[j] - y[i]) * AG_PAD_H_MM));
    }
    s->off[0] = (x[s->r] - cx) * AG_PAD_W_MM; s->off[1] = (y[s->r] - cy) * AG_PAD_H_MM;
}
static AgPrint gQP; static AgRoll gQR; static AgRest gQRe; static AgLone gQLo; static bool gQLoOk;
static int qScore(const AgRestSec *q, bool print) {
    int ok = 0;
    for (int i = 0; i < gQN; i++) {
        TOut o; qReplay(&gQ[i], &gQP, &gQR, &gQRe, gQLoOk ? &gQLo : NULL, q, &o);
        if (qOk(&gQ[i], &o)) { ok++; continue; }
        if (!print) continue;
        printf("   misread #%d %s (want %s) →", i + 1, gQ[i].ask, gQ[i].want);
        for (int e = 0; e < o.ne; e++) printf(" %s%s", o.held[e] ? "HELD " : "", o.name[e]);
        printf("%s\n", o.ne ? "" : " (nothing)");
    }
    return ok;
}
// THE LAYOUT from the samples: per combination, the first mover's offset (mean, sd ≥ 4 mm), 2+ samples.
static void qLayoutFit(AgRestSec *q) {
    for (int c = 0; c < AG_LAYS; c++) {
        float sx = 0, sy = 0, qx = 0, qy = 0; int n = 0;
        for (int i = 0; i < gQN; i++) {
            if (gQ[i].cls != c || isnan(gQ[i].off[0])) continue;
            sx += gQ[i].off[0]; sy += gQ[i].off[1]; qx += gQ[i].off[0] * gQ[i].off[0]; qy += gQ[i].off[1] * gQ[i].off[1]; n++;
        }
        q->mu[c][0] = q->mu[c][1] = q->sd[c][0] = q->sd[c][1] = 0;
        if (n < 2) continue;
        q->mu[c][0] = sx / n; q->mu[c][1] = sy / n;
        q->sd[c][0] = fmaxf(sqrtf(fmaxf(qx / n - q->mu[c][0] * q->mu[c][0], 0)), 4);
        q->sd[c][1] = fmaxf(sqrtf(fmaxf(qy / n - q->mu[c][1] * q->mu[c][1], 0)), 4);
    }
}
static void qRules(const char *label, const AgRestSec *q) {
    printf("   %s resters down %.0f ms before the movers, drift ≤ %.3f · a contact < %.0f mm from another is a finger · layout weight %.2f\n",
           label, (q->lead > 0 ? q->lead : gQRe.lead) * 1000, q->still > 0 ? q->still : gQRe.still,
           q->fingerMM > 0 ? q->fingerMM : AG_FINGER_MM, q->layW);
    static const char *const nm[AG_LAYS] = { "thumb resting", "1 finger resting", "2 fingers resting", "3 fingers resting" };
    for (int c = 0; c < AG_LAYS; c++)
        if (q->sd[c][0] > 0) printf("      %-18s → mover lands %+4.0f, %+4.0f mm (sd %.0f, %.0f)\n", nm[c], q->mu[c][0], q->mu[c][1], q->sd[c][0], q->sd[c][1]);
}
// The pad's print / rolls / thumb-down rules / lone thumb as remapd loads them, and its restsec.
static NSMutableDictionary *qLoad(const char *side, AgRestSec *cur) {
    NSMutableDictionary *doc = ttLoad(side, &gQP, &gQR, &gQRe);
    NSDictionary *h = [doc[@(side)] isKindOfClass:NSDictionary.class] ? doc[@(side)] : nil;
    NSDictionary *ln = [h[@"lone"] isKindOfClass:NSDictionary.class] ? h[@"lone"] : nil;
    gQLo = agLoneDefault; gQLoOk = ln && ln[@"shape"];
    if (gQLoOk) { gQLo.shape = [ln[@"shape"] floatValue]; gQLo.swipe = [ln[@"swipe"] floatValue]; gQLo.dur = [ln[@"dur"] floatValue]; gQLo.land = [ln[@"land"] floatValue]; }
    NSDictionary *rq = [h[@"restsec"] isKindOfClass:NSDictionary.class] ? h[@"restsec"] : nil;
    *cur = (AgRestSec){ [rq[@"lead"] floatValue], [rq[@"still"] floatValue], [rq[@"fingerMM"] floatValue], [rq[@"layW"] floatValue] };
    NSDictionary *lay = [rq[@"layout"] isKindOfClass:NSDictionary.class] ? rq[@"layout"] : nil;
    for (int c = 0; c < AG_LAYS; c++) {
        NSDictionary *e = lay[c == AG_LAY_THUMB ? @"thumb" : [NSString stringWithFormat:@"%d", c]];
        if (![e isKindOfClass:NSDictionary.class] || [e[@"mu"] count] != 2 || [e[@"sd"] count] != 2) continue;
        for (int a = 0; a < 2; a++) { cur->mu[c][a] = [e[@"mu"][a] floatValue]; cur->sd[c][a] = [e[@"sd"][a] floatValue]; }
    }
    return doc;
}
// Fit, one rule at a time (twice round), THE LAYOUT learnt first; a rule moves only when it
// reads more right. Then save <side>.restsec.
static void qFitSave(const char *side, NSMutableDictionary *doc, const AgRestSec *cur) {
    @autoreleasepool {
    if (!gQN) { fprintf(stderr, "no gestures — nothing saved\n"); exit(1); }
    AgRestSec x = { 0 };
    qLayoutFit(&x);
    float *fld[] = { &x.lead, &x.still, &x.fingerMM, &x.layW };
    static const float cand[][6] = {
        { 0, 0.02f, 0.04f, 0.08f, 0.15f, 0.25f },   // lead (0 = the thumb rules')
        { 0, 0.03f, 0.05f, 0.08f, 0.12f, 0.18f },   // still
        { 0, 20, 25, 30, 40, 44 },                  // fingerMM (0 = 35)
        { 0, 0.5f, 1, 2, 4, 8 },                    // layW (0 = position unused)
    };
    int best = qScore(&x, false);
    for (int pass = 0; pass < 2; pass++)
        for (int f = 0; f < 4; f++)
            for (int c = 0; c < 6; c++) {
                float was = *fld[f];
                *fld[f] = cand[f][c];
                int sc = qScore(&x, false);
                if (sc > best) best = sc; else *fld[f] = was;
            }
    int before = qScore(cur, false);
    printf("\nToday's rules: %d / %d read right\n", before, gQN);
    qRules("today:", cur);
    printf("Learnt:        %d / %d read right\n", best, gQN);
    qRules("learnt:", &x);
    qScore(&x, true);
    NSMutableDictionary *h = [doc[@(side)] isKindOfClass:NSMutableDictionary.class] ? doc[@(side)] : [NSMutableDictionary dictionary];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    NSMutableDictionary *lay = [NSMutableDictionary dictionary];
    for (int c = 0; c < AG_LAYS; c++)
        if (x.sd[c][0] > 0) lay[c == AG_LAY_THUMB ? @"thumb" : [NSString stringWithFormat:@"%d", c]] =
            @{ @"mu": @[r4(x.mu[c][0]), r4(x.mu[c][1])], @"sd": @[r4(x.sd[c][0]), r4(x.sd[c][1])] };
    h[@"restsec"] = @{ @"lead": r4(x.lead), @"still": r4(x.still), @"fingerMM": r4(x.fingerMM), @"layW": r4(x.layW), @"layout": lay,
                       @"accuracy": [NSString stringWithFormat:@"%d/%d (rules before %d/%d)", best, gQN, before, gQN],
                       @"learnt": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date] };
    doc[@(side)] = h;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:@"/Users/josh/Code/Scripts/remap/thumbprint.json" atomically:YES]) { fprintf(stderr, "could not write thumbprint.json\n"); exit(1); }
    printf("\nSaved → remap/thumbprint.json (%s.restsec). remapd picks it up now. Frames → remap/rest_calib_%s.jsonl\n", side, side);
    }
    exit(0);
}
// One sample's line: the ask, where the mover landed, and today's verdict.
static void qShow(const QSample *s, const AgRestSec *cur, int num) {
    TOut o; qReplay(s, &gQP, &gQR, &gQRe, gQLoOk ? &gQLo : NULL, cur, &o);
    printf("#%-2d %-46s", num, s->ask);
    if (!isnan(s->off[0])) printf(" mover %+4.0f,%+4.0f mm", s->off[0], s->off[1]);
    if (s->r > 1) printf(" · resters %.0f mm wide", s->spread);
    printf(" →");
    for (int e = 0; e < o.ne; e++) printf(" %s%s", o.held[e] ? "HELD " : "", o.name[e]);
    printf("%s   %s\n", o.ne ? "" : " (nothing)", qOk(s, &o) ? "✓" : "✗");
    fflush(stdout);
}
static void qFromJson(QSample *s, NSDictionary *rec) {
    NSArray *frames = rec[@"frames"];
    *s = (QSample){ .r = [rec[@"r"] intValue], .cls = [rec[@"cls"] intValue], .nt = [rec[@"nt"] intValue], .nf = (int)frames.count };
    snprintf(s->want, sizeof s->want, "%s", [rec[@"want"] UTF8String]);
    snprintf(s->ask, sizeof s->ask, "%s", [rec[@"ask"] UTF8String]);
    s->f = calloc((size_t)s->nf + 1, sizeof(RecF));
    for (int k = 0; k < s->nf; k++) {
        s->f[k].t = [frames[k][@"t"] doubleValue];
        for (NSArray *c in frames[k][@"c"]) {
            if (s->f[k].n >= AG_MAX) break;
            s->f[k].c[s->f[k].n++] = (AgContact){ [c[0] intValue], [c[1] floatValue], [c[2] floatValue],
                                                  [c[4] floatValue], [c[5] floatValue], [c[6] floatValue], [c[3] floatValue] };
        }
    }
    qLayout(s);
}
// REFIT from a recorded session (no pads): `thumbprint <side> rest refit <rest_calib.jsonl>`.
static void restRefit(const char *side, const char *file) {
    @autoreleasepool {
    gTTSide = strcmp(side, "left") ? -1 : 1;
    AgRestSec cur; NSMutableDictionary *doc = qLoad(side, &cur);
    NSString *all = [NSString stringWithContentsOfFile:@(file) encoding:NSUTF8StringEncoding error:NULL];
    if (!all) { fprintf(stderr, "can't read %s\n", file); exit(1); }
    for (NSString *ln in [all componentsSeparatedByString:@"\n"]) {
        if (!ln.length || gQN >= 64) continue;
        NSDictionary *rec = [NSJSONSerialization JSONObjectWithData:[ln dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![rec isKindOfClass:NSDictionary.class]) continue;
        qFromJson(&gQ[gQN], rec);
        qShow(&gQ[gQN], &cur, gQN + 1);
        gQN++;
    }
    qFitSave(side, doc, &cur);
    }
    exit(0);
}
static void restSession(const char *side) {
    @autoreleasepool {
    gTTSide = strcmp(side, "left") ? -1 : 1;
    AgRestSec cur; NSMutableDictionary *doc = qLoad(side, &cur);
    if (!gQP.ok) printf("(no thumbprint for the %s pad — run `thumbprint %s` first for the shapes)\n", side, side);
    // { want, ask, resters, layout combination, contacts }
    NSMutableArray<NSArray *> *u = [NSMutableArray array];
    NSArray *fw = @[@"", @"1 finger", @"2 fingers", @"3 fingers"];
    for (int r = 1; r <= 3; r++) {
        NSString *R = [NSString stringWithFormat:@"REST %@", fw[r]];
        int times[] = { 3, 2 };
        for (int m = 1; m <= 2 && r + m <= 4; m++)
            for (int i = 0; i < times[m - 1]; i++)
                [u addObject:@[[NSString stringWithFormat:@"rest%d:tap%d", r, m], [NSString stringWithFormat:@"%@, then tap %@ beside them", R, fw[m]], @(r), @(r), @(r + m)]];
        [u addObject:@[[NSString stringWithFormat:@"rest%d:up1", r], [NSString stringWithFormat:@"%@, then swipe 1 finger UP", R], @(r), @(r), @(r + 1)]];
        [u addObject:@[[NSString stringWithFormat:@"rest%d:down1", r], [NSString stringWithFormat:@"%@, then swipe 1 finger DOWN", R], @(r), @(r), @(r + 1)]];
        for (int i = 0; i < 2; i++)
            [u addObject:@[[NSString stringWithFormat:@"rest%d:thumbtap", r], [NSString stringWithFormat:@"%@, then TAP THE THUMB", R], @(r), @-1, @(r + 1)]];
        [u addObject:@[[NSString stringWithFormat:@"rest%d:thumbswipeL", r], [NSString stringWithFormat:@"%@, then swipe the THUMB LEFT", R], @(r), @-1, @(r + 1)]];
        [u addObject:@[[NSString stringWithFormat:@"rest%d:thumbswipeR", r], [NSString stringWithFormat:@"%@, then swipe the THUMB RIGHT", R], @(r), @-1, @(r + 1)]];
    }
    for (int i = 0; i < 3; i++) [u addObject:@[@"restthumb:tap1", @"REST THE THUMB, then tap 1 finger", @1, @(AG_LAY_THUMB), @2]];
    for (int i = 0; i < 2; i++) [u addObject:@[@"restthumb:tap2", @"REST THE THUMB, then tap 2 fingers", @1, @(AG_LAY_THUMB), @3]];
    for (int i = 0; i < 2; i++) [u addObject:@[@"tap1", @"tap 1 finger — nothing resting", @0, @-1, @1]];
    [u addObject:@[@"tap2", @"tap 2 fingers — nothing resting", @0, @-1, @2]];
    for (NSUInteger i = u.count; i > 1; i--) [u exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    calibOn();
    NSString *path = [NSString stringWithFormat:@"/Users/josh/Code/Scripts/remap/rest_calib_%s.jsonl", side];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    printf("Resting sections — the %s pad: %lu gestures. Do them the way you do for real.\n", side, (unsigned long)u.count);
    printf("Rest first, then move; lift EVERYTHING after each one. The pads don't click or type now. Ctrl-C to stop.\n");
    qRules("today:", &cur);
    pthread_mutex_lock(&gMu); gArmed = true; gRec = true; pthread_mutex_unlock(&gMu);
    for (NSUInteger i = 0; i < u.count && gQN < 64; ) {
        NSArray *a = u[i];
        printf("\n[%2lu/%lu]  %s\n", (unsigned long)i + 1, (unsigned long)u.count, [a[1] UTF8String]); fflush(stdout);
        Tr t[MAXT]; int nt = nextGesture(t), want = [a[4] intValue];
        if (nt != want) { printf("   got %d contact%s, wanted %d — again\n", nt, nt == 1 ? "" : "s", want); continue; }
        QSample *s = &gQ[gQN];
        *s = (QSample){ .r = [a[2] intValue], .cls = [a[3] intValue], .nt = nt, .nf = gNFOut };
        strlcpy(s->want, [a[0] UTF8String], sizeof s->want);
        strlcpy(s->ask, [a[1] UTF8String], sizeof s->ask);
        s->f = malloc(sizeof(RecF) * (size_t)(gNFOut ? gNFOut : 1));
        memcpy(s->f, gFOut, sizeof(RecF) * (size_t)gNFOut);
        qLayout(s);
        printf("   "); qShow(s, &cur, gQN + 1);
        // Log: the ask, where everything landed, today's verdict, and every frame.
        TOut o; qReplay(s, &gQP, &gQR, &gQRe, gQLoOk ? &gQLo : NULL, &cur, &o);
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:s->nf], *got = [NSMutableArray array];
        for (int k = 0; k < s->nf; k++) {
            NSMutableArray *cs = [NSMutableArray array];
            for (int j = 0; j < s->f[k].n; j++) {
                AgContact *c = &s->f[k].c[j];
                [cs addObject:@[@(c->id), @(roundf(c->x * 1e4f) / 1e4f), @(roundf(c->y * 1e4f) / 1e4f),
                                @(roundf(c->size * 1e3f) / 1e3f), @(roundf(c->major * 100) / 100), @(roundf(c->minor * 100) / 100), @(roundf(c->angle * 1e3f) / 1e3f)]];
            }
            [frames addObject:@{ @"t": @(round((s->f[k].t - s->f[0].t) * 1e4) / 1e4), @"c": cs }];
        }
        for (int e = 0; e < o.ne; e++) [got addObject:[NSString stringWithFormat:@"%s%s", o.held[e] ? "HELD " : "", o.name[e]]];
        NSDictionary *rec = @{ @"ask": a[1], @"want": a[0], @"r": a[2], @"cls": a[3], @"nt": @(nt), @"got": got, @"ok": @(qOk(s, &o)),
                               @"mover_mm": isnan(s->off[0]) ? @[] : @[@(roundf(s->off[0])), @(roundf(s->off[1]))], @"resters_mm": @(roundf(s->spread)),
                               @"frames": frames };
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:rec options:0 error:NULL] mutableCopy];
        [line appendBytes:"\n" length:1];
        [fh writeData:line];
        gQN++; i++;
    }
    [fh closeFile];
    pthread_mutex_lock(&gMu); gArmed = false; gRec = false; pthread_mutex_unlock(&gMu);
    qFitSave(side, doc, &cur);
    }
    exit(0);
}

/* ── HOLD: what rests on the left pad as the right pad's modifier (2026-10-21) ──
   Poses taken WHILE HELD (a second with nothing landing or lifting — no lift waited for,
   so the palm may rest throughout): fingertips 1–4 with and without the thumb, the thumb
   alone, knuckles, the palm. More contacts than a pose
   asks for are never an error: the most thumb-like / fingertip-like (by what is learnt so
   far) are the thumb and tips, the rest the pose's extra kind (palm), or left out of the fit
   when it names none. Every contact is a sample of its kind (auxgest.h AGK_*); with just
   the pose's contacts the thumb is the one furthest right and low (the left hand).
   Knuckles + thumb is a TEST pose only (must read as nothing).
   Fits one Gaussian per kind over agHoldFeatures, judges every pose by models made without
   it (the state it would give, against the plain thumbprint's), saves left.hold; poses go
   to remap/hold_calib_left.jsonl (`thumbprint left hold refit <file>` refits from them). */
#define HMAXP 4000
// idle: a moment of the resting hand (`thumbprint left idle`), want 0, every contact AGK_IDLE+
// pos: its contacts carry where they sat (f[AGH…] = agHoldPos; older recordings: shape only)
// fold: the hand reader's block cross-validation (hFolds)
typedef struct { int want, n, test, idle, combo, pos, fold; float f[MAXT][AGHP], score[MAXT], x[MAXT], y[MAXT]; int kind[MAXT]; char ask[64]; } HPose;
static HPose gH[HMAXP]; static int gHN = 0;

static int gHSide = 1;          // the hand's thumb side (hPlace): +1 = right, the left hand
static float gHoldMargin = 0;   // the unsure margin hFit gives its models (hJudgeSave picks it; sessions start from the saved one)
// withIdle: the resting hand's clusters too (else left out, for the before / after).
// Shape from every sample; place only from samples that carry it — a kind with fewer than 3
// gets the pooled place stats of all kinds (says nothing either way).
static void hFit(AgHold *h, int skip, bool withIdle) {
    *h = (AgHold){ .ok = false };
    double ps_[AGP] = {0}, pss[AGP] = {0}; int pn = 0;
    for (int p = 0; p < gHN; p++) {
        if (p == skip || gH[p].test || !gH[p].pos) continue;
        for (int c = 0; c < gH[p].n; c++) {
            if (gH[p].kind[c] < 0 || (gH[p].kind[c] >= AGK_IDLE && !withIdle)) continue;
            pn++;
            for (int i = 0; i < AGP; i++) { ps_[i] += gH[p].f[c][AGH + i]; pss[i] += gH[p].f[c][AGH + i] * gH[p].f[c][AGH + i]; }
        }
    }
    for (int k = 0; k < AGK_N; k++) {
        if (k >= AGK_IDLE && !withIdle) continue;
        double s[AGHP] = {0}, ss[AGHP] = {0}; int n = 0, np = 0;
        for (int p = 0; p < gHN; p++) {
            if (p == skip || gH[p].test) continue;
            for (int c = 0; c < gH[p].n; c++) {
                if (gH[p].kind[c] != k) continue;
                n++; np += gH[p].pos;
                int d = gH[p].pos ? AGHP : AGH;
                for (int i = 0; i < d; i++) { s[i] += gH[p].f[c][i]; ss[i] += gH[p].f[c][i] * gH[p].f[c][i]; }
            }
        }
        if (n < 3) continue;
        h->has[k] = true;
        for (int i = 0; i < AGHP; i++) {
            bool place = i >= AGH;
            double m = place ? (np >= 3 ? np : pn) : n, sum = place && np < 3 ? ps_[i - AGH] : s[i], sq = place && np < 3 ? pss[i - AGH] : ss[i];
            if (m < 1) { h->mu[k][i] = 0; h->sd[k][i] = 1e3f; continue; }
            double mu = sum / m;
            h->mu[k][i] = (float)mu;
            h->sd[k][i] = fmaxf(sqrtf((float)fmax(sq / m - mu * mu, 0)), place ? 0.01f : 0.02f);
        }
    }
    h->ok = h->has[AGK_FINGER];
    h->margin = gHoldMargin;
}
// A pose's place features from its contacts' x / y (all of them = the hand).
static void hPlace(HPose *ps, const char *side) {
    AgHand hd = agHandOf(ps->x, ps->y, ps->n, strcmp(side, "left") ? -1 : 1);
    for (int c = 0; c < ps->n; c++) agHoldPos(&hd, ps->x[c], ps->y[c], ps->f[c] + AGH);
    ps->pos = 1;
    gHSide = hd.side;
}
/* ── THE HAND READER's fit (auxgest.h AgReader, 2026-10-21) ──
   Roles by STRUCTURE, not by the per-kind models: the recorded thumb is the thumb, the
   pose's tips are its highest other contacts, everything else (and every idle contact) is
   the resting hand. Shapes: one Gaussian for tips, one for the thumb, AGR_RESTS k-means
   clusters for the resting hand. Weights: the log-linear model over every hypothesis
   (agReadHyps), maximizing each moment's probability of its own state (Adam, L2). Only
   recordings that carry positions. fold ≥ 0: leave that fold out (hFolds). */
#define HR_TAU  0.7f    // block CV 2026-10-21: 0.5 → idle as fingers 1/281, 0.7 → 0/281 at 3 fewer combos right
#define HR_KEEP 0.3f
static int hRoles(const HPose *ps, int *role) {   // 1 tip, 2 thumb, 0 the resting hand
    int tips = ps->idle ? 0 : ps->want == AG_HOLD_THREE_THUMB ? 3 : ps->want == 5 ? 4 : ps->want;
    for (int c = 0; c < ps->n; c++) role[c] = !ps->idle && ps->kind[c] == AGK_THUMB ? 2 : 0;
    for (int k = 0; k < tips; k++) {
        int bi = -1;
        for (int c = 0; c < ps->n; c++) if (!role[c] && (bi < 0 || ps->y[c] > ps->y[bi])) bi = c;
        if (bi >= 0) role[bi] = 1;
    }
    return tips;
}
static void hGauss(AgGauss *g, float (*rows)[AGH], const int *pick, int want, int n) {
    double s[AGH] = {0}, ss[AGH] = {0}; int m = 0;
    for (int r = 0; r < n; r++) if (!pick || pick[r] == want) { m++; for (int i = 0; i < AGH; i++) { s[i] += rows[r][i]; ss[i] += rows[r][i] * rows[r][i]; } }
    for (int i = 0; i < AGH; i++) {
        double mu = m ? s[i] / m : 0;
        g->mu[i] = (float)mu; g->sd[i] = m ? fmaxf(sqrtf((float)fmax(ss[i] / m - mu * mu, 0)), 0.02f) : 1e3f;
    }
}
static bool hUse(const HPose *ps, int fold) { return ps->pos && ps->n && !ps->test && (fold < 0 || ps->fold != fold); }
static void hReaderFit(AgReader *r, int fold) {
    *r = (AgReader){ .ok = false, .tau = HR_TAU, .keep = HR_KEEP };
    static float tip[HMAXP * 4][AGH], thb[HMAXP][AGH], rst[HMAXP * MAXT][AGH];
    static int asg[HMAXP * MAXT];
    int nt = 0, nb = 0, nr = 0;
    for (int p = 0; p < gHN; p++) {
        if (!hUse(&gH[p], fold)) continue;
        int role[MAXT]; hRoles(&gH[p], role);
        for (int c = 0; c < gH[p].n; c++) {
            float *dst = role[c] == 1 ? tip[nt++] : role[c] == 2 ? thb[nb++] : rst[nr++];
            memcpy(dst, gH[p].f[c], sizeof(float) * AGH);
        }
    }
    if (nt < 3 || nb < 3 || nr < 3 * AGR_RESTS) return;
    hGauss(&r->tip, tip, NULL, 0, nt); hGauss(&r->thumb, thb, NULL, 0, nb);
    // The resting hand: k-means on standardized shape, nearest the mean then farthest-point start.
    AgGauss all; hGauss(&all, rst, NULL, 0, nr);
    double cen[AGR_RESTS][AGH];
    #define HRZ(r_, i) ((rst[r_][i] - all.mu[i]) / all.sd[i])
    for (int k = 0; k < AGR_RESTS; k++) {
        double best = k ? -1 : 1e30; int bi = 0;
        for (int q = 0; q < nr; q++) {
            double d = k ? 1e30 : 0;
            for (int j = 0; j < (k ? k : 1); j++) {
                double e = 0;
                for (int i = 0; i < AGH; i++) { double z = HRZ(q, i) - (k ? cen[j][i] : 0); e += z * z; }
                d = k ? fmin(d, e) : e;
            }
            if (k ? d > best : d < best) { best = d; bi = q; }
        }
        for (int i = 0; i < AGH; i++) cen[k][i] = HRZ(bi, i);
    }
    for (int it = 0; it < 30; it++) {
        double sum[AGR_RESTS][AGH] = {{0}}; int cnt[AGR_RESTS] = {0};
        for (int q = 0; q < nr; q++) {
            int bk = 0; double bd = 1e30;
            for (int k = 0; k < AGR_RESTS; k++) {
                double e = 0;
                for (int i = 0; i < AGH; i++) { double z = HRZ(q, i) - cen[k][i]; e += z * z; }
                if (e < bd) { bd = e; bk = k; }
            }
            asg[q] = bk; cnt[bk]++;
            for (int i = 0; i < AGH; i++) sum[bk][i] += HRZ(q, i);
        }
        for (int k = 0; k < AGR_RESTS; k++) if (cnt[k]) for (int i = 0; i < AGH; i++) cen[k][i] = sum[k][i] / cnt[k];
    }
    #undef HRZ
    for (int k = 0; k < AGR_RESTS; k++) hGauss(&r->rest[k], rst, asg, k, nr);
    // The weights.
    int np = 0;
    for (int p = 0; p < gHN; p++) np += hUse(&gH[p], fold);
    AgHyp *hs = malloc(sizeof(AgHyp) * AGR_MAXH * (size_t)np);
    int *off = malloc(sizeof(int) * (size_t)(np + 1)), *want = malloc(sizeof(int) * (size_t)np);
    int q = 0; off[0] = 0;
    for (int p = 0; p < gHN; p++) {
        if (!hUse(&gH[p], fold)) continue;
        want[q] = gH[p].want;
        off[q + 1] = off[q] + agReadHyps(r, &gH[p].f[0][0], AGHP, gH[p].x, gH[p].y, gH[p].n, gHSide, hs + off[q]);
        q++;
    }
    double w[AGR] = {0}, m1[AGR] = {0}, m2[AGR] = {0};
    for (int it = 1; it <= 150; it++) {
        double g[AGR] = {0}; int n = 0;
        for (int i = 0; i < np; i++) {
            double s[AGR_MAXH], mx = -1e30, z = 0, pw = 0;
            int nh = off[i + 1] - off[i]; AgHyp *H = hs + off[i];
            for (int j = 0; j < nh; j++) { s[j] = 0; for (int d = 0; d < AGR; d++) s[j] += w[d] * H[j].phi[d]; mx = fmax(mx, s[j]); }
            for (int j = 0; j < nh; j++) { s[j] = exp(s[j] - mx); z += s[j]; }
            for (int j = 0; j < nh; j++) { s[j] /= z; if (H[j].st == want[i]) pw += s[j]; }
            if (pw <= 1e-300) continue;
            n++;
            for (int j = 0; j < nh; j++) {
                double c = (H[j].st == want[i] ? s[j] / pw : 0) - s[j];
                for (int d = 0; d < AGR; d++) g[d] += c * H[j].phi[d];
            }
        }
        for (int d = 0; d < AGR; d++) {
            double gi = (n ? g[d] / n : 0) - 0.003 * w[d];
            m1[d] = 0.9 * m1[d] + 0.1 * gi; m2[d] = 0.999 * m2[d] + 0.001 * gi * gi;
            w[d] += 0.1 * (m1[d] / (1 - pow(0.9, it))) / (sqrt(m2[d] / (1 - pow(0.999, it))) + 1e-8);
        }
    }
    for (int d = 0; d < AGR; d++) r->w[d] = (float)w[d];
    free(hs); free(off); free(want);
    r->ok = true;
}
// Folds: each recorded run (posed holds / resting hand / each combo) cut into 5 stretches
// IN TIME ORDER — moments 0.15 s apart are near-copies, so leave-one-out would flatter.
#define HR_FOLDS 5
static void hFolds(void) {
    for (int p = 0; p < gHN; p++) {
        int at = 0, of = 0;
        for (int q = 0; q < gHN; q++)
            if (gH[q].idle == gH[p].idle && gH[q].combo == gH[p].combo && gH[q].want == gH[p].want) { at += q < p; of++; }
        gH[p].fold = at * HR_FOLDS / of;
    }
}
// One recorded contact: its settled shape and place (x / y, features by hPlace), print score.
static void hContact(HPose *ps, int c, const Tr *t, const AgPrint *p) {
    agHoldFeatures(TSH(*t), ps->f[c]);
    float f[AGF]; agFeatures(TSH(*t), f);
    ps->score[c] = p->ok ? agPrintScore(p, f) : 0;
    ps->x[c] = t->st.ax; ps->y[c] = t->st.ay;
}
// A pose's contacts for the jsonl: [major, minor, angle, size, kind, print score, x, y].
static NSArray *hContactsJson(const HPose *ps, const Tr *t) {
    NSMutableArray *cs = [NSMutableArray array];
    for (int c = 0; c < ps->n; c++)
        [cs addObject:@[@(t[c].st.major), @(t[c].st.minor), @(t[c].st.angle), @(t[c].st.size), @(ps->kind[c]),
                        @(roundf(ps->score[c] * 100) / 100), @(roundf(ps->x[c] * 1e4f) / 1e4f), @(roundf(ps->y[c] * 1e4f) / 1e4f)]];
    return cs;
}
// The resting hand's contacts → AGK_IDLES clusters (k-means on standardized features,
// farthest-point start), written into their kind as AGK_IDLE + cluster.
static void hIdleCluster(void) {
    int n = 0;
    double mu[AGH] = {0}, sd[AGH] = {0};
    #define HIDLE(p, c) (gH[p].kind[c] >= AGK_IDLE)   // the resting hand's: idle moments and combos' extras
    for (int p = 0; p < gHN; p++) for (int c = 0; c < gH[p].n; c++) if (HIDLE(p, c)) {
        n++; for (int i = 0; i < AGH; i++) { mu[i] += gH[p].f[c][i]; sd[i] += gH[p].f[c][i] * gH[p].f[c][i]; }
    }
    if (!n) return;
    for (int i = 0; i < AGH; i++) { mu[i] /= n; sd[i] = fmax(sqrt(fmax(sd[i] / n - mu[i] * mu[i], 0)), 1e-3); }
    int K = n >= 3 * AGK_IDLES ? AGK_IDLES : 1;
    double cen[AGK_IDLES][AGH];
    #define HZ(p, c, i) ((gH[p].f[c][i] - mu[i]) / sd[i])
    for (int k = 0; k < K; k++) {   // start: nearest the mean, then each farthest from those so far
        double best = k ? -1 : 1e30; int bp = 0, bc = 0;
        for (int p = 0; p < gHN; p++) for (int c = 0; c < gH[p].n; c++) if (HIDLE(p, c)) {
            double d = k ? 1e30 : 0;
            for (int j = 0; j < (k ? k : 1); j++) {
                double e = 0;
                for (int i = 0; i < AGH; i++) { double z = HZ(p, c, i) - (k ? cen[j][i] : 0); e += z * z; }
                d = k ? fmin(d, e) : e;
            }
            if (k ? d > best : d < best) { best = d; bp = p; bc = c; }
        }
        for (int i = 0; i < AGH; i++) cen[k][i] = HZ(bp, bc, i);
    }
    for (int it = 0; it < 30; it++) {
        double sum[AGK_IDLES][AGH] = {{0}}; int cnt[AGK_IDLES] = {0};
        for (int p = 0; p < gHN; p++) for (int c = 0; c < gH[p].n; c++) if (HIDLE(p, c)) {
            int bk = 0; double bd = 1e30;
            for (int k = 0; k < K; k++) {
                double e = 0;
                for (int i = 0; i < AGH; i++) { double z = HZ(p, c, i) - cen[k][i]; e += z * z; }
                if (e < bd) { bd = e; bk = k; }
            }
            gH[p].kind[c] = AGK_IDLE + bk; cnt[bk]++;
            for (int i = 0; i < AGH; i++) sum[bk][i] += HZ(p, c, i);
        }
        for (int k = 0; k < K; k++) if (cnt[k]) for (int i = 0; i < AGH; i++) cen[k][i] = sum[k][i] / cnt[k];
    }
    #undef HZ
    #undef HIDLE
}
// The state a pose reads as: by the hold model, or (h NULL) by the plain thumbprint.
static int hState(const HPose *ps, const AgHold *h) {
    if (h && h->rd.ok && ps->pos) return agReadHand(&h->rd, &ps->f[0][0], AGHP, ps->x, ps->y, ps->n, gHSide, NULL, NULL);
    int k[MAXT], alt[MAXT], bi = -1;
    float cut;   // remapd's top row first (agTopRow)
    if (ps->pos) { int top = agTopRow(ps->y, ps->n, &cut); if (top) return top; }
    for (int c = 0; c < ps->n; c++) {
        alt[c] = AGK_FINGER;
        k[c] = h ? agHoldKindAlt(h, ps->f[c], ps->pos ? AGHP : AGH, &alt[c]) : ps->score[c] > 0 ? AGK_THUMB : AGK_FINGER;
        if (!h && k[c] == AGK_THUMB && (bi < 0 || ps->score[c] > ps->score[bi])) bi = c;
    }
    int m = 0, kk[MAXT], ka[MAXT];
    for (int c = 0; c < ps->n; c++) {
        if (!h && c != bi) k[c] = AGK_FINGER;
        if (!agKindIgnored(k[c])) { ka[m] = alt[c]; kk[m++] = k[c]; }   // unsure: as remapd, only when it changes the state
    }
    return agHoldStateU(kk, ka, m);
}
static const char *hName(int st) {
    static const char *const n[AG_HOLD_STATES] = { "nothing", "1", "2", "3", "4", "4 + thumb", "3 + thumb" };
    return st >= 0 && st < AG_HOLD_STATES ? n[st] : "?";
}
static void hJudgeSave(const char *side) {
    int poses = 0, idles = 0, combos = 0;
    for (int p = 0; p < gHN; p++) { poses += !gH[p].idle && !gH[p].combo; idles += gH[p].idle; combos += gH[p].combo; }
    if (!poses) { fprintf(stderr, "no hold poses — run `thumbprint %s hold` first\n", side); exit(1); }
    hIdleCluster();
    // THE UNSURE MARGIN: each candidate judged on everything (poses / combos by models made
    // without them); costs per share of its set — a resting hand read as fingers 5, a combo
    // read as a WRONG count 3, a combo read as nothing 1 (user: rather idle than false fingers).
    {
        static const float M[] = { 0, 0.5f, 1, 2, 3, 4, 6, 8, 12 };
        enum { NM = sizeof M / sizeof *M };
        int idleF[NM] = {0}, cOk[NM] = {0}, cWrong[NM] = {0}, cNone[NM] = {0};
        for (int p = 0; p < gHN; p++) {
            if (!gH[p].combo) continue;
            AgHold h; hFit(&h, p, true);
            for (int m = 0; m < NM; m++) {
                h.margin = M[m];
                int got = hState(&gH[p], &h);
                cOk[m] += got == gH[p].want; cNone[m] += got == 0 && gH[p].want != 0; cWrong[m] += got != gH[p].want && got != 0;
            }
        }
        AgHold h; hFit(&h, -1, true);
        for (int p = 0; p < gHN; p++) if (gH[p].idle)
            for (int m = 0; m < NM; m++) { h.margin = M[m]; idleF[m] += hState(&gH[p], &h) != 0; }
        int best = 0; double bc = 1e9;
        printf("\nUnsure margin (higher = more often nothing):\n   %6s  %22s  %14s  %12s  %12s\n", "margin", "resting hand as fingers", "combos right", "wrong count", "as nothing");
        for (int m = 0; m < NM; m++) {
            double cost = (idles ? 5.0 * idleF[m] / idles : 0) + (combos ? (3.0 * cWrong[m] + cNone[m]) / combos : 0);
            if (cost < bc - 1e-9) { bc = cost; best = m; }
        }
        for (int m = 0; m < NM; m++)
            printf("   %6.1f  %12d / %-9d  %6d / %-6d  %12d  %12d%s\n", M[m], idleF[m], idles, cOk[m], combos, cWrong[m], cNone[m], m == best ? "   ← picked" : "");
        gHoldMargin = M[best];
    }
    // The poses and combos, each judged by models made without it — with the resting hand
    // and without.
    int right = 0, plain = 0, base = 0;
    int cRight[AG_HOLD_STATES] = {0}, cAll[AG_HOLD_STATES] = {0}, cGot[AG_HOLD_STATES][AG_HOLD_STATES] = {{0}};
    for (int p = 0; p < gHN; p++) {
        if (gH[p].idle) continue;
        AgHold h, h0; hFit(&h, p, true);
        int got = hState(&gH[p], h.ok ? &h : NULL), w = gH[p].want;
        if (gH[p].combo) {
            if (w < 0 || w >= AG_HOLD_STATES || got < 0 || got >= AG_HOLD_STATES) continue;
            cAll[w]++; cRight[w] += got == w; cGot[w][got]++;
            continue;
        }
        hFit(&h0, p, false);
        right += got == w; plain += hState(&gH[p], h0.ok ? &h0 : NULL) == w;
        base += hState(&gH[p], NULL) == w;
        if (got != w) printf("   would misread pose %d (%s): reads as %s\n", p + 1, gH[p].ask, hName(got));
    }
    AgHold h, h0; hFit(&h, -1, true); hFit(&h0, -1, false);
    if (!h.ok) { fprintf(stderr, "too few fingertips to fit\n"); exit(1); }
    // The resting hand: every moment must read as nothing.
    int fp = 0, fp0 = 0;
    for (int p = 0; p < gHN; p++) if (gH[p].idle) { fp += hState(&gH[p], &h) != 0; fp0 += hState(&gH[p], &h0) != 0; }
    printf("\nPosed holds read right: %d / %d (each judged without itself)", right, poses);
    if (idles) printf("; without the resting hand learnt: %d / %d", plain, poses);
    printf("; the thumbprint alone: %d / %d.\n", base, poses);
    int cr = 0;
    if (combos) {
        printf("Combos caught in use (each moment judged without itself):\n");
        for (int w = 0; w < AG_HOLD_STATES; w++) {
            if (!cAll[w]) continue;
            cr += cRight[w];
            printf("   %-10s %4d / %-4d right", hName(w), cRight[w], cAll[w]);
            bool any = false;
            for (int g = 0; g < AG_HOLD_STATES; g++)
                if (g != w && cGot[w][g]) { printf("%s %s ×%d", any ? "," : "   misread as", hName(g), cGot[w][g]); any = true; }
            printf("\n");
        }
    }
    if (idles) printf("Resting hand read as fingers: %d / %d moments (was %d / %d before it was learnt).\n", fp, idles, fp0, idles);
    // THE HAND READER (what remapd uses when it's there), by block cross-validation: each
    // fifth of every run judged by a reader fit without it.
    hFolds();
    int rAll[AG_HOLD_STATES] = {0}, rOk[AG_HOLD_STATES] = {0}, rGot[AG_HOLD_STATES][AG_HOLD_STATES] = {{0}};
    int rPose = 0, rPoseOk = 0, rIdle = 0, rIdleF = 0, rWrong = 0, rNone = 0;
    for (int f = 0; f < HR_FOLDS; f++) {
        AgHold hr = { .ok = false }; hReaderFit(&hr.rd, f);
        if (!hr.rd.ok) continue;
        for (int p = 0; p < gHN; p++) {
            if (gH[p].fold != f || !gH[p].pos || !gH[p].n) continue;
            int got = hState(&gH[p], &hr), w = gH[p].want;
            if (gH[p].idle) { rIdle++; rIdleF += got != 0; continue; }
            if (!gH[p].combo) { rPose++; rPoseOk += got == w; continue; }
            if (w < 0 || w >= AG_HOLD_STATES) continue;
            rAll[w]++; rOk[w] += got == w; rGot[w][got]++; rWrong += got != w && got; rNone += !got && w;
        }
    }
    AgReader rd; hReaderFit(&rd, -1);
    int rc = 0, rn = 0;
    if (rd.ok) {
        printf("\nHAND READER (whole hand at once; each fifth of every run judged without it):\n");
        for (int w = 0; w < AG_HOLD_STATES; w++) {
            if (!rAll[w]) continue;
            rc += rOk[w]; rn += rAll[w];
            printf("   %-10s %4d / %-4d right", hName(w), rOk[w], rAll[w]);
            bool any = false;
            for (int g = 0; g < AG_HOLD_STATES; g++)
                if (g != w && rGot[w][g]) { printf("%s %s ×%d", any ? "," : "   misread as", hName(g), rGot[w][g]); any = true; }
            printf("\n");
        }
        printf("   combos %d / %d right, %d a wrong count, %d nothing; posed holds %d / %d; resting hand as fingers %d / %d.\n",
               rc, rn, rWrong, rNone, rPoseOk, rPose, rIdleF, rIdle);
    } else printf("\nHand reader: too little recorded with positions (needs tips, a thumb and the resting hand).\n");
    static const char *const kn[AGK_N] = { "finger", "thumb", "knuckle", "palm", "idle 1", "idle 2", "idle 3" };
    static const char *const fn[AGHP] = { "log length", "log width", "e·cos 2θ", "e·sin 2θ", "log size", "size/area",
                                          "below top", "from thumb" };
    printf("   %-12s", ""); for (int k = 0; k < AGK_N; k++) printf(" %16s", h.has[k] ? kn[k] : "(not seen)"); printf("\n");
    for (int i = 0; i < AGHP; i++) {
        printf("   %-12s", fn[i]);
        for (int k = 0; k < AGK_N; k++) if (h.has[k]) printf("   %6.2f ± %-5.2f", h.mu[k][i], h.sd[k][i]); else printf(" %16s", "");
        printf("\n");
    }
    NSString *path = @"/Users/josh/Code/Scripts/remap/thumbprint.json";
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *doc = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:NULL] : nil;
    if (![doc isKindOfClass:NSMutableDictionary.class]) doc = [NSMutableDictionary dictionary];
    NSMutableDictionary *sd = [doc[@(side)] isKindOfClass:NSMutableDictionary.class] ? doc[@(side)] : [NSMutableDictionary dictionary];
    id (^r4)(float) = ^id(float v) { return @(roundf(v * 1e4f) / 1e4f); };
    NSMutableDictionary *hd = [NSMutableDictionary dictionary];
    NSMutableArray *idle = [NSMutableArray array];
    static NSString *const names[AGK_IDLE] = { @"finger", @"thumb", @"knuckle", @"palm" };
    for (int k = 0; k < AGK_N; k++) {
        if (!h.has[k]) continue;
        NSMutableArray *mu = [NSMutableArray array], *s = [NSMutableArray array];
        for (int i = 0; i < AGHP; i++) { [mu addObject:r4(h.mu[k][i])]; [s addObject:r4(h.sd[k][i])]; }
        int n = 0;
        for (int p = 0; p < gHN; p++) for (int c = 0; c < gH[p].n; c++) n += !gH[p].test && gH[p].kind[c] == k;
        NSDictionary *e = @{ @"mu": mu, @"sd": s, @"n": @(n) };
        if (k < AGK_IDLE) hd[names[k]] = e; else [idle addObject:e];
    }
    if (idle.count) hd[@"idle"] = idle;
    hd[@"margin"] = @(gHoldMargin);
    hd[@"accuracy"] = [NSString stringWithFormat:@"%d/%d poses (thumbprint alone %d/%d); combos %d/%d; resting hand as fingers %d/%d (was %d)",
                                                 right, poses, base, poses, cr, combos, fp, idles, fp0];
    hd[@"learnt"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    if (rd.ok) {
        NSDictionary *(^gj)(const AgGauss *) = ^NSDictionary *(const AgGauss *g) {
            NSMutableArray *mu = [NSMutableArray array], *s = [NSMutableArray array];
            for (int i = 0; i < AGH; i++) { [mu addObject:r4(g->mu[i])]; [s addObject:r4(g->sd[i])]; }
            return @{ @"mu": mu, @"sd": s };
        };
        NSMutableArray *rest = [NSMutableArray array], *w = [NSMutableArray array];
        for (int k = 0; k < AGR_RESTS; k++) [rest addObject:gj(&rd.rest[k])];
        for (int d = 0; d < AGR; d++) [w addObject:r4(rd.w[d])];
        hd[@"reader"] = @{ @"tip": gj(&rd.tip), @"thumb": gj(&rd.thumb), @"rest": rest, @"w": w, @"tau": r4(rd.tau), @"keep": r4(rd.keep),
                           @"accuracy": [NSString stringWithFormat:@"block CV: combos %d/%d (%d wrong count, %d nothing); poses %d/%d; resting hand as fingers %d/%d",
                                                                    rc, rn, rWrong, rNone, rPoseOk, rPose, rIdleF, rIdle] };
    } else [hd removeObjectForKey:@"reader"];
    sd[@"hold"] = hd;
    doc[@(side)] = sd;
    NSData *out = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (![out writeToFile:path atomically:YES]) { fprintf(stderr, "could not write thumbprint.json\n"); exit(1); }
    printf("Saved → remap/thumbprint.json (%s.hold). remapd picks it up now.\n", side);
}
// The recorded sessions: posed holds, the resting hand, combos caught in use.
enum { HL_HOLD, HL_IDLE, HL_COMBO };
static NSString *holdFile(const char *side, int what) {
    static const char *const nm[] = { "hold", "idle", "combo" };
    return [NSString stringWithFormat:@"/Users/josh/Code/Scripts/remap/%s_calib_%s.jsonl", nm[what], side];
}
// Append a recorded session's poses / moments to gH (a missing file adds nothing).
static int holdLoad(NSString *file, int what, const char *side) {
    NSString *s = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
    int added = 0;
    bool idle = what == HL_IDLE;
    for (NSString *ln in s ? [s componentsSeparatedByString:@"\n"] : @[]) {
        NSDictionary *j = ln.length ? [NSJSONSerialization JSONObjectWithData:[ln dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
        if (![j isKindOfClass:NSDictionary.class] || gHN >= HMAXP) continue;
        HPose *ps = &gH[gHN++]; added++;
        *ps = (HPose){ .want = [j[@"want"] intValue], .test = [j[@"test"] boolValue], .idle = idle, .combo = what == HL_COMBO };
        strlcpy(ps->ask, idle ? "resting hand" : [j[@"ask"] UTF8String], sizeof ps->ask);
        bool pos = true;
        for (NSArray *c in j[@"contacts"]) {   // [major, minor, angle, size, kind, print score, x, y]
            if (ps->n >= MAXT || c.count < 6) continue;
            agHoldFeatures([c[0] floatValue], [c[1] floatValue], [c[2] floatValue], [c[3] floatValue], ps->f[ps->n]);
            ps->kind[ps->n] = idle ? AGK_IDLE : [c[4] intValue]; ps->score[ps->n] = [c[5] floatValue];
            if (c.count >= 8) { ps->x[ps->n] = [c[6] floatValue]; ps->y[ps->n] = [c[7] floatValue]; } else pos = false;
            ps->n++;
        }
        if (pos && ps->n) hPlace(ps, side);
    }
    return added;
}
// Everything recorded but `except` (its own session's data, already in gH).
static void holdLoadAll(const char *side, int except) {
    for (int w = HL_HOLD; w <= HL_COMBO; w++) if (w != except) holdLoad(holdFile(side, w), w, side);
}
static void holdRefit(const char *side, const char *file) {
    @autoreleasepool {
    if (!holdLoad(@(file), HL_HOLD, side)) { fprintf(stderr, "no poses in %s\n", file); exit(1); }
    holdLoadAll(side, HL_HOLD);
    hJudgeSave(side);
    }
    exit(0);
}
// Return pressed (a pose the pad never sees: skip it)?
static bool holdReturn(void) {
    struct pollfd pf = { 0, POLLIN, 0 };
    char b[64];
    return poll(&pf, 1, 0) > 0 && read(0, b, sizeof b) > 0;
}
// Return twice within 2 s (one stray Return never moves a session on).
static bool holdReturnTwice(double *first) {
    if (!holdReturn()) return false;
    if (now() - *first < 2) return true;
    *first = now();
    printf("   (press Return again to move on)\n"); fflush(stdout);
    return false;
}
// The contacts resting NOW, once at least `need` are down and nothing has landed or lifted
// for HOLD_SETTLE s (a palm may rest throughout: no lift is waited for). -1 = skipped.
#define HOLD_SETTLE 1.0
static int holdCapture(Tr *out, int need) {
    double asked = now(); bool hinted = false;
    for (;;) {
        usleep(20000);
        if (holdReturn()) return -1;
        pthread_mutex_lock(&gMu);
        int n = gNT; bool read = n >= need && n > 0 && now() - gChange >= HOLD_SETTLE;
        for (int j = 0; j < n && read; j++) read = gTr[j].frames >= 3;
        if (read) { memcpy(out, gTr, sizeof(Tr) * n); pthread_mutex_unlock(&gMu); return n; }
        pthread_mutex_unlock(&gMu);
        if (!hinted && now() - asked > 6) {
            printf("   (seeing %d contact%s — waiting for %d, held still; Return skips)\n", n, n == 1 ? "" : "s", need);
            fflush(stdout); hinted = true;
        }
    }
}
// Wait until none of these contacts is down any more (others — a resting palm — may stay).
static void holdLifted(const int *ids, int k) {
    for (;;) {
        usleep(20000);
        if (holdReturn()) return;
        pthread_mutex_lock(&gMu);
        bool down = false;
        for (int j = 0; j < gNT && !down; j++) for (int i = 0; i < k; i++) down |= gTr[j].id == ids[i];
        pthread_mutex_unlock(&gMu);
        if (!down) return;
    }
}
// How fingertip-like / thumb-like a contact is: by the hold model learnt so far, else the thumbprint.
static float holdLike(const AgHold *h, const AgPrint *p, int kind, const float *f, int dims) {
    if (h->ok && h->has[kind]) return agHoldLL(h, kind, f, dims);
    if (!p->ok) return kind == AGK_FINGER ? -f[4] : f[0];   // smaller = tip; longer = thumb
    float s = 0; int c = kind == AGK_THUMB;
    for (int i = 0; i < AGF; i++) { float z = (f[i] - p->mu[c][i]) / p->sd[c][i]; s -= 0.5f * z * z + logf(p->sd[c][i]); }
    return s;
}
// Who is who in a pose of `tips` fingertips (+ the thumb), its other contacts' kinds already
// set. Just the pose's own contacts: the thumb furthest right and low (the left hand), the
// rest tips. More: the most thumb-like is the thumb and the most fingertip-like the tips
// (by what is learnt so far, h, else the thumbprint p).
static void hLabel(HPose *ps, const Tr *t, int tips, int thumb, const AgHold *h, const AgPrint *p, const char *side) {
    int n = ps->n, need = tips + thumb, dims = ps->pos ? AGHP : AGH;
    float sgn = strcmp(side, "left") ? -1 : 1;
    int th = -1;
    for (int c = 0; thumb && c < n; c++) {
        bool better = th < 0 || (n == need ? sgn * t[c].x0 - t[c].y0 > sgn * t[th].x0 - t[th].y0
                                           : holdLike(h, p, AGK_THUMB, ps->f[c], dims) > holdLike(h, p, AGK_THUMB, ps->f[th], dims));
        if (better) th = c;
    }
    if (th >= 0) ps->kind[th] = AGK_THUMB;
    for (int k = 0; k < tips; k++) {
        int bi = -1;
        for (int c = 0; c < n; c++)
            if (ps->kind[c] != AGK_THUMB && ps->kind[c] != AGK_FINGER
                && (bi < 0 || holdLike(h, p, AGK_FINGER, ps->f[c], dims) > holdLike(h, p, AGK_FINGER, ps->f[bi], dims))) bi = c;
        if (bi >= 0) ps->kind[bi] = AGK_FINGER;
    }
}
static void holdSession(const char *side) {
    @autoreleasepool {
    AgPrint p; AgRoll r; AgRest re;
    ttLoad(side, &p, &r, &re);
    // want: the state it must read as · tips / thumb: what makes it · extra: what any OTHER
    // contacts are (AGK_FINGER = not stated: they're left out of the fit, still judged)
    // · test: judged only · block: 0 = asked first (clean), 1 = after (with the palm)
    typedef struct { int want, tips, thumb, extra, test, reps, block; const char *text; } Pose;
    static const Pose poses[] = {
        { 1, 1, 0, AGK_FINGER, 0, 3, 0, "1 FINGERTIP" },
        { 1, 1, 1, AGK_FINGER, 0, 2, 0, "1 FINGERTIP + THUMB" },
        { 2, 2, 0, AGK_FINGER, 0, 3, 0, "2 FINGERTIPS" },
        { 2, 2, 1, AGK_FINGER, 0, 2, 0, "2 FINGERTIPS + THUMB" },
        { 3, 3, 0, AGK_FINGER, 0, 3, 0, "3 FINGERTIPS (pinky, ring, middle)" },
        { AG_HOLD_THREE_THUMB, 3, 1, AGK_FINGER, 0, 3, 0, "3 FINGERTIPS + THUMB" },
        { 4, 4, 0, AGK_FINGER, 0, 3, 0, "4 FINGERTIPS" },
        { 5, 4, 1, AGK_FINGER, 0, 3, 0, "4 FINGERTIPS + THUMB" },
        { 0, 0, 1, AGK_FINGER, 0, 3, 0, "THUMB alone" },
        { 0, 0, 0, AGK_KNUCKLE, 0, 4, 0, "KNUCKLES (curled hand, no fingertips)" },
        { 0, 0, 1, AGK_KNUCKLE, 1, 2, 0, "KNUCKLES + THUMB" },
        { 0, 0, 0, AGK_PALM, 0, 4, 0, "PALM alone (fingers up)" },
        // No "with the palm resting" twins (user, 2026-10-21: the palm isn't thought about —
        // it's learnt as itself and filtered out; `thumbprint left combo` catches it in use).
    };
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (int bl = 0; bl < 2; bl++) {
        NSMutableArray<NSNumber *> *o = [NSMutableArray array];
        for (int i = 0; i < (int)(sizeof poses / sizeof *poses); i++)
            if (poses[i].block == bl) for (int k = 0; k < poses[i].reps; k++) [o addObject:@(i)];
        for (NSUInteger i = o.count; i > 1; i--) [o exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
        [order addObjectsFromArray:o];
    }
    calibOn();
    NSString *path = holdFile(side, HL_HOLD);
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    printf("Hold — the %s pad: %lu poses. Rest the hand as asked and keep it still: each is taken\n", side, (unsigned long)order.count);
    printf("after a second of stillness, whatever else is down. Then lift what it asks (the palm may stay).\n");
    printf("Return skips a pose the pad doesn't see. Ctrl-C to stop.\n");
    pthread_mutex_lock(&gMu); gArmed = true; gPrune = true; pthread_mutex_unlock(&gMu);
    static const char *const kn[AGK_N] = { "tip", "thumb", "knuckle", "palm", "idle", "idle", "idle" };
    for (NSUInteger i = 0; i < order.count && gHN < HMAXP; i++) {
        const Pose *po = &poses[order[i].intValue];
        printf("\n[%2lu/%lu]  %s — rest, hold still\n", (unsigned long)i + 1, (unsigned long)order.count, po->text); fflush(stdout);
        int need = po->tips + po->thumb;
        Tr t[MAXT]; int n = holdCapture(t, need ? need : 1);
        if (n < 0) { printf("   skipped\n"); continue; }
        HPose *ps = &gH[gHN];
        *ps = (HPose){ .want = po->want, .n = n, .test = po->test };
        strlcpy(ps->ask, po->text, sizeof ps->ask);
        for (int c = 0; c < n; c++) {
            hContact(ps, c, &t[c], &p);
            ps->kind[c] = need ? (po->extra == AGK_FINGER ? -1 : po->extra) : po->extra;   // the rest, below
        }
        hPlace(ps, side);
        AgHold h; hFit(&h, -1, false);
        hLabel(ps, t, po->tips, po->thumb, &h, &p, side);
        NSArray *cs = hContactsJson(ps, t);
        int lift[MAXT], nl = 0;
        printf("  ");
        for (int c = 0; c < n; c++) {
            printf(" %s %.1f×%.1f sz %.2f", ps->kind[c] >= 0 ? kn[ps->kind[c]] : "other", t[c].st.major, t[c].st.minor, t[c].st.size);
            if (!need || ps->kind[c] == AGK_FINGER || ps->kind[c] == AGK_THUMB) lift[nl++] = t[c].id;
        }
        printf("\n   ✓ lift %s\n", need ? (po->extra == AGK_PALM ? "the fingers (the palm may stay)" : "the fingers") : "it"); fflush(stdout);
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{ @"ask": @(po->text), @"want": @(po->want), @"test": @(po->test), @"contacts": cs }
                                                               options:0 error:NULL] mutableCopy];
        [line appendBytes:"\n" length:1];
        [fh writeData:line];
        gHN++;
        holdLifted(lift, nl);
    }
    [fh closeFile];
    pthread_mutex_lock(&gMu); gArmed = false; gPrune = false; pthread_mutex_unlock(&gMu);
    holdLoadAll(side, HL_HOLD);   // the resting hand and combos, when recorded
    hJudgeSave(side);
    }
    exit(0);
}

/* ── IDLE: the hand just resting on the left pad (2026-10-21) ──
   Runs for `secs` while you use the right pad as normal, the left hand lying on the left
   pad with no fingers meant. The pads work as ever (no calibration lock). Every 0.25 s
   what rests there (read: 3 frames, down AG_STILL_S) is one moment, every contact the
   resting hand's — appended to remap/idle_calib_left.jsonl (runs add up; delete it to
   start over). Then refits left.hold from hold_calib_left.jsonl + all of it, and says how
   many moments still read as fingers. */
static void idleSession(const char *side, double secs) {
    @autoreleasepool {
    AgPrint p; AgRoll r; AgRest re;
    ttLoad(side, &p, &r, &re);
    if (!holdLoad(holdFile(side, HL_HOLD), HL_HOLD, side)) { fprintf(stderr, "no hold poses — run `thumbprint %s hold` first\n", side); exit(1); }
    holdLoad(holdFile(side, HL_COMBO), HL_COMBO, side);
    int had = holdLoad(holdFile(side, HL_IDLE), HL_IDLE, side);
    NSString *path = holdFile(side, HL_IDLE);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    printf("Resting hand — the %s pad, %.0f s. Use the right pad as normal; leave the left hand lying on\n", side, secs);
    printf("the left pad however it falls, no fingers meant. The left pad sends nothing; the right works as usual.\n");
    printf("Ctrl-C stops early (what's\n");
    printf("recorded is kept, but only learnt by the next run or `thumbprint left hold refit remap/hold_calib_left.jsonl`).\n");
    if (had) printf("(%d moments from earlier runs are kept; delete remap/idle_calib_%s.jsonl to start over)\n", had, side);
    calibLeftOn();
    pthread_mutex_lock(&gMu); gArmed = true; gPrune = true; pthread_mutex_unlock(&gMu);
    double t0 = now(), said = t0; int got = 0, contacts = 0;
    while (now() - t0 < secs && gHN < HMAXP) {
        usleep(250000);
        Tr t[MAXT]; int n = 0; double tn = now();
        pthread_mutex_lock(&gMu);
        bool settled = false;   // a moment once something has settled; every read contact is in it (the hand)
        for (int j = 0; j < gNT; j++) if (gTr[j].live && gTr[j].frames >= 3) { t[n++] = gTr[j]; settled |= tn - gTr[j].st.t >= AG_STILL_S; }
        pthread_mutex_unlock(&gMu);
        if (n && settled) {
            HPose *ps = &gH[gHN++];
            *ps = (HPose){ .want = 0, .n = n, .idle = 1 };
            strlcpy(ps->ask, "resting hand", sizeof ps->ask);
            for (int c = 0; c < n; c++) { hContact(ps, c, &t[c], &p); ps->kind[c] = AGK_IDLE; }
            hPlace(ps, side);
            NSArray *cs = hContactsJson(ps, t);
            NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{ @"want": @0, @"contacts": cs } options:0 error:NULL] mutableCopy];
            [line appendBytes:"\n" length:1];
            [fh writeData:line];
            got++; contacts += n;
        }
        if (now() - said >= 10) {
            said = now();
            printf("   %3.0f s left · %d moments, %d contacts\n", fmax(secs - (said - t0), 0), got, contacts); fflush(stdout);
        }
    }
    [fh closeFile];
    pthread_mutex_lock(&gMu); gArmed = false; gPrune = false; pthread_mutex_unlock(&gMu);
    if (!got && !had) { fprintf(stderr, "nothing rested on the pad — nothing learnt\n"); exit(1); }
    printf("\nRecorded %d moments (%d contacts). Refitting…\n", got, contacts);
    hJudgeSave(side);
    }
    exit(0);
}

/* ── COMBO: finger + thumb combinations caught IN USE (2026-10-21) ──
   One combination at a time: hold it on the left pad and use the right pad as normal. While
   the right pad is touched, whatever is on the left IS that combination (a positive): every
   COMBO_EVERY s a moment is taken. Its most thumb-like / fingertip-like contacts (by the
   model so far, hLabel) are the thumb and tips; anything else there (the palm, knuckles — never
   asked about) is left out of the fit but must read as nothing. A moment counts once the tips
   and thumb have SETTLED (agSettleFrame): put down straight or unrolled from a curled hand,
   only where they came to rest is read, so both ways train the same thing. The pads work as
   usual (no calibration lock). Appended to remap/combo_calib_left.jsonl (runs add up), then
   everything (hold + idle + combo) is refit. Return moves on early. */
#define COMBO_EVERY 0.15
#define COMBO_WANT  60
static const char *gComboPick[16]; static int gComboN = 0;
static void comboSession(const char *side) {
    @autoreleasepool {
    typedef struct { const char *key; int want, tips, thumb; const char *text; } Combo;
    static const Combo all[] = {
        // One / two: the thumb doesn't count, down or not — no "+ thumb" twins (user, 2026-10-21).
        { "1",  1, 1, 0, "1 FINGERTIP (thumb down or not)" },
        { "2",  2, 2, 0, "2 FINGERTIPS (thumb down or not)" },
        { "3",  3, 3, 0, "3 FINGERTIPS (pinky, ring, middle)" },
        { "3t", AG_HOLD_THREE_THUMB, 3, 1, "3 FINGERTIPS + THUMB" },
        { "4",  4, 4, 0, "4 FINGERTIPS" },
        { "4t", 5, 4, 1, "4 FINGERTIPS + THUMB" },   // no thumb-only combo (user, 2026-10-21)
    };
    const int NC = (int)(sizeof all / sizeof *all);
    const Combo *run[16]; int nr = 0;
    for (int i = 0; i < gComboN; i++) {
        int k = 0;
        while (k < NC && strcasecmp(all[k].key, gComboPick[i])) k++;
        if (k == NC) { fprintf(stderr, "no combo \"%s\" — pick from 1 2 3 3t 4 4t\n", gComboPick[i]); exit(2); }
        run[nr++] = &all[k];
    }
    if (!nr) for (int k = 0; k < NC; k++) run[nr++] = &all[k];
    AgPrint p; AgRoll r; AgRest re;
    NSMutableDictionary *doc = ttLoad(side, &p, &r, &re);
    gHoldMargin = [doc[@(side)][@"hold"][@"margin"] floatValue];   // the live "reads as" = remapd's
    holdLoadAll(side, -1);
    hIdleCluster();
    AgHold h; hFit(&h, -1, true);
    hReaderFit(&h.rd, -1);   // "reads as" by the hand reader, as remapd
    NSString *path = holdFile(side, HL_COMBO);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    printf("Combos — the %s pad: %d combination%s. Hold each on the LEFT pad and use the RIGHT pad as normal;\n", side, nr, nr == 1 ? "" : "s");
    printf("whatever is on the left while the right is touched counts as that combination. Put the fingers\n");
    printf("down any way you like (straight down or unrolled) — the palm may be there or not. The left pad\n");
    printf("sends nothing while this runs. Return twice moves on early; Ctrl-C stops (what's recorded is\n");
    printf("kept, learnt by the next run or `thumbprint left hold refit remap/hold_calib_left.jsonl`).\n");
    calibLeftOn();
    pthread_mutex_lock(&gMu); gArmed = true; gPrune = true; pthread_mutex_unlock(&gMu);
    static const char *const kn[AGK_N] = { "tip", "thumb", "knuckle", "palm", "idle", "idle", "idle" };
    int total = 0;
    for (int ci = 0; ci < nr; ci++) {
        const Combo *co = run[ci];
        int need = co->tips + co->thumb, got = 0, readRight = 0, shortN = 0, settling = 0;
        printf("\n[%d/%d]  %s — hold it on the left, use the right pad\n", ci + 1, nr, co->text); fflush(stdout);
        // A fresh start: the right pad clear, then 1 s to set the left hand.
        double ret = -10;
        while (atomic_load(&gOtherN) > 0) { usleep(20000); if (holdReturnTwice(&ret)) break; }
        for (double t0 = now(); now() - t0 < 1.0; ) { usleep(20000); holdReturn(); }
        double last = 0, said = now();
        while (got < COMBO_WANT) {
            usleep(20000);
            if (holdReturnTwice(&ret)) break;
            if (atomic_load(&gOtherN) == 0 || now() - last < COMBO_EVERY) continue;
            last = now();
            Tr t[MAXT]; int n = 0; double tn = now();
            pthread_mutex_lock(&gMu);
            for (int j = 0; j < gNT; j++) if (gTr[j].live && gTr[j].frames >= 3) t[n++] = gTr[j];
            pthread_mutex_unlock(&gMu);
            if (n < (need ? need : 1)) { shortN++; continue; }
            HPose *ps = &gH[gHN];
            *ps = (HPose){ .want = co->want, .n = n, .combo = 1 };
            strlcpy(ps->ask, co->text, sizeof ps->ask);
            for (int c = 0; c < n; c++) { hContact(ps, c, &t[c], &p); ps->kind[c] = -1; }
            hPlace(ps, side);
            hLabel(ps, t, co->tips, co->thumb, &h, &p, side);
            // Anything else there isn't part of the combination: the resting hand's (the palm,
            // knuckles), learnt as that — with where it sits.
            for (int c = 0; c < n; c++) if (ps->kind[c] < 0) ps->kind[c] = AGK_IDLE;
            bool settled = true;
            for (int c = 0; c < n; c++)
                if ((ps->kind[c] == AGK_FINGER || ps->kind[c] == AGK_THUMB) && tn - t[c].st.t < AG_STILL_S) settled = false;
            if (!settled) { settling++; continue; }
            int reads = hState(ps, h.ok ? &h : NULL);
            readRight += reads == co->want;
            NSArray *cs = hContactsJson(ps, t);
            NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{ @"ask": @(co->text), @"want": @(co->want), @"contacts": cs } options:0 error:NULL] mutableCopy];
            [line appendBytes:"\n" length:1];
            [fh writeData:line];
            if (gHN < HMAXP) gHN++;
            got++; total++;
            if (now() - said >= 1.0 || got == COMBO_WANT) {
                said = now();
                printf("   %2d / %d · reads as %-10s ·", got, COMBO_WANT, hName(reads));
                for (int c = 0; c < n; c++) printf(" %s", ps->kind[c] >= 0 ? kn[ps->kind[c]] : "other");
                printf("\n"); fflush(stdout);
            }
        }
        printf("   ✓ %d moments, %d read right by the model so far", got, readRight);
        if (shortN) printf(" · %d skipped: fewer than %d contacts on the pad", shortN, need);
        if (settling) printf(" · %d still settling", settling);
        printf("\n");
    }
    [fh closeFile];
    pthread_mutex_lock(&gMu); gArmed = false; gPrune = false; pthread_mutex_unlock(&gMu);
    if (!total) { fprintf(stderr, "nothing recorded — nothing learnt\n"); exit(1); }
    printf("\nRecorded %d moments. Refitting…\n", total);
    hJudgeSave(side);
    }
    exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *side = argc > 1 ? argv[1] : "left";
        bool left = !strcmp(side, "left");
        bool group = argc > 2 && !strcmp(argv[2], "group"), roll = argc > 2 && !strcmp(argv[2], "roll");
        bool spread = argc > 2 && !strcmp(argv[2], "spread");
        bool ttap = argc > 2 && !strcmp(argv[2], "thumbtap");
        bool lone = argc > 2 && !strcmp(argv[2], "lone");
        bool rest = argc > 2 && !strcmp(argv[2], "rest");
        bool hold = argc > 2 && !strcmp(argv[2], "hold"), idle = argc > 2 && !strcmp(argv[2], "idle");
        double idleSecs = idle && argc > 3 ? atof(argv[3]) : 120;
        bool combo = argc > 2 && !strcmp(argv[2], "combo");
        for (int i = 3; combo && i < argc && gComboN < 16; i++) gComboPick[gComboN++] = argv[i];
        gRoll3L = roll && argc > 3 && !strcasecmp(argv[3], "3L");
        if ((!left && strcmp(side, "right")) || (argc > 2 && !group && !roll && !spread && !ttap && !lone && !rest && !hold && !idle && !combo) || (idle && idleSecs <= 0)) { fprintf(stderr, "usage: thumbprint left|right [group|roll [3L]|spread|thumbtap|lone|rest [refit <file>]] | thumbprint left hold [refit <file>] | thumbprint left idle [seconds] | thumbprint left combo [1 2 3 3t 4 4t]\n"); return 2; }
        if ((hold || idle || combo) && !left) { fprintf(stderr, "hold / idle / combo are the left pad's (the right pad's gestures read it)\n"); return 2; }
        if (hold && argc > 4 && !strcmp(argv[3], "refit")) holdRefit(side, argv[4]);
        if (rest && argc > 4 && !strcmp(argv[3], "refit")) restRefit(side, argv[4]);
        CFArrayRef devs = MTDeviceCreateList();
        int pads = 0;   // a built-in pad may publish more than one device: listen to all of that side's
        for (CFIndex i = 0; devs && i < CFArrayGetCount(devs); i++) {
            MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(devs, i);
            if (auxpadClassify(d, "thumbprint") != left) {   // the other pad: only the combo session hears it
                if (combo) { MTRegisterContactFrameCallback(d, otherTouch); MTDeviceStart(d, 0); }
                continue;
            }
            MTRegisterContactFrameCallback(d, touch);
            MTDeviceStart(d, 0);
            pads++;
        }
        if (!pads) { fprintf(stderr, "no %s trackpad (aux_trackpad in config/settings.json)\n", side); return 1; }
        // The session runs off the main thread; the main thread keeps the run loop going.
        if (ttap && argc > 4 && !strcmp(argv[3], "refit")) thumbtapRefit(side, argv[4], argc > 6 && !strcmp(argv[5], "drop") ? argv[6] : NULL);
        [NSThread detachNewThreadWithBlock:^{ if (combo) comboSession(side); else if (idle) idleSession(side, idleSecs); else if (hold) holdSession(side); else if (group) groupSession(side); else if (lone) loneSession(side); else if (rest) restSession(side); else if (ttap) thumbtapSession(side); else if (spread) spreadSession(side); else if (roll) rollSession(side); else session(side); }];
        CFRunLoopRun();
    }
    return 0;
}

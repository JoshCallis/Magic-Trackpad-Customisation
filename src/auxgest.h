/* auxgest.h — a trackpad-as-keyboard gesture recogniser, one instance per pad.
   Plain C, no OS calls, so the future Windows service (Raw Input PTP contacts) can
   feed it the same way.

   Feed every contact frame to auxgestFrame(); call auxgestTick() at/after the
   deadline it returns (a gesture is decided a short MERGE gap after its fingers
   lift, so fingers that roll on one after another still count as one gesture).

   THE THUMB is told apart by place (lowest contact, well below the others) and, alone
   on the pad, by its SHAPE: the thumb's edge is a long, skinny, slanted footprint.
   The shape is learnt per pad (bin/thumbprint → remap/thumbprint.json → AgPrint:
   one diagonal Gaussian per class over agFeatures); with no print a lone contact in
   the bottom of the pad is the thumb, as before. So is its PLACE AMONG RECENT FINGERS
   (2026-10-16): each pad remembers where fingers landed in the last few seconds
   (AgHist), and a lone contact's offset from the nearest of those is scored too —
   far off to the thumb's side = thumb; back where a swipe started = a finger
   returning to repeat it. Faded by age; learnt from swipes done in sequence. Its role by RELEASE ORDER, like the keyboard's
   chords: still down when the fingers' gesture is decided = HELD (a modifier for that
   gesture: flag AG_THUMB_HELD); lifted already = part of the gesture ("+thumb", or a
   thumb roll). A lone thumb that swipes sideways is "thumbswipeL" / "thumbswipeR"; one
   that taps (short, still, never a modifier) is "thumbtap".
   The thumb MOVING WITH the fingers (pinched to the forefinger, or with 3 fingers,
   bunched or apart) is told by the GROUP print when one is learnt (AgPrint.grpOk):
   it alone then picks the thumb among contacts that land together (agGroupThumb).
   NO THUMBS (2026-10-17): both pads run noThumb — every contact is a finger (1–5), and
   a contact resting before the others land is left out of their gesture (agRester;
   4 tapping beside it = tap5). The thumb rules above are dormant. Except THUMB DOWN
   (2026-10-18): that resting contact, thumb-shaped by the print, turns 1–4 fingers'
   up / down swipes into thumbup<n> / thumbdown<n> and taps into thumbtap<n>
   (auxgestThumbRestId; restSecs pads: restthumb:up<n> …). THE LONE THUMB (thumb alone
   on the pad swiping / tapping) is RETIRED (2026-10-29, user: lone fingers read as the
   thumb and their gestures died) — a lone contact is always a finger. The thumb
   swiping sideways by 1–4 fingers resting on the same pad = thumbswipeL<n> / R<n>, tapping
   by them = thumbtapby<n> (agSweepBy). RESTING SECTIONS (restSecs, the right pad,
   2026-10-21): fingers resting on this pad and others moving by them =
   "rest<r>:<gesture>" (agRestOf) instead. Two / three fingers rolling right → left there =
   rest<r>:rollL<m> / restthumb<f>:rollL<m> (only where bound, else tap<m>); by a resting
   thumb restthumb:rollL<m> (restSecs) / thumbrollL<m> — the 2–3-finger taps' roll twins (2026-10-29).

   emit(name, phase, flags, detail)
     name   tap1..5, up1.., down1.., left1.., right1.., rollR2 / rollL3 (fingers landing
            left→right / right→left), rollTF1 (thumb then finger), rollFT1 (finger then
            thumb), tap2+thumb, thumbswipeL / R, spread5 / pinch5 (whole hand
            apart / together, thumb counted), pinch2..4 (thumb closing on 1–3
            fingers, 2026-10-18), spread2..4 (opening out), none
     phase  AG_TAP = press+release; AG_DOWN / AG_UP = fingers HELD still (AG_HOLD_S):
            the key goes down, repeats, and lifts with them
     flags  AG_THUMB_HELD
     detail landing gaps etc., for the log / tuning
   thumb(down)  the held thumb came / went (queried live with auxgestThumbDown).
   Coordinates: normalized 0..1, y UP (MultitouchSupport's own convention). */
#pragma once
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AG_MAX          12
#define AG_MERGE_S      0.10   // gap after the last lift before a gesture is decided
#define AG_RETAP_DIST   0.06   // a finger landing this near a lifted one, in that gap = the next tap
#define AG_TAP_S        0.25   // longest tap (first down → last up), + AG_TAP_S_PER per extra finger
#define AG_TAP_S_PER    0.04   // (0.45 + 0.1/finger before 2026-10-17: a touch-and-lift read as a tap)
#define AG_TAP_LAND     0.78   // a TAP (or held key) lands with SPEED, like macOS's own: every finger's
                               // first frame is already this much of its peak contact size. Measured
                               // 2026-10-17: sharp taps 0.86–1.0, lazy touch-and-lifts 0.53–0.71 (they
                               // spread for 60–210 ms). Before this a finger resting 200 ms fired its
                               // tap binding as a held key.
#define AG_SWIPE_LONG   0.12   // a swipe this long only has to lean one way
#define AG_TAP_MOVE     0.05   // most a tapping finger may wander
#define AG_SWIPE        0.02   // least travel for a swipe (0.10 → 0.05 → 0.03 → 0.02, 2026-10-16; checked before tap, so a
                               // directed move this long is a swipe even at AG_TAP_MOVE)
#define AG_ROLL_GAP     0.018  // least gap between successive landings for a roll
                               // (a 4-finger tap spread ≤ 26 ms in all, 2026-10-16)
#define AG_ROLL_MIN_GAP  0.015 // floors on a pad's LEARNT roll rules (2026-11-15: right pad learnt 4 ms /
#define AG_ROLL_MAX_MOVE 0.02  // 0.03 drift / 0.62 landing, so fingers stopping a scroll rolled)
#define AG_ROLL_MIN_LAND 0.70
#define AG_HOLD_S       0.20   // fingers still this long after the last landing = held key
#define AG_THUMB_LEAD   0.05   // thumb already down this long when fingers land = held
#define AG_THUMB_WITH   0.04   // a thumb told by SHAPE may land up to this long AFTER a finger (together)
#define AG_THUMB_OUTLAST 0.04  // ... or (quick, thumb-shaped) lifting this long after the fingers did (agQuickThumb)
#define AG_THUMB_DROP   0.15   // thumb sits at least this far below the others
#define AG_THUMB_Y      0.35   // a lone thumb lands in the bottom of the pad
#define AG_THUMB_HOLD_S 0.25   // ... and is held once still this long
#define AG_THUMBTAP_S   0.25   // longest thumb tap
#define AG_STILL_S      0.10   // fingers resting this long = a modifier for the other pad
#define AG_SPREAD       0.06   // least change in the hand's mean radius for spread / pinch
#define AG_PINCH        0.03   // pinch2..4 / spread2..4: least change in the hand's mean radius ...
#define AG_PINCH_RATIO  0.85   // ... to under this share of it (spread: over 1 / this). Calibrated
                               // (spread_calib.jsonl, thumb + 3): pinch / spread ≥ 0.040, ratio ≤ 0.74 /
                               // ≥ 1.22; 4-finger swipes ≤ 0.022, 0.87–1.11 (2026-10-18; was: halve / double)
#define AG_CONVERGE     0.025  // pinch / spread need TWO contacts, down together, each travelling at least this
                               // toward (pinch) / away from (spread) the other (agConverge). spread_calib.jsonl:
                               // pinches ≥ 0.077, spreads ≥ 0.033, 4-finger swipes ≤ 0.030 one way only (2026-10-28:
                               // a 2-finger scroll + a stray still contact read pinch3 = Wispr, 59 of 75 fires)
#define AG_EARLY_MIN    3      // EARLY (mid-swipe) decisions: at least this many fingers
#define AG_EARLY_TRAVEL 0.06   // ... the hand's mean travel one way before it fires
#define AG_EARLY_SETTLE 0.08   // ... and no finger landed this recently (a 5th may follow)
#define AG_EARLY_QUICK  0.03   // ... cut to this when the one-more-finger gesture isn't wanted: nothing
                               // to wait for (up4/down4 slot swipes waited the full 80 ms, 2026-10-20);
                               // still long enough for the thumb-by-shape test's 3 frames
#define AG_RESHAPE      0.4    // 3+ contacts whose spread changes by this share of their travel = a
                               // pinch / spread, never a swipe (thumb + 3 pinching read as up4 / down4
                               // = slot switches, 2026-10-18)
#define AG_ALONG        0.35   // 3+ contacts: each must travel this share of the hand's mean travel to
                               // swipe (calibrated swipes ≥ 0.61; a still thumb ≈ 0), 2026-10-18
#define AG_LAND_SPREAD  0.25 // fingers landing further apart than this are no one swipe (a 3-finger
                               // orbit + a 4th finger to pan read as left4 = an app switch, 2026-10-16)
#define AG_THUMB_APART  1.4    // a thumb among 3+ contacts sits this many times further from its nearest
                               // neighbour than the fingers do from theirs (a 4-finger tap's low pinky
                               // read as thumb + tap3, 2026-10-17)

/* ROLLS, learnt per pad (2026-10-17, `thumbprint left|right roll` → thumbprint.json
   <side>.roll): fingers landing one after another (≥ gap apart, in order across the pad)
   are a roll, not a tap. A calibrated roll may also be slower (dur), wander more (move:
   checked BEFORE the swipe test, so a rolling drift is no swipe) and land softer (land)
   than a tap. Defaults = the fixed rules before calibration. */
typedef struct { float gap, dur, durPer, move, land; } AgRoll;
static const AgRoll agRollDefault = { AG_ROLL_GAP, AG_TAP_S + AG_TAP_S_PER, AG_TAP_S_PER, 0, AG_TAP_LAND };

/* THUMB-DOWN TAPS, learnt per pad (2026-10-18, `thumbprint left|right thumbtap` →
   thumbprint.json <side>.rest): fingers tapping by a resting thumb.
   lead  the thumb down this long before the fingers = resting (agRester, auxgestThumbRestId)
   still the most the resting thumb may drift
   land / dur / durPer  the fingers' tap rules there (agName)
   gap   the roll gap there (0 = the pad's own; 1 = no rolls by a resting thumb)
   shape the least print score for the resting contact to count as the thumb (agThumbish). */
typedef struct { float lead, still, land, dur, durPer, gap, shape; } AgRest;
static const AgRest agRestDefault = { AG_THUMB_LEAD, AG_TAP_MOVE, AG_TAP_LAND, AG_TAP_S, AG_TAP_S_PER, 0, 0 };
/* RESTING SECTIONS, learnt (2026-10-28, `thumbprint right rest` → thumbprint.json <side>.restsec):
   FINGERS resting on this pad (agRestOf). lead  the last rester down this long before the
   first mover · still  the most a rester may drift · fingerMM  a contact this close to
   another is a fingertip, never the thumb (agFingerClose). NULL = the thumb rules' lead /
   still (AgRest) and AG_FINGER_MM.
   THE LAYOUT (user, 2026-10-28: "their positions relative to each other are useful
   information"): where the first mover lands from the resters' centre, in mm (dx toward the
   pad's right, dy up), a Gaussian per combination — AG_LAY_THUMB = the thumb resting, fingers
   moving; 1–3 = that many fingers resting, fingers moving. A lone rester is the thumb when
   its print score + layW × (log-likelihood as thumb − as one finger) passes the rest shape
   (agThumbAt). sd 0 = not learnt. */
#define AG_LAY_THUMB 0
#define AG_LAYS 4
typedef struct { float lead, still, fingerMM, layW; float mu[AG_LAYS][2], sd[AG_LAYS][2]; } AgRestSec;

/* THE LONE THUMB, learnt (2026-10-18, `thumbprint right lone` → thumbprint.json
   right.lone, mirrored to left.lone): the thumb alone on a no-thumb pad, swiping
   sideways (thumbswipeL / R) or tapping (thumbtap).
   shape the least print score for a lone contact to be the thumb (off = AG_LONE_OFF:
         not calibrated — a finger read as the thumb would lose a typed letter)
   swipe least sideways travel · dur / land a thumb tap's longest time / least landing speed. */
#define AG_LONE_OFF 1e9f
typedef struct { float shape, swipe, dur, land; } AgLone;
static const AgLone agLoneDefault = { AG_LONE_OFF, AG_SWIPE, AG_THUMBTAP_S, AG_TAP_LAND };

enum { AG_TAP = 0, AG_DOWN = 1, AG_UP = 2 };
enum { AG_THUMB_HELD = 1 };

// major / minor / angle / size: the contact's ellipse, as MultitouchSupport reports it.
typedef struct { int id; float x, y, major, minor, angle, size; } AgContact;
/* SETTLED (2026-10-21): where a contact came to rest and its shape there — the hold's read
   (auxgestHold). A finger put straight down and one UNROLLED from a curled hand into the
   same place read the same: whatever it did on the way (rolling, sliding) is forgotten
   once it stays within AG_SETTLE_R. t = since when; the shape is its largest frame since. */
#define AG_SETTLE_R 0.03    // ~5 mm: a held finger's slow drift stays settled; an unroll moves far more
typedef struct { float ax, ay; double t; float major, minor, angle, size; } AgSettle;
static void agSettleFrame(AgSettle *s, bool first, float x, float y, float major, float minor, float angle, float size, double now) {
    if (first || hypotf(x - s->ax, y - s->ay) > AG_SETTLE_R) {
        *s = (AgSettle){ x, y, now, major, minor, angle, size };
    } else if (size >= s->size) {
        s->major = major; s->minor = minor; s->angle = angle; s->size = size;
    }
}
// pk*: the contact's shape at its largest (the press fully down); frames seen.
typedef struct { int id; float x0, y0, x, y, move; double t0, t1; bool live;
                 float pkSize, pkMajor, pkMinor, pkAngle; int frames;
                 float sz0, szMax;              // contact size on its first frame, and at most
                 AgSettle st;                   // where / how it came to rest (the hold's read)
                 bool rest;                     // rest: RESTING through others' gestures (agRester) — never a gesture itself
                 signed char hk; } AgTrack;     // the hold's last SURE kind + 1 (0 = none yet; auxgestHold)

// The first frame's share of the contact's peak size: ~1 = it arrived fast (a tap).
static float agLand(const AgTrack *t) { return t->szMax > 0 ? t->sz0 / t->szMax : 1; }
// The slowest landing among k tracks.
static float agLandMin(const AgTrack *t, int k) {
    float r = 1;
    for (int i = 0; i < k; i++) r = fminf(r, agLand(&t[i]));
    return r;
}
/* A contact's shape is read while it LANDS — its first frames, or until it moves:
   a fingertip sliding fast smears into a long footprint that looks like the thumb's
   edge, and big swipes read as thumb swipes (Space, 2026-10-16). */
static bool agShapeFrame(int frames, float move) { return frames <= 8 || move < 0.015f; }

/* THE THUMBPRINT. Features of one contact's peak ellipse; a print is the mean and
   spread of each for fingers [0] and the thumb [1], learnt by bin/thumbprint. */
#define AGF 5
typedef struct {
    bool ok; float mu[2][AGF], sd[2][AGF];
    // Context: the offset (dx, dy) from the nearest finger landing within `window` s.
    bool ctxOk; float cmu[2][2], csd[2][2], window;
    // GROUP (2026-10-17): a contact among others — its shape plus where it sits from the
    // others' centre — learnt from thumb + fingers swiping TOGETHER (pinched or apart)
    // and from plain finger swipes (`thumbprint left|right group`).
#define AGG 7
    bool grpOk; float gmu[2][AGG], gsd[2][AGG];
} AgPrint;

/* Recent FINGER landings on one pad (never the thumb's), for the context score. */
#define AG_HIST 8
typedef struct { float x, y; double t; } AgLand;
typedef struct { AgLand l[AG_HIST]; int n, at; } AgHist;
static void agHistAdd(AgHist *h, float x, float y, double t) {
    h->l[h->at] = (AgLand){ x, y, t };
    h->at = (h->at + 1) % AG_HIST;
    if (h->n < AG_HIST) h->n++;
}
// The offset of (x, y) from the nearest landing at most `window` s before `t`, and its age.
static bool agHistNearest(const AgHist *h, float x, float y, double t, double window,
                          float *dx, float *dy, double *age) {
    float best = 1e9f; bool found = false;
    for (int i = 0; i < h->n; i++) {
        double a = t - h->l[i].t;
        if (a < -0.5 || a > window) continue;
        float ddx = x - h->l[i].x, ddy = y - h->l[i].y, d = ddx * ddx + ddy * ddy;
        if (d < best) { best = d; *dx = ddx; *dy = ddy; *age = fmax(a, 0); found = true; }
    }
    return found;
}
static void agFeatures(float major, float minor, float angle, float size, float f[AGF]) {
    f[0] = logf(fmaxf(major, 1e-3f));      // length
    f[1] = logf(fmaxf(minor, 1e-3f));      // width
    f[2] = cosf(2 * angle);                // which way it points (an axis: 2θ has no wrap)
    f[3] = sinf(2 * angle);
    f[4] = logf(fmaxf(size, 1e-3f));       // area / pressure
}
// > 0 = more thumb than finger (log-likelihood ratio).
static float agPrintScore(const AgPrint *p, const float f[AGF]) {
    float s = 0;
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < AGF; i++) {
            float z = (f[i] - p->mu[c][i]) / p->sd[c][i];
            s += (c ? -1 : 1) * (0.5f * z * z + logf(p->sd[c][i]));
        }
    return s;
}
static float agCtxScore(const AgPrint *p, float dx, float dy) {
    float v[2] = { dx, dy }, s = 0;
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < 2; i++) {
            float z = (v[i] - p->cmu[c][i]) / p->csd[c][i];
            s += (c ? -1 : 1) * (0.5f * z * z + logf(p->csd[c][i]));
        }
    return s;
}
// Shape, plus the context when there is a recent landing to measure from (faded by its age).
static float agScoreWith(const AgPrint *p, const float f[AGF], bool has, float dx, float dy, double age) {
    float s = agPrintScore(p, f);
    if (p->ctxOk && has && age < p->window) s += (float)(1 - age / p->window) * agCtxScore(p, dx, dy);
    return s;
}
static float agTrackScore(const AgPrint *p, const AgTrack *t) {
    float f[AGF];
    agFeatures(t->pkMajor, t->pkMinor, t->pkAngle, t->pkSize, f);
    return agPrintScore(p, f);
}
// Contact i of k landing together: its shape, then its landing offset from the others' mean.
static void agGroupFeatures(float pk[][4], float (*xy0)[2], int k, int i, float f[AGG]) {
    agFeatures(pk[i][0], pk[i][1], pk[i][2], pk[i][3], f);
    float ox = 0, oy = 0;
    for (int j = 0; j < k; j++) if (j != i) { ox += xy0[j][0] / (k - 1); oy += xy0[j][1] / (k - 1); }
    f[AGF] = xy0[i][0] - ox; f[AGF + 1] = xy0[i][1] - oy;
}
static float agGroupScore(const AgPrint *p, const float f[AGG]) {   // > 0 = the thumb
    float s = 0;
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < AGG; i++) {
            float z = (f[i] - p->gmu[c][i]) / p->gsd[c][i];
            s += (c ? -1 : 1) * (0.5f * z * z + logf(p->gsd[c][i]));
        }
    return s;
}
// The thumb among k ≥ 2 tracks by the group model: the most thumb-like, if it is one
// at all; -1 = all fingers. Only with p->grpOk.
static int agGroupThumb(const AgPrint *p, const AgTrack *t, int k, float *best) {
    float pk[AG_MAX][4], xy[AG_MAX][2];
    for (int i = 0; i < k; i++) {
        pk[i][0] = t[i].pkMajor; pk[i][1] = t[i].pkMinor; pk[i][2] = t[i].pkAngle; pk[i][3] = t[i].pkSize;
        xy[i][0] = t[i].x0; xy[i][1] = t[i].y0;
    }
    int bi = -1; float bs = -1e9f;
    for (int i = 0; i < k; i++) {
        float f[AGG]; agGroupFeatures(pk, xy, k, i, f);
        float s = agGroupScore(p, f);
        if (s > bs) { bs = s; bi = i; }
    }
    if (best) *best = bs;
    return bs > 0 ? bi : -1;
}
typedef struct {
    AgTrack t[AG_MAX]; int n;      // the gesture under way, thumb included
    int thumbId;                    // the contact known to be the thumb, or -1
    bool thumbHeldSent;             // thumb(true) was reported
    bool thumbUsed;                 // the held thumb modified a gesture: its lift is no tap
    bool holding;                   // a held key is down (holdName)
    int holdFlags;
    bool spent;                     // fingers already acted on: ignore them until they lift
    char holdName[32];
    double deadline;                // 0 = nothing pending
    void (*emit)(const char *name, int phase, int flags, const char *detail, void *ctx);
    void (*thumb)(bool down, void *ctx);
    void *ctx;
    const AgPrint *print;           // this pad's thumbprint, or NULL / !ok (place only)
    const AgRoll *roll;             // this pad's learnt roll rules, or NULL (agRollDefault)
    const AgRest *rest;             // this pad's learnt thumb-down tap rules, or NULL (agRestDefault)
    const AgLone *lone;             // this pad's learnt lone-thumb rules, or NULL (off)
    const AgRestSec *restSec;       // this pad's learnt resting-finger rules, or NULL (AgRest's + AG_FINGER_MM)
    int thumbSide;                  // the thumb lands left (-1, right hand) / right (+1) of the fingers; 0 = either
    bool noThumb;                   // no thumb on this pad: every contact is a finger (right pad, 2026-10-17)
    bool restSecs;                  // fingers resting on THIS pad + others moving = rest<r>:… (agRestOf; right pad, 2026-10-21)
    AgHist hist;                    // where fingers landed lately (agLoneThumb's context)
    // EARLY decisions (2026-10-17): asked mid-swipe with the name the swipe would get
    // ("right4", "spread5"…); true = emit it NOW (fingers spent until they lift) instead
    // of after the lift + merge gap. NULL = never (the typing pads: every letter waits).
    bool (*early)(const char *name, void *ctx);
    // Is this gesture bound at all (agRestOf: unbound, it reads as it did)? NULL = never.
    // "rest<r>:" (no gesture) = anything in that resting section (agRestArmed).
    bool (*wants)(const char *name, void *ctx);
    signed char holdSt;             // the hand reader's last hold state (agHoldRead)
} AuxGest;

static void auxgestInit(AuxGest *g, void (*emit)(const char *, int, int, const char *, void *),
                        void (*thumb)(bool, void *), void *ctx) {
    *g = (AuxGest){ .thumbId = -1, .emit = emit, .thumb = thumb, .ctx = ctx };
}

static bool agHasPrint(const AuxGest *g) { return !g->noThumb && g->print && g->print->ok; }
static bool agHasGroup(const AuxGest *g) { return !g->noThumb && g->print && g->print->grpOk; }
// A contact ALONE on the pad: is it the thumb? By shape once seen a few frames
// (false before), else by place.
static bool agLoneThumb(const AuxGest *g, const AgTrack *t) {
    if (g->noThumb) return false;
    if (agHasPrint(g)) {
        if (t->frames < 3) return false;
        float f[AGF], dx = 0, dy = 0; double age = 0;
        agFeatures(t->pkMajor, t->pkMinor, t->pkAngle, t->pkSize, f);
        bool has = agHistNearest(&g->hist, t->x0, t->y0, t->t0, g->print->window, &dx, &dy, &age);
        return agScoreWith(g->print, f, has, dx, dy, age) > 0;
    }
    return t->y0 < AG_THUMB_Y;
}

// Can t[i] be the thumb among these contacts by LAYOUT? It lands on the thumb's side of
// the fingers' middle and, with 2+ fingers, clearly apart from them: its nearest
// neighbour AG_THUMB_APART × further than the fingers' own typical spacing. (A curled
// pinky is low too, but sits on the far side, as close to the ring finger as the rest.)
static bool agThumbApart(const AuxGest *g, const AgTrack *t, int k, int i) {
    float mx = 0;
    for (int j = 0; j < k; j++) if (j != i) mx += t[j].x0 / (k - 1);
    if (g->thumbSide && (t[i].x0 - mx) * g->thumbSide <= 0) return false;
    if (k < 3) return true;
    float own = 1e9f, nn[AG_MAX]; int m = 0;
    for (int j = 0; j < k; j++) {
        if (j == i) continue;
        own = fminf(own, hypotf(t[j].x0 - t[i].x0, t[j].y0 - t[i].y0));
        float d = 1e9f;
        for (int l = 0; l < k; l++)
            if (l != j && l != i) d = fminf(d, hypotf(t[l].x0 - t[j].x0, t[l].y0 - t[j].y0));
        nn[m++] = d;
    }
    float spacing = 0;   // the fingers' largest nearest-neighbour gap (generous to fingers spread wide)
    for (int j = 0; j < m; j++) if (nn[j] < 1e9f) spacing = fmaxf(spacing, nn[j]);
    return own >= AG_THUMB_APART * spacing;
}
static const AgRoll *agR(const AuxGest *g) { return g->roll ? g->roll : &agRollDefault; }
static const AgRest *agRs(const AuxGest *g) { return g->rest ? g->rest : &agRestDefault; }
static float agRsLead(const AuxGest *g)  { return g->restSec && g->restSec->lead > 0 ? g->restSec->lead : agRs(g)->lead; }
static float agRsStill(const AuxGest *g) { return g->restSec && g->restSec->still > 0 ? g->restSec->still : agRs(g)->still; }
static const AgLone *agLn(const AuxGest *g) { return g->lone ? g->lone : &agLoneDefault; }
// Two or more fingers that landed one after another (a roll), all lifted: macOS's
// tap-to-click reads it as a 2-finger tap (right-click), which it isn't — a tap needs
// the fingers down together (within the roll gap).
static bool agRollTap(const AuxGest *g) {
    if (g->n < 2) return false;
    const AgRoll *r = agR(g);
    double first = g->t[0].t0, last = g->t[0].t0;
    for (int i = 0; i < g->n; i++) {
        if (g->t[i].live || g->t[i].move > fmaxf(AG_TAP_MOVE, r->move)) return false;
        if (g->t[i].t0 < first) first = g->t[i].t0;
        if (g->t[i].t0 > last) last = g->t[i].t0;
    }
    return last - first >= r->gap;
}
// Tracks sorted by landing: each ≥ gap after the last, in order across the pad →
// 'R' (left→right) / 'L'; else 0.
static char agRollDir(const AgTrack *t, int k, float gap) {
    if (k < 2) return 0;
    bool right = true, left = true;
    for (int i = 1; i < k; i++) {
        if (t[i].x0 <= t[i - 1].x0) right = false;
        if (t[i].x0 >= t[i - 1].x0) left = false;
        if (t[i].t0 - t[i - 1].t0 < gap) return 0;
    }
    return right ? 'R' : left ? 'L' : 0;
}

static int agFind(const AuxGest *g, int id) {
    for (int i = 0; i < g->n; i++) if (g->t[i].id == id) return i;
    return -1;
}
static bool auxgestThumbDown(const AuxGest *g) {
    int i = g->thumbId >= 0 ? agFind(g, g->thumbId) : -1;
    return i >= 0 && g->t[i].live;
}
// Fingers resting still, no thumb: the pad is being HELD as a modifier for the other
// pad (1 = Shift, 2 = Space held; 3 / 4 / 5 pick only their own layers). How many; 0 = none / not still.
// `moving`: fingers moving around count too (the right pad, asked for 2026-10-17 — a
// finger steering the pointer is still "one finger down").
static int auxgestStill(const AuxGest *g, double now, bool moving) {
    if (g->thumbId >= 0 || g->n < 1 || g->n > 5) return 0;
    for (int i = 0; i < g->n; i++) {
        const AgTrack *t = &g->t[i];
        if (!t->live || t->frames < 3 || (!moving && t->move >= AG_TAP_MOVE) || now - t->t0 < AG_STILL_S) return 0;
    }
    if (g->n == 1 && agLoneThumb(g, &g->t[0])) return 0;
    return g->n;
}

/* THE HOLD (2026-10-21): what rests on the LEFT pad held as a modifier for the right pad.
   Each resting contact is a FINGERTIP, the THUMB, a KNUCKLE or the PALM, told by its
   shape (agHoldFeatures; one diagonal Gaussian per kind, learnt by `thumbprint left hold`
   → thumbprint.json left.hold). Knuckles and the palm never count. The state:
     0 nothing (no fingertips: the thumb alone, knuckles, the palm)
     1 / 2   one / two fingertips (the thumb doesn't matter)
     3 / AG_HOLD_THREE_THUMB   three fingertips, without / with the thumb
     4 / 5   four fingertips, without / with the thumb (5 = "Five Fingers")
   No hold model learnt: every contact is a fingertip except the most thumb-like one by the
   thumbprint (score > 0), which is the thumb. */
#define AGH 6
#define AG_HOLD_THREE_THUMB 6
#define AG_HOLD_STATES 7
/* IDLE (2026-10-21, `thumbprint left idle`): the hand just RESTING there while the right pad
   is used — no fingers meant. A resting hand leaves fingertip-like and palm-like contacts
   alike, so it is AGK_IDLES Gaussians (k-means clusters of what was recorded), not one. */
#define AGK_IDLES 3
enum { AGK_FINGER, AGK_THUMB, AGK_KNUCKLE, AGK_PALM, AGK_IDLE, AGK_N = AGK_IDLE + AGK_IDLES };
static bool agKindIgnored(int k) { return k >= AGK_KNUCKLE; }
/* WHERE IN THE HAND (2026-10-21): with the shape, AGP place features (agHoldPos), both
   RELATIVE to the hand (it sits anywhere on the pad — no place on the pad itself is used):
   how far below the hand's topmost contact (fingertips make the top row, the palm sits
   under them), how far in from the hand's thumb-side edge (the thumb is that edge). Taken
   from where each contact SETTLED, against every live contact on the pad.
   Learnt from recordings that carry positions; a kind never seen with them gets the pooled
   (uninformative) stats, so older recordings still count for shape. */
#define AGP 2
#define AGHP (AGH + AGP)
/* UNSURE → NOTHING (2026-10-21, user: false fingers are the worst — rather idle, even if
   fingers must go down more deliberately). `margin`: a contact is a fingertip / the thumb
   only when that beats its best not-deliberate kind (knuckle, palm, resting hand) by this
   much log-likelihood, and not-deliberate only when that wins by as much; between the two
   it is UNSURE, and one unsure contact makes the whole hold read as nothing — never a
   smaller count (that would fire a different binding). Fit by bin/thumbprint. */
#define AGK_UNSURE (-2)
/* THE HAND READER (2026-10-21, user: "quite inaccurate — interpret it smarter"): reads the
   WHOLE hand at once instead of one contact at a time. Every way of reading the pad is a
   hypothesis — k = 0…4 fingertips being the k HIGHEST contacts (the thumb set aside), plus
   none or one contact as the thumb — scored by a learnt log-linear model over what makes a
   hand: the gap under the row, how tip-shaped the row is (and its weakest member), how
   tip-shaped the best contact left below is, the row's own spread / spacing / inner gap,
   the thumb's shape and where it sits from the row. P(state) sums its hypotheses; the best
   state counts only at ≥ tau (else nothing — user: rather idle than false fingers).
   Why: recorded combos showed held tips are the top contacts 99% of the time with a median
   0.38 pad-height gap below, while per-contact labels were often wrong (the lone far tip
   recorded as "resting", a round resting contact as the tip) — the per-kind Gaussians had
   learnt partly from those. Block cross-validation on all recordings (each 1/5 of every
   combo held out in one run, 2026-10-21): combos 432 → 521/540 right, wrong counts 18 → 3,
   resting hand as fingers 25 → 0/281, posed holds 27 → 35/35. Fit by bin/thumbprint
   (hold.reader); without it the per-kind path below is used. */
#define AGR 18
#define AGR_RESTS 3
typedef struct { float mu[AGH], sd[AGH]; } AgGauss;
typedef struct { bool ok; AgGauss tip, thumb, rest[AGR_RESTS]; float w[AGR], tau, keep; } AgReader;
typedef struct { bool ok, has[AGK_N]; float mu[AGK_N][AGHP], sd[AGK_N][AGHP]; float margin; AgReader rd; } AgHold;
typedef struct { float xmin, xmax, ymax; int side; } AgHand;   // side: the thumb's, +1 = right (left hand)
static AgHand agHandOf(const float *x, const float *y, int n, int side) {
    AgHand hd = { 1e9f, -1e9f, -1e9f, side };
    for (int i = 0; i < n; i++) { hd.xmin = fminf(hd.xmin, x[i]); hd.xmax = fmaxf(hd.xmax, x[i]); hd.ymax = fmaxf(hd.ymax, y[i]); }
    return hd;
}
static void agHoldPos(const AgHand *hd, float x, float y, float out[AGP]) {
    out[0] = y - hd->ymax;
    out[1] = hd->side >= 0 ? x - hd->xmax : hd->xmin - x;
}
static void agHoldFeatures(float major, float minor, float angle, float size, float f[AGH]) {
    agFeatures(major, minor, angle, size, f);
    // Which way it points, only as much as it is long: a round contact's angle is noise
    // (the recorded poses read 43 / 55 this way, 40 with the bare angle, 2026-10-21).
    float e = major > 1e-3f ? (major - minor) / major : 0;
    f[2] *= e; f[3] *= e;
    f[5] = f[4] - f[0] - f[1];             // size for its footprint: a soft fingertip vs a bony knuckle
}
// The kind's log-likelihood (higher = more like it) over the first `dims` features
// (AGH = shape only, AGHP = shape + place).
static float agHoldLL(const AgHold *h, int k, const float *f, int dims) {
    float s = 0;
    for (int i = 0; i < dims; i++) { float z = (f[i] - h->mu[k][i]) / h->sd[k][i]; s -= 0.5f * z * z + logf(h->sd[k][i]); }
    return s;
}
// alt (or NULL): the best deliberate kind, what an UNSURE contact would be if it is one.
static int agHoldKindAlt(const AgHold *h, const float *f, int dims, int *alt) {
    int bd = AGK_FINGER, bi = -1; float sd = -1e30f, si = -1e30f;   // best deliberate / not
    for (int k = 0; k < AGK_N; k++) {
        if (!h->has[k]) continue;
        float s = agHoldLL(h, k, f, dims);
        if (agKindIgnored(k)) { if (s > si) { si = s; bi = k; } }
        else if (s > sd) { sd = s; bd = k; }
    }
    if (alt) *alt = bd;
    if (bi < 0) return bd;
    if (sd - si > h->margin) return bd;
    if (si - sd > h->margin) return bi;
    return AGK_UNSURE;
}
static int agHoldKind(const AgHold *h, const float *f, int dims) { return agHoldKindAlt(h, f, dims, NULL); }
// The state from each contact's kind (kinds[i] of n): the thumb is one contact at most —
// a second thumb-like one is a fingertip; five fingertips, no thumb = four and the thumb.
static int agHoldState(const int *kinds, int n) {
    int fingers = 0, thumbs = 0;
    for (int i = 0; i < n; i++) { fingers += kinds[i] == AGK_FINGER; thumbs += kinds[i] == AGK_THUMB; }
    if (thumbs > 1) { fingers += thumbs - 1; thumbs = 1; }
    if (fingers >= 5 && !thumbs) { fingers = 4; thumbs = 1; }
    if (fingers > 4) fingers = 4;
    if (fingers == 3 && thumbs) return AG_HOLD_THREE_THUMB;
    if (fingers == 4 && thumbs) return 5;
    return fingers;
}
/* UNSURE ONLY WHEN IT MATTERS (2026-10-21: two clear tips read as nothing because a resting
   contact was maybe-the-thumb — and the thumb doesn't count at two). kinds[i] AGK_UNSURE =
   either alt[i] or left out: the state when every way of reading the unsure ones agrees,
   else 0 (never a wrong count). Combos 1: 106 → 111/120, 2: 83 → 108/120; resting hand as
   fingers 24 → 27/281. */
static int agHoldStateU(const int *kinds, const int *alt, int n) {
    int u[4], nu = 0;
    for (int i = 0; i < n; i++) if (kinds[i] == AGK_UNSURE) { if (nu == 4) return 0; u[nu++] = i; }
    int st = -1;
    for (int m = 0; m < 1 << nu; m++) {
        int kk[32], c = 0, j = 0;
        for (int i = 0; i < n && c < 32; i++) {
            if (j < nu && u[j] == i) { if (m >> j & 1) kk[c++] = alt[i]; j++; }
            else kk[c++] = kinds[i];
        }
        int s = agHoldState(kk, c);
        if (st < 0) st = s; else if (s != st) return 0;
    }
    return st;
}
/* THE TOP ROW (2026-10-21, user: "the one finger can even be far away from all the other
   ones — it's obviously a finger"): a held fingertip's shape drifts (it flattens: size 0.84 →
   1.3 in a few s, read palm), its PLACE doesn't. Contacts sorted by height, the biggest gap
   between neighbours: one or two above a gap of AG_TOPROW_GAP are the deliberate fingertips,
   whatever their shape — the resting hand never leaves 1–2 up there (0 / 281 idle moments;
   combos 1: 115/120, 2: 114/120 + 2 read as 1; 3+ never). y: settled, pad-normalized (up =
   higher). Returns the row's size (1 / 2; *cut = contacts above it are the row), else 0. */
#define AG_TOPROW_GAP 0.15f
static int agTopRow(const float *y, int n, float *cut) {
    if (n < 2 || n > 32) return 0;
    float s[32];
    for (int i = 0; i < n; i++) {   // descending
        int j = i;
        while (j > 0 && s[j - 1] < y[i]) { s[j] = s[j - 1]; j--; }
        s[j] = y[i];
    }
    int r = 0; float g = -1;
    for (int i = 1; i < n; i++) if (s[i - 1] - s[i] > g) { g = s[i - 1] - s[i]; r = i; }
    if (g < AG_TOPROW_GAP || r > 2) return 0;
    *cut = (s[r - 1] + s[r]) / 2;
    return r;
}
// THE HAND READER's pieces (see AgReader). One hypothesis: its state, the thumb (contact
// index, -1 = none), the row (its k contacts, highest first) and its features.
typedef struct { int st, thumb, k, row[4]; float phi[AGR]; } AgHyp;
#define AGR_MAXH ((AG_MAX + 1) * 5)
static float agGaussLL(const AgGauss *g, const float *f) {
    float s = 0;
    for (int i = 0; i < AGH; i++) { float z = (f[i] - g->mu[i]) / g->sd[i]; s -= 0.5f * z * z + logf(g->sd[i]); }
    return s;
}
static float agClip(float v, float a) { return fmaxf(-a, fminf(a, v)); }
// Tip-ness / thumb-ness of one shape: against the resting hand's (log-sum of its clusters), ±10.
static void agReadLLR(const AgReader *r, const float *f, float *tl, float *hl) {
    float l[AGR_RESTS], m = -1e30f, s = 0;
    for (int j = 0; j < AGR_RESTS; j++) { l[j] = agGaussLL(&r->rest[j], f); m = fmaxf(m, l[j]); }
    for (int j = 0; j < AGR_RESTS; j++) s += expf(l[j] - m);
    float rl = m + logf(s);
    *tl = agClip(agGaussLL(&r->tip, f) - rl, 10); *hl = agClip(agGaussLL(&r->thumb, f) - rl, 10);
}
static int agHoldStateOf(int k, bool thumb) { return k == 3 && thumb ? AG_HOLD_THREE_THUMB : k == 4 && thumb ? 5 : k; }
// Every hypothesis for n contacts: f = each one's agHoldFeatures (stride floats apart), x / y
// where it settled (pad-normalized, up = higher), side = the thumb's (+1 right, the left hand).
static int agReadHyps(const AgReader *r, const float *f, int stride, const float *x, const float *y, int n, int side, AgHyp *hs) {
    if (n > AG_MAX) n = AG_MAX;
    float tl[AG_MAX], hl[AG_MAX]; int ord[AG_MAX];
    for (int i = 0; i < n; i++) { agReadLLR(r, f + i * stride, &tl[i], &hl[i]); ord[i] = i; }
    for (int i = 1; i < n; i++) { int v = ord[i], j = i; while (j > 0 && y[ord[j - 1]] < y[v]) { ord[j] = ord[j - 1]; j--; } ord[j] = v; }
    int nh = 0;
    for (int t = -1; t < n; t++) {
        int rs[AG_MAX], m = 0;
        for (int i = 0; i < n; i++) if (ord[i] != t) rs[m++] = ord[i];
        for (int k = 0; k <= 4 && k <= m; k++) {
            if (!k && t >= 0) continue;   // the thumb alone = nothing: one hypothesis
            AgHyp *h = &hs[nh++];
            memset(h, 0, sizeof *h);
            h->thumb = t; h->k = k; h->st = agHoldStateOf(k, t >= 0);
            float *p = h->phi;
            p[k] = 1;
            if (k) {
                float lo = y[rs[k - 1]], sum = 0, mn = 1e9f, xs[4];
                for (int i = 0; i < k; i++) { h->row[i] = rs[i]; sum += tl[rs[i]]; mn = fminf(mn, tl[rs[i]]); xs[i] = x[rs[i]]; }
                p[5] = 10 * fminf(lo - (k < m ? y[rs[k]] : 0), 0.5f);   // the gap under the row
                p[6] = sum / k;                                          // how tip-shaped
                p[7] = mn;                                               // its weakest tip
                p[8] = 10 * (y[rs[0]] - lo);                             // its height spread
                if (k >= 2) {
                    for (int i = 1; i < k; i++) { float v = xs[i]; int j = i; while (j > 0 && xs[j - 1] > v) { xs[j] = xs[j - 1]; j--; } xs[j] = v; }
                    float dx = 1e9f, gin = 0;
                    for (int i = 1; i < k; i++) { dx = fminf(dx, xs[i] - xs[i - 1]); gin = fmaxf(gin, y[rs[i - 1]] - y[rs[i]]); }
                    p[9] = 10 * dx;                                      // tips side by side
                    p[16] = 10 * gin;                                    // the biggest gap INSIDE the row
                }
            }
            if (k < m) { float b = -1e9f; for (int i = k; i < m; i++) b = fmaxf(b, tl[rs[i]]); p[10] = b; }   // best tip left out
            if (t >= 0) {
                float edge = side >= 0 ? -1e9f : 1e9f;
                for (int i = 0; i < k; i++) edge = side >= 0 ? fmaxf(edge, x[rs[i]]) : fminf(edge, x[rs[i]]);
                p[11] = 1;
                p[12] = hl[t];                                           // thumb-shaped
                p[13] = 10 * (y[rs[k - 1]] - y[t]);                      // below the row
                p[14] = 10 * (side >= 0 ? x[t] - edge : edge - x[t]);    // out on the thumb side
                p[15] = k >= 3;                                          // where the thumb counts
            }
            p[17] = (m - k) / 3.0f;                                      // contacts left resting
        }
    }
    return nh;
}
// The hand's state (0 when the best is under tau); P (AG_HOLD_STATES, or NULL) each state's
// probability; best (or NULL) the likeliest hypothesis of that state, for its roles.
static int agReadHand(const AgReader *r, const float *f, int stride, const float *x, const float *y, int n, int side, float *P, AgHyp *best) {
    AgHyp hs[AGR_MAXH];
    int nh = agReadHyps(r, f, stride, x, y, n, side, hs);
    float s[AGR_MAXH], m = -1e30f, pst[AG_HOLD_STATES] = {0}, z = 0;
    for (int i = 0; i < nh; i++) {
        s[i] = 0;
        for (int j = 0; j < AGR; j++) s[i] += r->w[j] * hs[i].phi[j];
        m = fmaxf(m, s[i]);
    }
    for (int i = 0; i < nh; i++) { float e = expf(s[i] - m); pst[hs[i].st] += e; z += e; }
    int st = 0;
    for (int k = 0; k < AG_HOLD_STATES; k++) { pst[k] /= z; if (pst[k] > pst[st]) st = k; }
    if (P) memcpy(P, pst, sizeof pst);
    if (best) {
        int bi = -1;
        for (int i = 0; i < nh; i++) if (hs[i].st == st && (bi < 0 || s[i] > s[bi])) bi = i;
        *best = hs[bi];
    }
    return st && pst[st] < r->tau ? 0 : st;
}
// The hold by the reader: every live contact where it settled. A NEW state needs its tips and
// thumb settled (AG_STILL_S); the held one is STICKY while it still reads ≥ keep (no flicker
// to nothing mid-gesture). g->holdSt is written: gAuxQ only.
static int agHoldRead(AuxGest *g, const AgReader *r, double now, int *kinds) {
    float f[AG_MAX][AGH], x[AG_MAX], y[AG_MAX]; int idx[AG_MAX], n = 0;
    for (int i = 0; i < g->n; i++) {
        const AgTrack *t = &g->t[i];
        if (kinds) kinds[i] = -1;
        if (!t->live || !t->frames || n == AG_MAX) continue;
        agHoldFeatures(t->st.major, t->st.minor, t->st.angle, t->st.size, f[n]);
        x[n] = t->st.ax; y[n] = t->st.ay; idx[n++] = i;
    }
    float P[AG_HOLD_STATES]; AgHyp b;
    int st = agReadHand(r, &f[0][0], AGH, x, y, n, g->thumbSide, P, &b);
    bool settled = true;
    for (int c = 0; c < n; c++) if (kinds) kinds[idx[c]] = AGK_IDLE;
    for (int c = -1; c < b.k; c++) {
        int j = c < 0 ? b.thumb : b.row[c];
        if (j < 0) continue;
        const AgTrack *t = &g->t[idx[j]];
        if (kinds) kinds[idx[j]] = c < 0 ? AGK_THUMB : AGK_FINGER;
        if (t->frames < 3 || now - t->st.t < AG_STILL_S) settled = false;
    }
    int prev = g->holdSt;
    if (st != prev) {
        if (prev && P[prev] >= r->keep) st = prev;
        else if (st && !settled) st = 0;
    }
    g->holdSt = (signed char)st;
    return st;
}
// The kind of one track: the hold model's (shape + where it sits in the hand), else (no
// model) finger / thumb by the print.
static int agTrackKind(const AuxGest *g, const AgHold *h, const AgTrack *t, const AgHand *hd, int *alt) {
    if (h && h->ok) {
        float f[AGHP];
        agHoldFeatures(t->st.major, t->st.minor, t->st.angle, t->st.size, f);
        agHoldPos(hd, t->st.ax, t->st.ay, f + AGH);
        return agHoldKindAlt(h, f, AGHP, alt);
    }
    return g->print && g->print->ok && agTrackScore(g->print, t) > 0 ? AGK_THUMB : AGK_FINGER;
}
// The pad's hold state now (0 = none / not resting). Every live contact must be read (3
// frames) and SETTLED AG_STILL_S (agSettleFrame) — except one already reading as a knuckle /
// the palm, which may come, go and move as it likes. Lifted ones
// (still in the gesture till it's decided) are left out. kinds (AG_MAX, or NULL) = each
// live track's kind (AGK_UNSURE: could be either), -1 for the rest, for the log.
// STICKY (2026-10-21 trace: a held tip read +2.1 / +1.0 / +2.3 against margin 2.0, so the
// hold flickered 1 ↔ nothing every frame and right-pad gestures landed on "nothing"): a
// contact once read SURELY keeps that kind while it only reads unsure; a sure read of
// another kind still changes it. g is written (each track's hk): gAuxQ only.
static int auxgestHold(AuxGest *g, const AgHold *h, double now, int *kinds) {
    if (h && h->rd.ok) return agHoldRead(g, &h->rd, now, kinds);
    int k[AG_MAX], alt[AG_MAX], n = 0;
    float ts[AG_MAX], hx[AG_MAX], hy[AG_MAX];
    int nh = 0;   // the hand: every live contact, where it settled
    for (int i = 0; i < g->n; i++) if (g->t[i].live && g->t[i].frames) { hx[nh] = g->t[i].st.ax; hy[nh++] = g->t[i].st.ay; }
    AgHand hd = agHandOf(hx, hy, nh, g->thumbSide);
    // The top row first: its fingertips, once read and settled, are the state; the rest of
    // the hand below the gap isn't looked at.
    float cut; int top = agTopRow(hy, nh, &cut);
    if (top) {
        for (int i = 0; i < g->n; i++) {
            const AgTrack *t = &g->t[i];
            bool row = t->live && t->frames && t->st.ay > cut;
            if (kinds) kinds[i] = row ? AGK_FINGER : -1;
            if (row && (t->frames < 3 || now - t->st.t < AG_STILL_S)) return 0;
        }
        return top;
    }
    for (int i = 0; i < g->n; i++) {
        AgTrack *t = &g->t[i];
        if (kinds) kinds[i] = -1;
        if (!t->live) continue;
        int ka = AGK_FINGER, kd = t->frames ? agTrackKind(g, h, t, &hd, &ka) : AGK_FINGER;
        if (h && h->ok && t->frames) {
            if (kd != AGK_UNSURE) t->hk = (signed char)(kd + 1);
            else if (t->hk) kd = t->hk - 1;
        }
        // Still landing: wait — unless it already reads as a knuckle / the palm (a palm's
        // contacts come and go under the hand; each would blank the hold for 100 ms).
        if (t->frames < 3 || now - t->st.t < AG_STILL_S) {
            if (h && h->ok && t->frames && agKindIgnored(kd)) { if (kinds) kinds[i] = kd; continue; }
            return 0;
        }
        if (kinds) kinds[i] = kd;
        if (agKindIgnored(kd)) continue;   // AGK_UNSURE is < 0: kept, settled by agHoldStateU
        ts[n] = g->print && g->print->ok ? agTrackScore(g->print, t) : 0;
        alt[n] = ka; k[n++] = kd;
    }
    // No model: only the MOST thumb-like is the thumb.
    if (!(h && h->ok)) {
        int bi = -1;
        for (int i = 0; i < n; i++) if (k[i] == AGK_THUMB && (bi < 0 || ts[i] > ts[bi])) bi = i;
        for (int i = 0; i < n; i++) if (i != bi) k[i] = AGK_FINGER;
    }
    return agHoldStateU(k, alt, n);
}

static void agSetThumb(AuxGest *g, int id) {
    if (g->noThumb) return;
    g->thumbId = id;
    if (!g->thumbHeldSent) { g->thumbHeldSent = true; if (g->thumb) g->thumb(true, g->ctx); }
}
static void agDropThumb(AuxGest *g) {
    g->thumbId = -1; g->thumbUsed = false;
    if (g->thumbHeldSent) { g->thumbHeldSent = false; if (g->thumb) g->thumb(false, g->ctx); }
}

static int agByT0(const void *a, const void *b) {
    double d = ((const AgTrack *)a)->t0 - ((const AgTrack *)b)->t0;
    return d < 0 ? -1 : d > 0;
}
static void agGaps(const AgTrack *t, int k, char *out, size_t n) {
    size_t at = (size_t)snprintf(out, n, "gaps(ms)=");
    for (int i = 1; i < k && at < n; i++)
        at += (size_t)snprintf(out + at, n - at, "%s%.0f", i > 1 ? "," : "", (t[i].t0 - t[i - 1].t0) * 1000);
}

// Name the fingers' gesture (thumb already taken out). `thumb` = a thumb that took part.
// t sorted by landing.
// How much the hand grew (+) / shrank (−): the contacts' mean distance from their centre,
// last frame vs first. Fingers swiping together barely change it.
static float agReshape(const AgTrack *t, int k) {
    float cx0 = 0, cy0 = 0, cx = 0, cy = 0, r0 = 0, r = 0;
    for (int i = 0; i < k; i++) { cx0 += t[i].x0 / k; cy0 += t[i].y0 / k; cx += t[i].x / k; cy += t[i].y / k; }
    for (int i = 0; i < k; i++) {
        r0 += hypotf(t[i].x0 - cx0, t[i].y0 - cy0) / k;
        r  += hypotf(t[i].x - cx, t[i].y - cy) / k;
    }
    return r - r0;
}

// tp: the tap rules (NULL = the fixed ones; agRs for fingers by a resting thumb).
static void agName(const AgTrack *t, int k, const AgTrack *thumb, const AgRoll *r, const AgRest *tp, char *name, size_t nn,
                   char *detail, size_t dn) {
    if (!tp) tp = &agRestDefault;
    double first = t[0].t0, last = t[0].t0, end = 0;
    float dx = 0, dy = 0, move = 0;
    for (int i = 0; i < k; i++) {
        if (t[i].t0 > last) last = t[i].t0;
        if (t[i].t1 > end) end = t[i].t1;
        dx += (t[i].x - t[i].x0) / k; dy += (t[i].y - t[i].y0) / k;
        if (t[i].move > move) move = t[i].move;
    }
    agGaps(t, k, detail, dn);
    const char *suf = thumb ? "+thumb" : "";
    // The hand changing SIZE as it goes (thumb + 3 pinching / spreading, 2026-10-18) is no
    // swipe, however far its centre drifted: the fingers move and the thumb doesn't.
    // Only a real change of size or travel counts: a 3-finger TAP's jitter (0.002 vs 0.003)
    // read as "pinched" — a third of thumb-down taps lost, 2026-10-18.
    float dr = agReshape(t, k);
    if (k >= 3 && fabsf(dr) > AG_RESHAPE * hypotf(dx, dy) && fmaxf(fabsf(dr), hypotf(dx, dy)) >= AG_SWIPE) {
        snprintf(name, nn, "none");
        size_t at = strlen(detail);
        snprintf(detail + at, dn - at, " (hand %s %.3f vs travel %.3f: not a swipe)",
                 dr > 0 ? "spread" : "pinched", fabsf(dr), hypotf(dx, dy));
        return;
    }
    // Every contact along (2026-10-18): the thumb held still while 3 fingers slide past it
    // keeps the hand's size, but it is no 4-finger swipe. Real swipes: each ≥ 0.61 of the mean.
    if (k >= 3 && fmaxf(fabsf(dx), fabsf(dy)) >= AG_SWIPE) {
        bool vert = fabsf(dy) > fabsf(dx);
        float d = vert ? dy : dx, lag = 1e9f;
        for (int i = 0; i < k; i++)
            lag = fminf(lag, (vert ? t[i].y - t[i].y0 : t[i].x - t[i].x0) * (d > 0 ? 1 : -1) / fabsf(d));
        if (lag < AG_ALONG) {
            snprintf(name, nn, "none");
            size_t at = strlen(detail);
            snprintf(detail + at, dn - at, " (a contact moved %.2f of the hand: not a %d-finger swipe)", lag, k);
            return;
        }
    }
    if (k >= 3) {
        size_t at = strlen(detail);
        snprintf(detail + at, dn - at, " reshape=%+.3f travel=%.3f", dr, hypotf(dx, dy));
    }
    // Mostly one way: 1.5 : 1 — or only just, for a long swipe (a big one arcs, 2026-10-16).
    float dom = hypotf(dx, dy) >= AG_SWIPE_LONG ? 1.05f : 1.5f;
    bool moved = fmaxf(fabsf(dx), fabsf(dy)) >= AG_SWIPE;
    char rd = agRollDir(t, k, r->gap);
    if (rd && r->move > 0 && move <= r->move && end - first <= r->dur + (k - 2) * r->durPer
        && agLandMin(t, k) >= r->land) {   // a learnt roll: before the swipe test (rolling fingers drift)
        snprintf(name, nn, "roll%c%d%s", rd, k, suf);
    } else if (moved && k >= 2 && last - first > AG_LAND_SPREAD) {
        snprintf(name, nn, "none");
        size_t at = strlen(detail);
        snprintf(detail + at, dn - at, " (landed over %.0f ms: not one swipe)", (last - first) * 1000);
    } else if (fabsf(dy) >= AG_SWIPE && fabsf(dy) > dom * fabsf(dx))
        snprintf(name, nn, "%s%d%s", dy > 0 ? "up" : "down", k, suf);
    else if (fabsf(dx) >= AG_SWIPE && fabsf(dx) > dom * fabsf(dy))
        snprintf(name, nn, "%s%d%s", dx > 0 ? "right" : "left", k, suf);
    else if (move <= AG_TAP_MOVE && end - first <= tp->dur + (k - 1) * tp->durPer) {
        float land = agLandMin(t, k);
        if (land < (rd ? r->land : tp->land)) {   // laid down, not tapped
            snprintf(name, nn, "none");
            size_t at = strlen(detail);
            snprintf(detail + at, dn - at, " (slow landing %.2f: not a tap)", land);
        } else if (thumb && thumb->t0 <= first - r->gap)      snprintf(name, nn, "rollTF%d", k);
        else if (thumb && thumb->t0 >= last + r->gap)  snprintf(name, nn, "rollFT%d", k);
        else if (rd) snprintf(name, nn, "roll%c%d%s", rd, k, suf);
        else         snprintf(name, nn, "tap%d%s", k, suf);
    } else {
        snprintf(name, nn, "none");
        size_t at = strlen(detail);
        snprintf(detail + at, dn - at, " k=%d dx=%.3f dy=%.3f move=%.3f dur=%.3f land=%.2f y0=%.2f",
                 k, dx, dy, move, end - first, agLandMin(t, k), t[0].y0);
        return;
    }
    if (!strncmp(name, "roll", 4)) {   // for tuning: how still / quick / sharp the roll was
        size_t at = strlen(detail);
        snprintf(detail + at, dn - at, " move=%.3f dur=%.0fms land=%.2f", move, (end - first) * 1000, agLandMin(t, k));
    }
}

// The thumb among these tracks: the known one, else the lowest landing well below the
// rest — or, with a print, the lowest when it alone is thumb-shaped.
static int agThumbOf(const AuxGest *g, const AgTrack *t, int k) {
    if (g->noThumb) return -1;
    for (int i = 0; i < k; i++) if (t[i].id == g->thumbId) return i;
    if (k < 2) return -1;
    if (agHasGroup(g)) return agGroupThumb(g->print, t, k, NULL);   // learnt: trust it alone
    int lo = 0; float sum = 0;
    for (int i = 0; i < k; i++) { sum += t[i].y0; if (t[i].y0 < t[lo].y0) lo = i; }
    if (!agThumbApart(g, t, k, lo)) return -1;   // low, but laid out like a finger
    if ((sum - t[lo].y0) / (k - 1) - t[lo].y0 >= AG_THUMB_DROP) return lo;
    if (!agHasPrint(g)) return -1;
    for (int i = 0; i < k; i++)
        if ((agTrackScore(g->print, &t[i]) > 0) != (i == lo)) return -1;
    return lo;
}

// Five contacts moving apart / together: "spread5" / "pinch5" (five's swipe up / down in
// Control Room). Four or more before the thumbs were retired (2026-10-17).
// Two to four: "pinch2".."pinch4" / "spread2".."spread4" — the whole hand, thumb and
// fingers, closing / opening (2026-10-18): its spread changed by a share (AG_PINCH_RATIO),
// its centre staying about put (fingers drifting together on a swipe are no pinch).
// Judged on the mean distance from their centre, first frame vs last — AND on the motion
// itself (2026-10-28): two contacts, down at the same time, each moving toward (pinch) /
// away from (spread) the other (agConverge). Landing order doesn't matter (thumb first,
// fingers first); a scroll's two fingers moving together by a still contact never pass.
// Each track's travel from its own landing, along the line between the two landings.
// pin: the best pair's closing (the lesser of the two approaches, + = toward);
// pout: the best pair's opening (the lesser of the two retreats, + = apart).
// only: pairs with t[only] in them (-1 = every pair).
static void agConverge(const AgTrack *t, int k, int only, float *pin, float *pout) {
    *pin = *pout = -1;
    for (int i = 0; i < k; i++)
        for (int j = i + 1; j < k; j++) {
            if (only >= 0 && i != only && j != only) continue;
            if (fmax(t[i].t0, t[j].t0) >= fmin(t[i].t1, t[j].t1)) continue;   // never down together
            float ux = t[j].x0 - t[i].x0, uy = t[j].y0 - t[i].y0, L = hypotf(ux, uy);
            if (L <= 0) continue;
            ux /= L; uy /= L;
            float ai = (t[i].x - t[i].x0) * ux + (t[i].y - t[i].y0) * uy;      // i toward j
            float aj = -((t[j].x - t[j].x0) * ux + (t[j].y - t[j].y0) * uy);   // j toward i
            *pin = fmaxf(*pin, fminf(ai, aj));
            *pout = fmaxf(*pout, fminf(-ai, -aj));
        }
}
// The numbers agSpread judged by, for the log.
static void agSpreadDetail(const AgTrack *t, int k, char *out, size_t n) {
    float cx0 = 0, cy0 = 0, cx = 0, cy = 0, r0 = 0, r = 0, pin, pout;
    double first = 1e18, last = 0;
    for (int i = 0; i < k; i++) { cx0 += t[i].x0 / k; cy0 += t[i].y0 / k; cx += t[i].x / k; cy += t[i].y / k; }
    for (int i = 0; i < k; i++) {
        r0 += hypotf(t[i].x0 - cx0, t[i].y0 - cy0) / k;
        r  += hypotf(t[i].x - cx, t[i].y - cy) / k;
        first = fmin(first, t[i].t0); last = fmax(last, t[i].t0);
    }
    agConverge(t, k, -1, &pin, &pout);
    snprintf(out, n, "radius %.3f→%.3f centre %.3f converge in %+.3f out %+.3f landed over %.0fms",
             r0, r, hypotf(cx - cx0, cy - cy0), pin, pout, (last - first) * 1000);
}
static bool agSpread(const AgTrack *t, int k, char *name, size_t nn) {
    if (k < 2) return false;
    float pin, pout;
    agConverge(t, k, -1, &pin, &pout);
    if (pin < AG_CONVERGE && pout < AG_CONVERGE) return false;   // nothing closing / opening: no pinch, no spread
    float cx0 = 0, cy0 = 0, cx = 0, cy = 0, r0 = 0, r = 0;
    for (int i = 0; i < k; i++) { cx0 += t[i].x0 / k; cy0 += t[i].y0 / k; cx += t[i].x / k; cy += t[i].y / k; }
    for (int i = 0; i < k; i++) {
        r0 += hypotf(t[i].x0 - cx0, t[i].y0 - cy0) / k;
        r  += hypotf(t[i].x - cx, t[i].y - cy) / k;
    }
    if (k < 5) {   // the whole hand closing / opening, centre about put (2026-10-18)
        float d = fabsf(r - r0);
        bool in = r < r0;
        if (d < AG_PINCH || (in ? r > AG_PINCH_RATIO * r0 : r0 > AG_PINCH_RATIO * r) || hypotf(cx - cx0, cy - cy0) > 1.5f * d
            || (in ? pin : pout) < AG_CONVERGE) return false;
        snprintf(name, nn, "%s%d", in ? "pinch" : "spread", k);
        return true;
    }
    if (r0 <= 0.01f || fabsf(r - r0) < AG_SPREAD || (r < r0 ? pin : pout) < AG_CONVERGE) return false;
    snprintf(name, nn, "%s%d", r > r0 ? "spread" : "pinch", k);
    return true;
}
// Is t[i] one side of a pinch / spread of all k — moving with it, not resting by it? The
// thumb laid down first then pinching barely moves (under the rest rules' 0.05), so it read
// as RESTING and the fingers' part became restthumb:… (2026-10-28: either landing order pinches).
static bool agInPinch(const AgTrack *t, int k, int i) {
    float pin, pout; char nm[16];
    agConverge(t, k, i, &pin, &pout);
    return fmaxf(pin, pout) >= AG_CONVERGE && agSpread(t, k, nm, sizeof nm);
}

// No-thumb pads (2026-10-17): a contact that was down AG_THUMB_LEAD before all the others,
// is still down and has not moved, while every other one has lifted = RESTING (the thumb,
// laid down first because landing it with the fingers is hard). The others' gesture is
// decided without it — 4 fingers tapping by a resting thumb = tap5 (swipes keep their
// own count); it stays resting for the next. With four others it may also have lifted
// within the merge gap, last. Its index, else -1.
// A QUICK THUMB (2026-10-18): thumb down, then a finger tapping almost at once — inside
// AG_THUMB_LEAD, so it read as a roll (rollR2 → Photoshop's search). Told apart from a
// finger roll by SHAPE (a print is needed: the first one down thumb-shaped, every other
// finger-shaped) and by the thumb OUTLASTING them: still down once they have all lifted,
// or lifting at least AG_THUMB_OUTLAST after the last of them.
static bool agQuickThumb(const AuxGest *g, const AgTrack *t, int k, int e) {
    const AgPrint *p = g->print;
    if (!(p && p->ok) || t[e].pkSize <= 0 || agTrackScore(p, &t[e]) <= 0) return false;
    double lastUp = 0;
    for (int i = 0; i < k; i++) {
        if (i == e) continue;
        if (t[i].live || t[i].t0 < t[e].t0 - AG_THUMB_WITH || t[i].pkSize <= 0 || agTrackScore(p, &t[i]) > 0) return false;
        lastUp = fmax(lastUp, t[i].t1);
    }
    return t[e].live || t[e].t1 - lastUp >= AG_THUMB_OUTLAST;
}
static int agRester(const AuxGest *g, const AgTrack *t, int k) {
    if (!g->noThumb || k < 2) return -1;
    int e = -1, first = 0;
    for (int i = 0; i < k; i++) if (t[i].live) { if (e >= 0) return -1; e = i; }
    for (int i = 1; i < k; i++) if (t[i].t0 < t[first].t0) first = i;
    bool quick = false;
    if (e < 0) {   // all lifted: a quick thumb (the most thumb-shaped), or the earliest down if it lifted last (five)
        int best = -1; float bs = 0;
        if (g->print && g->print->ok)
            for (int i = 0; i < k; i++) { float sc = t[i].pkSize > 0 ? agTrackScore(g->print, &t[i]) : 0; if (sc > bs) { bs = sc; best = i; } }
        quick = best >= 0 && agQuickThumb(g, t, k, best);
        e = quick ? best : first;
        if (!quick) {
            for (int i = 0; i < k; i++) if (t[i].t1 > t[e].t1) return -1;
            // Fewer than five: only a thumb by its print (2026-10-18: thumb down 130 ms
            // first, a finger tapping, the thumb lifting 16 ms after it — inside the merge gap).
            if (k != 5 && !(g->print && g->print->ok && t[e].pkSize > 0 && agTrackScore(g->print, &t[e]) > agRs(g)->shape)) return -1;
        }
    }
    if (t[e].move >= agRs(g)->still) return -1;
    if (quick) return e;
    for (int i = 0; i < k; i++)
        if (i != e && t[i].t0 - t[e].t0 < agRs(g)->lead) return agQuickThumb(g, t, k, e) ? e : -1;
    return e;
}
// Thumb-shaped by the pad's print (bin/thumbprint) — with no print, anything resting first is.
static bool agThumbish(const AuxGest *g, const AgTrack *t) {
    return !(g->print && g->print->ok) || t->pkSize <= 0 || agTrackScore(g->print, t) > agRs(g)->shape;
}
// FINGER-CLOSE (2026-10-28): a contact landed under AG_FINGER_MM from another of t[0..k) is
// a fingertip, whatever its print says — a resting thumb sits ≥ 44 mm from the nearest
// finger in every thumbtap calibration, fingers 17–29 mm apart (remapd TWO_FINGERS_MM).
// Three resting fingers read their first as the thumb (+28 > lone 22.5), so
// right_rest_three never fired (New Layer). `live`: only live contacts count.
#define AG_PAD_W_MM 160.0f   // Magic Trackpad: x / y are pad-normalized
#define AG_PAD_H_MM 115.0f
#define AG_FINGER_MM 35.0f
static float agMM(const AgTrack *a, const AgTrack *b) {
    return hypotf((a->x0 - b->x0) * AG_PAD_W_MM, (a->y0 - b->y0) * AG_PAD_H_MM);
}
static bool agFingerClose(const AuxGest *g, const AgTrack *t, int k, int i, bool live) {
    float lim = g->restSec && g->restSec->fingerMM > 0 ? g->restSec->fingerMM : AG_FINGER_MM;
    for (int j = 0; j < k; j++)
        if (j != i && (!live || t[j].live) && agMM(&t[j], &t[i]) < lim) return true;
    return false;
}
// The layout's log-likelihood of an offset (mm) under combination c; NAN = not learnt.
static float agLayLL(const AgRestSec *q, int c, float dx, float dy) {
    if (!q || c < 0 || c >= AG_LAYS || q->sd[c][0] <= 0 || q->sd[c][1] <= 0) return NAN;
    float a = (dx - q->mu[c][0]) / q->sd[c][0], b = (dy - q->mu[c][1]) / q->sd[c][1];
    return -0.5f * (a * a + b * b) - logf(q->sd[c][0] * q->sd[c][1]);
}
// A resting contact t[i] that may be the thumb: no finger close by, and thumb-shaped —
// with a mover t[mi] (-1 = none yet), where it landed from t[i] weighs in (THE LAYOUT).
static bool agThumbAt(const AuxGest *g, const AgTrack *t, int k, int i, int mi, bool live) {
    if (agFingerClose(g, t, k, i, live)) return false;
    const AgRestSec *q = g->restSec;
    float d = 0; bool lay = false;
    if (q && q->layW > 0 && mi >= 0) {
        float dx = (t[mi].x0 - t[i].x0) * AG_PAD_W_MM, dy = (t[mi].y0 - t[i].y0) * AG_PAD_H_MM;
        float a = agLayLL(q, AG_LAY_THUMB, dx, dy), b = agLayLL(q, 1, dx, dy);
        if (!isnan(a) && !isnan(b)) { d = q->layW * (a - b); lay = true; }
    }
    if (!(g->print && g->print->ok) || t[i].pkSize <= 0) return lay ? d > 0 : true;
    return agTrackScore(g->print, &t[i]) + d > agRs(g)->shape;
}
// THUMB DOWN (2026-10-18): a live contact down AG_THUMB_LEAD before every other live one
// (or thumb-shaped among finger-shaped ones),
// still, thumb-shaped — while 1+ fingers are down with it. The pointer freezes then
// (remapd gMainThumbHold), and its fingers' up / down swipes are thumbup<n> / thumbdown<n>.
static int auxgestThumbRestId(const AuxGest *g) {   // the thumb's contact id, else -1
    int e = -1, others = 0;
    for (int i = 0; i < g->n; i++) if (g->t[i].live && (e < 0 || g->t[i].t0 < g->t[e].t0)) e = i;
    if (e < 0) return -1;
    // Landing WITH the fingers (or just ahead, 2026-10-18: a fast thumb-down swipe got no
    // freeze, and thumb + 2 fingers is macOS's three-finger drag): told by shape instead —
    // the print's thumb, every finger landing inside the lead finger-shaped.
    // The thumb then needn't be first down (2026-10-18: thumb + 2 fingers landed within
    // 3 ms, the earliest a finger): the most thumb-shaped live contact.
    const AgPrint *p = g->print;
    bool lead = true;
    int mi = -1;   // the first finger after it: THE LAYOUT reads where it landed
    for (int i = 0; i < g->n; i++) {
        if (i == e || !g->t[i].live) continue;
        if (g->t[i].t0 - g->t[e].t0 < agRs(g)->lead) lead = false;
        if (mi < 0 || g->t[i].t0 < g->t[mi].t0) mi = i;
        others++;
    }
    if (lead) return others > 0 && g->t[e].move < agRs(g)->still && agThumbAt(g, g->t, g->n, e, mi, true) ? g->t[e].id : -1;
    if (!(p && p->ok)) return -1;
    int th = -1; float bs = 0;
    for (int i = 0; i < g->n; i++) {
        if (!g->t[i].live || g->t[i].pkSize <= 0) continue;
        float sc = agTrackScore(p, &g->t[i]);
        if (sc > bs) { bs = sc; th = i; }
    }
    if (th < 0 || g->t[th].move >= AG_TAP_MOVE || agFingerClose(g, g->t, g->n, th, true)) return -1;
    others = 0;
    for (int i = 0; i < g->n; i++) {
        if (i == th || !g->t[i].live) continue;
        if (g->t[i].t0 < g->t[th].t0 - AG_THUMB_WITH || g->t[i].pkSize <= 0 || agTrackScore(p, &g->t[i]) > 0) return -1;
        others++;
    }
    return others > 0 ? g->t[th].id : -1;
}

/* THUMB AMONG FINGERS, by the shape print even on a no-thumb pad (2026-10-18): thumb + 3
   moving together must never be a 4-finger swipe. The best-scoring contact scores
   AG_THUMB_AMONG and lands left of and below the others (the main pad is the right hand —
   on thumbSide when set). Calibrated (remap/spread_calib.jsonl): thumb + 3 best ≥ 68,
   4-finger swipes ≤ 5.2. Shape needs a couple of frames: until then, no thumb. Its index, else -1. */
#define AG_THUMB_AMONG 14.0f   // reanchor's NAV_THUMB_SCORE
static int agThumbAmong(const AuxGest *g, const AgTrack *t, int k) {
    if (!g->print || !g->print->ok || k < 2) return -1;
    int b = -1; float bs = -1e9f;
    for (int i = 0; i < k; i++) {
        if (t[i].frames < 2 || t[i].pkSize <= 0) continue;
        float s = agTrackScore(g->print, &t[i]);
        if (s > bs) { bs = s; b = i; }
    }
    if (b < 0 || bs < AG_THUMB_AMONG) return -1;
    float mx = 0, my = 0;
    for (int i = 0; i < k; i++) if (i != b) { mx += t[i].x0 / (k - 1); my += t[i].y0 / (k - 1); }
    int side = g->thumbSide ? g->thumbSide : -1;
    return (t[b].x0 - mx) * side > 0 && t[b].y0 < my ? b : -1;
}

/* THE THUMB SWEEPING BY RESTING FINGERS (2026-10-18): 1–4 fingers down and still, then the
   thumb lands on the same pad, swipes sideways and lifts = thumbswipeL<n> / thumbswipeR<n>
   (n = the fingers resting). The fingers stay resting (flagged `rest`: no gesture of their
   own when they lift) so the thumb may sweep again. With a print, the mover must be more
   thumb-shaped than every rester (a resting THUMB with one finger swiping is left1 by it).
   t[li] = the contact that lifted (the rest still down, unless `all`: everything lifted
   together, judged at the merge); the resting count, else 0.
   THE THUMB TAPPING BY RESTING FINGERS (2026-10-18): same, the thumb tapping instead
   (short, still, landed with speed) = thumbtapby<n> (*tap set). A finger tapping beside
   resting ones must stay tapN, so the tapper must also sit on the thumb's side of the
   resters and below them, and (with a print) be thumb-shaped. */
static int agSweepOf(const AuxGest *g, const AgTrack *t, int k, int li, bool all, bool *tap) {
    *tap = false;
    if (!g->noThumb || k < 2 || k > 5) return 0;
    const AgTrack *m = &t[li];
    float dx = m->x - m->x0, dy = m->y - m->y0;
    if (m->live) return 0;
    bool shape = g->print && g->print->ok && m->pkSize > 0;
    float ms = shape ? agTrackScore(g->print, m) : 0;
    if (fabsf(dx) < agLn(g)->swipe || fabsf(dx) <= fabsf(dy)) {
        if (m->move > AG_TAP_MOVE || m->t1 - m->t0 > agLn(g)->dur || agLand(m) < agLn(g)->land
            || (shape && ms <= 0)) return 0;
        *tap = true;
    }
    float mx = 0, my = 0;
    for (int i = 0; i < k; i++) {
        if (i == li) continue;
        const AgTrack *r = &t[i];
        if ((!all && !r->live) || r->move >= agRs(g)->still || m->t0 - r->t0 < agRs(g)->lead) return 0;
        if (shape && r->pkSize > 0 && agTrackScore(g->print, r) >= ms) return 0;
        mx += r->x0 / (k - 1); my += r->y0 / (k - 1);
    }
    int side = g->thumbSide ? g->thumbSide : -1;
    if (*tap && ((m->x0 - mx) * side <= 0 || m->y0 >= my)) return 0;
    return k - 1;
}
static int agSweepBy(const AuxGest *g, int li, bool *tap) { return agSweepOf(g, g->t, g->n, li, false, tap); }
// The thumb's gesture by r resting fingers: thumbswipeL<r> / R<r>, or thumbtapby<r>.
static void agSweepName(char *nm, size_t sz, const AgTrack *m, int r, bool tap) {
    if (tap) snprintf(nm, sz, "thumbtapby%d", r);
    else snprintf(nm, sz, "thumbswipe%s%d", m->x < m->x0 ? "L" : "R", r);
}
/* RESTING SECTIONS (2026-10-21, user: "three fingers down on the right trackpad will have
   its own section"): 1–3 fingers down and still on this pad (never the thumb), then more
   land (at least `lead` after the last of them) and lift while they rest = "rest<r>:<g>",
   r = the fingers resting, g = what the others did: up<m> / down<m> / tap<m> (m fingers,
   four in all at most), or — one mover, thumb-shaped — thumbswipeL / thumbswipeR /
   thumbtap (agSweepOf's rules), or 2+ movers pinching / spreading (pinch<m> / spread<m>,
   the thumb one of them: five contacts in all, 2026-10-28).
   remapd reads it in <hand>_rest_one … _three. The fingers' gestures fire only when
   g->wants has the name (unbound, the gesture reads as before: tap1 by a resting
   finger…); the thumb's always (it was thumbswipeL<r> before). Pads with restSecs only.
   FOUR resting (2026-10-29): the thumb's swipes / tap only (rest4:thumbswipeL …).
   THE THUMB + FINGERS RESTING (2026-10-29, user): one of 2–4 resters may be the thumb —
   "restthumb<f>:<g>", f = the fingers resting with it (1–3), g = up<m> / down<m> / tap<m>
   only (no ← →, no pinches by a resting thumb), five contacts in all (remapd
   <hand>_rest_thumb_one … _three). A reading that fails with r resters tries r + 1.
   mv[i] (k) = the movers; `all` = everything lifted together (judged at the merge). The
   resting count, else 0. */
static int agByT0Idx(const AgTrack *t, int k, int *ord) {
    for (int i = 0; i < k; i++) {
        int j = i;
        while (j > 0 && t[ord[j - 1]].t0 > t[i].t0) { ord[j] = ord[j - 1]; j--; }
        ord[j] = i;
    }
    return k;
}
static int agRestOf(const AuxGest *g, const AgTrack *t, int k, bool all, bool *mv, char *nm, size_t sz) {
    if (!g->restSecs || !g->noThumb || k < 2 || k > 5) return 0;
    int ord[AG_MAX];
    agByT0Idx(t, k, ord);
    bool print = g->print && g->print->ok;
    for (int r = 1; r <= 4 && r < k; r++) {
        int m = k - r;
        if (t[ord[r]].t0 - t[ord[r - 1]].t0 < agRsLead(g)) continue;
        bool ok = true;
        int th = -1;   // the resting thumb among 2+ resters (THE THUMB + FINGERS RESTING)
        float mx = 0, my = 0, rmax = -1e9f;
        for (int j = 0; j < r && ok; j++) {
            const AgTrack *R = &t[ord[j]];
            if ((!all && !R->live) || R->move >= agRsStill(g)) ok = false;
            else if (agThumbAt(g, t, k, ord[j], r == 1 ? ord[1] : -1, !all)) { if (r == 1 || th >= 0) ok = false; else th = j; }
            mx += R->x0 / r; my += R->y0 / r;
            if (print && R->pkSize > 0) rmax = fmaxf(rmax, agTrackScore(g->print, R));
        }
        for (int j = r; j < k && ok; j++) if (t[ord[j]].live) ok = false;
        for (int j = 0; j < r && ok; j++) if (agInPinch(t, k, ord[j])) ok = false;   // pinching with the rest, not resting
        if (!ok) continue;
        for (int i = 0; i < k; i++) mv[i] = false;
        for (int j = r; j < k; j++) mv[ord[j]] = true;
        const AgTrack *M = &t[ord[r]];
        float ms = print && M->pkSize > 0 ? agTrackScore(g->print, M) : 0;
        int side = g->thumbSide ? g->thumbSide : -1;
        if (th < 0 && m == 1 && (print ? ms > 0 && ms > rmax : (M->x0 - mx) * side > 0 && M->y0 < my)) {   // the thumb
            float dx = M->x - M->x0, dy = M->y - M->y0;
            if (fabsf(dx) >= agLn(g)->swipe && fabsf(dx) > fabsf(dy)) snprintf(nm, sz, "rest%d:thumbswipe%s", r, dx < 0 ? "L" : "R");
            else if (M->move <= AG_TAP_MOVE && M->t1 - M->t0 <= agLn(g)->dur && agLand(M) >= agLn(g)->land
                     && (M->x0 - mx) * side > 0 && M->y0 < my) snprintf(nm, sz, "rest%d:thumbtap", r);
            else continue;
            return r;
        }
        if (!g->wants) return 0;
        if (r == 4 && th < 0) continue;   // four fingers resting: the thumb's alone
        float dx = 0, dy = 0; double t0 = 1e18, t1 = 0; bool still = true;
        AgTrack ms_[AG_MAX]; int n = 0;
        for (int j = r; j < k; j++) ms_[n++] = t[ord[j]];
        // 2+ movers closing / opening (agSpread's rules, the thumb may be one): pinch<m> /
        // spread<m> (2026-10-21). The thumb counts, so five contacts in all (2026-10-28).
        // Never by a resting thumb (2026-10-29).
        char sp[16];
        if (th < 0 && m >= 2 && agSpread(ms_, n, sp, sizeof sp)) {
            snprintf(nm, sz, "rest%d:%s", r, sp);
            if (g->wants(nm, g->ctx)) return r;
            continue;
        }
        if (r + m > (th >= 0 ? 5 : 4)) continue;
        n = 0;
        bool thumbMv = false;
        for (int j = r; j < k; j++) {
            const AgTrack *F = &t[ord[j]];
            // A thumb among them: thumb-shaped AND more so than the resting fingers (the
            // thumb test above). A bare > 0 threw out a tapping fingertip scoring +3.4 by
            // three resting (thumbs score 140–280) — New Layer never fired (2026-10-28).
            if (print && F->pkSize > 0) { float s = agTrackScore(g->print, F); if (s > 0 && s > rmax) thumbMv = true; }
            dx += (F->x - F->x0) / m; dy += (F->y - F->y0) / m;
            t0 = fmin(t0, F->t0); t1 = fmax(t1, F->t1);
            if (F->move > AG_TAP_MOVE) still = false;
            ms_[n++] = *F;
        }
        if (thumbMv) continue;
        const char *kind = NULL;
        bool along = true;
        if (fabsf(dy) >= AG_SWIPE && fabsf(dy) > fabsf(dx)) {
            kind = dy > 0 ? "up" : "down";
            for (int j = r; j < k; j++)   // every mover along (half the mean at least)
                if ((t[ord[j]].y - t[ord[j]].y0) * (dy > 0 ? 1 : -1) < fabsf(dy) * 0.5f) along = false;
        } else if (still && t1 - t0 <= AG_TAP_S + AG_TAP_S_PER * (m - 1) && agLandMin(ms_, n) >= AG_TAP_LAND) kind = "tap";
        if (!kind || !along) continue;
        // Two or three tapping fingers landing right → left (a roll, ≥ the pad's roll gap
        // apart): rollL2 / rollL3 there — only where bound, else still the tap (2026-10-29,
        // user; three asked the same day). Never
        // under AG_ROLL_GAP: the right pad's learnt gap (4 ms) would split sloppy taps.
        if (!strcmp(kind, "tap") && (m == 2 || m == 3) && agRollDir(ms_, n, fmaxf(agR(g)->gap, AG_ROLL_GAP)) == 'L') {
            if (th >= 0) snprintf(nm, sz, "restthumb%d:rollL%d", r - 1, m);
            else snprintf(nm, sz, "rest%d:rollL%d", r, m);
            if (g->wants(nm, g->ctx)) return r;
        }
        if (th >= 0) snprintf(nm, sz, "restthumb%d:%s%d", r - 1, kind, m);
        else snprintf(nm, sz, "rest%d:%s%d", r, kind, m);
        if (g->wants(nm, g->ctx)) return r;
    }
    return 0;
}
// k fingers held still where a resting section for k is bound: they're resting, never a
// held key (2026-10-28: three laid down firmly read HELD tap3 at 200 ms, before the tapping
// finger came, and New Layer never fired — 4 of 39 calibration misses).
static bool agRestArmed(const AuxGest *g, int k) {
    char nm[16];
    if (!g->restSecs || !g->wants || k < 1 || k > 4) return false;
    snprintf(nm, sizeof nm, "rest%d:", k);
    if (g->wants(nm, g->ctx)) return true;
    snprintf(nm, sizeof nm, "restthumb%d:", k - 1);   // the thumb + k − 1 fingers (2026-10-29)
    return k >= 2 && g->wants(nm, g->ctx);
}
// Live now: fingers resting on this pad (still, not the thumb, landed `lead` before the
// rest) and the ones that landed since — what agRestOf would read on their lift. For the
// main pad's claim, judged as they land. The resting count (*movers = the others), else 0;
// *thumb = one of 2+ resters is the thumb (restthumb<r−1>:…, 2026-10-29).
static int auxgestRestSplit(const AuxGest *g, int *movers, bool *thumb) {
    int k = g->n, ord[AG_MAX];
    *movers = 0; *thumb = false;
    if (!g->restSecs || k < 2 || k > 5) return 0;
    for (int i = 0; i < k; i++) if (!g->t[i].live) return 0;
    agByT0Idx(g->t, k, ord);
    for (int r = 1; r <= 4 && r < k; r++) {
        if (g->t[ord[r]].t0 - g->t[ord[r - 1]].t0 < agRsLead(g)) continue;
        bool ok = true;
        int th = 0;
        for (int j = 0; j < r; j++) {
            const AgTrack *R = &g->t[ord[j]];
            if (R->move >= agRsStill(g)) ok = false;
            else if (agThumbAt(g, g->t, k, ord[j], r == 1 ? ord[1] : -1, true) && (r == 1 || th++)) ok = false;
        }
        if (ok) { *movers = k - r; *thumb = th > 0; return r; }
    }
    return 0;
}
// While the thumb is still down: contacts resting (live, still, landed `lead` before the
// latest live one), the latest moving — what agSweepBy would read on its lift. For the
// main pad's claim, judged as the thumb lands. The resting count, else 0.
static int auxgestSweepResting(const AuxGest *g) {
    if (!g->noThumb || g->n < 2 || g->n > 5) return 0;
    int last = -1;
    for (int i = 0; i < g->n; i++) {
        if (!g->t[i].live) return 0;
        if (last < 0 || g->t[i].t0 > g->t[last].t0) last = i;
    }
    for (int i = 0; i < g->n; i++)
        if (i != last && (g->t[i].move >= agRs(g)->still || g->t[last].t0 - g->t[i].t0 < agRs(g)->lead)) return 0;
    return g->n - 1;
}

static void agDecide(AuxGest *g) {
    char name[32] = "", detail[160] = "";
    AgTrack t[AG_MAX]; int k = g->n;
    for (int i = 0; i < k; i++) t[i] = g->t[i];
    g->deadline = 0;
    if (!k) return;
    {   // only resting contacts (a sweep's fingers), lifted: they did nothing
        bool rest = true;
        for (int i = 0; i < k; i++) rest &= t[i].rest;
        if (rest) { g->n = 0; return; }
    }
    // The thumb's sweep by resting fingers, everything lifting together (the latest down).
    if (k >= 2 && k <= 5) {
        int last = 0;
        for (int i = 1; i < k; i++) if (t[i].t0 > t[last].t0) last = i;
        bool tap, mv[AG_MAX];
        int r = g->restSecs ? agRestOf(g, t, k, true, mv, name, sizeof name) : agSweepOf(g, t, k, last, true, &tap);
        if (r) {
            g->n = 0;
            if (g->restSecs) snprintf(detail, sizeof detail, "by %d resting (all lifted)", r);
            else {
                agSweepName(name, sizeof name, &t[last], r, tap);
                snprintf(detail, sizeof detail, "thumb by %d resting (all lifted) · travel %.3f", r, fabsf(t[last].x - t[last].x0));
            }
            if (g->emit) g->emit(name, AG_TAP, 0, detail, g->ctx);
            return;
        }
    }
    int ri = agRester(g, t, k);
    if (ri >= 0 && agInPinch(t, k, ri)) ri = -1;   // the thumb pinching with them, not resting
    if (ri >= 0) {
        AgTrack rt = t[ri]; rt.rest = true;
        for (int i = ri; i < k - 1; i++) t[i] = t[i + 1];
        k--;
        g->n = 0;
        if (rt.live) { g->t[0] = rt; g->n = 1; }
        qsort(t, k, sizeof *t, agByT0);
        AgRoll rr = *agR(g);   // rolls by a resting thumb: its own gap, when learnt
        if (agRs(g)->gap > 0) rr.gap = agRs(g)->gap;
        agName(t, k, NULL, &rr, agRs(g), name, sizeof name, detail, sizeof detail);
        // Thumb down, 1–4 fingers swiping up / down / left / right or tapping: their own
        // gestures (thumbup<n> / thumbdown<n>, thumbtap<n> 2026-10-18; thumbleft<n> /
        // thumbright<n> 2026-10-19, the thumb still). Not thumb-shaped, four tapping by the
        // resting contact = tap5. RESTING SECTIONS (restSecs, 2026-10-21): the thumb resting
        // is a section of its own — "restthumb:up<n>" … (remapd <hand>_rest_thumb).
        // 2–4 fingers pinching / spreading by the resting thumb: "restthumb:pinch<n>" /
        // "restthumb:spread<n>" — only where bound (unbound, read as before). 2026-10-21.
        int sn = 0;
        char sp[16], tsp[32];
        if (g->restSecs && g->wants && k >= 2 && k <= 4 && agThumbish(g, &rt) && agSpread(t, k, sp, sizeof sp)
            && (snprintf(tsp, sizeof tsp, "restthumb:%s", sp), g->wants(tsp, g->ctx))) {
            strlcpy(name, tsp, sizeof name);
        } else if ((sscanf(name, "up%d", &sn) == 1 || sscanf(name, "down%d", &sn) == 1 || sscanf(name, "tap%d", &sn) == 1
             || sscanf(name, "left%d", &sn) == 1 || sscanf(name, "right%d", &sn) == 1)
            && sn >= 1 && sn <= 4 && !strchr(name, '+') && agThumbish(g, &rt)) {
            char tn[32]; snprintf(tn, sizeof tn, g->restSecs ? "restthumb:%s" : "thumb%s", name); strlcpy(name, tn, sizeof name);
        } else if ((!strcmp(name, "rollL2") || !strcmp(name, "rollL3")) && agThumbish(g, &rt)) {   // 2–3 rolling right → left by it (2026-10-29)
            char tn[32]; snprintf(tn, sizeof tn, g->restSecs ? "restthumb:%s" : "thumb%s", name); strlcpy(name, tn, sizeof name);
        } else if (!strcmp(name, "tap4")) strcpy(name, "tap5");
        size_t at = strlen(detail);
        snprintf(detail + at, sizeof detail - at, " (+1 resting)");
        for (int i = 0; i < k; i++) agHistAdd(&g->hist, t[i].x0, t[i].y0, t[i].t1);
        if (g->emit) g->emit(name, AG_TAP, 0, detail, g->ctx);
        return;
    }
    // Only resting contacts left, lifted: they did nothing.
    bool allRest = true;
    for (int i = 0; i < k; i++) if (!t[i].rest) allRest = false;
    if (allRest) { g->n = 0; return; }
    // The thumb with 1–3 fingers (bunching up as they go) is a thumb swipe, not a pinch.
    bool thumbSwipe = agHasGroup(g) && k <= 4 && agGroupThumb(g->print, t, k, NULL) >= 0;
    if (!thumbSwipe && agSpread(t, k, name, sizeof name)) {   // the whole hand, thumb and all
        g->n = 0; agDropThumb(g);
        agSpreadDetail(t, k, detail, sizeof detail);
        if (g->emit) g->emit(name, AG_TAP, 0, detail, g->ctx);
        return;
    }
    qsort(t, k, sizeof *t, agByT0);
    int ti = agThumbOf(g, t, k);
    // A "thumb" that lifted with 2+ fingers after travelling WITH them is one more
    // finger (a 4-finger swipe's low pinky read as left3+thumb, 2026-10-16) — unless its
    // shape says thumb: the thumb may swipe along with the fingers (the mirror layer).
    // (The group model already weighed exactly that: not second-guessed.)
    if (ti >= 0 && !t[ti].live && t[ti].id != g->thumbId && k >= 3 && !agHasGroup(g)
        && !(agHasPrint(g) && agTrackScore(g->print, &t[ti]) > 0)) {
        float fx = 0, fy = 0;
        for (int i = 0; i < k; i++) if (i != ti) { fx += (t[i].x - t[i].x0) / (k - 1); fy += (t[i].y - t[i].y0) / (k - 1); }
        float tx = t[ti].x - t[ti].x0, ty = t[ti].y - t[ti].y0, fl = hypotf(fx, fy);
        if (fl >= AG_SWIPE && (tx * fx + ty * fy) / fl >= fl * 0.5f) ti = -1;
    }
    AgTrack th = {0};
    if (ti >= 0) { th = t[ti]; for (int i = ti; i < k - 1; i++) t[i] = t[i + 1]; k--; }
    int flags = 0;
    bool used = g->thumbUsed;   // read before agDropThumb clears it
    if (ti >= 0 && th.live) {
        // Still down: HELD for this gesture, and it stays in the group for the next.
        flags = AG_THUMB_HELD;
        agSetThumb(g, th.id);
        g->thumbUsed = true;
        g->t[0] = th; g->n = 1;
    } else {
        g->n = 0;
        if (ti >= 0 && th.id == g->thumbId) agDropThumb(g);
    }
    if (!k) {   // the thumb alone, lifted
        float dx = th.x - th.x0, dy = th.y - th.y0;
        if (fabsf(dx) >= AG_SWIPE && fabsf(dx) > fabsf(dy)) snprintf(name, sizeof name, "thumbswipe%s", dx < 0 ? "L" : "R");
        else if (!used && th.move <= AG_TAP_MOVE && th.t1 - th.t0 <= AG_THUMBTAP_S && agLand(&th) >= AG_TAP_LAND) snprintf(name, sizeof name, "thumbtap");
        else return;   // a thumb that rested and left: no gesture
    } else if (ti < 0 && k == 1 && agLoneThumb(g, &t[0])
               && fabsf(t[0].x - t[0].x0) >= AG_SWIPE
               && fabsf(t[0].x - t[0].x0) > fabsf(t[0].y - t[0].y0)) {
        snprintf(name, sizeof name, "thumbswipe%s", t[0].x < t[0].x0 ? "L" : "R");   // a lone sideways swipe (the thumb by shape / place)
    } else if (ti < 0 && k == 1 && agLoneThumb(g, &t[0])
               && t[0].move <= AG_TAP_MOVE && t[0].t1 - t[0].t0 <= AG_THUMBTAP_S) {
        if (agLand(&t[0]) < AG_TAP_LAND) return;     // laid down, not tapped
        snprintf(name, sizeof name, "thumbtap");     // a lone thumb tap
    } else {
        agName(t, k, ti >= 0 && !th.live ? &th : NULL, agR(g), NULL, name, sizeof name, detail, sizeof detail);
        for (int i = 0; i < k; i++) agHistAdd(&g->hist, t[i].x0, t[i].y0, t[i].t1);   // fingers only
        int sn = 0; char dir[8];
        // Five contacts = the whole hand, the thumb always among them: never renamed
        // (left5 / right5 never fired before 2026-11-14).
        if (k >= 3 && k < 5 && sscanf(name, "%7[a-z]%d", dir, &sn) == 2 && sn == k && !strchr(name, '+')
            && (!strcmp(dir, "up") || !strcmp(dir, "down") || !strcmp(dir, "left") || !strcmp(dir, "right"))
            && agThumbAmong(g, t, k) >= 0) {
            size_t at = strlen(detail);
            snprintf(detail + at, sizeof detail - at, " (%s: a thumb among them, not %d fingers)", name, k);
            strcpy(name, "none");
        }
    }
    if (g->emit) g->emit(name, AG_TAP, flags, detail, g->ctx);
}

// Mid-swipe: every finger down, settled, no thumb, the hand clearly travelling one way
// (or spreading / pinching) — name it and, if g->early wants that name, emit it now.
static bool agEarly(AuxGest *g, double now) {
    int k = g->n;
    if (!g->early || k < AG_EARLY_MIN || g->thumbId >= 0) return false;
    double first = g->t[0].t0, last = g->t[0].t0;
    float dx = 0, dy = 0;
    const bool whole = k >= 5;   // the whole hand: the thumb is one of the five (2026-11-14)
    for (int i = 0; i < k; i++) {
        const AgTrack *t = &g->t[i];
        if (!t->live) return false;
        if (!whole && !agHasGroup(g) && agHasPrint(g) && t->frames >= 3 && agTrackScore(g->print, t) > 0) return false;   // a thumb by shape
        if (t->t0 < first) first = t->t0;
        if (t->t0 > last) last = t->t0;
        dx += (t->x - t->x0) / k; dy += (t->y - t->y0) / k;
    }
    if (last - first > AG_LAND_SPREAD || now - last < AG_EARLY_QUICK) return false;
    if (!whole && agHasGroup(g) && agGroupThumb(g->print, g->t, k, NULL) >= 0) return false;   // the thumb swiping along
    if (!whole && agThumbAmong(g, g->t, k) >= 0) return false;   // thumb + fingers: never a k-finger swipe
    if (auxgestSweepResting(g)) return false;          // fingers resting, the thumb sweeping by them
    char name[32] = "";
    if (!agSpread(g->t, k, name, sizeof name)) {
        bool vert = fabsf(dy) > fabsf(dx);
        float d = vert ? dy : dx, o = vert ? dx : dy;
        if (fabsf(d) < AG_EARLY_TRAVEL || fabsf(d) <= 1.5f * fabsf(o)) return false;
        if (fabsf(agReshape(g->t, k)) > AG_RESHAPE * hypotf(dx, dy)) return false;   // pinching / spreading
        // Every finger along (half the mean at least): not an orbit, a twist or a stray.
        for (int i = 0; i < k; i++)
            if ((vert ? g->t[i].y - g->t[i].y0 : g->t[i].x - g->t[i].x0) * (d > 0 ? 1 : -1) < fabsf(d) * 0.5f) return false;
        snprintf(name, sizeof name, "%s%d", vert ? (d > 0 ? "up" : "down") : (d > 0 ? "right" : "left"), k);
    }
    if (!g->early(name, g->ctx)) return false;
    if (now - last < AG_EARLY_SETTLE) {   // a finger may still join: wait only if that gesture is wanted
        char more[32];
        size_t at = strcspn(name, "0123456789");
        snprintf(more, sizeof more, "%.*s%d", (int)at, name, k + 1);
        if (g->early(more, g->ctx)) return false;
    }
    for (int i = 0; i < k; i++) agHistAdd(&g->hist, g->t[i].x0, g->t[i].y0, now);
    g->spent = true; g->deadline = 0;
    char det[224];
    int at = snprintf(det, sizeof det, "early reshape=%+.3f travel=%.3f landed=%.0fms at=%.0fms", agReshape(g->t, k), hypotf(dx, dy),
                      (last - first) * 1000, (now - first) * 1000);
    if (!strncmp(name, "pinch", 5) || !strncmp(name, "spread", 6)) {
        det[at++] = ' ';
        agSpreadDetail(g->t, k, det + at, sizeof det - at);
    }
    if (g->emit) g->emit(name, AG_TAP, 0, det, g->ctx);
    return true;
}

static void agHoldEnd(AuxGest *g) {
    if (!g->holding) return;
    g->holding = false;
    if (g->emit) g->emit(g->holdName, AG_UP, g->holdFlags, "", g->ctx);
}

// One frame. Returns the time auxgestTick should run at (0 = none pending).
static double auxgestFrame(AuxGest *g, const AgContact *c, int nc, double now) {
    bool was[AG_MAX];
    // A RE-TAP (2026-10-18): every finger already lifted, the gesture waiting out its merge
    // gap, and a finger lands again where one of them was — the next tap of a fast double
    // tap, not more of this one (it merged, and fast double taps never registered). Decide
    // this one first. A roll's next finger lands beside, not on, the last.
    if (g->deadline && g->n) {
        bool anyLive = false;
        for (int i = 0; i < g->n; i++) anyLive |= g->t[i].live;
        bool again = false;
        for (int i = 0; i < nc && !anyLive && !again; i++)
            for (int j = 0; j < g->n && !again; j++)
                again = hypotf(c[i].x - g->t[j].x0, c[i].y - g->t[j].y0) < AG_RETAP_DIST;
        // By a RESTING thumb (2026-10-18): the thumb is still down, so "every finger lifted"
        // never held and a tap repeated by the thumb merged with the last (1 finger twice =
        // rollL2, 4 twice = tap8). Any new contact, wherever it lands, is the next tap.
        if (!again && anyLive && agRester(g, g->t, g->n) >= 0)
            for (int i = 0; i < nc && !again; i++) {
                bool known = false;
                for (int j = 0; j < g->n; j++) known |= g->t[j].live && g->t[j].id == c[i].id;
                again = !known;
            }
        if (again) agDecide(g);
    }
    for (int i = 0; i < g->n; i++) { was[i] = g->t[i].live; g->t[i].live = false; }
    int landed = 0;
    for (int i = 0; i < nc; i++) {
        // Continue only a track that was down last frame: a reused id after a lift is a new finger.
        AgTrack *tr = NULL;
        for (int j = 0; j < g->n; j++) if (was[j] && g->t[j].id == c[i].id) tr = &g->t[j];
        if (!tr) {
            if (g->n >= AG_MAX) continue;
            tr = &g->t[g->n++];
            *tr = (AgTrack){ .id = c[i].id, .x0 = c[i].x, .y0 = c[i].y, .t0 = now };
            landed++;
        }
        if (!tr->frames) tr->sz0 = c[i].size;
        tr->szMax = fmaxf(tr->szMax, c[i].size);
        agSettleFrame(&tr->st, !tr->frames, c[i].x, c[i].y, c[i].major, c[i].minor, c[i].angle, c[i].size, now);
        tr->x = c[i].x; tr->y = c[i].y; tr->t1 = now; tr->live = true; tr->frames++;
        if (agShapeFrame(tr->frames, tr->move) && c[i].size >= tr->pkSize) {
            tr->pkSize = c[i].size; tr->pkMajor = c[i].major; tr->pkMinor = c[i].minor; tr->pkAngle = c[i].angle;
        }
        float m = hypotf(tr->x - tr->x0, tr->y - tr->y0);
        if (m > tr->move) tr->move = m;
    }
    int ti = g->thumbId >= 0 ? agFind(g, g->thumbId) : -1;
    bool thumbLive = ti >= 0 && g->t[ti].live;
    int fingers = 0, liveFingers = 0, lifted = 0;
    for (int i = 0; i < g->n; i++) {
        if (i == ti) continue;
        fingers++;
        if (g->t[i].live) liveFingers++;
        else if (was[i]) lifted++;
    }

    // A known thumb that lifted with no fingers pending: settle it (a swipe = thumbswipe).
    if (ti >= 0 && !thumbLive && !fingers) { agDecide(g); return 0; }

    // RESTING SECTIONS: the fingers moving by resting ones all lifted, those still down —
    // fire now (agRestOf); the resters stay, for the next.
    if (g->restSecs && !g->holding && !g->spent && lifted) {
        bool mv[AG_MAX];
        char nm[40], det[64];
        int r = agRestOf(g, g->t, g->n, false, mv, nm, sizeof nm);
        if (r) {
            int k = 0;
            for (int i = 0; i < g->n; i++) {
                if (mv[i]) continue;
                g->t[k] = g->t[i]; g->t[k++].rest = true;
            }
            snprintf(det, sizeof det, "by %d resting · %d moved", r, g->n - k);
            g->n = k;
            g->deadline = 0;
            if (g->emit) g->emit(nm, AG_TAP, 0, det, g->ctx);
            return 0;
        }
    }
    // The thumb swept by resting fingers and lifted: fire now (agSweepBy).
    if (!g->restSecs && !g->holding && !g->spent && lifted == 1)
        for (int i = 0; i < g->n; i++) {
            if (g->t[i].live || !was[i]) continue;
            bool tap;
            int r = agSweepBy(g, i, &tap);
            if (!r) break;
            AgTrack m = g->t[i];
            char nm[32], det[96];
            agSweepName(nm, sizeof nm, &m, r, tap);
            snprintf(det, sizeof det, "thumb by %d resting · shape %+.0f travel %.3f",
                     r, g->print && g->print->ok && m.pkSize > 0 ? agTrackScore(g->print, &m) : 0, fabsf(m.x - m.x0));
            for (int j = i; j < g->n - 1; j++) g->t[j] = g->t[j + 1];
            g->n--;
            for (int j = 0; j < g->n; j++) g->t[j].rest = true;
            g->deadline = 0;
            if (g->emit) g->emit(nm, AG_TAP, 0, det, g->ctx);
            return 0;
        }
    // A held key (or fingers already acted on) ends with the first lift and owns those
    // fingers until they are all off; the thumb stays.
    if (g->holding && lifted) { agHoldEnd(g); g->spent = true; }
    if (g->spent) {
        if (!liveFingers) {
            g->spent = false;
            int k = 0;
            for (int i = 0; i < g->n; i++) if (i == ti && thumbLive) g->t[k++] = g->t[i];
            g->n = k;
            if (!k && ti >= 0) agDropThumb(g);
        }
        return 0;
    }
    if (g->holding) return 0;

    // Fingers landing while a low contact already rests = that contact is the thumb, HELD.
    if (g->thumbId < 0 && landed && g->n >= 2) {
        int e = 0;
        for (int i = 1; i < g->n; i++) if (g->t[i].t0 < g->t[e].t0) e = i;
        bool held = g->t[e].live && g->t[e].move < AG_TAP_MOVE
                 && (agHasGroup(g) || agThumbApart(g, g->t, g->n, e));
        bool shaped = agHasGroup(g) ? agGroupThumb(g->print, g->t, g->n, NULL) == e
                    : agHasPrint(g) && g->t[e].frames >= 3 && agTrackScore(g->print, &g->t[e]) > 0;
        for (int i = 0; i < g->n && held; i++)
            if (i != e && (g->t[i].t0 - g->t[e].t0 < AG_THUMB_LEAD
                           || (!shaped && g->t[i].y0 - g->t[e].y0 < AG_THUMB_DROP))) held = false;
        if (held) agSetThumb(g, g->t[e].id);
    }
    // A lone, low, still contact held long enough is the thumb, HELD.
    bool thumbCandidate = g->thumbId < 0 && g->n == 1 && agLoneThumb(g, &g->t[0]);
    if (thumbCandidate && g->t[0].live && g->t[0].move < AG_TAP_MOVE
        && now - g->t[0].t0 >= AG_THUMB_HOLD_S) {
        agSetThumb(g, g->t[0].id);
        return 0;
    }
    ti = g->thumbId >= 0 ? agFind(g, g->thumbId) : -1;
    // Every finger down and still for AG_HOLD_S: a held key.
    bool resting = false;   // a resting contact (agRester) is never a held key
    for (int i = 0; i < g->n; i++) if (g->t[i].rest) resting = true;
    if (!thumbCandidate && !resting && fingers && liveFingers == fingers) {
        double lastLand = 0; float move = 0;
        AgTrack t[AG_MAX]; int k = 0;
        for (int i = 0; i < g->n; i++) {
            if (i == ti) continue;
            t[k++] = g->t[i];
            if (g->t[i].t0 > lastLand) lastLand = g->t[i].t0;
            if (g->t[i].move > move) move = g->t[i].move;
        }
        // Fingers that were laid down (slow landing) are resting, not pressing a key.
        // Nor is a lone thumb-shaped contact on a no-thumb pad: the thumb put down to tap by
        // (2026-10-18, calibration: a firm thumb resting 200 ms fired a held tap1 and ate the taps).
        bool loneThumb = g->noThumb && k == 1 && g->print && g->print->ok && t[0].frames >= 3
                      && t[0].pkSize > 0 && agTrackScore(g->print, &t[0]) > agRs(g)->shape;
        if (!loneThumb && move <= AG_TAP_MOVE && now - lastLand >= AG_HOLD_S && agLandMin(t, k) >= AG_TAP_LAND
            && !agRestArmed(g, k)) {
            int tj = ti >= 0 ? -1 : agThumbOf(g, t, k);   // a thumb resting WITH the fingers
            if (tj >= 0) { for (int i = tj; i < k - 1; i++) t[i] = t[i + 1]; k--; }
            snprintf(g->holdName, sizeof g->holdName, "tap%d%s", k, tj >= 0 ? "+thumb" : "");
            g->holdFlags = auxgestThumbDown(g) ? AG_THUMB_HELD : 0;
            if (g->holdFlags) g->thumbUsed = true;
            g->holding = true; g->deadline = 0;
            for (int i = 0; i < k; i++) agHistAdd(&g->hist, t[i].x0, t[i].y0, now);
            if (g->emit) g->emit(g->holdName, AG_DOWN, g->holdFlags, "", g->ctx);
            return 0;
        }
    }
    if (!thumbCandidate && fingers && liveFingers == fingers && agEarly(g, now)) return 0;
    if (fingers && (!liveFingers || agRester(g, g->t, g->n) >= 0)) { if (!g->deadline) g->deadline = now + AG_MERGE_S; }
    else g->deadline = 0;
    return g->deadline;
}

// Decide a pending gesture once its merge gap has passed.
static void auxgestTick(AuxGest *g, double now) {
    if (g->deadline && now >= g->deadline) agDecide(g);
}

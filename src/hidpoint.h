// hidpoint.h — where to post a mouse / scroll event at kCGHIDEventTap while the screen
// is zoomed (ui_zoom.sh § Screen zoom).
//
// The HID → session stage reads an HID-posted event's location as a point ON THE GLASS
// and maps it through the window server's zoom, which ui_zoom pins top-left: posted at
// (900,600) at ×1.5, it arrives — and puts the pointer — at (600,400). Measured
// 2026-10-29 (a listen tap at each stage). So every post at the pointer's own spot
// jumped it toward the top-left: reanchor's 3-finger orbit / pan / tap, remapd's pin
// kick and own cursor. CGWarpMouseCursorPosition, session-tap posts and the locations
// our session taps read are all plain global points and need nothing.
//
// hidPoint(global) → the point to post so the event lands at `global`. The zoom is the
// window server's own (CGSGetZoomParameters), cached 0.1 s. Only the zoomed display
// (the main one) maps; at ×1 it returns the point as it is.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <time.h>
#include <os/lock.h>

extern int _CGSDefaultConnection(void);
extern CGError CGSGetZoomParameters(int cid, CGPoint *center, double *scale, unsigned char *smooth);

// The zoom, re-read at most every 0.1 s (the query is ~60 µs; nav posts at 165 Hz):
// its scale and the visible rect's top-left on the main display `d`.
static inline void hidZoom(double *zz, double *x0, double *y0, CGRect *dd) {
    static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT;
    static uint64_t at = 0;
    static double z = 1, ox = 0, oy = 0;
    static CGRect d;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&lk);
    if (now - at > 100000000ull) {
        CGPoint c = { 0, 0 }; double s = 1; unsigned char sm = 0;
        if (CGSGetZoomParameters(_CGSDefaultConnection(), &c, &s, &sm) != kCGErrorSuccess) s = 1;
        d = CGDisplayBounds(CGMainDisplayID());
        z = s > 1.0001 ? s : 1;
        // The visible rect: `center` is its middle, clamped to the screen ({0,0} = top-left).
        double w = d.size.width / z, h = d.size.height / z;
        ox = fmin(fmax(c.x - w / 2, 0), d.size.width - w);
        oy = fmin(fmax(c.y - h / 2, 0), d.size.height - h);
        at = now;
    }
    *zz = z; *x0 = ox; *y0 = oy; *dd = d;
    os_unfair_lock_unlock(&lk);
}

static inline CGPoint hidPoint(CGPoint g) {
    double zz, x0, y0; CGRect dd;
    hidZoom(&zz, &x0, &y0, &dd);
    if (zz == 1 || !CGRectContainsPoint(dd, g)) return g;
    return CGPointMake(dd.origin.x + (g.x - dd.origin.x - x0) * zz, dd.origin.y + (g.y - dd.origin.y - y0) * zz);
}

// The part of display `r` on the glass (r itself unless it is the zoomed one).
static inline CGRect hidVisible(CGRect r) {
    double zz, x0, y0; CGRect dd;
    hidZoom(&zz, &x0, &y0, &dd);
    if (zz == 1 || !CGRectEqualToRect(r, dd)) return r;
    return CGRectMake(dd.origin.x + x0, dd.origin.y + y0, dd.size.width / zz, dd.size.height / zz);
}

// Set an event's location for an HID-tap post (CGEventCreateMouseEvent's point included).
static inline void hidPlace(CGEventRef e) { CGEventSetLocation(e, hidPoint(CGEventGetLocation(e))); }

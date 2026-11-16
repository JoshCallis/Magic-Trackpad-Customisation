// reanchor_pan — pan-mode variant of reanchor (3-finger trackpad → middle-button
// drag for CAD nav). Deployed binary: /Users/josh/Code/Scripts/reanchor_pan.
// Build (verified 2026-06-11):
//   clang -O2 -o reanchor_pan reanchor_pan.c -framework CoreFoundation \
//     -framework CoreGraphics -framework ApplicationServices \
//     -F/System/Library/PrivateFrameworks -framework MultitouchSupport
#include <CoreGraphics/CoreGraphics.h>
#include <stdatomic.h>
#include <stdio.h>
#include "hidpoint.h"

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
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);

static atomic_bool threeFinger = false;
static atomic_bool mmbEngaged  = false;  // MMB actually pressed — deferred to the first drag
                                         // frame so a 3-finger TAP never holds a button and
                                         // stays free for BetterTouchTool tap triggers
                                         // (mirrors reanchor.m; see its mmbEngaged comment)
static atomic_bool isSynthetic = false;

// Identify the CAD window (Fusion or SketchUp) directly under the pointer.
// Returns its owning pid (0 if the topmost window under the pointer isn't a CAD
// app), and sets *isFront to whether that app is the global frontmost (already
// active). One CGWindowList query, run ONLY at gesture start (the first 3-finger
// frame) — never on a timer, so it costs nothing when idle. Lets the 3-finger
// drag become a CAD pan over the viewport while passing straight through to a
// floater (Finder, etc.) on top, regardless of which app holds focus. The first
// call in a process is ~150ms cold; warmCAD() (at startup) pays that once.
static pid_t cadUnderCursor(bool *isFront) {
    if (isFront) *isFront = false;
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    CFArrayRef wins = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!wins) return 0;
    pid_t result = 0, frontPid = 0;
    bool haveFront = false;
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
        if (!haveFront) { frontPid = opid; haveFront = true; }   // first layer-0 = frontmost app
        CFDictionaryRef b = CFDictionaryGetValue(info, kCGWindowBounds);
        CGRect r;
        if (!b || !CGRectMakeWithDictionaryRepresentation(b, &r)) continue;
        if (!CGRectContainsPoint(r, p)) continue;     // not under the pointer
        CFStringRef owner = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (owner &&
            (CFStringCompare(owner, CFSTR("Fusion"),   0) == kCFCompareEqualTo ||
             CFStringCompare(owner, CFSTR("SketchUp"), 0) == kCFCompareEqualTo)) {
            result = opid;
            if (isFront) *isFront = (opid == frontPid);
        }
        break;                                         // topmost window at point decides
    }
    CFRelease(wins);
    return result;
}

// Prime the WindowServer query so the first real gesture doesn't pay the cold
// ~150ms first-call cost. Result discarded; once warm, every later call is
// sub-millisecond for the life of the process (measured, even across idle gaps).
static void warmCAD(void) { (void)cadUnderCursor(NULL); }

static void postMMB(CGEventType type, CGPoint pos, CGEventFlags flags) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef event = CGEventCreateMouseEvent(src, type, pos, kCGMouseButtonCenter);
    CGEventSetFlags(event, flags);
    if (type == kCGEventOtherMouseDown) {
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    }
    atomic_store(&isSynthetic, true);
    hidPlace(event); CGEventPost(kCGHIDEventTap, event);
    atomic_store(&isSynthetic, false);
    CFRelease(event);
    CFRelease(src);
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

// Drop an orbit-centre request at the cursor when a 3-finger CAD gesture ends, so
// Cursor Probe sets the orbit pivot under the pointer — exactly the lift-fire that
// fusion_dwell does when a one-finger drag releases. Only genuine 3-finger CAD
// gestures reach the call site (threeFinger latches solely on a 3-finger touchdown
// over the canvas), so a 2-finger gesture never triggers it. The probe applies its
// own guards and removes the file, so a write that doesn't land on geometry is harmless.
static void requestOrbitCenter(void) {
    CGEventRef ev = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(ev);
    CFRelease(ev);
    FILE *f = fopen("/tmp/fusion_orbit_center_request", "w");
    if (f) { fprintf(f, "%d,%d", (int)p.x, (int)p.y); fclose(f); }
    f = fopen("/tmp/fusion_dwell_fired", "w");   // legacy marker, mirrors fusion_dwell
    if (f) fclose(f);
}

static int touchCallback(int device, Finger *data, int nFingers, double timestamp, int frame) {
    if (nFingers == 3 && !atomic_load(&threeFinger)) {
        // Only hijack the drag into a CAD pan when the pointer is actually over a
        // CAD window. Over a floater on top (even with the CAD app focused) we stay
        // dormant, so the underlying 3-finger drag moves that window.
        if (!cadUnderCursor(NULL)) return 0;
        // MMB button-down deferred to the first drag frame (eventCallback): a tap
        // then presses nothing, so BTT tap triggers over the canvas keep working.
        atomic_store(&mmbEngaged, false);
        atomic_store(&threeFinger, true);
    } else if (nFingers >= 4 && atomic_load(&threeFinger)) {
        atomic_store(&threeFinger, false);
        if (atomic_load(&mmbEngaged)) endDrag();
        atomic_store(&mmbEngaged, false);
    } else if (nFingers == 0 && atomic_load(&threeFinger)) {
        bool navved = atomic_load(&mmbEngaged);       // did this gesture actually pan?
        atomic_store(&threeFinger, false);
        if (navved) endDrag();
        atomic_store(&mmbEngaged, false);
        if (navved) requestOrbitCenter();             // pivot under cursor — real drags only, taps stay inert
    }
    return 0;
}

static CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (atomic_load(&isSynthetic)) return event;

    if (atomic_load(&threeFinger)) {
        // Left events posted by another PROCESS (BetterTouchTool's tap-triggered
        // synthetic clicks — nonzero source pid) are not part of the gesture: pass
        // them through even inside the touch-lift lag window. Hardware/system
        // events (pid 0) are the gesture's own and get swallowed/converted.
        if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0)
            return event;
        if (type == kCGEventLeftMouseDown) return NULL;
        if (type == kCGEventLeftMouseUp) return NULL;
        if (type == kCGEventLeftMouseDragged) {
            // Always send drag without shift
            CGPoint pos = CGEventGetLocation(event);
            if (!atomic_load(&mmbEngaged)) {
                // First movement frame: press the MMB deferred at touchdown.
                atomic_store(&mmbEngaged, true);
                postMMB(kCGEventOtherMouseDown, pos, 0);
            }
            postMMB(kCGEventOtherMouseDragged, pos, 0);
            return NULL;
        }
    }

    return event;
}

int main(void) {
    MTDeviceRef dev = MTDeviceCreateDefault();
    MTRegisterContactFrameCallback(dev, touchCallback);
    MTDeviceStart(dev, 0);

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp);

    CFMachPortRef tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        eventCallback,
        NULL
    );
    if (!tap) return 1;

    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    warmCAD();   // absorb the one-time ~150ms cold-call cost before any gesture

    CFRunLoopRun();
    return 0;
}

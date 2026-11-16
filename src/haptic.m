/*
 * haptic — one tap on the trackpad's actuator.
 *
 * WHY IT EXISTS: the four/five-finger slot layer used to be BetterTouchTool's, and
 * every jump in it ended with BTT's "Perform Haptic Feedback on Trackpad". That tap
 * is how a key which types nothing says it did something, so the port of those
 * bindings to remapd (remap/bindings.json, situations finger4 / finger5) had to
 * bring it along. remapd's action vocabulary is "run a command", so the tap is a
 * command, and it fronts each of those bindings.
 *
 * NSHapticFeedbackManager IS the public API for this and it does NOT work here:
 * from a plain CLI it returns without error and actuates nothing (the alignment
 * performer wants an app with a window). The first version of this file used it
 * and was silently a no-op — which is the failure this comment exists to prevent
 * being repeated. MultitouchSupport's actuator is what BTT itself drives.
 *
 * WHY THE IOKIT SERVICE PATH AND NOT MTDeviceCreateDefault(): that call SEGFAULTS
 * in a bare tool. Matching AppleMultitouchDevice and taking the first device that
 * answers MTDeviceSupportsActuation is the same route bin/remapd.m already uses for
 * the contact count, and it is the one that works.
 *
 * Usage:  haptic [actuation-id]     default 15. 1-6, 15 and 16 are the ids the
 *                                   actuator accepts; they differ in strength.
 *
 * Silent and exit 0 on hardware with no actuator: this only ever accompanies an
 * action that already happened, and must never be the thing that fails.
 *
 * Build: bin/build.sh haptic
 */
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

// MultitouchSupport is dlopen'd in the tapping child, not linked: loading it is
// most of this tool's start-up, and the caller must not wait for that.
typedef void *MTDeviceRef, *MTActuatorRef;
static MTDeviceRef   (*MTDeviceCreateFromService)(io_service_t);
static int           (*MTDeviceSupportsActuation)(MTDeviceRef);
static MTActuatorRef (*MTDeviceGetMTActuator)(MTDeviceRef);
static IOReturn      (*MTDeviceGetDeviceID)(MTDeviceRef, uint64_t *);
static MTActuatorRef (*MTActuatorCreateFromDeviceID)(uint64_t);
static IOReturn      (*MTActuatorOpen)(MTActuatorRef);
static IOReturn      (*MTActuatorClose)(MTActuatorRef);
static IOReturn      (*MTActuatorActuate)(MTActuatorRef, int32_t, uint32_t, float, float);

static int load_mt(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!h) return 0;
#define SYM(n) if (!(*(void **)&n = dlsym(h, #n))) return 0
    SYM(MTDeviceCreateFromService); SYM(MTDeviceSupportsActuation); SYM(MTDeviceGetMTActuator);
    SYM(MTDeviceGetDeviceID); SYM(MTActuatorCreateFromDeviceID); SYM(MTActuatorOpen);
    SYM(MTActuatorClose); SYM(MTActuatorActuate);
#undef SYM
    return 1;
}

int main(int argc, char **argv) {
    // Return at once and tap from a detached child. Every slot binding runs
    // `haptic; <jump>`, and finding + opening the actuator takes 120–250ms — the
    // jump used to wait for the tap (2026-10-10: measured as most of a hotkey's
    // latency). The child's stdio goes to /dev/null so nothing reading the
    // caller's output waits on it either.
    pid_t pid = fork();
    if (pid > 0) return 0;          // parent: done; the child taps
    if (pid == 0) {
        setsid();
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) { dup2(dn, 0); dup2(dn, 1); dup2(dn, 2); if (dn > 2) close(dn); }
    }                               // fork failed (-1): just tap inline
    int32_t aid = (argc > 1) ? (int32_t)atoi(argv[1]) : 15;
    if (!load_mt()) return 0;

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("AppleMultitouchDevice"), &it) != KERN_SUCCESS)
        return 0;

    MTDeviceRef dev = NULL;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        MTDeviceRef d = MTDeviceCreateFromService(s);
        IOObjectRelease(s);
        if (d && MTDeviceSupportsActuation(d)) { dev = d; break; }
    }
    IOObjectRelease(it);
    if (!dev) return 0;

    MTActuatorRef act = MTDeviceGetMTActuator(dev);
    if (!act) {
        uint64_t did = 0;
        MTDeviceGetDeviceID(dev, &did);
        if (did) act = MTActuatorCreateFromDeviceID(did);
    }
    if (!act) return 0;

    MTActuatorOpen(act);
    MTActuatorActuate(act, aid, 0, 0.0f, 0.0f);
    MTActuatorClose(act);
    return 0;
}

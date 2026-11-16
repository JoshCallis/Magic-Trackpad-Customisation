/*
 * navwords.h — the two shared words remapd and reanchor talk through (2026-10-18).
 * Each is 8 bytes in a /tmp file, mmap'd by both sides; this header is the whole
 * protocol, so neither side spells a bit by hand.
 *
 *   NAV_PIN_FILE   reanchor writes, remapd reads. While reanchor's Fusion / Max orbit,
 *                  pan or zoom owns the touch, remapd's thumb pin is where reanchor says,
 *                  or none.  0 = not reanchor's; bit 63 = its; bit 62 = pinned at x
 *                  (bits 0–23), y (24–47), each + 0x100000.
 *   CLAIM_FILE     remapd writes, reanchor reads. The touch's state is a swipe bound in
 *                  Control Room: nothing of reanchor's moves the camera. bit 63 = claimed,
 *                  low 48 bits = when (ms, CLOCK_UPTIME_RAW); older than a minute = stale
 *                  (remapd died holding it).
 */
#pragma once
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <CoreGraphics/CoreGraphics.h>

#define NAV_PIN_FILE   "/tmp/reanchor_pin"
#define CLAIM_FILE     "/tmp/remapd_claim"
#define CLAIM_STALE_MS 60000.0

// The word in PATH, created at 8 bytes if missing; NULL if it can't be mapped.
static inline _Atomic uint64_t *navword_map(const char *path, bool writable) {
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size < 8) ftruncate(fd, 8);
    void *m = mmap(NULL, 8, writable ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return m == MAP_FAILED ? NULL : (_Atomic uint64_t *)m;
}

static inline uint64_t navword_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000ull; }

// ── the pin word ──
static inline uint64_t pinword_make(bool ours, bool pin, CGPoint at) {
    if (!ours) return 0;
    uint64_t w = 1ull << 63;
    if (pin) w |= 1ull << 62
                | ((uint64_t)((int64_t)lround(at.x) + 0x100000) & 0xFFFFFF)
                | (((uint64_t)((int64_t)lround(at.y) + 0x100000) & 0xFFFFFF) << 24);
    return w;
}
static inline bool pinword_ours(uint64_t w)   { return w >> 63; }
static inline bool pinword_pinned(uint64_t w) { return (w >> 62) & 1; }
static inline CGPoint pinword_at(uint64_t w) {
    return CGPointMake((double)(int64_t)(w & 0xFFFFFF) - 0x100000,
                       (double)(int64_t)((w >> 24) & 0xFFFFFF) - 0x100000);
}

// ── the claim word ──
static inline uint64_t claimword_make(bool on) {
    return on ? (1ull << 63) | (navword_ms() & 0xFFFFFFFFFFFFull) : 0;
}
static inline bool claimword_live(uint64_t w) {
    return (w >> 63) && (double)navword_ms() - (double)(w & 0xFFFFFFFFFFFFull) < CLAIM_STALE_MS;
}

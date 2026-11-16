/* auxpad.h — which trackpad is the AUXILIARY one (shared by remapd and reanchor).

   The aux pad never drives the pointer: it is a gesture keyboard (bin/auxgest.h →
   keys per remap/auxpad.json, resting thumb = Space held), remapd drops its
   pointer/click/scroll events, and reanchor ignores it for nav. The other pad(s)
   stay the mouse and keep the `fingers` axis.

   Chosen by `aux_trackpad` in config/settings.json:
     "builtin"   the MacBook's own trackpad (the test setup, 2026-10-16)
     "<id>"      a device id, as logged at bind time ("trackpad bound: id=…") —
                 how a second Magic Trackpad gets picked
     absent / "" / "none"  no aux pad: every pad behaves as before

   Read once per bind (each pad arrival), so an edit takes effect on the next
   restart or reconnect. Include after <Foundation/Foundation.h>; needs
   MultitouchSupport linked and MTDeviceRef declared. */
#pragma once

bool MTDeviceIsBuiltIn(MTDeviceRef);
int  MTDeviceGetDeviceID(MTDeviceRef, uint64_t *);

#define AUXPAD_SETTINGS "/Users/josh/Code/Scripts/config/settings.json"

static NSString *auxpadSetting(void) {
    NSData *d = [NSData dataWithContentsOfFile:@AUXPAD_SETTINGS];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    id v = [j isKindOfClass:NSDictionary.class] ? j[@"aux_trackpad"] : nil;
    if ([v isKindOfClass:NSNumber.class]) v = [v stringValue];
    if (![v isKindOfClass:NSString.class] || ![v length] || [v isEqualToString:@"none"]) return nil;
    return v;
}

static uint64_t auxpadID(MTDeviceRef dev) {
    uint64_t id = 0;
    MTDeviceGetDeviceID(dev, &id);
    return id;
}

// Is this freshly bound device the aux pad? Logs every bind with its id + verdict.
static bool auxpadClassify(MTDeviceRef dev, const char *who) {
    NSString *want = auxpadSetting();
    bool builtin = MTDeviceIsBuiltIn(dev);
    uint64_t id = auxpadID(dev);
    bool aux = want && ([want isEqualToString:@"builtin"] ? builtin
                        : [want isEqualToString:[NSString stringWithFormat:@"%llu", id]]);
    fprintf(stderr, "%s: trackpad bound: id=%llu builtin=%d → %s\n", who,
            (unsigned long long)id, builtin, aux ? "AUX (no pointer)" : "main");
    fflush(stderr);
    return aux;
}

// cp2077-padfix
//
// Cyberpunk on macOS only hears a controller through GCController callbacks, and
// it stops draining the main queue while it renders, so those callbacks pile up
// until you quit. Real Xbox pads are fixed by pointing handlerQueue at a private
// queue.
//
// The 8BitDo Ultimate C 2.4G dongle in D-input mode (hold B + Home) is a plain
// HID gamepad. macOS has no GameController profile for it, so the settings pane
// stays hidden and the game never sees a GCController. This file also reads that
// HID device and presents it as an Xbox-style GCController inside the game.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <string.h>

static dispatch_queue_t g_hq;
static NSString *pf_xbox_category(void);

#pragma mark - stand-in controller

@interface PFButton : GCControllerButtonInput
@property (nonatomic) float fakeValue;
@property (nonatomic) BOOL fakePressed;
@property (nonatomic, weak) GCController *owner;
@end
@implementation PFButton
- (float)value { return _fakeValue; }
- (BOOL)isPressed { return _fakePressed; }
- (GCController *)controller { return _owner; }
@end

@interface PFAxis : GCControllerAxisInput
@property (nonatomic) float fakeValue;
@property (nonatomic, weak) GCController *owner;
@end
@implementation PFAxis
- (float)value { return _fakeValue; }
- (GCController *)controller { return _owner; }
@end

@interface PFPad : GCControllerDirectionPad
@property (nonatomic, strong) PFAxis *fx;
@property (nonatomic, strong) PFAxis *fy;
@property (nonatomic, strong) PFButton *fup, *fdown, *fleft, *fright;
@property (nonatomic, weak) GCController *owner;
@end
@implementation PFPad
- (GCControllerAxisInput *)xAxis { return _fx; }
- (GCControllerAxisInput *)yAxis { return _fy; }
- (GCControllerButtonInput *)up { return _fup; }
- (GCControllerButtonInput *)down { return _fdown; }
- (GCControllerButtonInput *)left { return _fleft; }
- (GCControllerButtonInput *)right { return _fright; }
- (GCController *)controller { return _owner; }
@end

@interface PFExt : GCExtendedGamepad
@property (nonatomic, strong) PFButton *a, *b, *x, *y, *lb, *rb, *lt, *rt;
@property (nonatomic, strong) PFButton *menu, *opt, *home, *ls, *rs;
@property (nonatomic, strong) PFPad *dp, *lefts, *rights;
@property (nonatomic, weak) GCController *owner;
@end
@implementation PFExt
- (GCController *)controller { return _owner; }
- (GCControllerButtonInput *)buttonA { return _a; }
- (GCControllerButtonInput *)buttonB { return _b; }
- (GCControllerButtonInput *)buttonX { return _x; }
- (GCControllerButtonInput *)buttonY { return _y; }
- (GCControllerButtonInput *)leftShoulder { return _lb; }
- (GCControllerButtonInput *)rightShoulder { return _rb; }
- (GCControllerButtonInput *)leftTrigger { return _lt; }
- (GCControllerButtonInput *)rightTrigger { return _rt; }
- (GCControllerButtonInput *)buttonMenu { return _menu; }
- (GCControllerButtonInput *)buttonOptions { return _opt; }
- (GCControllerButtonInput *)buttonHome { return _home; }
- (GCControllerButtonInput *)leftThumbstickButton { return _ls; }
- (GCControllerButtonInput *)rightThumbstickButton { return _rs; }
- (GCControllerDirectionPad *)dpad { return _dp; }
- (GCControllerDirectionPad *)leftThumbstick { return _lefts; }
- (GCControllerDirectionPad *)rightThumbstick { return _rights; }
@end

@interface PFController : GCController
@property (nonatomic, strong) PFExt *ext;
@end
@implementation PFController
- (GCExtendedGamepad *)extendedGamepad { return _ext; }
- (NSString *)vendorName { return @"8BitDo"; }
- (NSString *)productCategory { return pf_xbox_category(); }
@end

static PFController *g_pad;

static PFButton *pf_button(PFController *owner) {
    PFButton *b = [PFButton new];
    b.owner = owner;
    return b;
}

static PFPad *pf_pad(PFController *owner) {
    PFPad *p = [PFPad new];
    p.owner = owner;
    p.fx = [PFAxis new];
    p.fy = [PFAxis new];
    p.fx.owner = owner;
    p.fy.owner = owner;
    p.fup = pf_button(owner);
    p.fdown = pf_button(owner);
    p.fleft = pf_button(owner);
    p.fright = pf_button(owner);
    return p;
}

static PFController *pf_make(void) {
    PFController *c = [PFController new];
    PFExt *e = [PFExt new];
    e.owner = c;
    e.a = pf_button(c);
    e.b = pf_button(c);
    e.x = pf_button(c);
    e.y = pf_button(c);
    e.lb = pf_button(c);
    e.rb = pf_button(c);
    e.lt = pf_button(c);
    e.rt = pf_button(c);
    e.menu = pf_button(c);
    e.opt = pf_button(c);
    e.home = pf_button(c);
    e.ls = pf_button(c);
    e.rs = pf_button(c);
    e.dp = pf_pad(c);
    e.lefts = pf_pad(c);
    e.rights = pf_pad(c);
    c.ext = e;
    c.handlerQueue = g_hq;
    return c;
}

static void pf_fire_button(PFButton *b, float value) {
    BOOL pressed = value > 0.12f;
    if (fabsf(b.fakeValue - value) < 0.008f && b.fakePressed == pressed) return;
    b.fakeValue = value;
    b.fakePressed = pressed;
    GCControllerButtonValueChangedHandler h = b.valueChangedHandler;
    if (h) h(b, value, pressed);
}

static void pf_fire_pad(PFPad *p, float x, float y) {
    BOOL moved = fabsf(p.fx.fakeValue - x) > 0.01f || fabsf(p.fy.fakeValue - y) > 0.01f;
    p.fx.fakeValue = x;
    p.fy.fakeValue = y;
    pf_fire_button(p.fup, y > 0.5f ? 1.f : 0.f);
    pf_fire_button(p.fdown, y < -0.5f ? 1.f : 0.f);
    pf_fire_button(p.fright, x > 0.5f ? 1.f : 0.f);
    pf_fire_button(p.fleft, x < -0.5f ? 1.f : 0.f);
    if (!moved) return;
    GCControllerDirectionPadValueChangedHandler h = p.valueChangedHandler;
    if (h) h(p, x, y);
    GCExtendedGamepadValueChangedHandler gh = p.owner.extendedGamepad.valueChangedHandler;
    if (gh) gh(p.owner.extendedGamepad, p);
}

// HID absolute axis 0..255, 128 at rest. GameController's Y is positive upward.
static float pf_axis(CFIndex raw, BOOL invertY) {
    float n = ((float)raw - 128.f) / 127.f;
    if (invertY) n = -n;
    if (n > 1.f) n = 1.f;
    if (n < -1.f) n = -1.f;
    if (fabsf(n) < 0.12f) n = 0.f;
    return n;
}

static float pf_trigger(CFIndex raw) {
    float n = (float)raw / 255.f;
    if (n < 0.04f) n = 0.f;
    if (n > 1.f) n = 1.f;
    return n;
}

// 8BitDo D-input, same layout as the Ultimate Wireless map:
// buttons 1=A 2=B 4=X 5=Y 7=LB 8=RB 11=Back 12=Start 13=Guide 14=L3 15=R3
// axes X/Y left, Z/Rz right, simulation brake/accelerator = LT/RT.
static void pf_apply(uint32_t page, uint32_t usage, CFIndex raw) {
    PFExt *e = g_pad.ext;
    if (!e) return;
    if (page == 0x09) {
        float v = raw ? 1.f : 0.f;
        switch (usage) {
            case 1: pf_fire_button(e.a, v); break;
            case 2: pf_fire_button(e.b, v); break;
            case 4: pf_fire_button(e.x, v); break;
            case 5: pf_fire_button(e.y, v); break;
            case 7: pf_fire_button(e.lb, v); break;
            case 8: pf_fire_button(e.rb, v); break;
            case 11: pf_fire_button(e.opt, v); break;
            case 12: pf_fire_button(e.menu, v); break;
            case 13: pf_fire_button(e.home, v); break;
            case 14: pf_fire_button(e.ls, v); break;
            case 15: pf_fire_button(e.rs, v); break;
            default: break;
        }
        return;
    }
    if (page == 0x01 && usage == 0x39) {
        float x = 0, y = 0;
        switch (raw) {
            case 0: y = 1; break;
            case 1: y = 1; x = 1; break;
            case 2: x = 1; break;
            case 3: y = -1; x = 1; break;
            case 4: y = -1; break;
            case 5: y = -1; x = -1; break;
            case 6: x = -1; break;
            case 7: y = 1; x = -1; break;
            default: break;
        }
        pf_fire_pad(e.dp, x, y);
        return;
    }
    if (page == 0x01) {
        switch (usage) {
            case 0x30: pf_fire_pad(e.lefts, pf_axis(raw, NO), e.lefts.fy.fakeValue); break;
            case 0x31: pf_fire_pad(e.lefts, e.lefts.fx.fakeValue, pf_axis(raw, YES)); break;
            case 0x32: pf_fire_pad(e.rights, pf_axis(raw, NO), e.rights.fy.fakeValue); break;
            case 0x35: pf_fire_pad(e.rights, e.rights.fx.fakeValue, pf_axis(raw, YES)); break;
            default: break;
        }
        return;
    }
    if (page == 0x02) {
        if (usage == 0xC5) pf_fire_button(e.lt, pf_trigger(raw));
        else if (usage == 0xC4) pf_fire_button(e.rt, pf_trigger(raw));
    }
}

static BOOL g_game_listening;
static BOOL g_delivered;

// assignControllerToPlayers writes a type code through player-slot 0. That
// pointer is still null during startup, and the write is the crash at address
// 0x30. Build 5314028's getter is these three instructions; the adrp target is
// the slot array in __bss. A fixed offset from the mach header missed at
// runtime, the 15s fallback then announced anyway, and the game crashed again.
static const uint32_t kSlotGetter[] = { 0xb002fc60, 0x91088000, 0xd65f03c0 };

// 0 = not looked up, 1 = slots found, 2 = not the game, 3 = game, getter missing
static int g_slot_mode;
static void **g_slots;

static void **pf_decode_slots(const uint32_t *ins) {
    uint32_t adrp = ins[0];
    int64_t immlo = (adrp >> 29) & 3;
    int64_t immhi = (adrp >> 5) & 0x7ffff;
    int64_t imm = (immhi << 2) | immlo;
    if (imm & (1LL << 20)) imm -= (1LL << 21);
    uintptr_t page = ((uintptr_t)ins & ~(uintptr_t)0xfff) + ((uint64_t)imm << 12);
    uint32_t add = ins[1];
    uintptr_t imm12 = (add >> 10) & 0xfff;
    if ((add >> 22) & 1) imm12 <<= 12;
    return (void **)(page + imm12);
}

static void pf_locate_slots(void) {
    if (g_slot_mode) return;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "Cyberpunk2077")) continue;
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) {
            g_slot_mode = 3;
            return;
        }
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cmd = (const uint8_t *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmd;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                const struct section_64 *sec = (const struct section_64 *)(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
                    if (strncmp(sec->sectname, "__text", 16) != 0) continue;
                    const uint32_t *p = (const uint32_t *)(sec->addr + slide);
                    size_t words = sec->size / 4;
                    for (size_t w = 0; w + 2 < words; w++) {
                        if (p[w] != kSlotGetter[0] || p[w + 1] != kSlotGetter[1] || p[w + 2] != kSlotGetter[2])
                            continue;
                        g_slots = pf_decode_slots(p + w);
                        g_slot_mode = 1;
                        fprintf(stderr, "cp2077-padfix: player slots at %p\n", (void *)g_slots);
                        return;
                    }
                }
            }
            cmd += lc->cmdsize;
        }
        g_slot_mode = 3;
        fprintf(stderr, "cp2077-padfix: player-slot getter not in %s (slide %ld)\n", name, (long)slide);
        return;
    }
    g_slot_mode = 2;
}

static BOOL pf_slots_ready(void) {
    pf_locate_slots();
    if (g_slot_mode == 2) return YES;
    if (g_slot_mode != 1 || !g_slots) return NO;
    return g_slots[0] != NULL;
}

static NSString *pf_xbox_category(void) {
    // Reporting Xbox One is what makes the game write into the player slot.
    // Until that slot exists, any other category takes the path that does not.
    return pf_slots_ready() ? GCProductCategoryXboxOne : @"8BitDo";
}

static void pf_try_deliver(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ pf_try_deliver(); });
        return;
    }
    if (g_delivered || !g_pad || !g_game_listening || !pf_slots_ready()) return;
    g_delivered = YES;
    fprintf(stderr, "cp2077-padfix: 8BitDo D-input bridged as an Xbox controller\n");
    [[NSNotificationCenter defaultCenter]
        postNotificationName:GCControllerDidConnectNotification
                      object:g_pad];
}

static void pf_arm_deliver(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        pf_try_deliver();
        if (!g_delivered) pf_arm_deliver();
    });
}

static void pf_publish(void) {
    if (g_pad) return;
    g_pad = pf_make();
    pf_try_deliver();
}

#pragma mark - HID

static void pf_value(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)ctx; (void)result; (void)sender;
    if (!g_pad) return;
    IOHIDElementRef el = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(el);
    uint32_t usage = IOHIDElementGetUsage(el);
    CFIndex raw = IOHIDValueGetIntegerValue(value);
    dispatch_async(g_hq, ^{
        pf_apply(page, usage, raw);
    });
}

static void pf_matched(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)result; (void)sender;
    pf_publish();
    NSArray *els = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone));
    for (id obj in els) {
        IOHIDElementRef el = (__bridge IOHIDElementRef)obj;
        IOHIDValueRef val = NULL;
        if (IOHIDDeviceGetValue(dev, el, &val) != kIOReturnSuccess || !val) continue;
        uint32_t page = IOHIDElementGetUsagePage(el);
        uint32_t usage = IOHIDElementGetUsage(el);
        CFIndex raw = IOHIDValueGetIntegerValue(val);
        dispatch_async(g_hq, ^{
            pf_apply(page, usage, raw);
        });
    }
}

static void *pf_hid_thread(void *arg) {
    (void)arg;
    @autoreleasepool {
        IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDManagerOptionNone);
        NSDictionary *match = @{
            @kIOHIDVendorIDKey: @0x2DC8,
            @kIOHIDPrimaryUsagePageKey: @0x01,
            @kIOHIDPrimaryUsageKey: @0x05,
        };
        IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)match);
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, pf_matched, NULL);
        IOHIDManagerRegisterInputValueCallback(mgr, pf_value, NULL);
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
        CFRunLoopRun();
    }
    return NULL;
}

#pragma mark - so the game can find the stand-in

static IMP g_origControllers;
static NSArray *pf_controllers(id self, SEL _cmd) {
    NSArray *found = ((NSArray *(*)(id, SEL))g_origControllers)(self, _cmd);
    if (!g_pad || !pf_slots_ready() || [found containsObject:g_pad]) return found;
    return [found arrayByAddingObject:g_pad];
}

static IMP g_origAddBlock;
static id pf_add_block(id self, SEL _cmd, NSNotificationName name, id obj, NSOperationQueue *queue,
                       void (^block)(NSNotification *)) {
    id token = ((id (*)(id, SEL, NSNotificationName, id, NSOperationQueue *,
                        void (^)(NSNotification *)))g_origAddBlock)(self, _cmd, name, obj, queue, block);
    if ([name isEqualToString:GCControllerDidConnectNotification]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_game_listening = YES;
            pf_try_deliver();
        });
    }
    return token;
}

static IMP g_origAddSel;
static void pf_add_sel(id self, SEL _cmd, id observer, SEL sel, NSNotificationName name, id obj) {
    ((void (*)(id, SEL, id, SEL, NSNotificationName, id))g_origAddSel)(self, _cmd, observer, sel, name, obj);
    if ([name isEqualToString:GCControllerDidConnectNotification]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // The game subscribes once, often before the slot objects exist.
            // If a framework observer already consumed the one announcement,
            // send it again now that this observer is registered.
            g_game_listening = YES;
            if (g_delivered) g_delivered = NO;
            pf_try_deliver();
        });
    }
}

static void pf_swizzle(void) {
    Method m = class_getClassMethod([GCController class], @selector(controllers));
    g_origControllers = method_getImplementation(m);
    method_setImplementation(m, (IMP)pf_controllers);

    Class nc = [NSNotificationCenter class];
    m = class_getInstanceMethod(nc, @selector(addObserverForName:object:queue:usingBlock:));
    g_origAddBlock = method_getImplementation(m);
    method_setImplementation(m, (IMP)pf_add_block);

    m = class_getInstanceMethod(nc, @selector(addObserver:selector:name:object:));
    g_origAddSel = method_getImplementation(m);
    method_setImplementation(m, (IMP)pf_add_sel);
}

#pragma mark - entry

__attribute__((constructor))
static void padfix_init(void) {
    g_hq = dispatch_queue_create("cp2077.padfix", DISPATCH_QUEUE_SERIAL);

    // Register before the swizzle, so this observer is not treated as the game's.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:GCControllerDidConnectNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        GCController *c = n.object;
        if (c) c.handlerQueue = g_hq;
    }];

    pf_swizzle();
    for (GCController *c in [GCController controllers]) c.handlerQueue = g_hq;
    pf_arm_deliver();

    pthread_t thread;
    pthread_create(&thread, NULL, pf_hid_thread, NULL);
    pthread_detach(thread);
}

// cp2077-padfix — makes the Xbox controller work in Cyberpunk 2077 on macOS.
//
// The game installs GameController valueChangedHandler blocks correctly, but it
// starves the main dispatch queue while it renders. GCController delivers those
// blocks on handlerQueue, which defaults to the main queue, so every button press
// sits in the queue until the game leaves its render loop.
//
// This forces handlerQueue to a private serial queue, so the blocks run at once.
// It changes no file in the game. Remove it by launching the game without
// DYLD_INSERT_LIBRARIES.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

static dispatch_queue_t g_hq;

__attribute__((constructor))
static void padfix_init(void) {
    g_hq = dispatch_queue_create("cp2077.padfix", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter]
        addObserverForName:GCControllerDidConnectNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        GCController *c = n.object;
        if (c) c.handlerQueue = g_hq;
    }];
    for (GCController *c in [GCController controllers]) c.handlerQueue = g_hq;
}

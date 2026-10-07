# Cyberpunk 2077 on macOS — controller fix

Fork of [SL33PiNg/cyberpunk2077-mac-controller-fix](https://github.com/SL33PiNg/cyberpunk2077-mac-controller-fix)
for **Apple silicon**. It keeps that fix for Xbox pads, and adds the **8BitDo Ultimate C 2.4G**
dongle, which macOS never shows as a game controller.

**Symptom:** the game shows the Xbox button glyphs, so it clearly sees your controller, and then
responds to no button. Keyboard and mouse work fine. On an 8BitDo Ultimate C in the wrong mode,
the game does not see the pad at all.

**Cause:** for a pad macOS already exposes, the input is not lost. Every press is queued on a
dispatch queue the engine stops draining the moment it enters its render loop, and all of it runs
at once when you quit. An 8BitDo Ultimate C never gets that far: macOS does not expose it as a
game controller, so the game has nothing to listen to.

**Fix:** twenty lines. It points `GCController.handlerQueue` at a queue that actually runs. It
changes no file in the game and does not touch your saves.

```sh
git clone https://github.com/FijshH/cyberpunk2077-mac-controller-fix
cd cyberpunk2077-mac-controller-fix
./build.sh
cp2077
```

Requires Xcode Command Line Tools (`xcode-select --install`). Apple silicon.

## 8BitDo Ultimate C 2.4G

This is the USB dongle, vendor `0x2DC8`, not the Bluetooth Ultimate 2C. macOS has no Game
Controller profile for it, so System Settings never shows a Game Controllers row and Cyberpunk
never receives a `GCController`. The original fix cannot help a pad the system does not announce.

Switch the dongle to **D-input** and leave it there. The mode is saved.

| Mode | How | Product | What macOS does |
|---|---|---|---|
| XInput | hold X + Home | `0x3106` | No HID driver. The game cannot see it. |
| D-input | hold B + Home | `0x3016` | A normal HID gamepad. This fork can read it. |

In D-input the library reads the pad with `IOHIDManager` and, inside the game process only,
presents a stand-in Xbox One controller. Resting state: hat usage `0x39` is `15` (neutral, not
up), sticks sit at `127`, triggers at `0`. Face buttons follow the usual 8BitDo D-input map
(1=A, 2=B, 4=X, 5=Y).

The stand-in is announced only after Cyberpunk has created its player slots. Announcing earlier
crashes `assignControllerToPlayers`. That wait matches 2.3.1 build `5314028`. On any other build
the pad stays hidden rather than crashing the game.

Rumble is not wired up. The game drives separate left and right motors, and this pad can take
that report, but the stand-in controller does not send it yet.

---

## The measurement

A dylib injected into the game process wraps every `valueChangedHandler` block and logs the
instant it actually executes. Both runs below are the same pad, the same session length, and the
same button presses.

| | events | first → last |
|---|---|---|
| stock game | 40 | 14:32:05.747 → 14:32:05.**750** |
| with the fix | 40 | 14:35:22.993 → 14:36:21.643 |

In the stock game every event lands inside a single **3 millisecond** window, 56 seconds after the
handlers were installed, at the moment the player chose Exit and the engine left its render loop.

```
14:31:09.309  SET  button handler on 'A Button'   block=0x16fc2ac18
14:31:09.309  SET  button handler on 'B Button'   block=0x16fc2abf0
              … 38 elements across 2 controllers …

              ▼ the player presses buttons for ~45 s. Nothing happens on screen.

14:32:05.747  FIRE button 'B Button' value=1.000 pressed=1   (#1)
14:32:05.749  FIRE button 'B Button' value=0.000 pressed=0   (#2)
14:32:05.750  FIRE button 'A Button' value=1.000 pressed=1   (#13)
14:32:05.750  FIRE button 'A Button' value=0.000 pressed=0   (#40)
```

The values are correct and the order is the real press order. Nothing was dropped by macOS — it
was only late by a minute. Raw logs for both runs are in [`evidence/`](evidence).

## Why it happens

The game installs a `valueChangedHandler` block on all 38 controller elements at load, which is
correct, and then calls `-[GCController extendedGamepad]` exactly ten times, all during load, and
never again. It does not poll element values. The callbacks are its only input path.

GameController delivers those blocks on `GCController.handlerQueue`, which defaults to the **main
dispatch queue**. The engine does not drain the main queue while it renders, so no handler block
runs during gameplay.

Keyboard and mouse are unaffected because the binary contains no reference to `GCKeyboard` or
`GCMouse` and reads them through AppKit — `NSEvent`, `addLocalMonitorForEventsMatchingMask:`,
`keyDown` — which the engine pumps itself, every frame. That is why a half-broken game feels like
a broken controller.

## The fix

```objc
static dispatch_queue_t g_hq;

__attribute__((constructor))
static void padfix_init(void) {
    g_hq = dispatch_queue_create("cp2077.padfix", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter]
        addObserverForName:GCControllerDidConnectNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        GCController *c = n.object;
        if (c) c.handlerQueue = g_hq;      // ← the whole fix
    }];
    for (GCController *c in [GCController controllers]) c.handlerQueue = g_hq;
}
```

Full source: [`src/cp2077-padfix.m`](src/cp2077-padfix.m). The same file is where the 8BitDo D-input
bridge lives.

It loads through `DYLD_INSERT_LIBRARIES`, which works because the game ships with
`com.apple.security.cs.allow-dyld-environment-variables` and
`com.apple.security.cs.disable-library-validation` in its entitlements.

## Launching

`build.sh` installs the dylib to `~/.local/lib` and a launcher to `~/.local/bin/cp2077`.

```sh
cp2077          # play
cp2077 --hud    # also enable Apple's Metal Performance HUD (FPS, frame time, GPU)
```

Steam on macOS treats the first Launch Options token as the program to run.
`DYLD_INSERT_LIBRARIES=... %command%` fails with OS Error 260, because that token is not a file.
Put the launcher that `build.sh` just installed in front of `%command%`. In Steam, right-click
Cyberpunk 2077 → Properties → General → Launch Options, and paste the path `./build.sh` printed.
It looks like this:

```
/Users/you/.local/bin/cp2077 %command%
```

Launching through Steam keeps playtime tracking, achievements, and Cloud saves working normally.

## Removing it

Launch the game normally. The fix lives entirely in an environment variable — clear the Launch
Options field and it is gone. Delete `~/.local/lib/cp2077-padfix.dylib` and
`~/.local/bin/cp2077` to remove it completely. Nothing in the game directory was ever modified,
so game updates neither break the fix nor undo it.

## Caveat

The handler blocks now run on a background thread instead of the main thread. That is a real
change in threading contract. It held up across full sessions here with no crash, but it is the
one risk worth naming. If you see instability, remove the fix and you are back to stock.

## Things that are *not* the cause

Every one of these is a fix circulating for this symptom. Each was rejected by a measurement.

| Hypothesis | Killed by |
|---|---|
| Faulty controller | 342 events, every element, to a normal frontmost macOS app |
| Bluetooth pairing | Encrypted link, 7.5 ms interval at every launch |
| Steam Input phantom pad | One controller for the whole session |
| Steam overlay stealing focus | Real, and fixed — symptom unchanged |
| Pad arrives after session activation | A working probe shows the same 28 ms gap |
| Empty event delivery policy | A working probe logs the same empty set |
| macOS gating old-SDK binaries | Probe restamped to SDK 15.2 received 78 events |
| Corrupt user settings | Reset to factory — symptom unchanged |
| Dead Steam input pipe | Fails identically on a direct launch |
| Game polls instead of using callbacks | Binary carries the value-changed block encodings |

## Tested on

macOS 26.6.2 (25G83), Apple silicon · Cyberpunk 2077 Ultimate 2.3.1 build 5314028, native arm64,
Steam appid 1091500 · Xbox Wireless Controller model 1914, over both Bluetooth LE and USB ·
8BitDo Ultimate C 2.4G dongle (`0x2DC8` / `0x3016`) in D-input.

## Upstream

The proper fix belongs in the engine: set `handlerQueue` explicitly to a queue the engine
services, or read element values in the frame loop instead of relying on block delivery. Reported
to CD PROJEKT RED. If this repo helped you, say so in the forum thread — a reproduction from a
second machine is worth more than a good report.

## Licence

MIT. This is an independent fix, forked from
[SL33PiNg/cyberpunk2077-mac-controller-fix](https://github.com/SL33PiNg/cyberpunk2077-mac-controller-fix).
It is not affiliated with or endorsed by CD PROJEKT RED, 8BitDo, or Apple.

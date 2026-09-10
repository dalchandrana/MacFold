# Mac Duo

**Your desktop follows your MacBook lid.** An open-source native macOS menu-bar app, written in Swift and Metal.

[Website](https://dhananjaybhosale.github.io/MacDuo/) · [How to build](#build) · [Attribution](ATTRIBUTION.md) · [MIT license](LICENSE)

## What it does

The default **Duo** effect expands and softly defocuses the desktop around the bottom hinge as you close the lid. The preview follows the same animation, and the desktop returns to normal when you open the lid or hold it still.

- Live HID lid-angle tracking on compatible MacBooks.
- A **1–5 second** clear-after timer, on by default at **2 seconds**.
- A compact floating control window with no internal scrolling.
- System, Light and Dark appearance, with an orange accent.
- Esc or Control–Option–Command–F to pause; menu-bar controls remain available.
- Up to 120 Hz requested rendering on supported displays while moving on external power. Battery and Low Power Mode cap rendering at 60 Hz; serious thermal pressure caps it at 30 Hz. These are scheduling limits, not a measured end-to-end FPS guarantee.
- Idle preview rendering stops, unchanged draws are skipped, and blur calculations are cached until source pixels change.

**Roll, Shutter, Flex and Iris are being developed.** They are not included in this initial public version (0.1.4).

## Requirements

- macOS 14 or newer and a Metal-capable MacBook exposing the HID lid-angle sensor.
- Xcode with Swift 6 to build.
- Screen Recording permission for the real desktop effect. Manual preview and Replay do not need it.
- An active, unmirrored built-in display. External displays are not animated.

Tested locally on an Apple M4 MacBook Pro. A chip name alone does not establish sensor compatibility. This is a personal desktop utility, not a notarized App Store release.

## Build

```sh
git clone https://github.com/DhananjayBhosale/MacDuo.git
cd MacDuo
./build.sh
open "build/Mac Duo.app"
```

The default build uses ad-hoc signing. For a stable Screen Recording identity across rebuilds, provide your own Apple Development certificate:

```sh
MACDUO_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
```

You can also store that identity in a local `signing-identity.txt`, which is ignored by Git. Keep using the same identity for updates. An ad-hoc signature changes with the executable, so macOS may require granting access again after a rebuild. No certificate, private key, signing identity file, or personal validation log is included in this repository.

## Use

1. Open the app and try **Replay**. Turn off **Follow my lid** to use the manual angle slider.
2. Click **Enable Mac Duo**, then allow Screen Recording in System Settings if requested. Quit and reopen if macOS asks.
3. Choose a **Clears at** angle below your usual working angle. Gently lower the lid to see the effect.
4. Leave **Clear when the lid is still** on to restore normal viewing after the selected delay, at any angle.
5. Use Esc during an effect or Control–Option–Command–F to pause. Closing the settings window keeps the menu-bar app running.

The app starts paused. It does not change sleep, brightness, wallpaper, display settings or login items. The internal bundle identifier remains `local.lidflow.mac` to preserve settings and permission continuity for early builds.

## Privacy and implementation

ScreenCaptureKit excludes this app from its own capture. Audio capture is disabled. Desktop frames remain in bounded memory; they are not saved, uploaded or analyzed. The live effect uses no network service, account, analytics or third-party runtime dependency.

The HID reader runs off the main thread. A Metal fragment shader and reusable blur pyramid render the effect. Reduce Motion uses a simple fade. Capture stops when the effect clears, and sensor/capture failures restore the desktop.

macOS owns sleep and the secure login screen. Animation cannot be guaranteed while the display is asleep, during login or with protected content. Capture may take a moment to warm up; the desktop and live preview remain clear until a fresh frame is ready.

## Verify

```sh
swift test
swift build
.build/debug/MacDuo --render-check validation
```

The render check uses generated artwork only; it does not capture the desktop. It verifies pixel identity after reopening, opacity, blur, geometry, cache freshness and GPU timing. GPU measurements exclude capture and display composition. Physical lid sweeps, sustained energy use and platform lifecycle transitions still need testing on more hardware.

## Contributing

Issues and focused pull requests are welcome. Include macOS version, Mac model, whether its lid sensor is detected, reproduction steps and relevant test results. Do not attach private desktop recordings or signing credentials. Run the checks above for renderer or motion changes. Keep the app dependency-free and respect Reduce Motion and existing power limits.

## Credits

The implementation is original. Public demonstrations and hardware research helped guide it; see [ATTRIBUTION.md](ATTRIBUTION.md). Mac Duo is independent and is not affiliated with Apple, Bendy or the reference projects.

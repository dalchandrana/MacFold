<img src="docs/assets/mark.png" alt="Mac Fold logo" width="96" align="right" style="border-radius: 18px;">

# Mac Fold

**Make your desktop feel physical.** Six effects that follow the movement of your MacBook lid.

[![Author](https://img.shields.io/badge/Author-Dalchand%20Rana-c65a16)](https://github.com/dalchandrana)
[![Release](https://img.shields.io/github/v/release/dalchandrana/MacFold?color=c65a16&label=download)](https://github.com/dalchandrana/MacFold/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-333333)](#install)
[![MIT](https://img.shields.io/badge/license-MIT-c65a16)](LICENSE)

### [↓ Download Mac Fold](https://github.com/dalchandrana/MacFold/releases/latest/download/Mac-Fold.dmg)

[All releases & ZIP](https://github.com/dalchandrana/MacFold/releases) · [Changelog](CHANGELOG.md) · [Build from source](docs/DEVELOPMENT.md) · [Report an issue](https://github.com/dalchandrana/MacFold/issues)

<p align="center"><img src="docs/assets/effects-preview.gif" alt="Generated artwork showing the Duo effect closing and reopening" width="720"><br><sub>Generated Duo demo. Your real desktop stays on your Mac.</sub></p>

## Six ways to close

| Effect | What it feels like |
|---|---|
| **Duo** · default | The desktop expands, softens and disappears around the hinge. |
| **Ghost** | The desktop appears anchored behind the tilting lid, with gradual defocus. |
| **Roll** | A flexible display curling into a roll. |
| **Shutter** | Four rigid panels sliding behind one another. |
| **Flex** | A continuous display bowing under tension. |
| **Iris** | Precision blades closing around the desktop. |

<p><img src="docs/assets/roll.jpg" alt="Roll effect" width="24%"> <img src="docs/assets/shutter.jpg" alt="Shutter effect" width="24%"> <img src="docs/assets/flex.jpg" alt="Flex effect" width="24%"> <img src="docs/assets/iris.jpg" alt="Iris effect" width="24%"></p>

Hold the lid still and the screen clears after **1–5 seconds**—**2 seconds** by default. Live preview, compact floating controls, orange Light/Dark themes, and menu-bar access are included. Close settings or switch desktops: Mac Fold keeps following in the background, without raising its window. Press **Esc** or **⌃⌥⌘F** to pause.

## Install

**Mac Fold 0.1.12 supports macOS 13 Ventura or newer**, with six effects including Ghost. A compatible lid sensor is required. Built for macOS 13 and tested on a newer M4 Mac; physical Ventura testing is still pending.

> [!NOTE]
> **MacBook compatibility · macOS 13+**<br>
> **Expected to work:** MacBook Air with M2 or newer, and 14-/16-inch MacBook Pro with M1 Pro/Max or newer.<br>
> **Unsupported:** M1 MacBook Air and 13-inch MacBook Pro with M1 or M2.<br>
> Tested on an M4 MacBook Pro. Mac Fold checks for a compatible lid sensor; external displays are not animated.

1. [Download **Mac-Fold.dmg**](https://github.com/dalchandrana/MacFold/releases/latest/download/Mac-Fold.dmg), open it, and drag **Mac Fold** into **Applications**.
2. Open **Mac Fold** from Applications. This release is **not notarized**, so macOS may initially block it with “cannot be opened” or “Apple could not verify” wording.
3. After trying to open it, go to **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** for **Mac Fold**, then confirm **Open**. [Apple’s instructions](https://support.apple.com/102445).
4. In Mac Fold, click **Enable Mac Fold** and allow **Screen Recording** when prompted. Reopen the app if macOS asks. Desktop frames stay in memory; nothing is recorded or uploaded.

Try **Replay** first—it works without Screen Recording permission. For manual control, turn off **Follow my lid**. Keep **Clear when the lid is still** enabled for normal use at any angle.

<details><summary><strong>Updating or using the ZIP instead</strong></summary>

In Mac Fold, choose **Check for Updates…** from the header or menu bar, then **Install & Relaunch**. The app checks the official GitHub release and verifies the download before replacing itself. Checks run only when you ask. macOS may require **Privacy & Security → Open Anyway** for an update; the recovery dialog lets you retry or restore the previous app. Install the app in a writable Applications folder first.

For a manual update, quit Mac Fold before replacing the app in Applications. For the ZIP, unzip it and move **Mac Fold.app** into Applications, then follow steps 2–4 above. Development signatures may require granting Screen Recording again after an update. If permission appears enabled but capture fails, remove the old Mac Fold entry in Screen Recording settings, add the current app from Applications, and reopen it.

</details>

## Small, local, open

Native **Swift + Metal**, with no third-party runtime dependencies, accounts or analytics. Effects stay entirely local; **Check for Updates** contacts GitHub only when you request it, and installation downloads the release. No screen content is sent. Settled previews stop rendering; blur is cached. Rendering is capped according to power and temperature, with up to 120 Hz requested on supported displays while plugged in. Actual frame rate and battery impact vary by Mac.

[Build & verification](docs/DEVELOPMENT.md) · [Reference credits](ATTRIBUTION.md) · [MIT license](LICENSE)

## Author & Maintainer

Mac Fold is created and maintained by **[Dalchand Rana](https://github.com/dalchandrana)**.

- **GitHub**: [@dalchandrana](https://github.com/dalchandrana)
- **Repository**: [dalchandrana/MacFold](https://github.com/dalchandrana/MacFold)

---

Independent software, not affiliated with Apple. Contributions and hardware reports are welcome.

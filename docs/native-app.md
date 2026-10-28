# LM Mask — native Mac app (parked)

> **Status:** parked. The camera extension works (it shows up as **LM Halloween Cam**), but the look moved to the web filter in [`web/`](../web/), which is what we use. This is the install guide written for the native app, kept for reference. Developer setup: [`README-dev.md`](../README-dev.md).

LM Mask turns you into the Lawmatics logo on video calls. It adds a camera called **LM Halloween Cam** that you pick in Zoom. The logo follows your head, blinks when you blink, and opens its mouth when you talk.

Requires a Mac running macOS 14 (Sonoma) or newer.

## Install

1. Open the `LM-Mask` disk image and drag **LM Mask** onto **Applications**.
2. Open **LM Mask** from the Applications folder. It lives in the menu bar (the mask icon at the top of your screen) and has no Dock icon.
3. Follow the setup guide that opens the first time:
   - Allow camera access.
   - Enable the camera extension (see the next section).
   - Pick LM Halloween Cam in Zoom.

Important: LM Mask must be in the Applications folder, not run from the disk image or Downloads. The camera extension will not install otherwise.

## Enable the camera extension

macOS asks you to approve the extension once. You will need an administrator password.

- **macOS 15 (Sequoia) and macOS 26:** open System Settings, then General, then **Login Items & Extensions**. Scroll to **Extensions**, open **Camera Extensions**, and turn on **LM Mask**.
- **macOS 14 (Sonoma):** open System Settings, then **Privacy & Security**. Scroll down to the message that says system software was blocked and click **Allow**.

The setup guide and the menu bar item both have a button that opens System Settings for you. Once approved, the menu shows **Camera Extension: Active**.

## Pick the camera in Zoom

1. In Zoom, open **Settings**, then **Video**.
2. Choose **LM Halloween Cam** in the Camera menu.
3. Click the mask icon in the menu bar and make sure **LM Mask** is checked (on).

Use **Open Preview…** from the menu bar to see what Zoom sees and to adjust mask size, mouth size and blink sensitivity.

## Uninstall

1. Quit LM Mask from its menu bar icon.
2. Drag **LM Mask** from Applications to the Trash.
3. Optional: remove the camera extension entry in System Settings, General, **Login Items & Extensions**, Camera Extensions. macOS also removes it after the app is deleted and you restart.

## Troubleshooting

**LM Halloween Cam is not in Zoom's camera list.**
Quit Zoom completely (Zoom menu, Quit) and open it again. Zoom only checks for cameras when it starts. If it is still missing, check the menu bar: it should say Camera Extension: Active. If not, click **Enable Camera Extension** and follow the approval steps above.

**My Zoom tile is black, or shows plain blue.**
Click the mask icon in the menu bar and turn **LM Mask** on. If it is already on, turn it off and on again. If the preview window is also empty, check System Settings, Privacy & Security, Camera, and make sure LM Mask is allowed.

**The mask does not follow me, or it lags.**
Face the camera in good light and keep your eyes open for a few seconds, then click **Recalibrate** in the preview window. Turn on **Show tracking overlay** to see what the app detects.

**The wrong physical camera is used.**
Open Settings from the menu bar and choose a camera under **Camera**.

**Nothing works after an update.**
Quit and reopen LM Mask, then quit and reopen Zoom.

Still stuck? Message the person who sent you this app and include the macOS version (Apple menu, About This Mac).

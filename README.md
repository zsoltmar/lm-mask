# LM Mask

A Halloween face filter for video calls. Your head becomes the inflatable LM logo (or Merlin, the mascot), your real eyes and mouth come along for the ride, and when you open your mouth and eyes wide it turns into a scare.

**Open it:** the live page is linked under **About** at the top right of this repo (GitHub Pages). Use Google Chrome on a computer with a webcam. Everything runs in your browser: the camera picture never leaves your computer.

## Characters

- **LM Logo** — an inflatable LM logo with your eyes peeking through the two middle fingers and your mouth, giant, on the swoosh. The scare turns the logo black and grows a white demon face out of your eyes and mouth; it blinks and gapes with you. Press **I** to invert it (white logo, black face) — tap it fast to strobe.
- **Merlin** — lavender skin, a starry hat, aviators that react to your eyes and brows, and your real mouth. The scare turns him into Dark Merlin, with laser eyes and lightning.

## Put it in Zoom

1. Open the page in Chrome and allow the camera. Press **H** for the clean picture (no controls).
2. Install [OBS Studio](https://obsproject.com) (free). Add a **macOS Screen Capture** source (Method: Window) of the Chrome window, then **Transform → Fit to Screen**.
3. Click **Start Virtual Camera** in OBS.
4. In Zoom → **Settings → Video**, choose **OBS Virtual Camera** and untick **Mirror my video**.

## Keys

| Key | |
| --- | --- |
| **S** (hold) | Scare |
| **I** | Invert the scare colors (LM Logo) |
| **C** | Switch character |
| **M** | Mirror |
| **H** | Clean output for OBS |
| **F** | Fullscreen |

All controls and tuning are in [`web/README.md`](web/README.md).

## Offline copy

The page also offers a single file, `lm-mask.html` (about 20 MB), that works without internet: open it in Chrome from your computer. The link is in the page's **Output** section.

## Repository

| Path | |
| --- | --- |
| [`web/`](web/) | The filter: source, build script, vendored three.js and MediaPipe |
| [`.github/workflows/pages.yml`](.github/workflows/pages.yml) | Builds the site and publishes it to GitHub Pages on every push to `main` |
| `LMMask/`, `LMMaskCamera/`, `Shared/`, `Config/`, `project.yml`, `scripts/` | Native Mac app with a camera extension — parked, see [`docs/native-app.md`](docs/native-app.md) |

Build locally: `python3 web/tools/build_app.py --pages` writes the site to `web/site/`; `python3 web/tools/build_app.py` writes the offline file to `web/dist/lm-mask.html`.

# LM Mask — Halloween face filter

Two characters (switch with the **Character** control or **C**):

- **LM Logo** — your head becomes an inflatable LM logo. Your real eyes peek through slits in the two middle fingers that open and close with your eyelids, and your real mouth becomes a giant mouth on the swoosh. The scare turns the logo glossy black and covers your eyes and mouth; the scare face (`assets/scare-face.png`) grows out from them in white, its eyes on your eyes and its mouth on your mouth. The face stays alive: its eyes squash when you blink or squint, and its fangs lengthen as you open your mouth wider. **I** inverts it (white logo, black face) instantly, so you can strobe between the two.
- **Wizard** — you become the mascot: a soft lavender head, a glossy starry wizard hat with a floppy tip, gold aviators over your eyes and your real mouth where its smile is. The scare turns it into a dark wizard with laser eyes and lightning crackling out from under the glasses.

The scare starts when you open your mouth **and** your eyes wide, plays in quickly, holds for as long as you keep your mouth open, and plays backwards when you close it. Holding **S** does the same.

## Use it (everyone)

1. Open the LM Mask page (GitHub Pages, linked from the repo's **About** box) in **Google Chrome**. For offline use, download the single file from the page's **Output** section (or build it, see below) and open it in Chrome (right-click → Open With → Google Chrome).
2. Allow the camera when Chrome asks. The headpiece appears as soon as your face is found.
3. To scare: open your mouth wide and widen your eyes. Or hold **S**.

### Put it in Zoom (one-time setup, about 3 minutes)

1. Install [OBS Studio](https://obsproject.com) (free).
2. In the LM Mask page press **H** for the clean output (no controls).
3. In OBS, under **Sources**, click **+ → macOS Screen Capture**, set **Method: Window**, pick the Chrome window “LM Mask”. Right-click the source → **Transform → Fit to Screen**. If the tab bar shows, hold **Option** and drag the source’s top edge to crop it.
4. Click **Start Virtual Camera** in OBS.
5. In Zoom → **Settings → Video**, choose **OBS Virtual Camera** and untick **Mirror my video** (so the logo reads the right way round for you too).

macOS asks once for Screen Recording permission for OBS — allow it and restart OBS.

### Controls

| Control | What it does |
| --- | --- |
| Character (**C**) | LM Logo or Wizard. |
| Mirror (**M**) | Mirror the picture. The logo always reads correctly. |
| Mouth size | How big the cartoon mouth is (default 2.15×). |
| Edge softness | How softly the eye and mouth cut-outs blend into the character. |
| Eye cut-outs | How far the eye slits reach beyond your eyelids. |
| Mouth / Eyes trigger | How wide you need to open for the scare. The meters show your live values; the white tick is the trigger. |
| Mouth alone triggers | Scare on mouth only, for anyone whose “wide eyes” don’t register. |
| Invert colors (**I**) | LM scare: black logo with a white face, or white logo with a black face. Flips instantly — tap or hold **I** during a scare to strobe. |
| Hold **S** | Scare for as long as you hold it. |
| **H** | Clean output for OBS. **F** fullscreen. |

## Develop

```
web/
  src/            svgpath.js  mark geometry · env.js  studio lighting · inflate.js  inflatable mesh
                  wizard.js  the mascot · scareart.js  warped scare face
                  face.js  tracking + scare trigger · overlay.js  eye/mouth/demon layers
                  render.js  3D + composite · app.js  camera/MediaPipe/UI · ui.css · body.html
  vendor/         three.js r170, MediaPipe tasks-vision 0.10.18 (+ wasm, face_landmarker.task)
  tools/          build_app.py (builds dist/ and site/), build_page.py (look-dev pages)
  preview/        look-dev drivers (studio render of the mask, still-photo pipeline)
  dist/           lm-mask.html (offline, ~20 MB) · lm-mask-lite.html (loads MediaPipe from the CDN)   [not in git]
  site/           the GitHub Pages site: index.html + mediapipe/ + the offline lm-mask.html        [not in git]
```

Build: `python3 tools/build_app.py` (offline), `python3 tools/build_app.py --lite`, and `python3 tools/build_app.py --pages` (the hosted site). Pushing to `main` rebuilds and publishes the site through `.github/workflows/pages.yml`.

Pipeline per camera frame: MediaPipe FaceLandmarker (478 landmarks, head pose matrix, blendshapes) → One-Euro smoothing → the mask is anchored so its two eye anchors sit exactly on your eyes in screen space and rotated by the head pose → the inflatable renders to an offscreen target → one composite pass lays it over the video, cuts the eye holes, pastes the relocated mouth, and applies the scare grade, flash and shake.

The scare face is the artwork in `assets/scare-face.png` (ink on transparent, made from `scare-face-source.png`; printed white on the black logo); its eye and mouth anchor points and the rows where its lower jaw hinges live in `tools/build_app.py`. Without that file the build falls back to the face drawn in code (`overlay.js → demonShapes`).

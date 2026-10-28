# Third-party code in `vendor/`

| Path | Project | Version | License |
| --- | --- | --- | --- |
| `three.cjs` | [three.js](https://github.com/mrdoob/three.js) | r170 | MIT — Copyright 2010-2024 Three.js Authors |
| `mediapipe/vision_bundle.mjs`, `mediapipe/wasm/*` | [MediaPipe Tasks Vision](https://www.npmjs.com/package/@mediapipe/tasks-vision) | 0.10.18 | Apache-2.0 — Copyright The MediaPipe Authors |
| `mediapipe/face_landmarker.task` | [MediaPipe Face Landmarker model](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker) | float16 v1 | Apache-2.0 — Copyright The MediaPipe Authors |

These files are unmodified copies. The build embeds them in the offline page (`dist/lm-mask.html`) and serves them next to the hosted page (`site/mediapipe/`).

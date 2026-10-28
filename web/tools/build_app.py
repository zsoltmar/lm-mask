#!/usr/bin/env python3
"""Build the LM Mask web app.

  python3 tools/build_app.py              → dist/lm-mask.html (offline, everything embedded, ~20 MB)
  python3 tools/build_app.py --lite       → dist/lm-mask-lite.html (MediaPipe from CDN, ~1.8 MB)
  python3 tools/build_app.py --pages      → site/ (GitHub Pages: index.html + MediaPipe served alongside,
                                            plus the offline lm-mask.html as a download)
  python3 tools/build_app.py --still x.still.js --out y.html   (look-dev: demo photo instead of camera)
"""
import argparse, base64, pathlib, re, shutil

root = pathlib.Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument('--lite', action='store_true')
ap.add_argument('--pages', action='store_true')
ap.add_argument('--still', default=None)
ap.add_argument('--pre', default='')
ap.add_argument('--out', default=None)
a = ap.parse_args()

def script(code, name=''):
    return f'<script>/* {name} */\n' + code.replace('</script', '<\\/script') + '\n</script>\n'

SRC = ['src/svgpath.js', 'src/env.js', 'src/inflate.js', 'src/merlin.js', 'src/face.js', 'src/overlay.js', 'src/scareart.js', 'src/render.js', 'src/app.js']
mp = root / 'vendor/mediapipe'
icon = root.parent / 'Assets/mark-light-color.svg'

def page(offline, pre=''):
    """offline: embed MediaPipe (wasm + model). pre: extra script run before the app."""
    head = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
            '<meta name="viewport" content="width=device-width,initial-scale=1">',
            '<title>LM Mask</title>',
            '<meta name="description" content="A Halloween face filter for video calls: become the inflatable LM logo or Merlin, then scare everyone.">']
    if icon.exists():
        head.append('<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,' + base64.b64encode(icon.read_bytes()).decode() + '">')
    parts = head + ['<style>' + (root / 'src/ui.css').read_text() + '</style></head><body>', (root / 'src/body.html').read_text()]
    three = (root / 'vendor/three.cjs').read_text()
    parts.append(script('(function(){var module={exports:{}};var exports=module.exports;\n' + three + '\nwindow.THREE=module.exports;})();', 'three.js r170 (MIT)'))
    if offline:
        loader = (mp / 'wasm/vision_wasm_internal.js').read_text()
        parts.append(script(loader + '\nwindow.__mpFactory = ModuleFactory;', 'MediaPipe wasm loader (Apache-2.0)'))
        bundle = (mp / 'vision_bundle.mjs').read_text()
        m = re.search(r'export\{([^}]*)\};?\s*(//# sourceMappingURL=.*)?\s*$', bundle)
        pairs = [p.strip().split(' as ') for p in m.group(1).split(',')]
        bundle = '(function(){' + bundle[:m.start()] + 'window.MPVision={' + ','.join(f'{b}:{x}' for x, b in pairs) + '};})();'
        parts.append(script(bundle, 'MediaPipe tasks-vision 0.10.18 (Apache-2.0)'))
        wasm = base64.b64encode((mp / 'wasm/vision_wasm_internal.wasm').read_bytes()).decode()
        model = base64.b64encode((mp / 'face_landmarker.task').read_bytes()).decode()
        parts.append(f'<script>window.MP_INLINE={{wasm:"{wasm}",model:"{model}"}};</script>\n')
    face = root / 'assets/scare-face.png'
    if face.exists():
        b64 = base64.b64encode(face.read_bytes()).decode()
        # anchors in the artwork's pixels: eye-mass centres and the fang tips. As your jaw opens, the fangs
        # (rows fangTop → jawTop) lengthen by up to `fangStretch`; the chin drops by up to `chinDrop` face units.
        anchors = '{eyeL:[397.6,634.8],eyeR:[1160.9,653.3],mouth:[772.9,1274.5],fangTop:1000,jawTop:1290,fangStretch:0.5,chinDrop:0.1,scale:1.7}'
        parts.append(f'<script>window.LM_SCARE_FACE={{src:"data:image/png;base64,{b64}",anchors:{anchors}}};</script>\n')
    if a.still:
        parts.append(script(pathlib.Path(a.still).read_text(), 'still'))
    if pre:
        parts.append(script(pre, 'pre'))
    for s in SRC:
        parts.append(script((root / s).read_text(), s))
    parts.append('</body></html>')
    return ''.join(parts)

def write(path, html):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html)
    print(path.relative_to(root) if path.is_relative_to(root) else path, round(path.stat().st_size / 1e6, 2), 'MB')

if a.pages:
    site = pathlib.Path(a.out) if a.out else root / 'site'
    # MediaPipe next to the page (same origin, cached separately); the app falls back to the CDN.
    # Files are overwritten in place (no clean step), which also works in folders that forbid deletes.
    shutil.copytree(mp, site / 'mediapipe', dirs_exist_ok=True, copy_function=shutil.copyfile)
    write(site / 'index.html', page(offline=False, pre="window.MP_BASE='mediapipe';"))
    write(site / 'lm-mask.html', page(offline=True))
    (site / '.nojekyll').write_text('')
else:
    offline = not a.lite and not a.still
    out = pathlib.Path(a.out) if a.out else root / ('dist/lm-mask-lite.html' if a.lite else 'dist/lm-mask.html')
    write(out, page(offline, a.pre))

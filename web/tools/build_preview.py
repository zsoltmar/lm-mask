#!/usr/bin/env python3
"""Inline three.js (CJS build, shimmed to window.THREE) + the mask sources into one static HTML for
look-dev screenshots. Usage: build_preview.py <three.cjs> <out.html> [--scare] [--yaw 0.3] [--style '{...}']"""
import sys, json, argparse, pathlib

ap = argparse.ArgumentParser()
ap.add_argument('three'); ap.add_argument('out')
ap.add_argument('--scare', action='store_true')
ap.add_argument('--yaw', type=float, default=0.0)
ap.add_argument('--pitch', type=float, default=0.0)
ap.add_argument('--style', default='{}')
a = ap.parse_args()

root = pathlib.Path(__file__).resolve().parent.parent
three = pathlib.Path(a.three).read_text()
srcs = ['src/svgpath.js', 'src/env.js', 'src/mask.js', 'src/stencil.js', 'src/scare.js', 'preview/preview_driver.js']
parts = []
for s in srcs:
    p = root / s
    if p.exists():
        parts.append(f'<script>/* {s} */\n' + p.read_text() + '\n</script>')

html = f'''<!doctype html><html><head><meta charset="utf-8">
<style>body{{margin:0;background:#1b1f26;color:#9aa;font:12px ui-monospace,monospace}}#stage{{display:block}}#log{{margin:6px;white-space:pre}}</style>
</head><body><div id="stage"></div><pre id="log">preview</pre>
<script>var module={{exports:{{}}}};var exports=module.exports;
{three}
window.THREE=module.exports;</script>
<script>window.PREVIEW_SCARE={str(a.scare).lower()};window.PREVIEW_YAW={a.yaw};window.PREVIEW_PITCH={a.pitch};window.PREVIEW_STYLE={a.style};</script>
{''.join(parts)}
</body></html>'''
pathlib.Path(a.out).write_text(html)
print(a.out, len(html))

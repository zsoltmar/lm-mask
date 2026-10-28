#!/usr/bin/env python3
"""Assemble a single self-contained HTML page from the web/ sources.

  build_page.py <out.html> --scripts a.js b.js ... [--pre 'js code'] [--body '<html>'] [--css file.css]

three.js (vendor/three.cjs) is always inlined first and exposed as window.THREE.
"""
import argparse, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument('out')
ap.add_argument('--scripts', nargs='+', default=[])
ap.add_argument('--pre', default='')
ap.add_argument('--body', default='<div id="stage"></div><pre id="log"></pre>')
ap.add_argument('--css', default=None)
ap.add_argument('--title', default='LM Mask')
a = ap.parse_args()

def script(code, name=''):
    return f'<script>/* {name} */\n' + code.replace('</script', '<\\/script') + '\n</script>\n'

three = (root / 'vendor/three.cjs').read_text()
css = (root / a.css).read_text() if a.css else 'body{margin:0;background:#15181d;color:#9aa3ad;font:12px ui-monospace,monospace}#log{margin:6px;white-space:pre-wrap}'
parts = [f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{a.title}</title><style>{css}</style></head><body>',
         a.body,
         script('(function(){var module={exports:{}};var exports=module.exports;\n' + three + '\nwindow.THREE=module.exports;})();', 'three.js r170'),
         script(a.pre, 'pre') if a.pre else '']
for s in a.scripts:
    p = pathlib.Path(s)
    if not p.is_absolute():
        p = root / s
    parts.append(script(p.read_text(), s))
parts.append('</body></html>')
html = ''.join(parts)
pathlib.Path(a.out).write_text(html)
print(a.out, len(html) // 1024, 'KB')

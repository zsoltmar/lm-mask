// LM Mask — per-frame overlay layers, drawn in output pixels into one opaque canvas.
//
// Normal mode:  R = eye cut-outs (live video), G = big-mouth patch (relocated live mouth), B = shadow/edge.
// Scare mode:   no cut-outs. Only the drawn fallback face uses the layer: R = white paint, B = black
//               (its fangs). The artwork arrives separately via ScareArt.
// The composite pass and the mask material read these channels; channels are additive ('lighter').
(function () {
  'use strict';

  const RED = 'rgb(255,0,0)', GREEN = 'rgb(0,255,0)', BLUE = 'rgb(0,0,255)';

  // closed Catmull-Rom through points → Path2D
  function smoothPath(pts, closed = true, tension = 0.5) {
    const p = new Path2D();
    const n = pts.length;
    p.moveTo(pts[0][0], pts[0][1]);
    const last = closed ? n : n - 1;
    for (let i = 0; i < last; i++) {
      const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
      const q0 = closed || i > 0 ? p0 : p1, q3 = closed || i < n - 2 ? p3 : p2;
      const k = tension / 3 * 2;
      p.bezierCurveTo(p1[0] + (p2[0] - q0[0]) * k / 2, p1[1] + (p2[1] - q0[1]) * k / 2, p2[0] - (q3[0] - p1[0]) * k / 2, p2[1] - (q3[1] - p1[1]) * k / 2, p2[0], p2[1]);
    }
    if (closed) p.closePath();
    return p;
  }

  // Almond eye cut-out around one eye: tips beyond the corners, upper arc taller than the lower.
  function eyeAlmond(e, cfg) {
    const ax = [e.outer[0] - e.inner[0], e.outer[1] - e.inner[1]];
    const L = Math.hypot(ax[0], ax[1]) || 1;
    let ux = ax[0] / L, uy = ax[1] / L;
    if (ux < 0) { ux = -ux; uy = -uy; } // left → right on screen
    const nx = uy, ny = -ux;              // "up" on screen (perpendicular)
    const w = e.width * cfg.eyeScale;
    const hu = w * 0.36, hd = w * 0.26;
    const c = [e.center[0] + nx * w * 0.03, e.center[1] + ny * w * 0.03];
    const P = (a, b) => [c[0] + ux * a + nx * b, c[1] + uy * a + ny * b];
    const L0 = P(-w / 2, 0), R0 = P(w / 2, 0);
    const path = new Path2D();
    path.moveTo(...L0);
    let c1 = P(-w * 0.27, hu * 1.33), c2 = P(w * 0.25, hu * 1.33);
    path.bezierCurveTo(c1[0], c1[1], c2[0], c2[1], R0[0], R0[1]);
    c1 = P(w * 0.25, -hd * 1.33); c2 = P(-w * 0.27, -hd * 1.33);
    path.bezierCurveTo(c1[0], c1[1], c2[0], c2[1], L0[0], L0[1]);
    path.closePath();
    return path;
  }

  // Eye cut-out that follows the eyelids (like the mouth follows the lips): the lid-margin loop, grown a
  // little about its centre and pushed out by a small margin, so a blink closes it to a thin slit.
  function eyeSlit(e, cfg) {
    const pts = e.lids;
    let cx = 0, cy = 0;
    for (const p of pts) { cx += p[0]; cy += p[1]; }
    cx /= pts.length; cy /= pts.length;
    const k = cfg.eyeScale, d = e.width * 0.06, n = pts.length;
    const grown = pts.map(([x, y]) => [cx + (x - cx) * k, cy + (y - cy) * k]);
    const out = grown.map((p, i) => {
      const a = grown[(i - 1 + n) % n], b = grown[(i + 1) % n];
      let nx = b[1] - a[1], ny = -(b[0] - a[0]);
      const L = Math.hypot(nx, ny) || 1; nx /= L; ny /= L;
      if (nx * (p[0] - cx) + ny * (p[1] - cy) < 0) { nx = -nx; ny = -ny; }
      return [p[0] + nx * d, p[1] + ny * d];
    });
    return smoothPath(out);
  }
  const eyeCut = (e, cfg) => (e.lids ? eyeSlit(e, cfg) : eyeAlmond(e, cfg));

  // ---------------------------------------------------------------- demon stencil (mask SVG space)
  // Authored in "face units": origin at the eye midpoint, 1 unit = distance between the mask's eye
  // anchors, x right, y down. Everything is original geometry.
  // cubic Bézier sampled into points (face units)
  function bez(p0, p1, p2, p3, n = 14, skipFirst = false) {
    const out = [];
    for (let i = skipFirst ? 1 : 0; i <= n; i++) {
      const t = i / n, u = 1 - t;
      out.push([
        u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
      ]);
    }
    return out;
  }
  const mirrorX = (pts) => pts.map(([x, y]) => [-x, y]).reverse();

  // The demon face (original design). `open` (0..1) drives the jaw. Every shape carries the point it
  // grows out of — the eyes or the mouth — and a delay, so the face erupts from them on the scare.
  const EYE_R = [0.5, 0.02], EYE_L = [-0.5, 0.02], MOUTH = [0.18, 1.42], BRIDGE = [0, 0.02];
  function demonShapes(open) {
    const shapes = [];
    const add = (pts, from, delay, dur, paint = false) => shapes.push({ pts, from, delay, dur, paint });
    const o = Math.max(0, Math.min(1, open));
    // EYES — wide angular slants; inner tips hook down toward the nose, outer tails sweep up.
    const eye = [
      ...bez([0.02, 0.22], [0.20, 0.00], [0.50, -0.16], [1.10, -0.40]),
      ...bez([1.10, -0.40], [1.02, -0.06], [0.84, 0.26], [0.54, 0.38], 14, true),
      ...bez([0.54, 0.38], [0.36, 0.44], [0.18, 0.38], [0.02, 0.22], 12, true),
    ];
    add(eye, EYE_R, 0, 0.14); add(mirrorX(eye), EYE_L, 0, 0.14);
    // BROWS — heavy blades from the bridge of the nose up to horn-like points, with one flame lick.
    const brow = [
      ...bez([0.00, -0.18], [0.30, -0.34], [0.60, -0.56], [0.84, -0.78]),
      [0.92, -1.08],
      ...bez([0.98, -0.80], [1.12, -0.90], [1.26, -1.06], [1.36, -1.38], 10),
      ...bez([1.36, -1.38], [1.34, -0.94], [1.18, -0.62], [0.92, -0.50], 10, true),
      ...bez([0.92, -0.50], [0.62, -0.32], [0.30, -0.14], [0.06, -0.06], 12, true),
    ];
    add(brow, EYE_R, 0.05, 0.22); add(mirrorX(brow), EYE_L, 0.05, 0.22);
    // FOREHEAD DAGGER — shoots up from between the eyes.
    const dag = bez([0.11, -0.20], [0.10, -0.55], [0.05, -0.85], [0, -1.15], 10);
    add([[0, 0.05], ...dag, ...mirrorX(dag).slice(1)], BRIDGE, 0.09, 0.2);
    // NOSTRILS — two blade slits.
    const nostril = [[0.07, 0.58], ...bez([0.16, 0.52], [0.26, 0.58], [0.28, 0.70], [0.24, 0.78], 6), [0.13, 0.70]];
    add(nostril, MOUTH, 0.1, 0.16); add(mirrorX(nostril), MOUTH, 0.1, 0.16);
    // GRIN — cheek-to-cheek, corners hooked up; the lower jaw drops with the real mouth.
    const dx = MOUTH[0];
    const top = (x) => 1.02 + 0.10 * Math.cos((x - dx) * 2.2) + 0.04 * Math.abs(x - dx);
    const drop = 0.42 + 0.70 * o;
    const bot = (x) => top(x) + 0.08 + drop * Math.pow(Math.max(0, Math.cos((Math.abs(x - dx) / 1.22) * Math.PI / 2)), 0.75);
    const N = 28, X0 = 1.22;
    const mouth = [[dx - 1.52, 0.66]];
    for (let i = 0; i <= N; i++) { const x = dx - X0 + (2 * X0 * i) / N; mouth.push([x, top(x)]); }
    mouth.push([dx + 1.52, 0.66]);
    for (let i = N; i >= 0; i--) { const x = dx - X0 + (2 * X0 * i) / N; mouth.push([x, bot(x)]); }
    add(mouth, MOUTH, 0, 0.16);
    // FANGS — white, curved, interlocking. Canines are the longest.
    const fang = (x, w, len, down, lean) => {
      const y0 = down ? top(x) - 0.04 : bot(x) + 0.04, s = down ? 1 : -1;
      const tip = [x + lean, y0 + s * len];
      return [[x - w / 2, y0], ...bez([x - w / 2, y0], [x - w * 0.42, y0 + s * len * 0.45], [tip[0] - w * 0.12, tip[1] - s * len * 0.2], tip, 6, true),
        ...bez(tip, [tip[0] + w * 0.18, tip[1] - s * len * 0.35], [x + w * 0.46, y0 + s * len * 0.4], [x + w / 2, y0], 6, true)];
    };
    const L = 0.6 + 0.55 * o;
    const tops = [[-1.00, 0.10, 0.20], [-0.76, 0.12, 0.30], [-0.50, 0.15, 0.56], [-0.25, 0.11, 0.26], [0.0, 0.11, 0.22], [0.25, 0.11, 0.26], [0.50, 0.15, 0.56], [0.76, 0.12, 0.30], [1.00, 0.10, 0.20]];
    for (const [x, w, l] of tops) add(fang(dx + x, w, l * L, true, -x * 0.05), MOUTH, 0.06, 0.16, true);
    const bots = [[-0.88, 0.10, 0.18], [-0.63, 0.12, 0.30], [-0.38, 0.11, 0.22], [-0.12, 0.12, 0.38], [0.12, 0.12, 0.38], [0.38, 0.11, 0.22], [0.63, 0.12, 0.30], [0.88, 0.10, 0.18]];
    for (const [x, w, l] of bots) add(fang(dx + x, w, l * L, false, x * 0.05), MOUTH, 0.06, 0.16, true);
    // CHEEK SLASHES — rip up from the grin corners toward the eyes.
    const slash = [[1.46, 0.60], ...bez([1.52, 0.40], [1.64, 0.10], [1.66, -0.12], [1.62, -0.30], 8), ...bez([1.62, -0.30], [1.56, -0.04], [1.50, 0.26], [1.40, 0.56], 8, true)];
    const sh = (pts) => pts.map(([x, y]) => [x + dx, y]);
    add(sh(slash), [dx + 1.3, 0.9], 0.12, 0.2); add(sh(mirrorX(slash)), [dx - 1.3, 0.9], 0.12, 0.2);
    return shapes;
  }
  const easeOutBack = (x) => { const c1 = 1.9, c3 = c1 + 1; return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2); };

class Overlay {
    constructor(W, H) {
      this.canvas = document.createElement('canvas');
      this.canvas.width = W; this.canvas.height = H;
      this.ctx = this.canvas.getContext('2d', { alpha: false, willReadFrequently: false });
      // colour effects layer (laser eyes, lightning): premultiplied, added on top in the composite
      this.fx = document.createElement('canvas');
      this.fx.width = W; this.fx.height = H;
      this.fxCtx = this.fx.getContext('2d');
      this.fxDirty = false;
      this.W = W; this.H = H;
      this.cfg = { eyeScale: 1.2, mouthScale: 2.15, mouthPad: 1.07, wizardMouth: 0.6, soft: 0.5 };
      this.patch = null;
    }

    // project: (svgX, svgY) → [px, py]; anchors: { mid, span } in mask svg; mouthDst: [px, py]
    // sc: { on, p (0..1 reveal progress), art (bool: the artwork is drawn by ScareArt) }; opts: { character }
    draw(state, sc, project, anchors, mouthDst, opts = {}) {
      const ctx = this.ctx;
      ctx.globalCompositeOperation = 'source-over';
      ctx.filter = 'none';
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, this.W, this.H);
      this.patch = null;
      if (!state || !state.present) return;
      ctx.globalCompositeOperation = 'lighter';
      if (opts.character === 'wizard') { this.drawMouth(state, mouthDst, this.cfg.mouthScale * this.cfg.wizardMouth); return; }
      if (!sc.on) this.drawNormal(state, mouthDst);
      else this.drawScare(state, sc, project, anchors, mouthDst);
    }

    // the real mouth, relocated to `mouthDst` and scaled by k (G channel) with a soft shadow (B)
    mouthPath(s, mouthDst, k) {
      const lips = s.lips, cfg = this.cfg;
      let cx = 0, cy = 0;
      for (const p of lips) { cx += p[0]; cy += p[1]; }
      cx /= lips.length; cy /= lips.length;
      const a = s.lipTop;
      const dst = lips.map(([x, y]) => [mouthDst[0] + (cx + (x - cx) * cfg.mouthPad - a[0]) * k, mouthDst[1] + (cy + (y - cy) * cfg.mouthPad - a[1]) * k]);
      return { path: smoothPath(dst), centre: [mouthDst[0] + (cx - a[0]) * k, mouthDst[1] + (cy - a[1]) * k], src: a };
    }
    drawMouth(s, mouthDst, k) {
      const ctx = this.ctx;
      const m = this.mouthPath(s, mouthDst, k);
      this.patch = { src: m.src, dst: mouthDst, scale: k };
      ctx.save();
      ctx.filter = `blur(${Math.max(2, s.iod * 0.05).toFixed(1)}px)`;
      ctx.translate(0, s.iod * 0.05);
      ctx.fillStyle = 'rgba(0,0,255,0.75)';
      ctx.fill(m.path);
      ctx.restore();
      // feathered edge so the mouth blends into the character (Edge softness slider)
      const fm = this.cfg.soft * s.iod * 0.06 * Math.max(0.6, k / 2);
      ctx.save();
      if (fm > 0.4) ctx.filter = `blur(${fm.toFixed(1)}px)`;
      ctx.fillStyle = GREEN;
      ctx.fill(m.path);
      ctx.restore();
      return m;
    }

    drawNormal(s, mouthDst) {
      const ctx = this.ctx, cfg = this.cfg;
      this.drawMouth(s, mouthDst, cfg.mouthScale);
      // eye cut-outs that follow the eyelids, with a crisp edge line on the mask side
      const fe = cfg.soft * s.iod * 0.05;
      for (const e of [s.eyeA, s.eyeB]) {
        const p = eyeCut(e, cfg);
        // a faint shadow just outside the slit, fading with the softness
        ctx.save();
        ctx.filter = `blur(${Math.max(1, fe * 1.5 + 1).toFixed(1)}px)`;
        ctx.strokeStyle = `rgba(0,0,255,${(0.75 * (1 - cfg.soft * 0.6)).toFixed(2)})`;
        ctx.lineWidth = Math.max(1.5, s.iod * 0.016);
        ctx.stroke(p);
        ctx.restore();
        ctx.save();
        if (fe > 0.4) ctx.filter = `blur(${fe.toFixed(1)}px)`;
        ctx.fillStyle = RED;
        ctx.fill(p);
        ctx.restore();
      }
    }

    // Scare: no eye slits or mouth — your face is fully covered and the white face spreads out from where
    // your eyes and mouth are. With the artwork, ScareArt draws it; this is the drawn fallback.
    drawScare(s, sc, project, anchors, mouthDst) {
      const ctx = this.ctx;
      if (sc.art) return;
      // fallback: the face drawn in code, grown from the eyes and mouth by the same progress
      const E = anchors.mid, U = anchors.span;
      const toPx = ([fx, fy]) => project(E[0] + fx * U, E[1] + fy * U);
      const tOn = (sc.p ?? 1) * 0.9;
      const clamp01 = (x) => Math.max(0, Math.min(1, x));
      const easeOut = (x) => 1 - Math.pow(1 - x, 3);
      // white face (R) with black fangs (B), matching the artwork's look on the black logo
      for (const pass of [false, true]) {
        ctx.fillStyle = pass ? BLUE : RED;
        for (const sh of demonShapes(s.jaw)) {
          if (sh.paint !== pass) continue;
          const g = easeOut(clamp01((tOn - sh.delay * 2.2) / (sh.dur * 2.6)));
          if (g <= 0.01) continue;
          const [ox, oy] = sh.from;
          const q = sh.pts.map(([x, y]) => toPx([ox + (x - ox) * g, oy + (y - oy) * g]));
          const p = new Path2D();
          p.moveTo(q[0][0], q[0][1]);
          for (let i = 1; i < q.length; i++) p.lineTo(q[i][0], q[i][1]);
          p.closePath();
          ctx.fill(p);
        }
      }
    }

    // ---------------------------------------------------------------- wizard: laser eyes + lightning
    // info: { lenses: [[x,y]×2], ends: [[x,y]×2], bottoms: [[[x,y]…]×2], iod (px), k (0..1), t }
    drawWizardFx(info) {
      const ctx = this.fxCtx;
      ctx.globalCompositeOperation = 'source-over';
      ctx.clearRect(0, 0, this.W, this.H);
      this.fxDirty = true;
      if (!info || info.k <= 0.01) return;
      const { k, iod, t } = info;
      ctx.globalCompositeOperation = 'lighter';
      ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      // lightning crawling out from under the lenses (regenerated ~18×/s)
      const R = mulberry(Math.floor(t * 18) + 1);
      const bolt = (x, y, ang, len, depth) => {
        let pts = [[x, y], [x + Math.cos(ang) * len, y + Math.sin(ang) * len]];
        for (let lv = 0; lv < 5; lv++) {
          const out = [pts[0]];
          for (let i = 1; i < pts.length; i++) {
            const a = pts[i - 1], b = pts[i];
            const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy);
            const off = (R() - 0.5) * L * 0.55;
            out.push([(a[0] + b[0]) / 2 - (dy / L) * off, (a[1] + b[1]) / 2 + (dx / L) * off], b);
          }
          pts = out;
        }
        const path = new Path2D();
        pts.forEach((p, i) => (i ? path.lineTo(p[0], p[1]) : path.moveTo(p[0], p[1])));
        const w = Math.max(1, iod * 0.022) * (depth ? 0.6 : 1);
        ctx.shadowColor = `rgba(140,110,255,${0.9 * k})`; ctx.shadowBlur = iod * 0.25;
        ctx.strokeStyle = `rgba(120,90,255,${0.45 * k})`; ctx.lineWidth = w * 5; ctx.stroke(path);
        ctx.shadowBlur = 0;
        ctx.strokeStyle = `rgba(225,230,255,${0.95 * k})`; ctx.lineWidth = w; ctx.stroke(path);
        if (depth < 1) for (let b = 0; b < 2; b++) { const p = pts[4 + Math.floor(R() * (pts.length - 6))]; if (p) bolt(p[0], p[1], ang + (R() - 0.5) * 1.6, len * (0.3 + R() * 0.3), depth + 1); }
      };
      info.bottoms.forEach((pts, side) => {
        const out = side === 0 ? 1 : -1; // left lens: bolts fan down-left; right lens: down-right
        for (let i = 0; i < 3; i++) {
          const p = pts[Math.floor(R() * pts.length)];
          const ang = Math.PI / 2 + out * (0.15 + R() * 0.8);
          bolt(p[0], p[1], ang, iod * (0.9 + R() * 1.3) * (0.4 + 0.6 * k), 0);
        }
      });
      // laser beams
      info.lenses.forEach((c, i) => {
        const e = info.ends[i];
        const dx = e[0] - c[0], dy = e[1] - c[1];
        const g = ctx.createLinearGradient(c[0], c[1], e[0], e[1]);
        g.addColorStop(0, `rgba(255,40,30,${0.9 * k})`); g.addColorStop(1, `rgba(255,20,20,${0.15 * k})`);
        ctx.strokeStyle = g;
        ctx.shadowColor = `rgba(255,0,0,${k})`; ctx.shadowBlur = iod * 0.35;
        ctx.lineWidth = iod * 0.22 * (0.9 + 0.1 * Math.sin(t * 40 + i)); ctx.beginPath(); ctx.moveTo(c[0], c[1]); ctx.lineTo(e[0], e[1]); ctx.stroke();
        ctx.shadowBlur = 0;
        ctx.strokeStyle = `rgba(255,235,225,${0.95 * k})`; ctx.lineWidth = iod * 0.06; ctx.beginPath(); ctx.moveTo(c[0], c[1]); ctx.lineTo(e[0], e[1]); ctx.stroke();
        // flare at the lens
        const r = iod * 0.75;
        const fl = ctx.createRadialGradient(c[0], c[1], 0, c[0], c[1], r);
        fl.addColorStop(0, `rgba(255,255,255,${k})`); fl.addColorStop(0.18, `rgba(255,90,60,${0.85 * k})`); fl.addColorStop(1, 'rgba(255,0,0,0)');
        ctx.fillStyle = fl; ctx.beginPath(); ctx.arc(c[0], c[1], r, 0, Math.PI * 2); ctx.fill();
      });
    }
    clearFx() { if (this.fxDirty) { this.fxCtx.clearRect(0, 0, this.W, this.H); this.fxDirty = false; return true; } return false; }
  }
  const mulberry = (seed) => { let st = seed >>> 0; return () => { st = (st + 0x6d2b79f5) >>> 0; let t = st; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; };

  // pixels per face unit near the face (for line widths)
  function pxPerUnit(toPx) { const a = toPx([0, 0]), b = toPx([1, 0]); return Math.hypot(b[0] - a[0], b[1] - a[1]) / 1; }
  // tapered filled stroke along a polyline (px), width w at the root → 0 at the tip
  function taper(q, w) {
    const left = [], right = [], n = q.length;
    for (let i = 0; i < n; i++) {
      const a = q[Math.max(0, i - 1)], b = q[Math.min(n - 1, i + 1)];
      let dx = b[0] - a[0], dy = b[1] - a[1];
      const L = Math.hypot(dx, dy) || 1; dx /= L; dy /= L;
      const hw = (w / 2) * Math.pow(1 - i / (n - 1), 0.8);
      left.push([q[i][0] - dy * hw, q[i][1] + dx * hw]);
      right.push([q[i][0] + dy * hw, q[i][1] - dx * hw]);
    }
    const p = new Path2D();
    p.moveTo(left[0][0], left[0][1]);
    for (const pt of left.slice(1)) p.lineTo(pt[0], pt[1]);
    for (const pt of right.reverse()) p.lineTo(pt[0], pt[1]);
    p.closePath();
    return p;
  }
  // Branching cracks (face units) radiating from the eyes and the mouth. Seeded so they hold still.
  function makeCracks(seed) {
    let st = (seed * 2654435761) >>> 0;
    const rnd = () => { st = (st + 0x6d2b79f5) >>> 0; let t = st; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
    const out = [];
    const walk = (x, y, ang, len, w, delay, depth) => {
      const pts = [[x, y]], step = 0.045;
      let a = ang;
      for (let d = 0; d < len; d += step) {
        a += (rnd() - 0.5) * 0.55;
        x += Math.cos(a) * step; y += Math.sin(a) * step;
        pts.push([x, y]);
        if (depth < 1 && d > len * 0.35 && rnd() < 0.05) walk(x, y, a + (rnd() < 0.5 ? -1 : 1) * (0.5 + rnd() * 0.5), (len - d) * 0.7, w * 0.55, delay + (d / len) * 0.4, depth + 1);
      }
      out.push({ pts, w, delay });
    };
    const deg = Math.PI / 180;
    for (const sx of [-1, 1]) {
      const ex = 0.5 * sx, ey = 0.02;
      // from the eyes: up and out, sideways, down the cheek
      for (const [angDeg, len] of [[-100, 0.75], [-55, 0.9], [-10, 0.75], [35, 0.7]]) {
        const ang = sx > 0 ? angDeg * deg : Math.PI - angDeg * deg;
        walk(ex + Math.cos(ang) * 0.32, ey + Math.sin(ang) * 0.2, ang, len * (0.8 + rnd() * 0.4), 0.05, rnd() * 0.15, 0);
      }
      // from the mouth corners: up toward the ears, down toward the jaw
      const mx = 0.18 + 1.35 * sx, my = 0.9;
      for (const [angDeg, len] of [[-70, 0.7], [-20, 0.6], [40, 0.7]]) {
        const ang = sx > 0 ? angDeg * deg : Math.PI - angDeg * deg;
        walk(mx, my, ang, len * (0.8 + rnd() * 0.4), 0.05, 0.1 + rnd() * 0.15, 0);
      }
    }
    // from under the mouth: down the chin
    for (const angDeg of [70, 95, 115]) walk(0.18 + (rnd() - 0.5) * 0.4, 2.0, angDeg * deg, 0.5 + rnd() * 0.3, 0.05, 0.12, 0);
    return out;
  }

  window.LMOverlay = { Overlay, demonShapes, eyeAlmond, smoothPath };
})();

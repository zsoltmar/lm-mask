// LM Mask — the inflatable "foam hand" headpiece.
//
// The mark's four shapes become inflated chambers (three fingers, a thumb + swoosh base, and a palm that
// fills the space between them). Each chamber has its own puffy height profile; taking the max of the
// profiles gives one welded inflatable with natural creases where chambers meet. A scalloped seam runs
// around the outer edge. The solid is polygonised with surface nets and shaded with analytic normals.
//
// Units: SVG units of the 72-unit mark. Build space is SVG (x right, y down); the returned mesh is in
// mask-local world space: X = x - CX, Y = CY - y, Z toward the viewer.
(function (THREE) {
  'use strict';
  const S = window.LMSvg;
  const CX = S.VIEW.w / 2, CY = S.VIEW.h / 2;

  // ------------------------------------------------------------------ shape data (from the SVG path)
  const BAR = {
    short: { a: [21.517, 50.324], b: [27.576, 28.410], hw: 4.677 },
    tall: { a: [37.891, 50.259], b: [46.994, 17.170], hw: 4.690 },
    right: { a: [54.284, 50.198], b: [66.543, 5.854], hw: 4.650 },
  };
  function swooshAxis() {
    const pts = [];
    const tip = [8.05, 39.81], knee = [6.29, 46.263];
    pts.push(tip, knee);
    const P0 = knee, P1 = [3.65, 56.23], P2 = [11.16, 66.13], P3 = [21.52, 66.13];
    for (let i = 1; i <= 16; i++) {
      const t = i / 16, u = 1 - t;
      pts.push([
        u * u * u * P0[0] + 3 * u * u * t * P1[0] + 3 * u * t * t * P2[0] + t * t * t * P3[0],
        u * u * u * P0[1] + 3 * u * u * t * P1[1] + 3 * u * t * t * P2[1] + t * t * t * P3[1],
      ]);
    }
    pts.push([49.893, 66.13]);
    return pts;
  }

  const DEFAULTS = {
    grid: 0.3,            // polygonisation cell size (units)
    pad: 4.6,             // white border around the print on the sides
    tip: { short: 4.6, tall: 2.8, right: 1.5, thumb: 5.2 }, // extra length of each finger tip beyond the print
    edgeRoll: 3.7,        // radius of the rolled edge
    fingerDome: 1.35, fingerDomeR: 6.5,
    palmDome: 0.75, palmDomeR: 12,
    palmLift: -0.25,      // palm sits a touch lower than the fingers so the welds read
    backScale: 0.5,       // back sheet thickness relative to the front
    pleatPeriod: 3.1,     // scalloped seam: distance between pleats
    pleatDepth: 0,        // scalloped seam depth (0 = smooth edge; ~0.4 for a pleated pool-toy seam)
    pleatBand: 3.0,       // how far into the surface the pleat grooves reach
    creaseSoft: 0.35,     // softening of chamber welds
    printSize: 2048,
  };

  // Palm: a closed smooth blob that fills the area under and between the fingers (SVG coords).
  const PALM_CTRL = [[6.5, 46], [17, 41], [33, 40], [49, 39], [61, 42], [66.5, 52], [65.5, 64], [58.5, 72.5], [44, 74.5], [24, 74.5], [11, 70], [4.5, 59]];

  // ------------------------------------------------------------------ 2D distance helpers
  function segDist(px, py, ax, ay, bx, by) {
    const pax = px - ax, pay = py - ay, bax = bx - ax, bay = by - ay;
    let h = (pax * bax + pay * bay) / (bax * bax + bay * bay);
    h = h < 0 ? 0 : h > 1 ? 1 : h;
    const dx = pax - bax * h, dy = pay - bay * h;
    return Math.sqrt(dx * dx + dy * dy);
  }
  function polylineDist(px, py, pts) {
    let d = Infinity;
    for (let i = 0; i < pts.length - 1; i++) {
      const v = segDist(px, py, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]);
      if (v < d) d = v;
    }
    return d;
  }
  function polygonSigned(px, py, poly) { // positive inside
    let d = Infinity, inside = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const [xi, yi] = poly[i], [xj, yj] = poly[j];
      const v = segDist(px, py, xj, yj, xi, yi);
      if (v < d) d = v;
      if ((yi > py) !== (yj > py) && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside ? d : -d;
  }
  function catmullClosed(ctrl, per = 14) {
    const out = [], n = ctrl.length;
    for (let i = 0; i < n; i++) {
      const p0 = ctrl[(i - 1 + n) % n], p1 = ctrl[i], p2 = ctrl[(i + 1) % n], p3 = ctrl[(i + 2) % n];
      for (let k = 0; k < per; k++) {
        const t = k / per, t2 = t * t, t3 = t2 * t;
        out.push([0, 1].map((c) => 0.5 * (2 * p1[c] + (-p0[c] + p2[c]) * t + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2 + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3)));
      }
    }
    return out;
  }
  const smax = (a, b, k) => { // polynomial smooth max
    if (k <= 0) return Math.max(a, b);
    const h = Math.max(k - Math.abs(a - b), 0) / k;
    return Math.max(a, b) + h * h * k * 0.25;
  };

  // ------------------------------------------------------------------ height field
  function buildField(o) {
    const g = o.grid;
    const x0 = -9, x1 = 81, y0 = -10, y1 = 85;
    const nx = Math.round((x1 - x0) / g) + 1, ny = Math.round((y1 - y0) / g) + 1;

    // chambers: signed inside distance functions (positive inside)
    const chambers = [];
    for (const key of ['short', 'tall', 'right']) {
      const b = BAR[key];
      const dx = b.b[0] - b.a[0], dy = b.b[1] - b.a[1], L = Math.hypot(dx, dy);
      const tip = [b.b[0] + (dx / L) * o.tip[key], b.b[1] + (dy / L) * o.tip[key]];
      const r = b.hw + o.pad;
      chambers.push({ kind: 'finger', f: (x, y) => r - segDist(x, y, b.a[0], b.a[1], tip[0], tip[1]) });
    }
    {
      const ax = swooshAxis();
      const dx = ax[0][0] - ax[1][0], dy = ax[0][1] - ax[1][1], L = Math.hypot(dx, dy);
      ax.unshift([ax[0][0] + (dx / L) * o.tip.thumb, ax[0][1] + (dy / L) * o.tip.thumb]);
      const r = 4.64 + o.pad;
      chambers.push({ kind: 'finger', f: (x, y) => r - polylineDist(x, y, ax) });
    }
    const palm = catmullClosed(PALM_CTRL, 12);
    chambers.push({ kind: 'palm', f: (x, y) => polygonSigned(x, y, palm) });

    const N = nx * ny;
    const sc = chambers.map(() => new Float32Array(N));
    const su = new Float32Array(N); // union signed distance
    for (let j = 0; j < ny; j++) {
      const y = y0 + j * g;
      for (let i = 0; i < nx; i++) {
        const x = x0 + i * g, id = j * nx + i;
        let u = -Infinity;
        for (let c = 0; c < chambers.length; c++) { const v = chambers[c].f(x, y); sc[c][id] = v; if (v > u) u = v; }
        su[id] = u;
      }
    }

    // ---------------------------------------------------------------- scalloped seam parameter
    // Trace the outer contour of the union (marching squares on su = 0), parametrise by arc length,
    // then give every pixel near the edge the arc-length position of its nearest contour point.
    const contour = traceContour(su, nx, ny, x0, y0, g);
    const pleat = new Float32Array(N); // 0..1, 1 at a pleat pinch
    if (contour && o.pleatDepth > 0) {
      const per = o.pleatPeriod;
      const total = contour.len[contour.len.length - 1];
      const nPleats = Math.max(8, Math.round(total / per));
      const k = (2 * Math.PI * nPleats) / total;
      // bucket grid for nearest-contour lookup
      const B = 2.0, bx = Math.ceil((x1 - x0) / B) + 1, by = Math.ceil((y1 - y0) / B) + 1;
      const buckets = Array.from({ length: bx * by }, () => []);
      for (let s = 0; s < contour.pts.length; s++) {
        const [px, py] = contour.pts[s];
        buckets[Math.floor((py - y0) / B) * bx + Math.floor((px - x0) / B)].push(s);
      }
      const band = o.pleatBand + 1.2;
      for (let j = 0; j < ny; j++) {
        for (let i = 0; i < nx; i++) {
          const id = j * nx + i, s0 = su[id];
          if (s0 < -1.2 || s0 > band) continue;
          const x = x0 + i * g, y = y0 + j * g;
          const cbx = Math.floor((x - x0) / B), cby = Math.floor((y - y0) / B);
          let best = Infinity, bs = -1;
          const R = Math.ceil(band / B) + 1;
          for (let yy = cby - R; yy <= cby + R; yy++) {
            if (yy < 0 || yy >= by) continue;
            for (let xx = cbx - R; xx <= cbx + R; xx++) {
              if (xx < 0 || xx >= bx) continue;
              for (const s of buckets[yy * bx + xx]) {
                const dx = contour.pts[s][0] - x, dy = contour.pts[s][1] - y, d = dx * dx + dy * dy;
                if (d < best) { best = d; bs = s; }
              }
            }
          }
          if (bs < 0) continue;
          const phase = 0.5 - 0.5 * Math.cos(k * contour.len[bs]);
          const w = Math.max(0, 1 - Math.max(0, s0) / o.pleatBand);
          pleat[id] = Math.pow(phase, 1.6) * w * w;
        }
      }
    }

    // ---------------------------------------------------------------- profiles → height
    const E = o.edgeRoll;
    const profile = (s, dome, domeR) => {
      if (s <= 0) return s;
      const roll = s < E ? Math.sqrt(E * E - (E - s) * (E - s)) : E;
      const t = Math.min(s / domeR, 1);
      return roll + dome * (1 - (1 - t) * (1 - t));
    };
    const H = new Float32Array(N);
    for (let id = 0; id < N; id++) {
      const pinch = o.pleatDepth * pleat[id];
      let h = -Infinity;
      for (let c = 0; c < chambers.length; c++) {
        const ch = chambers[c];
        const s = sc[c][id] - pinch;
        const v = ch.kind === 'palm' ? profile(s, o.palmDome, o.palmDomeR) + (s > 0 ? o.palmLift * Math.min(1, s / E) : 0) : profile(s, o.fingerDome, o.fingerDomeR);
        h = smax(h, v, s > 0 ? o.creaseSoft : 0);
      }
      H[id] = h;
    }
    // light blur inside the shape only (anti-alias the welds), keep the outside linear
    const Hb = blur(H, nx, ny, 1);
    for (let id = 0; id < N; id++) if (H[id] > 0.6) H[id] = Hb[id];

    return { H, su, nx, ny, x0, y0, g, contour };
  }

  function blur(src, nx, ny, r) {
    const tmp = new Float32Array(src.length), out = new Float32Array(src.length);
    const w = [];
    let ws = 0;
    for (let k = -r; k <= r; k++) { const v = Math.exp(-(k * k) / (2 * Math.max(0.6, r * 0.6) ** 2)); w.push(v); ws += v; }
    for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
      let a = 0;
      for (let k = -r; k <= r; k++) a += src[j * nx + Math.min(nx - 1, Math.max(0, i + k))] * w[k + r];
      tmp[j * nx + i] = a / ws;
    }
    for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
      let a = 0;
      for (let k = -r; k <= r; k++) a += tmp[Math.min(ny - 1, Math.max(0, j + k)) * nx + i] * w[k + r];
      out[j * nx + i] = a / ws;
    }
    return out;
  }

  // Marching squares on f = 0, returns the longest closed loop resampled every ~0.25 units.
  function traceContour(f, nx, ny, x0, y0, g) {
    const segs = [];
    const P = (i, j) => f[j * nx + i];
    const lerp = (i0, j0, i1, j1) => {
      const a = P(i0, j0), b = P(i1, j1), t = a / (a - b);
      return [x0 + (i0 + (i1 - i0) * t) * g, y0 + (j0 + (j1 - j0) * t) * g];
    };
    for (let j = 0; j < ny - 1; j++) for (let i = 0; i < nx - 1; i++) {
      const c = (P(i, j) > 0 ? 1 : 0) | (P(i + 1, j) > 0 ? 2 : 0) | (P(i + 1, j + 1) > 0 ? 4 : 0) | (P(i, j + 1) > 0 ? 8 : 0);
      if (c === 0 || c === 15) continue;
      const e = { t: () => lerp(i, j, i + 1, j), r: () => lerp(i + 1, j, i + 1, j + 1), b: () => lerp(i, j + 1, i + 1, j + 1), l: () => lerp(i, j, i, j + 1) };
      const add = (a, b) => segs.push([e[a](), e[b]()]);
      switch (c) {
        case 1: case 14: add('l', 't'); break;
        case 2: case 13: add('t', 'r'); break;
        case 3: case 12: add('l', 'r'); break;
        case 4: case 11: add('r', 'b'); break;
        case 6: case 9: add('t', 'b'); break;
        case 7: case 8: add('l', 'b'); break;
        case 5: add('l', 't'); add('r', 'b'); break;
        case 10: add('t', 'r'); add('l', 'b'); break;
      }
    }
    if (!segs.length) return null;
    // chain segments by endpoint hashing
    const key = (p) => Math.round(p[0] * 1000) + ',' + Math.round(p[1] * 1000);
    const adj = new Map();
    segs.forEach((s, idx) => { for (const p of s) { const k = key(p); if (!adj.has(k)) adj.set(k, []); adj.get(k).push(idx); } });
    const used = new Uint8Array(segs.length);
    let best = null;
    for (let s0 = 0; s0 < segs.length; s0++) {
      if (used[s0]) continue;
      used[s0] = 1;
      const loop = [segs[s0][0], segs[s0][1]];
      for (;;) {
        const end = loop[loop.length - 1];
        const cand = (adj.get(key(end)) || []).find((q) => !used[q]);
        if (cand === undefined) break;
        used[cand] = 1;
        const s = segs[cand];
        loop.push(key(s[0]) === key(end) ? s[1] : s[0]);
      }
      if (!best || loop.length > best.length) best = loop;
    }
    // resample
    const pts = [best[0]], len = [0];
    let acc = 0;
    for (let i = 1; i < best.length; i++) {
      const d = Math.hypot(best[i][0] - best[i - 1][0], best[i][1] - best[i - 1][1]);
      acc += d;
      if (acc - len[len.length - 1] >= 0.2) { pts.push(best[i]); len.push(acc); }
    }
    return { pts, len };
  }

  // ------------------------------------------------------------------ surface nets
  function polygonise(field, o) {
    const { H, nx, ny, x0, y0, g } = field;
    const zb = -Math.ceil(7 * o.backScale / g + 2) * g, zt = 8.5;
    const nz = Math.round((zt - zb) / g) + 1;
    const back = o.backScale;
    const F = new Float32Array(nx * ny * nz);
    for (let k = 0; k < nz; k++) {
      const z = zb + k * g;
      for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
        const h = H[j * nx + i];
        F[(k * ny + j) * nx + i] = z >= 0 ? z - h : -z - (h > 0 ? h * back : h);
      }
    }
    const idx = (i, j, k) => (k * ny + j) * nx + i;
    const cellV = new Int32Array(nx * ny * nz).fill(-1);
    const pos = [];
    const tris = [];
    const E = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]];
    const cv = new Float32Array(8);
    for (let k = 0; k < nz - 1; k++) for (let j = 0; j < ny - 1; j++) for (let i = 0; i < nx - 1; i++) {
      let mask = 0;
      for (let c = 0; c < 8; c++) {
        const v = F[idx(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1))];
        cv[c] = v;
        if (v < 0) mask |= 1 << c;
      }
      if (mask === 0 || mask === 255) continue;
      let sx = 0, sy = 0, sz = 0, n = 0;
      for (const [a, b] of E) {
        if (((mask >> a) & 1) === ((mask >> b) & 1)) continue;
        const t = cv[a] / (cv[a] - cv[b]);
        sx += (a & 1) + ((b & 1) - (a & 1)) * t;
        sy += ((a >> 1) & 1) + (((b >> 1) & 1) - ((a >> 1) & 1)) * t;
        sz += ((a >> 2) & 1) + (((b >> 2) & 1) - ((a >> 2) & 1)) * t;
        n++;
      }
      const vi = pos.length / 3;
      cellV[idx(i, j, k)] = vi;
      pos.push(x0 + (i + sx / n) * g, y0 + (j + sy / n) * g, zb + (k + sz / n) * g);
      // faces for the three edges leaving corner 0
      const inside0 = mask & 1;
      const quad = (a, b, c, d) => { if (inside0) tris.push(a, b, c, a, c, d); else tris.push(a, c, b, a, d, c); };
      if (((mask >> 1) & 1) !== inside0 && j > 0 && k > 0) quad(vi, cellV[idx(i, j - 1, k)], cellV[idx(i, j - 1, k - 1)], cellV[idx(i, j, k - 1)]);
      if (((mask >> 2) & 1) !== inside0 && i > 0 && k > 0) quad(vi, cellV[idx(i, j, k - 1)], cellV[idx(i - 1, j, k - 1)], cellV[idx(i - 1, j, k)]);
      if (((mask >> 4) & 1) !== inside0 && i > 0 && j > 0) quad(vi, cellV[idx(i - 1, j, k)], cellV[idx(i - 1, j - 1, k)], cellV[idx(i, j - 1, k)]);
    }
    return { pos, tris };
  }

  // bilinear sample of a 2D grid at SVG (x, y)
  function sampler(field, arr) {
    const { nx, ny, x0, y0, g } = field;
    return (x, y) => {
      const fx = (x - x0) / g, fy = (y - y0) / g;
      const i = Math.max(0, Math.min(nx - 2, Math.floor(fx))), j = Math.max(0, Math.min(ny - 2, Math.floor(fy)));
      const tx = Math.min(1, Math.max(0, fx - i)), ty = Math.min(1, Math.max(0, fy - j));
      const a = arr[j * nx + i], b = arr[j * nx + i + 1], c = arr[(j + 1) * nx + i], d = arr[(j + 1) * nx + i + 1];
      return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
    };
  }

  // ------------------------------------------------------------------ textures
  function printCanvas(field, size) {
    const { nx, ny, x0, y0, g } = field;
    const w = (nx - 1) * g, h = (ny - 1) * g;
    const cv = document.createElement('canvas');
    cv.width = cv.height = size;
    const ctx = cv.getContext('2d');
    ctx.clearRect(0, 0, size, size);
    ctx.save();
    ctx.scale(size / w, size / h);
    ctx.translate(-x0, -y0);
    const grad = ctx.createLinearGradient(1.116, 0, 71.19, 0);
    grad.addColorStop(0.0591, '#00b3c0');
    grad.addColorStop(1, '#009ce4');
    ctx.fillStyle = grad;
    ctx.fill(new Path2D(S.MARK_PATH));
    ctx.restore();
    return { canvas: cv, w, h };
  }

  function aoCanvas(field) {
    const { H, nx, ny } = field;
    const Hb = blur(H, nx, ny, 9);
    const cv = document.createElement('canvas');
    cv.width = nx; cv.height = ny;
    const ctx = cv.getContext('2d');
    const img = ctx.createImageData(nx, ny);
    for (let id = 0; id < nx * ny; id++) {
      const h = H[id];
      const occl = Math.max(0, Hb[id] - h);
      const ao = Math.max(0.35, 1 - occl * 0.55);
      const v = Math.round(ao * 255);
      img.data[id * 4] = img.data[id * 4 + 1] = img.data[id * 4 + 2] = v;
      img.data[id * 4 + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
    return cv;
  }

  // ------------------------------------------------------------------ material
  function makeMaterial(printTex, aoTex, uniforms) {
    const m = new THREE.MeshPhysicalMaterial({
      color: 0xf5f6f8,
      roughness: 0.42,
      metalness: 0,
      clearcoat: 0.7,
      clearcoatRoughness: 0.2,
      sheen: 0.25,
      sheenRoughness: 0.55,
      sheenColor: new THREE.Color(0xffffff),
      aoMap: aoTex,
      aoMapIntensity: 1.0,
    });
    m.onBeforeCompile = (sh) => {
      Object.assign(sh.uniforms, uniforms, { uPrint: { value: printTex } });
      sh.vertexShader = sh.vertexShader
        .replace('#include <common>', '#include <common>\nattribute float aFront;\nvarying float vFront;\nvarying vec2 vPUv;')
        .replace('#include <uv_vertex>', '#include <uv_vertex>\nvFront = aFront;\nvPUv = uv;');
      sh.fragmentShader = sh.fragmentShader
        .replace('#include <common>', [
          '#include <common>',
          'uniform sampler2D uPrint; uniform sampler2D uOverlay; uniform sampler2D uArt; uniform vec2 uRes;',
          'uniform float uInk; uniform float uPrintHide; uniform float uScare; uniform float uBody; uniform float uInvert;',
          'uniform vec3 uInkColor; uniform vec3 uBodyColor; uniform vec3 uVinylColor; uniform vec3 uPaintColor; uniform vec3 uPaintGlow; uniform vec3 uGlowColor;',
          'varying float vFront; varying vec2 vPUv;',
          'float gPrintCov; float gFace; float gInkFace;',
        ].join('\n'))
        .replace('#include <map_fragment>', [
          '#include <map_fragment>',
          'vec4 pr = texture2D(uPrint, vPUv);',
          'gPrintCov = pr.a * vFront * (1.0 - uPrintHide);',
          'vec3 printCol = mix(pr.rgb * 0.86, uInkColor, uInk);',
          'diffuseColor.rgb = mix(diffuseColor.rgb, printCol, gPrintCov);',
          // scare: the whole logo (vinyl and print) turns one colour — black, or white when inverted —
          // and the face prints in the other
          'vec3 bodyCol = mix(uBodyColor, uVinylColor, uInvert);',
          'vec3 faceCol = mix(uPaintColor, uInkColor, uInvert);',
          'diffuseColor.rgb = mix(diffuseColor.rgb, bodyCol, uBody);',
          'vec4 ov = texture2D(uOverlay, gl_FragCoord.xy / uRes);',
          // face = the artwork, or the drawn fallback (R); the fallback's fangs (B) take the body colour
          'float gVoid = ov.b * uScare;',
          'gFace = max(texture2D(uArt, gl_FragCoord.xy / uRes).r, ov.r) * uScare * (1.0 - gVoid);',
          'gInkFace = gFace * uInvert;',
          'diffuseColor.rgb = mix(diffuseColor.rgb, faceCol, gFace);',
          'diffuseColor.rgb = mix(diffuseColor.rgb, bodyCol, gVoid);',
        ].join('\n'))
        .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.5, gPrintCov * uInk);\nroughnessFactor = mix(roughnessFactor, 0.6, gFace);')
        .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\ntotalEmissiveRadiance += uGlowColor * ov.g * uScare;\ntotalEmissiveRadiance += uPaintGlow * gFace * (1.0 - uInvert);')
        // A black face is ink: no clearcoat, no specular, so it reads pitch black under any light. Black
        // vinyl keeps its gloss (that is what shows its shape) but loses most of the white sheen.
        .replace('#include <lights_physical_fragment>', '#include <lights_physical_fragment>\nmaterial.clearcoat *= 1.0 - gInkFace;\nmaterial.specularColor *= 1.0 - gInkFace;\nmaterial.specularF90 *= 1.0 - gInkFace;\nmaterial.sheenColor *= (1.0 - gInkFace) * (1.0 - 0.8 * uBody * (1.0 - uInvert) * (1.0 - gFace));');
    };
    return m;
  }

  // ------------------------------------------------------------------ public
  function buildInflatable(opts = {}) {
    const o = { ...DEFAULTS, ...opts, tip: { ...DEFAULTS.tip, ...(opts.tip || {}) } };
    const t0 = performance.now();
    const field = buildField(o);
    const t1 = performance.now();
    const { pos, tris } = polygonise(field, o);
    const t2 = performance.now();

    const nV = pos.length / 3;
    const hx = new Float32Array(field.H.length), hy = new Float32Array(field.H.length);
    const { H, nx, ny, g } = field;
    for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
      const id = j * nx + i;
      const l = H[j * nx + Math.max(0, i - 1)], r = H[j * nx + Math.min(nx - 1, i + 1)];
      const u = H[Math.max(0, j - 1) * nx + i], d = H[Math.min(ny - 1, j + 1) * nx + i];
      hx[id] = (r - l) / (2 * g); hy[id] = (d - u) / (2 * g);
    }
    const sHx = sampler(field, hx), sHy = sampler(field, hy);
    const w = (field.nx - 1) * g, h = (field.ny - 1) * g;
    const P = new Float32Array(nV * 3), Nn = new Float32Array(nV * 3), UV = new Float32Array(nV * 2), FR = new Float32Array(nV);
    for (let v = 0; v < nV; v++) {
      const x = pos[v * 3], y = pos[v * 3 + 1], z = pos[v * 3 + 2];
      P[v * 3] = x - CX; P[v * 3 + 1] = CY - y; P[v * 3 + 2] = z;
      const gx = sHx(x, y), gy = sHy(x, y);
      let nxv, nyv, nzv;
      if (z >= 0) { nxv = -gx; nyv = gy; nzv = 1; } else { nxv = -gx * o.backScale; nyv = gy * o.backScale; nzv = -1; }
      const L = Math.hypot(nxv, nyv, nzv);
      Nn[v * 3] = nxv / L; Nn[v * 3 + 1] = nyv / L; Nn[v * 3 + 2] = nzv / L;
      UV[v * 2] = (x - field.x0) / w; UV[v * 2 + 1] = 1 - (y - field.y0) / h;
      FR[v] = Math.min(1, Math.max(0, (z - 0.4) / 1.2));
    }
    // orientation check: face normals should agree with the analytic normals
    let agree = 0;
    for (let t = 0; t < tris.length; t += 30) {
      const a = tris[t] * 3, b = tris[t + 1] * 3, c = tris[t + 2] * 3;
      const ux = P[b] - P[a], uy = P[b + 1] - P[a + 1], uz = P[b + 2] - P[a + 2];
      const vx = P[c] - P[a], vy = P[c + 1] - P[a + 1], vz = P[c + 2] - P[a + 2];
      const fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx;
      agree += fx * Nn[a] + fy * Nn[a + 1] + fz * Nn[a + 2] > 0 ? 1 : -1;
    }
    if (agree < 0) for (let t = 0; t < tris.length; t += 3) { const s = tris[t + 1]; tris[t + 1] = tris[t + 2]; tris[t + 2] = s; }

    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(P, 3));
    // Normals: analytic (height-field gradient) on the face of each chamber, true mesh normals on the
    // rolled edge where the profile turns vertical and the gradient grid would band.
    {
      const tmp = new THREE.BufferGeometry();
      tmp.setAttribute('position', new THREE.BufferAttribute(P, 3));
      tmp.setIndex(nV > 65535 ? new THREE.Uint32BufferAttribute(tris, 1) : new THREE.Uint16BufferAttribute(tris, 1));
      tmp.computeVertexNormals();
      const MN = tmp.attributes.normal.array;
      for (let v = 0; v < nV; v++) {
        const z = P[v * 3 + 2];
        const w = z < 0 ? 1 : Math.min(1, Math.max(0, 1 - z / (0.85 * o.edgeRoll)));
        const ww = w * w * (3 - 2 * w);
        let x = Nn[v * 3] * (1 - ww) + MN[v * 3] * ww, y = Nn[v * 3 + 1] * (1 - ww) + MN[v * 3 + 1] * ww, zz = Nn[v * 3 + 2] * (1 - ww) + MN[v * 3 + 2] * ww;
        const L = Math.hypot(x, y, zz) || 1;
        Nn[v * 3] = x / L; Nn[v * 3 + 1] = y / L; Nn[v * 3 + 2] = zz / L;
      }
      tmp.dispose();
    }
    geo.setAttribute('normal', new THREE.BufferAttribute(Nn, 3));
    geo.setAttribute('uv', new THREE.BufferAttribute(UV, 2));
    geo.setAttribute('aFront', new THREE.BufferAttribute(FR, 1));
    geo.setIndex(nV > 65535 ? new THREE.Uint32BufferAttribute(tris, 1) : new THREE.Uint16BufferAttribute(tris, 1));
    geo.computeBoundingSphere();

    const pc = printCanvas(field, o.printSize);
    const printTex = new THREE.CanvasTexture(pc.canvas);
    printTex.colorSpace = THREE.SRGBColorSpace;
    printTex.anisotropy = 8;
    printTex.premultiplyAlpha = false;
    const aoTex = new THREE.CanvasTexture(aoCanvas(field));
    aoTex.colorSpace = THREE.NoColorSpace;

    const uniforms = {
      uOverlay: { value: null },
      uArt: { value: null },
      uRes: { value: new THREE.Vector2(1280, 720) },
      uInk: { value: 0 },
      uPrintHide: { value: 0 },
      uScare: { value: 0 },
      uBody: { value: 0 },
      uInvert: { value: 0 },
      uInkColor: { value: new THREE.Color(0x060607) },
      uBodyColor: { value: new THREE.Color(0x0c0c10) },
      uVinylColor: { value: new THREE.Color(0xf5f6f8) },
      uPaintColor: { value: new THREE.Color(0xf4f5f7) },
      uPaintGlow: { value: new THREE.Color(0.42, 0.44, 0.48) },
      uGlowColor: { value: new THREE.Color(6.0, 0.25, 0.08) },
    };
    const material = makeMaterial(printTex, aoTex, uniforms);
    const mesh = new THREE.Mesh(geo, material);
    mesh.name = 'lmInflatable';

    const heightAt = sampler(field, field.H);
    const t3 = performance.now();
    return {
      mesh, material, uniforms, field, options: o,
      stats: { field: Math.round(t1 - t0), mesh: Math.round(t2 - t1), finish: Math.round(t3 - t2), verts: nV, tris: tris.length / 3 },
      // front-surface point in mask-local world coords for an SVG coordinate
      surfacePoint(x, y, lift = 0) { return new THREE.Vector3(x - CX, CY - y, Math.max(0, heightAt(x, y)) + lift); },
      heightAt,
    };
  }

  window.LMInflate = { buildInflatable, DEFAULTS, BAR, CX, CY };
})(window.THREE);

// The wizard mascot: a soft lavender bean head that swallows your whole head, a starry wizard hat, gold
// aviators that hug the face and react to your eyes and brows, and your real mouth where its smile goes.
// Scare turns it into a dark wizard (the renderer adds the laser eyes and the lightning).
//
// Units: 1 = your inter-ocular distance. Head space: origin between your eyes, x right (screen right when
// facing the camera), y up, z toward the camera.
(function (THREE) {
  'use strict';

  // ------------------------------------------------------------------ small helpers
  const canvas = (w, h) => { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; };
  const tex = (c, srgb = true) => { const t = new THREE.CanvasTexture(c); t.colorSpace = srgb ? THREE.SRGBColorSpace : THREE.NoColorSpace; t.anisotropy = 8; return t; };
  function rng(seed) { let s = seed >>> 0; return () => { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  function star(ctx, x, y, r, sx = 1, rot = 0) {
    ctx.save(); ctx.translate(x, y); ctx.scale(sx, 1); ctx.rotate(rot);
    ctx.beginPath();
    for (let i = 0; i < 10; i++) {
      const a = -Math.PI / 2 + (i * Math.PI) / 5, rr = i % 2 ? r * 0.47 : r;
      if (i) ctx.lineTo(Math.cos(a) * rr, Math.sin(a) * rr); else ctx.moveTo(Math.cos(a) * rr, Math.sin(a) * rr);
    }
    ctx.closePath(); ctx.lineJoin = 'round'; ctx.lineWidth = r * 0.22; ctx.fill(); ctx.stroke();
    ctx.restore();
  }
  // critically damped spring toward a target (keeps the glasses lively, never jittery)
  class Spring { constructor(v = 0, w = 18) { this.v = v; this.d = 0; this.w = w; } step(target, dt) { const w = this.w, a = w * w * (target - this.v) - 2 * w * this.d; this.d += a * dt; this.v += this.d * dt; return this.v; } }

  // ------------------------------------------------------------------ head
  // A soft "bean" big enough to swallow a whole human head (ears, hair, back of the skull) from any angle:
  // squircle cross-sections, full cheeks, a rounded-flat top, a touch wider at the bottom.
  const HEAD = { c: [0, -0.55, -1.25], r: [1.95, 2.3, 1.95], taper: 0.04, n: 2.5 };
  const SKIN = 0xc7b3fb; // lavender
  function squircle(x, y, z) {
    const n = HEAD.n, d = Math.pow(Math.pow(Math.abs(x), n) + Math.pow(Math.abs(y), n) + Math.pow(Math.abs(z), n), 1 / n) || 1;
    return [x / d, y / d, z / d];
  }
  function headSurfaceZ(x, y) { // front surface z of the head at (x, y), or null outside
    const [cx, cy, cz] = HEAD.c, [rx, ry, rz] = HEAD.r, n = HEAD.n;
    const ny = (y - cy) / ry, k = 1 + HEAD.taper * -ny;
    const q = 1 - Math.pow(Math.abs((x - cx) / (rx * k)), n) - Math.pow(Math.abs(ny), n);
    return q <= 0 ? null : cz + rz * k * Math.pow(q, 1 / n);
  }
  function headHalfWidth(y, z) { // |x| of the head surface at height y and depth z
    const [, cy, cz] = HEAD.c, [rx, ry, rz] = HEAD.r, n = HEAD.n;
    const ny = (y - cy) / ry, k = 1 + HEAD.taper * -ny;
    const q = 1 - Math.pow(Math.abs(ny), n) - Math.pow(Math.abs((z - cz) / (rz * k)), n);
    return q <= 0 ? 0 : rx * k * Math.pow(q, 1 / n);
  }
  const surfZ = (x, y) => headSurfaceZ(x, y) ?? HEAD.c[2];
  function makeHead() {
    const g = new THREE.SphereGeometry(1, 160, 120);
    const p = g.attributes.position;
    for (let i = 0; i < p.count; i++) {
      const [x, y, z] = squircle(p.getX(i), p.getY(i), p.getZ(i));
      const k = 1 + HEAD.taper * -y;
      p.setXYZ(i, HEAD.c[0] + x * HEAD.r[0] * k, HEAD.c[1] + y * HEAD.r[1], HEAD.c[2] + z * HEAD.r[2] * k);
    }
    g.computeVertexNormals();
    const m = new THREE.MeshPhysicalMaterial({
      color: SKIN, roughness: 0.5, sheen: 0.8, sheenRoughness: 0.45, sheenColor: new THREE.Color(0xf1e9ff),
      clearcoat: 0.25, clearcoatRoughness: 0.35,
    });
    const mesh = new THREE.Mesh(g, m);
    mesh.name = 'wizHead';
    mesh.receiveShadow = true;
    return mesh;
  }

  // ------------------------------------------------------------------ hat
  // The cone is swept along a curved spine: up, then flopping over to the right with a rounded, drooping
  // tip. It sits low, right above the glasses, and is wide enough to swallow the top of the head.
  // tilt.x < 0 tips the front of the brim up (worn slightly back on the head), the back sits lower
  const HAT = { base: [0, 0.87, -1.25], tilt: [-0.1, 0, -0.06], R0: 2.06, Rtip: 0.11 };
  const SPINE = [[0, 0, 0], [0.05, 1.05, -0.06], [0.22, 2.05, -0.16], [0.68, 2.88, -0.26], [1.42, 3.22, -0.28], [2.08, 2.95, -0.22], [2.3, 2.56, -0.18]];
  const radiusAt = (t) => (HAT.R0 - HAT.Rtip) * Math.pow(1 - t, 1.15) + HAT.Rtip;
  function hatTextures(spineLen) {
    const W = 2048, H = 2048, c = canvas(W, H), s = canvas(W, H);
    const ctx = c.getContext('2d'), sx = s.getContext('2d');
    const gr = ctx.createLinearGradient(0, H, 0, 0);
    gr.addColorStop(0, '#2e44d8'); gr.addColorStop(0.35, '#3a5ff0'); gr.addColorStop(0.75, '#4f8af8'); gr.addColorStop(1, '#69a9ff');
    ctx.fillStyle = gr; ctx.fillRect(0, 0, W, H);
    sx.fillStyle = '#000'; sx.fillRect(0, 0, W, H);
    const R = rng(21), placed = [];
    for (let tries = 0; tries < 1200 && placed.length < 52; tries++) {
      const t = 0.05 + R() * 0.82, u = R();
      const size = (0.11 + Math.pow(R(), 1.6) * 0.26) * (1 - t * 0.5);
      const circ = 2 * Math.PI * radiusAt(t);
      const ok = placed.every((q) => { const du = Math.min(Math.abs(q.u - u), 1 - Math.abs(q.u - u)) * circ, dv = (q.t - t) * spineLen; return Math.hypot(du, dv) > (q.size + size) * 1.35; });
      if (!ok) continue;
      placed.push({ t, u, size });
      const ry = (size / spineLen) * H, stretch = (W / circ) / (H / spineLen);
      for (const [cx2, col] of [[ctx, '#fff3cd'], [sx, '#ffffff']]) {
        cx2.fillStyle = col; cx2.strokeStyle = col;
        for (const dx of [0, -W, W]) star(cx2, u * W + dx, H - t * H, ry, stretch, (R() - 0.5) * 0.7);
      }
    }
    return { map: tex(c), stars: tex(s, false) };
  }
  function sweptCone() {
    const curve = new THREE.CatmullRomCurve3(SPINE.map((p) => new THREE.Vector3(...p)), false, 'centripetal', 0.5);
    const NS = 150, NR = 104, len = curve.getLength();
    const pos = [], uv = [], idx = [];
    const fwd = new THREE.Vector3(0, 0, 1);
    for (let i = 0; i <= NS; i++) {
      const t = i / NS;
      const P = curve.getPointAt(t), T = curve.getTangentAt(t).normalize();
      const F = fwd.clone().sub(T.clone().multiplyScalar(fwd.dot(T))).normalize();
      const S = new THREE.Vector3().crossVectors(T, F).normalize();
      const r = radiusAt(t);
      for (let j = 0; j <= NR; j++) {
        const th = (j / NR) * Math.PI * 2 - Math.PI; // seam at the back
        const n = F.clone().multiplyScalar(Math.cos(th)).add(S.clone().multiplyScalar(Math.sin(th)));
        const v = P.clone().add(n.multiplyScalar(r));
        pos.push(v.x, v.y, v.z); uv.push(j / NR, t);
      }
    }
    for (let i = 0; i < NS; i++) for (let j = 0; j < NR; j++) { const a = i * (NR + 1) + j, b = a + NR + 1; idx.push(a, b, a + 1, a + 1, b, b + 1); }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    g.setIndex(idx);
    g.computeVertexNormals();
    // faces must point outward
    const N = g.attributes.normal, k = Math.floor(NS / 3) * (NR + 1) + Math.floor(NR / 4), P0 = curve.getPointAt(Math.floor(NS / 3) / NS);
    const out = new THREE.Vector3(pos[k * 3] - P0.x, pos[k * 3 + 1] - P0.y, pos[k * 3 + 2] - P0.z);
    if (out.dot(new THREE.Vector3(N.getX(k), N.getY(k), N.getZ(k))) < 0) {
      for (let i = 0; i < idx.length; i += 3) { const s2 = idx[i + 1]; idx[i + 1] = idx[i + 2]; idx[i + 2] = s2; }
      g.setIndex(idx); g.computeVertexNormals();
    }
    return { g, curve, len };
  }
  function makeHat() {
    const grp = new THREE.Group();
    grp.name = 'wizHat';
    const cone = sweptCone();
    const { map, stars } = hatTextures(cone.len);
    const coneMat = new THREE.MeshPhysicalMaterial({
      map, emissiveMap: stars, emissive: new THREE.Color(0xff2a20), emissiveIntensity: 0,
      roughness: 0.34, clearcoat: 0.55, clearcoatRoughness: 0.22, sheen: 0.35, sheenRoughness: 0.5, sheenColor: new THREE.Color(0xb8d2ff),
    });
    const coneMesh = new THREE.Mesh(cone.g, coneMat);
    const tip = new THREE.Mesh(new THREE.SphereGeometry(HAT.Rtip, 32, 24), coneMat);
    tip.position.copy(cone.curve.getPointAt(1));
    // brim: a thick soft disc with a rolled edge that turns up slightly at the sides
    const prof = [];
    const add = (r, y) => prof.push(new THREE.Vector2(r, y));
    add(1.9, -0.09); add(2.6, -0.07); add(3.1, -0.01);
    for (let k = 0; k <= 14; k++) { const a = -Math.PI / 2 + (k / 14) * Math.PI; add(3.26 + 0.13 * Math.cos(a), 0.08 + 0.13 * Math.sin(a)); }
    add(3.1, 0.17); add(2.6, 0.1); add(1.9, 0.1);
    const brim = new THREE.LatheGeometry(prof, 200);
    const bp = brim.attributes.position;
    for (let i = 0; i < bp.count; i++) {
      const x = bp.getX(i), z = bp.getZ(i), r = Math.hypot(x, z), th = Math.atan2(z, x);
      const w = Math.max(0, (r - 2.0) / 1.4);
      bp.setY(i, bp.getY(i) + 0.17 * w * w * (0.5 + 0.5 * Math.cos(2 * th)) - 0.05 * w * w);
    }
    brim.computeVertexNormals();
    const brimMat = new THREE.MeshPhysicalMaterial({ color: 0x3a52e6, roughness: 0.36, clearcoat: 0.55, clearcoatRoughness: 0.22, sheen: 0.35, sheenColor: new THREE.Color(0xb8d2ff), side: THREE.DoubleSide });
    const brimMesh = new THREE.Mesh(brim, brimMat);
    // dark inner lining across the opening: the sliver between head and brim reads as the hat's inside
    const lining = new THREE.Mesh(new THREE.CircleGeometry(1.96, 96).rotateX(-Math.PI / 2).translate(0, 0.02, 0),
      new THREE.MeshStandardMaterial({ color: 0x121a52, roughness: 0.85, side: THREE.DoubleSide }));
    for (const m of [coneMesh, tip, brimMesh]) m.castShadow = true;
    grp.add(coneMesh, tip, brimMesh, lining);
    grp.position.set(...HAT.base);
    grp.rotation.set(...HAT.tilt);
    return { grp, coneMat, brimMat };
  }

  // ------------------------------------------------------------------ aviators
  // Built flat in "lens space" once; every frame each vertex is morphed (squash with the eyelid, lift and
  // tilt with the brow) and then laid onto the face: z follows the head's front surface, so the glasses
  // wrap around it instead of floating in front of it.
  const LENS = [[-0.46, 0.29], [-0.12, 0.345], [0.25, 0.35], [0.47, 0.27], [0.56, 0.08], [0.52, -0.16], [0.36, -0.36], [0.12, -0.48], [-0.12, -0.48], [-0.33, -0.38], [-0.47, -0.18], [-0.52, 0.06]].map(([x, y]) => [x * 1.22, y * 1.18]);
  const G = { cx: 0.7, cy: -0.03, gap: 0.12 };
  function lensTexture() {
    const W = 256, H = 256, c = canvas(W, H), ctx = c.getContext('2d');
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, '#e8287c'); g.addColorStop(0.38, '#ff5a45'); g.addColorStop(0.72, '#ffa63a'); g.addColorStop(1, '#ffd94e');
    ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    const h = ctx.createLinearGradient(0, H * 0.05, W * 0.6, H * 0.55);
    h.addColorStop(0, 'rgba(255,255,255,0)'); h.addColorStop(0.45, 'rgba(255,255,255,0.3)'); h.addColorStop(0.55, 'rgba(255,255,255,0.3)'); h.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = h; ctx.beginPath(); ctx.moveTo(0, H * 0.18); ctx.lineTo(W * 0.42, 0); ctx.lineTo(W * 0.62, 0); ctx.lineTo(0, H * 0.5); ctx.closePath(); ctx.fill();
    return tex(c);
  }
  function makeGlasses() {
    const grp = new THREE.Group();
    grp.name = 'wizGlasses';
    const gold = new THREE.MeshPhysicalMaterial({ color: 0xf0c25a, metalness: 1, roughness: 0.2, clearcoat: 0.5, clearcoatRoughness: 0.12 });
    const lensMap = lensTexture();
    const lensMat = new THREE.MeshPhysicalMaterial({ map: lensMap, emissiveMap: lensMap, emissive: new THREE.Color(0xffffff), emissiveIntensity: 0.48, roughness: 0.24, metalness: 0.05, clearcoat: 0.8, clearcoatRoughness: 0.22, envMapIntensity: 0.3, side: THREE.DoubleSide });
    const outline = new THREE.CatmullRomCurve3(LENS.map(([x, y]) => new THREE.Vector3(x, y, 0)), true, 'centripetal').getSpacedPoints(96).slice(0, 96);
    // lens: rings from the centre to the outline, so it can bend smoothly onto the face
    const RINGS = 12, NO = outline.length, BULGE = 0.07, C0 = -0.02;
    const lensBase = [], lensUV = [], lensIdx = [];
    const uvOf = (x, y) => [(x + 0.7) / 1.4, (y + 0.62) / 1.06];
    // the dome's apex sits at full bulge height, so the centre is smooth (no dimple)
    lensBase.push(0, C0, BULGE); lensUV.push(...uvOf(0, C0));
    for (let k = 1; k <= RINGS; k++) for (let j = 0; j < NO; j++) {
      const f = k / RINGS, x = outline[j].x * f, y = C0 + (outline[j].y - C0) * f;
      lensBase.push(x, y, BULGE * (1 - f * f)); // gentle outward dome
      lensUV.push(...uvOf(x, y));
    }
    for (let j = 0; j < NO; j++) lensIdx.push(0, 1 + j, 1 + ((j + 1) % NO));
    for (let k = 1; k < RINGS; k++) for (let j = 0; j < NO; j++) {
      const a = 1 + (k - 1) * NO + j, b = 1 + (k - 1) * NO + ((j + 1) % NO), c = a + NO, d = b + NO;
      lensIdx.push(a, c, b, b, c, d);
    }
    const rimBase = new THREE.TubeGeometry(new THREE.CatmullRomCurve3(outline.map((v) => v.clone()), true, 'centripetal'), 192, 0.036, 10, true);
    const sides = [];
    for (const side of [-1, 1]) {
      const lg = new THREE.BufferGeometry();
      lg.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(lensBase.length), 3));
      lg.setAttribute('uv', new THREE.Float32BufferAttribute(lensUV, 2));
      lg.setIndex(side < 0 ? lensIdx.map((v, i) => (i % 3 === 1 ? lensIdx[i + 1] : i % 3 === 2 ? lensIdx[i - 1] : v)) : lensIdx);
      const lens = new THREE.Mesh(lg, lensMat);
      const rg = rimBase.clone();
      if (side < 0) { const ix = rg.index.array; for (let i = 0; i < ix.length; i += 3) { const t = ix[i + 1]; ix[i + 1] = ix[i + 2]; ix[i + 2] = t; } }
      const rim = new THREE.Mesh(rg, gold);
      lens.castShadow = rim.castShadow = true;
      lens.frustumCulled = rim.frustumCulled = false;
      grp.add(lens, rim);
      sides.push({ side, lens, rim, rimBase: rimBase.attributes.position.array.slice(), ex: { sy: new Spring(1), sx: new Spring(1), lift: new Spring(0), tilt: new Spring(0) }, pts: {} });
    }
    // bridges and temples are rebuilt each frame from the morphed lens corners
    const tubes = { brow: null, nose: null, tL: null, tR: null };
    const setTube = (key, pts, r) => {
      const geo = new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts.map((p) => new THREE.Vector3(...p))), 40, r, 10, false);
      if (!tubes[key]) { tubes[key] = new THREE.Mesh(geo, gold); tubes[key].castShadow = true; tubes[key].frustumCulled = false; grp.add(tubes[key]); }
      else { tubes[key].geometry.dispose(); tubes[key].geometry = geo; }
    };

    // lens space → head space for one lens, with the current morph
    const place = (S, lx, ly, lz) => {
      const sx = S.ex.sx.v, sy = S.ex.sy.v, th = -S.ex.tilt.v, lift = S.ex.lift.v;
      const ax = lx * sx, ay = ly * sy;
      const rx = ax * Math.cos(th) - ay * Math.sin(th), ry = ax * Math.sin(th) + ay * Math.cos(th);
      const x = S.side * (G.cx + rx), y = G.cy + lift + ry;
      return [x, y, surfZ(x, y) + G.gap + lz];
    };
    function layout() {
      for (const S of sides) {
        const lp = S.lens.geometry.attributes.position;
        for (let i = 0; i < lp.count; i++) { const v = place(S, lensBase[i * 3], lensBase[i * 3 + 1], lensBase[i * 3 + 2]); lp.setXYZ(i, v[0], v[1], v[2]); }
        lp.needsUpdate = true; S.lens.geometry.computeVertexNormals(); S.lens.geometry.computeBoundingSphere();
        const rp = S.rim.geometry.attributes.position, rb = S.rimBase;
        for (let i = 0; i < rp.count; i++) { const v = place(S, rb[i * 3], rb[i * 3 + 1], 0.04 + rb[i * 3 + 2]); rp.setXYZ(i, v[0], v[1], v[2]); }
        rp.needsUpdate = true; S.rim.geometry.computeVertexNormals(); S.rim.geometry.computeBoundingSphere();
        S.pts = {
          centre: place(S, 0, C0, 0.12),
          topIn: place(S, -0.5, 0.39, 0.05), midIn: place(S, -0.65, 0.07, 0.05), topOut: place(S, 0.66, 0.28, 0.05),
          bottom: LENS.filter(([, y]) => y < -0.2).map(([x, y]) => place(S, x, y, 0.06)),
        };
      }
      const [L, R] = sides;
      const lift = (p, d) => [p[0], p[1] + d, p[2] + 0.02];
      setTube('brow', [L.pts.topIn, lift([(L.pts.topIn[0] * 2 + R.pts.topIn[0]) / 3, (L.pts.topIn[1] * 2 + R.pts.topIn[1]) / 3, Math.max(L.pts.topIn[2], R.pts.topIn[2])], 0.02), lift([(L.pts.topIn[0] + R.pts.topIn[0] * 2) / 3, (L.pts.topIn[1] + R.pts.topIn[1] * 2) / 3, Math.max(L.pts.topIn[2], R.pts.topIn[2])], 0.02), R.pts.topIn], 0.03);
      const nz = Math.max(L.pts.midIn[2], R.pts.midIn[2]) + 0.03;
      setTube('nose', [L.pts.midIn, [L.pts.midIn[0] * 0.4, (L.pts.midIn[1] + R.pts.midIn[1]) / 2 + 0.06, nz], [R.pts.midIn[0] * 0.4, (L.pts.midIn[1] + R.pts.midIn[1]) / 2 + 0.06, nz], R.pts.midIn], 0.03);
      for (const S of sides) {
        const [x0, y0, z0] = S.pts.topOut, pts = [[x0, y0, z0]];
        for (const zz of [z0 - 0.35, z0 - 0.9, -1.4, -2.2]) pts.push([S.side * (headHalfWidth(y0, zz) + 0.05), y0, zz]);
        setTube(S.side < 0 ? 'tL' : 'tR', pts, 0.028);
      }
    }
    // ex: { open, inner, outer } per lens (screen-left, screen-right); dt in seconds
    function update(exL, exR, dt) {
      const d = Math.min(0.05, Math.max(0.001, dt));
      sides.forEach((S, i) => {
        const ex = i === 0 ? exL : exR;
        const o = ex ? Math.max(0, Math.min(1.6, ex.open)) : 1;
        const inner = ex ? ex.inner : 0, outer = ex ? ex.outer : 0;
        S.ex.sy.step(Math.max(0.42, Math.min(1.3, 0.3 + 0.7 * o)), d);
        S.ex.sx.step(1 + 0.06 * (o - 1), d);
        S.ex.lift.step(Math.max(-0.14, Math.min(0.15, 1.5 * (inner + outer) / 2)), d);
        S.ex.tilt.step(Math.max(-0.4, Math.min(0.4, 4.0 * (inner - outer))), d);
      });
      layout();
    }
    layout();
    return {
      grp, lensMat, gold, update,
      centres: () => sides.map((S) => new THREE.Vector3(...S.pts.centre)),
      bottoms: () => sides.map((S) => S.pts.bottom.map((p) => new THREE.Vector3(...p))),
    };
  }

  // ------------------------------------------------------------------ build
  function build() {
    const head = new THREE.Group(); head.name = 'wizHeadRig';
    const headMesh = makeHead();
    const hat = makeHat();
    const glasses = makeGlasses();
    head.add(headMesh, hat.grp, glasses.grp);
    const C = (hex) => new THREE.Color(hex);
    const base = { head: headMesh.material.color.clone(), cone: C(0xffffff), brim: hat.brimMat.color.clone(), lens: C(0xffffff), gold: glasses.gold.color.clone() };
    const dark = { head: C(0x5b536f), cone: C(0x2a1838), brim: C(0x1c1028), lens: C(0x0c0c10), gold: C(0x3e3e4a) };
    let lastLevel = -1;
    return {
      head,
      mouth: new THREE.Vector3(0, -1.05, surfZ(0, -1.05) + 0.02),
      get lensCenters() { return glasses.centres(); },
      get lensBottoms() { return glasses.bottoms(); },
      expression(state, dt) { glasses.update(state && state.present ? state.exA : null, state && state.present ? state.exB : null, dt); },
      // 0 = friendly wizard … 1 = dark wizard
      setDark(level, t) {
        const k = Math.max(0, Math.min(1, level));
        if (Math.abs(k - lastLevel) > 1e-3) {
          lastLevel = k;
          headMesh.material.color.lerpColors(base.head, dark.head, k);
          hat.coneMat.color.lerpColors(base.cone, dark.cone, k);
          hat.brimMat.color.lerpColors(base.brim, dark.brim, k);
          glasses.lensMat.color.lerpColors(base.lens, dark.lens, k);
          glasses.lensMat.emissiveIntensity = 0.48 * (1 - k);
          glasses.gold.color.lerpColors(base.gold, dark.gold, k);
        }
        hat.coneMat.emissiveIntensity = k * (2.2 + 0.8 * Math.sin(t * 13) * Math.sin(t * 7.3));
      },
    };
  }

  window.LMWizard = { build, headSurfaceZ };
})(window.THREE);

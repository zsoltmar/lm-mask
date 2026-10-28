// LM Mask — face tracking state from MediaPipe FaceLandmarker results.
//
// Input: one FaceLandmarker result (478 landmarks, facial transformation matrix, blendshapes) for the
// raw (unmirrored) camera frame, plus the frame→output mapping. Output: everything the renderer needs,
// in output pixels (y down) and three.js camera space, smoothed with One-Euro filters.
(function (THREE) {
  'use strict';

  // ------------------------------------------------------------------ One-Euro filter
  class OneEuro {
    constructor(minCutoff = 1.0, beta = 0.0, dCutoff = 1.0) { this.minCutoff = minCutoff; this.beta = beta; this.dCutoff = dCutoff; this.x = null; this.dx = 0; this.t = null; }
    static alpha(cutoff, dt) { const tau = 1 / (2 * Math.PI * cutoff); return 1 / (1 + tau / dt); }
    reset() { this.x = null; this.t = null; this.dx = 0; }
    filter(x, t) {
      if (this.x === null) { this.x = x; this.t = t; return x; }
      const dt = Math.max(1e-3, t - this.t);
      this.t = t;
      const dx = (x - this.x) / dt;
      this.dx += OneEuro.alpha(this.dCutoff, dt) * (dx - this.dx);
      const cutoff = this.minCutoff + this.beta * Math.abs(this.dx);
      this.x += OneEuro.alpha(cutoff, dt) * (x - this.x);
      return this.x;
    }
  }
  // Filters a 2D point; speed is measured on the point (not per axis) so motion stays isotropic.
  class OneEuro2 {
    constructor(minCutoff, beta, dCutoff = 1.0) { this.p = new OneEuro(minCutoff, beta, dCutoff); this.minCutoff = minCutoff; this.beta = beta; this.dCutoff = dCutoff; this.x = null; this.v = 0; this.t = null; }
    reset() { this.x = null; this.t = null; this.v = 0; }
    filter(px, py, t) {
      if (this.x === null) { this.x = [px, py]; this.t = t; return this.x; }
      const dt = Math.max(1e-3, t - this.t);
      this.t = t;
      const sp = Math.hypot(px - this.x[0], py - this.x[1]) / dt;
      this.v += OneEuro.alpha(this.dCutoff, dt) * (sp - this.v);
      const a = OneEuro.alpha(this.minCutoff + this.beta * this.v, dt);
      this.x = [this.x[0] + a * (px - this.x[0]), this.x[1] + a * (py - this.x[1])];
      return this.x;
    }
  }

  // ------------------------------------------------------------------ landmark indices (MediaPipe face mesh)
  const IDX = {
    rOuter: 33, rInner: 133, rUp: 159, rDown: 145, rIris: 468,
    lOuter: 263, lInner: 362, lUp: 386, lDown: 374, lIris: 473,
    lipTop: 0, lipBottom: 17, mouthR: 61, mouthL: 291, innerTop: 13, innerBottom: 14,
    noseTip: 1, forehead: 10, chin: 152,
  };
  const LIPS_OUTER = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146];
  // eyelid margins, closed loops (upper lid then lower lid)
  const EYE_R = [33, 246, 161, 160, 159, 158, 157, 173, 133, 155, 154, 153, 145, 144, 163, 7];
  const EYE_L = [263, 466, 388, 387, 386, 385, 384, 398, 362, 382, 381, 380, 374, 373, 390, 249];

  // Frame → output mapping (aspect fill, optional mirror).
  function makeMapping(vw, vh, W, H, mirror) {
    const s = Math.max(W / vw, H / vh);
    const dw = vw * s, dh = vh * s;
    return { vw, vh, W, H, s, dw, dh, ox: (W - dw) / 2, oy: (H - dh) / 2, mirror };
  }
  const toPx = (m, p) => [m.ox + (m.mirror ? 1 - p.x : p.x) * m.dw, m.oy + p.y * m.dh, p.z * m.dw];

  // Rotation from the facial transformation matrix (canonical face → camera, y up, camera looks −z),
  // as a three.js quaternion. Layout is detected (column- vs row-major) from where the translation sits.
  const _m4 = new THREE.Matrix4(), _q = new THREE.Quaternion(), _t = new THREE.Vector3(), _s = new THREE.Vector3();
  function poseFromMatrix(data, mirror) {
    const d = Array.from(data);
    const colMajor = Math.abs(d[14]) >= Math.abs(d[11]);
    if (colMajor) _m4.fromArray(d); else _m4.set(...d);
    _m4.decompose(_t, _q, _s);
    const q = _q.clone(), t = _t.clone();
    if (mirror) { q.y = -q.y; q.z = -q.z; t.x = -t.x; } // S R S with S = diag(-1, 1, 1)
    return { q, t };
  }

  class FaceTracker {
    constructor() {
      this.f = {};
      this.qf = [0, 1, 2, 3].map(() => new OneEuro(1.4, 0.9, 1.0));
      this.iodF = new OneEuro(0.8, 0.004, 1.0);
      this.bsF = {};
      this.q = null;
      this.lastSeen = -1;
      this.state = null;
      this.earBase = { r: null, l: null };
      this.rollCheck = { n: 0, agree: 0, flip: false };
    }
    pt(key, p, t, minCutoff = 1.6, beta = 0.012) {
      let f = this.f[key];
      if (!f) f = this.f[key] = new OneEuro2(minCutoff, beta);
      return f.filter(p[0], p[1], t);
    }
    reset() { for (const k in this.f) this.f[k].reset(); this.qf.forEach((f) => f.reset()); this.iodF.reset(); this.q = null; }

    // result: { faceLandmarks: [[{x,y,z}]], facialTransformationMatrixes: [{data}], faceBlendshapes: [{categories}] }
    update(result, mapping, t) {
      const L = result && result.faceLandmarks && result.faceLandmarks[0];
      if (!L || L.length < 468) {
        if (this.state) this.state.present = false;
        return this.state;
      }
      if (this.lastSeen >= 0 && t - this.lastSeen > 0.5) this.reset();
      this.lastSeen = t;
      const m = mapping;
      const P = (i) => toPx(m, L[i]);
      // screen-left / screen-right eye (person's right eye is screen-left unless mirrored)
      const RE = { o: IDX.rOuter, i: IDX.rInner, u: IDX.rUp, d: IDX.rDown, iris: IDX.rIris, base: 'r', loop: EYE_R };
      const LE = { o: IDX.lOuter, i: IDX.lInner, u: IDX.lUp, d: IDX.lDown, iris: IDX.lIris, base: 'l', loop: EYE_L };
      const A = m.mirror ? LE : RE;
      const B = m.mirror ? RE : LE;
      const eye = (E, tag) => {
        const o = this.pt(tag + 'o', P(E.o), t), i = this.pt(tag + 'i', P(E.i), t);
        const up = this.pt(tag + 'u', P(E.u), t, 3.0, 0.03), dn = this.pt(tag + 'd', P(E.d), t, 3.0, 0.03);
        const iris = this.pt(tag + 'iris', P(E.iris), t, 2.5, 0.03);
        const c = [(o[0] + i[0]) / 2, (o[1] + i[1]) / 2];
        // the lid margin, filtered fast so blinks and squints come through like the lips do
        const lids = E.loop.map((idx, k) => this.pt(tag + 'lid' + k, P(idx), t, 3.2, 0.04));
        return { outer: o, inner: i, up, down: dn, iris, center: c, lids, width: Math.hypot(o[0] - i[0], o[1] - i[1]) };
      };
      const eA = eye(A, 'A'), eB = eye(B, 'B');
      // yaw-invariant inter-ocular distance (3D, eye-centre from corners)
      const c3 = (E) => { const o = P(E.o), i = P(E.i); return [(o[0] + i[0]) / 2, (o[1] + i[1]) / 2, (o[2] + i[2]) / 2]; };
      const a3 = c3(A), b3 = c3(B);
      const iodRaw = Math.hypot(a3[0] - b3[0], a3[1] - b3[1], a3[2] - b3[2]);
      const iod = this.iodF.filter(iodRaw, t);
      const mid = [(eA.center[0] + eB.center[0]) / 2, (eA.center[1] + eB.center[1]) / 2];
      const ex = [eB.center[0] - eA.center[0], eB.center[1] - eA.center[1]];
      const roll2d = Math.atan2(ex[1], ex[0]); // image angle of the eye line (y down)

      // rotation
      let q = null;
      const M = result.facialTransformationMatrixes && result.facialTransformationMatrixes[0];
      if (M && M.data) {
        const pose = poseFromMatrix(M.data, m.mirror);
        q = pose.q;
        // safety net: roll from the matrix must agree with the eye line, else flip handedness
        const e = new THREE.Euler().setFromQuaternion(q, 'YXZ');
        const rollM = -e.z; // camera y up → image y down
        if (Math.abs(roll2d) > 0.08) {
          this.rollCheck.n++;
          if (Math.sign(rollM) === Math.sign(roll2d)) this.rollCheck.agree++;
          if (this.rollCheck.n >= 15) this.rollCheck.flip = this.rollCheck.agree / this.rollCheck.n < 0.3;
        }
        if (this.rollCheck.flip) { q.y = -q.y; q.z = -q.z; }
      } else {
        q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), -roll2d);
      }
      if (this.q && this.q.dot(q) < 0) { q.x = -q.x; q.y = -q.y; q.z = -q.z; q.w = -q.w; }
      const qs = [q.x, q.y, q.z, q.w].map((v, k) => this.qf[k].filter(v, t));
      this.q = new THREE.Quaternion(qs[0], qs[1], qs[2], qs[3]).normalize();

      // mouth
      const lips = LIPS_OUTER.map((i, k) => this.pt('lip' + k, P(i), t, 2.2, 0.02));
      const lipTop = this.pt('lipTop', P(IDX.lipTop), t, 2.2, 0.02);

      // blendshapes
      const bs = {};
      const cats = result.faceBlendshapes && result.faceBlendshapes[0] && result.faceBlendshapes[0].categories;
      if (cats) for (const c of cats) {
        let f = this.bsF[c.categoryName];
        if (!f) f = this.bsF[c.categoryName] = new OneEuro(4.0, 2.0, 1.0);
        bs[c.categoryName] = f.filter(c.score, t);
      }
      // eye aspect ratios with a slow baseline (for "eyes wide")
      const ear = (E) => { const u = P(E.u), d = P(E.d), o = P(E.o), i = P(E.i); return Math.hypot(u[0] - d[0], u[1] - d[1]) / Math.max(1, Math.hypot(o[0] - i[0], o[1] - i[1])); };
      const earA = ear(A), earB = ear(B);
      const base = this.earBase;
      const upd = (k, v) => { if (base[k] === null) base[k] = v; else if (v < base[k] * 1.12) base[k] += (v - base[k]) * 0.01; };
      upd(A.base, earA); upd(B.base, earB);
      const wideRatio = ((earA / base[A.base]) + (earB / base[B.base])) / 2;
      // per-eye expression for the wizard's glasses: openness (1 = relaxed) and brow raise (eye spans,
      // relative to your own resting brow), split into inner and outer ends of the brow
      const iod2 = Math.max(1, Math.hypot(eA.center[0] - eB.center[0], eA.center[1] - eB.center[1]));
      const up = [Math.sin(roll2d), -Math.cos(roll2d)]; // face "up" in image space
      const browH = (ids, E) => { let x = 0, y = 0; for (const i of ids) { const q = P(i); x += q[0]; y += q[1]; } x /= ids.length; y /= ids.length; const c = P(E.o), d = P(E.i); return ((x - (c[0] + d[0]) / 2) * up[0] + (y - (c[1] + d[1]) / 2) * up[1]) / iod2; };
      const BROW = { r: { inner: [107, 66], outer: [70, 63] }, l: { inner: [336, 296], outer: [300, 293] } };
      const bb = this.browBase || (this.browBase = {});
      const brow = (E) => {
        const b = BROW[E.base], hi = browH(b.inner, E), ho = browH(b.outer, E);
        const k = E.base;
        if (!bb[k]) bb[k] = { i: hi, o: ho };
        bb[k].i += (Math.min(hi, bb[k].i + 0.02) - bb[k].i) * 0.004; // slow, biased toward the resting (lower) brow
        bb[k].o += (Math.min(ho, bb[k].o + 0.02) - bb[k].o) * 0.004;
        const ef = this.exF || (this.exF = {});
        const f = (name, v) => { if (!ef[name]) ef[name] = new OneEuro(3.0, 1.5, 1.0); return ef[name].filter(v, t); };
        return { inner: f(k + 'bi', hi - bb[k].i), outer: f(k + 'bo', ho - bb[k].o), open: f(k + 'op', (k === A.base ? earA : earB) / base[k]) };
      };
      const exA = brow(A), exB = brow(B);
      const inner = Math.hypot(P(IDX.innerTop)[0] - P(IDX.innerBottom)[0], P(IDX.innerTop)[1] - P(IDX.innerBottom)[1]);
      const mouthW = Math.hypot(P(IDX.mouthR)[0] - P(IDX.mouthL)[0], P(IDX.mouthR)[1] - P(IDX.mouthL)[1]);

      this.state = {
        present: true, t,
        eyeA: eA, eyeB: eB, mid, iod, roll2d, q: this.q,
        lips, lipTop,
        jaw: bs.jawOpen ?? Math.min(1, inner / Math.max(1, mouthW) * 1.6),
        eyeWide: Math.max(((bs.eyeWideLeft ?? 0) + (bs.eyeWideRight ?? 0)) / 2, 0),
        wideRatio,
        exA, exB,
        blinkA: bs[m.mirror ? 'eyeBlinkLeft' : 'eyeBlinkRight'] ?? 0,
        blinkB: bs[m.mirror ? 'eyeBlinkRight' : 'eyeBlinkLeft'] ?? 0,
        bs,
      };
      return this.state;
    }
  }

  // ------------------------------------------------------------------ scare trigger
  // Mouth wide open AND eyes wide open → the scare starts; it holds for as long as you keep your mouth
  // open (eyes may relax) and releases a moment after you close it. Holding S forces it.
  class ScareController {
    constructor() {
      this.cfg = { mouth: 0.55, eyes: 0.45, hold: 0.08, release: 0.12, keep: 0.7, mouthOnly: false };
      this.active = false; this.armed = 0; this.below = 0; this.forced = false; this.onset = -10;
    }
    // eyes score: blendshape eyeWide (≈0.0 relaxed … 0.6+ wide) or EAR above baseline
    eyeScore(s) { return Math.max(s.eyeWide / 0.5, (s.wideRatio - 1.0) / 0.32); }
    mouthScore(s) { return s.jaw; }
    update(s, t, dt) {
      const c = this.cfg;
      const live = s && s.present;
      if (this.forced) { if (!this.active) this.fire(t); return true; }
      if (!this.active) {
        const want = live && this.mouthScore(s) >= c.mouth && (c.mouthOnly || this.eyeScore(s) >= c.eyes);
        this.armed = want ? this.armed + dt : 0;
        if (this.armed >= c.hold) this.fire(t);
      } else {
        const keep = live && this.mouthScore(s) >= c.mouth * c.keep;
        this.below = keep ? 0 : this.below + dt;
        if (this.below >= c.release) { this.active = false; this.armed = 0; }
      }
      return this.active;
    }
    fire(t) { this.active = true; this.onset = t; this.below = 0; this.armed = 0; }
    force(on, t) { this.forced = on; if (on && !this.active) this.fire(t); if (!on) { this.active = false; this.below = 0; } }
  }

  window.LMFace = { OneEuro, OneEuro2, FaceTracker, ScareController, makeMapping, toPx, IDX, LIPS_OUTER, poseFromMatrix };
})(window.THREE);

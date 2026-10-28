// The scare face artwork, warped onto the mask so its eyes sit on your eye slits and its mouth on your
// big mouth — while the face as a whole stays big. Rendered as a textured grid into a screen-space
// coverage target that the mask material prints in white on the black vinyl. Ragged fronts reveal it
// outward from the eyes and the mouth; the reveal runs backwards on release.
// It is alive: each eye socket squashes with your eyelid (blinks, squints, wide eyes), and as your jaw
// opens the fangs lengthen and the lower jaw drops.
(function (THREE) {
  'use strict';

  const VS = `
    varying vec2 vUv; varying vec2 vPx;
    uniform vec2 uRes;
    void main() { vUv = uv; vPx = vec2((position.x * 0.5 + 0.5) * uRes.x, (0.5 - position.y * 0.5) * uRes.y); gl_Position = vec4(position.xy, 0.0, 1.0); }`;
  const FS = `
    uniform sampler2D uArt; uniform vec2 uRes;
    uniform vec3 uFront[3];   // centre px (x, y) + radius px
    uniform float uPhase;
    varying vec2 vUv; varying vec2 vPx;
    float front(vec3 f, float k) {
      vec2 d = vPx - f.xy; float a = atan(d.y, d.x);
      float rr = f.z * (1.0 + 0.17 * sin(5.0 * a + k) * sin(3.0 * a - k) + 0.08 * sin(13.0 * a + 2.3 * k));
      return smoothstep(rr + 1.0, rr - 1.0, length(d));
    }
    void main() {
      float a = texture2D(uArt, vUv).a;
      float m = max(front(uFront[0], 0.7 + uPhase), max(front(uFront[1], 2.8 + uPhase), front(uFront[2], 4.9 + uPhase)));
      gl_FragColor = vec4(a * m, 0.0, 0.0, 1.0);
    }`;

  // Gaussian RBF displacement that pins anchor points exactly.
  function solve3(A, b) { // tiny Gaussian elimination
    const n = b.length, M = A.map((r, i) => [...r, b[i]]);
    for (let c = 0; c < n; c++) {
      let p = c; for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
      [M[c], M[p]] = [M[p], M[c]];
      for (let r = 0; r < n; r++) if (r !== c) { const f = M[r][c] / M[c][c]; for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k]; }
    }
    return M.map((r, i) => r[n] / r[i]);
  }

  class ScareArt {
    // img: blue-ink PNG; A: { eyeL, eyeR, mouth (art px), cut (art px row), scale, stretch, eyeTargets, mouthTarget }
    constructor(img, A, W, H) {
      this.A = A; this.W = W; this.H = H;
      this.tex = new THREE.Texture(img); this.tex.needsUpdate = true;
      this.tex.colorSpace = THREE.NoColorSpace; this.tex.anisotropy = 8;
      this.tex.minFilter = THREE.LinearMipmapLinearFilter; this.tex.generateMipmaps = true;
      this.iw = img.naturalWidth; this.ih = img.naturalHeight;
      this.GX = 40; this.GY = 52;
      const geo = new THREE.PlaneGeometry(2, 2, this.GX - 1, this.GY - 1);
      this.geo = geo;
      this.mat = new THREE.ShaderMaterial({
        uniforms: { uArt: { value: this.tex }, uRes: { value: new THREE.Vector2(W, H) }, uFront: { value: [new THREE.Vector3(), new THREE.Vector3(), new THREE.Vector3()] }, uPhase: { value: 0 } },
        vertexShader: VS, fragmentShader: FS, depthTest: false, depthWrite: false, side: THREE.DoubleSide,
      });
      const mesh = new THREE.Mesh(geo, this.mat); mesh.frustumCulled = false;
      this.scene = new THREE.Scene(); this.scene.add(mesh);
      this.cam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
      this.rt = new THREE.WebGLRenderTarget(W, H, { type: THREE.UnsignedByteType, generateMipmaps: false });
      this.prepare();
    }

    // art px → face units (origin between the mask's eye anchors, 1 = anchor spacing, y down)
    prepare() {
      const A = this.A;
      const mid = [(A.eyeL[0] + A.eyeR[0]) / 2, (A.eyeL[1] + A.eyeR[1]) / 2];
      const dx = A.eyeR[0] - A.eyeL[0], dy = A.eyeR[1] - A.eyeL[1], iod = Math.hypot(dx, dy);
      const c = dx / iod, s = dy / iod, k = A.scale / iod;
      this.unitsPerPx = k;
      this.base =(x, y) => { const X = x - mid[0], Y = y - mid[1]; return [k * (c * X + s * Y), k * (-s * X + c * Y)]; };
      const anchors = [A.eyeL, A.eyeR, A.mouth].map(([x, y]) => this.base(x, y));
      const targets = [A.eyeTargets[0], A.eyeTargets[1], A.mouthTarget];
      const sig = [0.65, 0.65, 0.9];
      const phi = (p, i) => Math.exp(-((p[0] - anchors[i][0]) ** 2 + (p[1] - anchors[i][1]) ** 2) / (2 * sig[i] * sig[i]));
      const M = anchors.map((p) => [0, 1, 2].map((i) => phi(p, i)));
      this.wx = solve3(M, targets.map((t, i) => t[0] - anchors[i][0]));
      this.wy = solve3(M.map((r) => r.slice()), targets.map((t, i) => t[1] - anchors[i][1]));
      this.phi = phi;
    }
    warp(x, y) {
      const p = this.base(x, y);
      let ox = 0, oy = 0;
      for (let i = 0; i < 3; i++) { const w = this.phi(p, i); ox += this.wx[i] * w; oy += this.wy[i] * w; }
      return [p[0] + ox, p[1] + oy];
    }

    // project: (fx, fy) face units → [px, py]; fronts: [[x, y, r] ×3] in px
    // ex: { open: [screen-left eye, screen-right eye] (1 = relaxed, 0 = shut), jaw: 0 (closed) … 1 (wide) }
    update(project, fronts, ex, t) {
      const pos = this.geo.attributes.position, uv = this.geo.attributes.uv;
      const { GX, GY, iw, ih } = this, A = this.A;
      const sstep = (a, b, x) => { const k = Math.max(0, Math.min(1, (x - a) / (b - a))); return k * k * (3 - 2 * k); };
      // mouth: as your jaw opens the fangs (fangTop → jawTop) lengthen, the jaw below them gives way, and
      // the chin drops only a little — so its drips stay on the logo instead of sliding off the bottom
      const j = Math.max(0, Math.min(1, ex.jaw || 0));
      const fangPx = j * A.fangStretch * (A.jawTop - A.fangTop);
      const chinPx = Math.min(fangPx, (j * A.chinDrop) / this.unitsPerPx);
      const jawY = (y) => y + (y <= A.jawTop
        ? fangPx * sstep(A.fangTop, A.jawTop, y)
        : fangPx + (chinPx - fangPx) * Math.min(1, (y - A.jawTop) / (ih - A.jawTop)));
      // each socket squashes toward its eye line as the lid closes, and grows a little when eyes go wide
      const sy = (ex.open || [1, 1]).map((o) => 0.12 + 0.88 * Math.max(0, Math.min(1.4, o)));
      const eyes = A.eyeTargets;
      for (let j = 0; j < GY; j++) for (let i = 0; i < GX; i++) {
        const id = j * GX + i;
        const u = i / (GX - 1), v = j / (GY - 1);
        const ax = u * iw, ay = jawY(v * ih);
        const f = this.warp(ax, ay);
        for (let e = 0; e < 2; e++) {
          const dx = f[0] - eyes[e][0], dy = f[1] - eyes[e][1];
          const w = Math.exp(-(dx * dx) / (2 * 0.62 * 0.62) - (dy * dy) / (2 * 0.55 * 0.55));
          f[1] = eyes[e][1] + dy * (1 + (sy[e] - 1) * w); // monotonic for any sy > 0: no folds
        }
        const p = project(f[0], f[1]);
        pos.setXYZ(id, (p[0] / this.W) * 2 - 1, 1 - (p[1] / this.H) * 2, 0);
        uv.setXY(id, u, 1 - v);
      }
      pos.needsUpdate = true; uv.needsUpdate = true;
      const F = this.mat.uniforms.uFront.value;
      fronts.forEach((f, i) => F[i].set(f[0], f[1], f[2]));
      this.mat.uniforms.uPhase.value = 0;
    }
    render(renderer) {
      renderer.setRenderTarget(this.rt);
      renderer.setClearColor(0x000000, 1);
      renderer.clear();
      renderer.render(this.scene, this.cam);
      renderer.setRenderTarget(null);
    }
    clear(renderer) { renderer.setRenderTarget(this.rt); renderer.setClearColor(0x000000, 1); renderer.clear(); renderer.setRenderTarget(null); }
  }

  window.LMScareArt = { ScareArt };
})(window.THREE);

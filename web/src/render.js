// LM Mask — renderer: the character in 3D (to an offscreen target), then one composite pass that puts
// it over the live video with the eye cut-outs, the relocated mouth, shadows, effects and the scare grade.
(function (THREE) {
  'use strict';

  const ANCHORS = { eyeA: [25.76, 35.0], eyeB: [42.09, 35.0], mouth: [37.6, 55.6] }; // SVG coords on the LM mask
  const SPAN = Math.hypot(ANCHORS.eyeB[0] - ANCHORS.eyeA[0], ANCHORS.eyeB[1] - ANCHORS.eyeA[1]);
  const MID = [(ANCHORS.eyeA[0] + ANCHORS.eyeB[0]) / 2, (ANCHORS.eyeA[1] + ANCHORS.eyeB[1]) / 2];
  const REVEAL = 0.32; // seconds for the scare face to grow in (and to retract)
  const COMPOSITE_FS = `
    uniform sampler2D tVideo; uniform sampler2D tMask; uniform sampler2D tOverlay; uniform sampler2D tFx;
    uniform vec2 uRes; uniform vec4 uCrop; uniform float uMirror;
    uniform vec4 uPatch; uniform float uPatchScale;
    uniform float uScare; uniform float uHoles; uniform float uFlash; uniform float uVis; uniform float uExposure;
    uniform vec2 uShake; uniform vec2 uShadowOff; uniform float uShadow; uniform vec3 uGrade; uniform float uFx;
    varying vec2 vUv;
    vec3 videoAt(vec2 p) {
      vec2 t = (p - uCrop.xy) / uCrop.zw;
      if (uMirror > 0.5) t.x = 1.0 - t.x;
      return texture2D(tVideo, vec2(t.x, 1.0 - t.y)).rgb;
    }
    vec2 uvOf(vec2 p) { return vec2(p.x / uRes.x, 1.0 - p.y / uRes.y); }
    vec3 neutral(vec3 color) {
      const float StartCompression = 0.8 - 0.04; const float Desaturation = 0.15;
      float x = min(color.r, min(color.g, color.b));
      float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
      color -= offset;
      float peak = max(color.r, max(color.g, color.b));
      if (peak < StartCompression) return color;
      float d = 1. - StartCompression;
      float newPeak = 1. - d * d / (peak + d - StartCompression);
      color *= newPeak / peak;
      float g = 1. - 1. / (Desaturation * (peak - newPeak) + 1.);
      return mix(color, vec3(newPeak), g);
    }
    vec3 toSRGB(vec3 c) { c = clamp(c, 0.0, 1.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
    void main() {
      vec2 p = vec2(vUv.x * uRes.x, (1.0 - vUv.y) * uRes.y) + uShake;
      vec2 suv = uvOf(p);
      vec3 live = videoAt(p);
      float lum = dot(live, vec3(0.2126, 0.7152, 0.0722));
      vec3 bg = mix(live, vec3(lum) * uGrade * 0.55, uScare);
      float sh = textureLod(tMask, uvOf(p - uShadowOff), 5.0).a;
      bg *= 1.0 - uShadow * sh * uVis;
      vec4 m = texture2D(tMask, suv);
      vec3 mc = m.a > 0.001 ? m.rgb / m.a : vec3(0.0);
      mc = neutral(mc * uExposure);
      float ma = clamp(m.a * uVis, 0.0, 1.0);
      vec3 col = mix(bg, mc, ma);
      vec4 ov = texture2D(tOverlay, suv);
      col *= 1.0 - 0.5 * ov.b * ma * uHoles;
      col = mix(col, live, ov.r * ma * uHoles);
      vec2 src = uPatch.xy + (p - uPatch.zw) / uPatchScale;
      col = mix(col, videoAt(src), ov.g * ma * uHoles);
      col += texture2D(tFx, suv).rgb * uFx * uVis;
      vec2 q = vUv - 0.5;
      float vig = smoothstep(0.95, 0.15, length(q * vec2(1.0, 1.25)));
      col *= mix(1.0, mix(0.08, 1.0, vig), uScare);
      col = mix(col, vec3(1.0), uFlash);
      gl_FragColor = vec4(toSRGB(col), 1.0);
    }`;

  const black1 = () => { const t = new THREE.DataTexture(new Uint8Array([0, 0, 0, 255]), 1, 1); t.needsUpdate = true; return t; };

  class Renderer {
    constructor(canvas, opts = {}) {
      this.W = opts.width || 1280; this.H = opts.height || 720;
      this.opts = Object.assign({ character: 'lm' }, opts);
      const r = this.renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'high-performance', preserveDrawingBuffer: !!opts.preserve });
      r.setPixelRatio(1);
      r.setSize(this.W, this.H, false);
      r.autoClear = true;

      // ---------------- 3D scene
      this.fovY = 38;
      this.camera = new THREE.PerspectiveCamera(this.fovY, this.W / this.H, 0.1, 6000);
      this.focal = (this.H / 2) / Math.tan((this.fovY * Math.PI) / 360);
      const scene = this.scene = new THREE.Scene();
      const pmrem = new THREE.PMREMGenerator(r);
      scene.environment = pmrem.fromScene(new window.LMEnv.RoomEnvironment(), 0.04).texture;
      scene.environmentIntensity = 0.5;
      this.key = new THREE.DirectionalLight(0xffffff, 2.6);
      this.key.position.set(-0.45, 0.65, 1.0);
      r.shadowMap.type = THREE.VSMShadowMap;
      this.key.shadow.mapSize.set(1024, 1024);
      Object.assign(this.key.shadow.camera, { left: -4.5, right: 4.5, top: 5, bottom: -4, near: 20, far: 42 });
      this.key.shadow.radius = 14; this.key.shadow.blurSamples = 16; this.key.shadow.intensity = 0.5;
      this.key.shadow.bias = -0.0006;
      this.key.shadow.normalBias = 0.02;
      scene.add(this.key.target);
      this.fill = new THREE.DirectionalLight(0xdfe8ff, 0.5);
      this.fill.position.set(0.7, -0.2, 0.6);
      this.scareLight = new THREE.DirectionalLight(0xe4ecff, 0);
      this.scareLight.position.set(0.15, -1.0, 0.55);
      this.rimLight = new THREE.DirectionalLight(0xff2a14, 0);
      this.rimLight.position.set(-0.3, 0.9, -0.6);
      scene.add(this.key, this.fill, this.scareLight, this.rimLight);

      const t0 = performance.now();
      this.inf = window.LMInflate.buildInflatable(opts.inflate || {});
      this.buildMs = Math.round(performance.now() - t0);
      this.rig = new THREE.Group();
      this.rig.add(this.inf.mesh);
      const a = this.inf.surfacePoint(...ANCHORS.eyeA), b = this.inf.surfacePoint(...ANCHORS.eyeB);
      this.inf.mesh.position.copy(a.clone().add(b).multiplyScalar(0.5)).multiplyScalar(-1);
      this.rig.visible = false;
      scene.add(this.rig);
      this.merlin = null; // built on first use

      this.maskRT = new THREE.WebGLRenderTarget(this.W, this.H, {
        samples: 4, type: THREE.HalfFloatType, generateMipmaps: true,
        minFilter: THREE.LinearMipmapLinearFilter, magFilter: THREE.LinearFilter,
      });

      // ---------------- overlay layers
      this.overlay = new window.LMOverlay.Overlay(this.W, this.H);
      this.overlayTex = new THREE.CanvasTexture(this.overlay.canvas);
      this.overlayTex.colorSpace = THREE.NoColorSpace;
      this.overlayTex.minFilter = THREE.LinearFilter; this.overlayTex.generateMipmaps = false;
      this.fxTex = new THREE.CanvasTexture(this.overlay.fx);
      this.fxTex.colorSpace = THREE.NoColorSpace; this.fxTex.premultiplyAlpha = true;
      this.fxTex.minFilter = THREE.LinearFilter; this.fxTex.generateMipmaps = false;
      this.inf.uniforms.uOverlay.value = this.overlayTex;
      this.inf.uniforms.uArt.value = black1();
      this.inf.uniforms.uRes.value.set(this.W, this.H);

      // the scare face artwork, warped so its eyes and mouth land on yours
      this.art = null;
      if (window.LM_SCARE_FACE) {
        const img = new Image();
        img.onload = () => {
          const A = Object.assign({ eyeTargets: [[-0.5, 0], [0.5, 0]], mouthTarget: [0.22, 1.52] }, window.LM_SCARE_FACE.anchors);
          this.art = new window.LMScareArt.ScareArt(img, A, this.W, this.H);
        };
        img.src = window.LM_SCARE_FACE.src;
      }

      this.videoTex = null;
      this.mapping = null;
      this.compMat = new THREE.ShaderMaterial({
        uniforms: {
          tVideo: { value: null }, tMask: { value: this.maskRT.texture }, tOverlay: { value: this.overlayTex }, tFx: { value: this.fxTex },
          uRes: { value: new THREE.Vector2(this.W, this.H) }, uCrop: { value: new THREE.Vector4(0, 0, this.W, this.H) }, uMirror: { value: 0 },
          uPatch: { value: new THREE.Vector4() }, uPatchScale: { value: 1 },
          uScare: { value: 0 }, uHoles: { value: 1 }, uFlash: { value: 0 }, uVis: { value: 0 }, uExposure: { value: 0.84 },
          uShake: { value: new THREE.Vector2() }, uShadowOff: { value: new THREE.Vector2(10, 16) }, uShadow: { value: 0.45 },
          uGrade: { value: new THREE.Vector3(0.55, 0.22, 0.2) }, uFx: { value: 0 },
        },
        vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }',
        fragmentShader: COMPOSITE_FS,
        depthTest: false, depthWrite: false,
      });
      this.quadScene = new THREE.Scene();
      const quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.compMat);
      quad.frustumCulled = false;
      this.quadScene.add(quad);
      this.quadCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

      this.vis = 0;
      this.prog = 0;        // scare reveal progress 0..1 (runs backwards on release)
      this.onsetAt = -10;   // time of the last scare onset (flash/shake)
      this.wasOn = false;
      this.setCharacter(this.opts.character);
    }

    // LM scare colours: false = black logo, white face; true = white logo, black face. Flips instantly
    // (flip it fast to strobe); each flip during a scare also jolts the picture a little.
    setInvert(on) {
      const v = on ? 1 : 0, u = this.inf.uniforms.uInvert;
      if (u.value === v) return;
      u.value = v;
      this.kickPending = true;
    }

    setCharacter(name) {
      this.opts.character = name === 'merlin' ? 'merlin' : 'lm';
      if (this.opts.character === 'merlin' && !this.merlin) {
        this.merlin = window.LMMerlin.build();
        this.merlin.head.visible = false;
        this.scene.add(this.merlin.head);
      }
      // soft shadows (hat brim and glasses onto the head) only matter for Merlin
      this.renderer.shadowMap.enabled = this.opts.character === 'merlin';
      this.key.castShadow = this.opts.character === 'merlin';
    }

    // Average colour of the camera image → a gentle tint on the lights so the character sits in the room.
    sampleRoom(t) {
      const img = this.videoTex && this.videoTex.image;
      if (!img || t - (this._roomT || -1) < 0.4) return;
      this._roomT = t;
      try {
        if (!this._roomCtx) { const c = document.createElement('canvas'); c.width = 16; c.height = 9; this._roomCtx = c.getContext('2d', { willReadFrequently: true }); }
        const ctx = this._roomCtx;
        ctx.drawImage(img, 0, 0, 16, 9);
        const d = ctx.getImageData(0, 0, 16, 9).data;
        let r = 0, g = 0, b = 0;
        for (let i = 0; i < d.length; i += 4) { r += d[i] ** 2.2; g += d[i + 1] ** 2.2; b += d[i + 2] ** 2.2; }
        const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b || 1;
        const tint = new THREE.Color(r / lum, g / lum, b / lum);
        tint.lerp(new THREE.Color(1, 1, 1), 0.72);
        this.roomTint = this.roomTint ? this.roomTint.lerp(tint, 0.35) : tint;
      } catch (e) { /* tainted or not ready */ }
    }

    setSource(texture, vw, vh, mirror) {
      this.videoTex = texture;
      texture.colorSpace = THREE.SRGBColorSpace;
      this.compMat.uniforms.tVideo.value = texture;
      this.mapping = window.LMFace.makeMapping(vw, vh, this.W, this.H, mirror);
      const m = this.mapping;
      this.compMat.uniforms.uCrop.value.set(m.ox, m.oy, m.dw, m.dh);
      this.compMat.uniforms.uMirror.value = mirror ? 1 : 0;
    }

    rayPoint(px, py, D) { return new THREE.Vector3(((px - this.W / 2) / this.focal) * D, (-(py - this.H / 2) / this.focal) * D, -D); }
    toPx(v) { const p = v.clone().project(this.camera); return [(p.x * 0.5 + 0.5) * this.W, (0.5 - p.y * 0.5) * this.H]; }
    project(svgX, svgY) { return this.toPx(this.inf.surfacePoint(svgX, svgY, 0.12).applyMatrix4(this.inf.mesh.matrixWorld)); }

    placeLM(state, pop) {
      if (state && state.present) {
        const D = (SPAN * this.focal) / Math.max(8, state.iod);
        this.rig.position.copy(this.rayPoint(state.mid[0], state.mid[1], D));
        this.rig.quaternion.copy(state.q);
        this.rig.scale.setScalar(pop);
      }
      this.rig.visible = !!state;
      this.rig.updateMatrixWorld(true);
    }

    placeMerlin(state, pop) {
      const w = this.merlin;
      if (state && state.present) {
        const D = this.focal / Math.max(8, state.iod); // 1 unit = your eye spacing
        w.head.position.copy(this.rayPoint(state.mid[0], state.mid[1], D));
        w.head.quaternion.copy(state.q);
        w.head.scale.setScalar(pop);
        // keep the key light's shadow camera wrapped around the head
        const dir = new THREE.Vector3(-0.4, 0.45, 1.0).normalize();
        this.key.target.position.copy(w.head.position);
        this.key.position.copy(w.head.position).add(dir.multiplyScalar(30));
        this.key.target.updateMatrixWorld();
      }
      w.head.visible = !!state;
      w.head.updateMatrixWorld(true);
    }

    render(state, scare, t, dt) {
      const U = this.compMat.uniforms;
      const merlin = this.opts.character === 'merlin';
      const target = state && state.present ? 1 : 0;
      this.vis += (target - this.vis) * (1 - Math.exp(-dt / (target ? 0.08 : 0.25)));
      // scare progress: grows quickly while the scare is held, runs backwards on release
      if (scare.on && !this.wasOn && this.prog < 0.05) this.onsetAt = t;
      this.wasOn = scare.on;
      this.prog = Math.max(0, Math.min(1, this.prog + (scare.on ? dt : -dt) / REVEAL));
      if (this.forceProg !== undefined) this.prog = this.forceProg; // look-dev
      const p = this.prog, ease = 1 - Math.pow(1 - p, 3);
      const visual = p > 0.001;
      const since = t - this.onsetAt;
      const pop = 1 + 0.08 * Math.exp(-since * 9) * Math.cos(since * 22) * (scare.on ? 1 : 0) + 0.035 * ease;

      this.rig.visible = false;
      if (this.merlin) this.merlin.head.visible = false;
      let mouthDst;
      if (merlin) {
        this.placeMerlin(state, pop);
        this.merlin.expression(state, dt);
        mouthDst = this.toPx(this.merlin.mouth.clone().applyMatrix4(this.merlin.head.matrixWorld));
        this.merlin.setDark(ease, t);
      } else {
        this.placeLM(state, pop);
        mouthDst = this.project(...ANCHORS.mouth);
      }

      // overlay: eye slits / big mouth (normal), black eyes and mouth (scare)
      const useArt = !merlin && !!this.art;
      this.overlay.draw(state, { on: !merlin && visual, p: ease, art: useArt }, (x, y) => this.project(x, y), { mid: MID, span: SPAN }, mouthDst, { character: this.opts.character });
      this.overlayTex.needsUpdate = true;
      const patch = this.overlay.patch;
      if (patch) { U.uPatch.value.set(patch.src[0], patch.src[1], patch.dst[0], patch.dst[1]); U.uPatchScale.value = patch.scale; }

      // scare face artwork (LM) — warped onto the mask, revealed from the eyes and the mouth
      const iu = this.inf.uniforms;
      if (useArt && visual && state && state.present) {
        const m = this.overlay.mouthPath(state, mouthDst, this.overlay.cfg.mouthScale);
        const R = state.iod * Math.pow(p, 1.15) * 1.08;
        const projF = (fx, fy) => this.project(MID[0] + fx * SPAN, MID[1] + fy * SPAN);
        // the face follows yours: eye openness per eye, and how far your jaw is open
        const jq = Math.max(0, Math.min(1, (state.jaw - 0.08) / 0.82));
        const ex = {
          open: [state.exA ? state.exA.open : 1, state.exB ? state.exB.open : 1],
          jaw: jq * jq * (3 - 2 * jq),
        };
        this.art.update(projF, [
          [state.eyeA.center[0], state.eyeA.center[1], R * 1.75],
          [state.eyeB.center[0], state.eyeB.center[1], R * 1.75],
          [m.centre[0], m.centre[1], R * 2.5],
        ], ex, t);
        this.art.render(this.renderer);
        iu.uArt.value = this.art.rt.texture;
      } else if (this.art && iu.uArt.value === this.art.rt.texture) {
        this.art.clear(this.renderer);
      }

      // Merlin effects: laser eyes + lightning from under the glasses
      let fxOn = 0;
      if (merlin && visual && state && state.present) {
        const H = this.merlin.head, M = H.matrixWorld;
        const lenses = this.merlin.lensCenters.map((c) => this.toPx(c.clone().applyMatrix4(M)));
        const ends = this.merlin.lensCenters.map((c, i) => {
          const dir = new THREE.Vector3(i === 0 ? -0.22 : 0.22, -0.32, 1).normalize();
          const len = Math.min(6.5, (-H.position.z - 1.2) * 0.9);
          return this.toPx(c.clone().add(dir.multiplyScalar(len)).applyMatrix4(M));
        });
        const bottoms = this.merlin.lensBottoms.map((pts) => pts.map((q) => this.toPx(q.clone().applyMatrix4(M))));
        this.overlay.drawMerlinFx({ lenses, ends, bottoms, iod: state.iod, k: ease, t });
        this.fxTex.needsUpdate = true;
        fxOn = 1;
      } else if (this.overlay.clearFx()) {
        this.fxTex.needsUpdate = true;
      }

      // lighting
      this.sampleRoom(t);
      const tint = this.roomTint || new THREE.Color(1, 1, 1);
      const s = ease;
      this.key.color.copy(tint);
      this.fill.color.copy(tint).multiply(new THREE.Color(0xdfe8ff));
      if (merlin) {
        this.key.intensity = 2.5 * (1 - 0.85 * s);
        this.fill.color.set(0xb9a6ff); this.fill.intensity = 0.9 * (1 - s);
        this.scareLight.color.set(0x8f7bff); this.scareLight.intensity = 2.6 * s;
        this.rimLight.color.lerpColors(new THREE.Color(0x7fb2ff), new THREE.Color(0xff3020), s); this.rimLight.intensity = 1.6 + 0.4 * s;
        this.scene.environmentIntensity = 0.6 * (1 - 0.6 * s);
        U.uGrade.value.set(0.32, 0.24, 0.62);
      } else {
        // scare: the logo turns to black vinyl, the face prints white on it
        iu.uScare.value = visual ? 1 : 0;
        // black lands first (under the onset flash), so the white face always grows on a fully black
        // logo; on release the face retracts first and the logo turns white again at the very end
        const b = Math.min(1, p / 0.3);
        iu.uBody.value = b * b * (3 - 2 * b);
        iu.uInk.value = 0;
        iu.uPrintHide.value = 0;
        this.key.intensity = 2.6 * (1 - 0.92 * s);
        this.fill.intensity = 0.5 * (1 - s);
        this.scareLight.color.set(0xe4ecff); this.scareLight.intensity = 3.4 * s;
        this.rimLight.color.set(0xff2a14); this.rimLight.intensity = 2.2 * s;
        this.scene.environmentIntensity = 0.5 * (1 - 0.7 * s);
        U.uGrade.value.set(0.55, 0.22, 0.2);
      }

      const r = this.renderer;
      r.setRenderTarget(this.maskRT);
      r.setClearColor(0x000000, 0);
      r.clear();
      if (state) r.render(this.scene, this.camera);
      r.setRenderTarget(null);

      U.uVis.value = this.vis;
      U.uScare.value = s;
      U.uHoles.value = merlin ? 1 : visual ? 0 : 1;
      U.uFx.value = fxOn;
      U.uFlash.value = scare.on ? Math.max(0, 0.8 - since * 7.0) : 0;
      if (this.kickPending) { this.kickAt = t; this.kickPending = false; }
      const kick = !merlin && p > 0.5 ? 0.4 * Math.max(0, 1 - (t - (this.kickAt ?? -10)) / 0.09) : 0;
      const shake = Math.max(scare.on ? Math.max(0, 1 - since / 0.35) : 0, kick);
      U.uShake.value.set((Math.random() - 0.5) * 26 * shake, (Math.random() - 0.5) * 18 * shake);
      r.render(this.quadScene, this.quadCam);
    }
  }

  window.LMRender = { Renderer, ANCHORS, SPAN };
})(window.THREE);

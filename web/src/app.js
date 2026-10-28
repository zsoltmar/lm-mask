// LM Mask — app shell: camera, MediaPipe FaceLandmarker, render loop, controls.
(function () {
  'use strict';
  const THREE = window.THREE;
  const $ = (id) => document.getElementById(id);
  const MP_VERSION = '0.10.18';
  const MP_CDN = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${MP_VERSION}`;
  const MODEL_URLS = [
    'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task',
    'https://cdn.jsdelivr.net/npm/ptmaker-vision-models@1.0.0/face_landmarker.task',
  ];

  // ---------------------------------------------------------------- settings
  const DEFAULTS = { character: 'lm', mirror: true, mouthScale: 2.15, eyeScale: 1.2, soft: 0.5, thMouth: 0.55, thEyes: 0.45, mouthOnly: false, invertScare: false, camera: '' };
  let S = { ...DEFAULTS };
  try { S = { ...DEFAULTS, ...JSON.parse(localStorage.getItem('lmmask.settings.v2') || '{}') }; } catch (e) { /* private mode */ }
  if (window.STILL_CHAR) S.character = window.STILL_CHAR; // look-dev
  if (window.STILL_INVERT !== undefined) S.invertScare = !!window.STILL_INVERT; // look-dev
  const save = () => { try { localStorage.setItem('lmmask.settings.v2', JSON.stringify(S)); } catch (e) { /* ignore */ } };

  // ---------------------------------------------------------------- ui helpers
  const veil = (msg, { spin = true, error = false, button = null } = {}) => {
    $('veil').classList.remove('hidden');
    $('veilMsg').textContent = msg;
    $('veilMsg').className = error ? 'err' : '';
    $('veilSpin').hidden = !spin;
    const b = $('veilBtn');
    b.hidden = !button;
    if (button) { b.textContent = button.label; b.onclick = button.onClick; }
  };
  const hideVeil = () => $('veil').classList.add('hidden');
  const status = (text, kind = '') => { $('statusText').textContent = text; $('status').className = 'status ' + kind; };
  const setRange = (el) => { const p = ((el.value - el.min) / (el.max - el.min)) * 100; el.style.setProperty('--p', p + '%'); };

  // ---------------------------------------------------------------- core objects
  const canvas = $('out');
  let R, tracker, scare, landmarker = null, source = null;

  function applySettings() {
    R.overlay.cfg.mouthScale = S.mouthScale;
    R.overlay.cfg.eyeScale = S.eyeScale;
    R.overlay.cfg.soft = S.soft;
    if (R.opts.character !== S.character) R.setCharacter(S.character);
    R.setInvert(S.invertScare);
    $('invertScare').checked = S.invertScare;
    $('invertRow').style.display = S.character === 'lm' ? '' : 'none';
    document.querySelectorAll('#charSeg button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.char === S.character)));
    $('eyeRow').style.display = S.character === 'lm' ? '' : 'none';
    scare.cfg.mouth = S.thMouth;
    scare.cfg.eyes = S.thEyes;
    scare.cfg.mouthOnly = S.mouthOnly;
    $('eyeMeter').style.opacity = S.mouthOnly ? 0.4 : 1;
    if (source) {
      const flipped = R.mapping && R.mapping.mirror !== S.mirror;
      R.setSource(source.texture, source.width, source.height, S.mirror);
      if (flipped && tracker) tracker.reset();
    }
    if (source && source.kind === 'still' && window.LMRequestFrames) window.LMRequestFrames();
  }

  function bindControls() {
    const bindRange = (id, fmt) => {
      const el = $(id), v = $(id + 'V');
      el.value = S[id];
      const show = () => { v.textContent = fmt(+el.value); setRange(el); };
      show();
      el.addEventListener('input', () => { S[id] = +el.value; show(); applySettings(); save(); });
    };
    bindRange('mouthScale', (x) => x.toFixed(2) + '×');
    bindRange('eyeScale', (x) => x.toFixed(2) + '×');
    bindRange('soft', (x) => Math.round(x * 100) + '%');
    bindRange('thMouth', (x) => Math.round(x * 100) + '%');
    bindRange('thEyes', (x) => Math.round(x * 100) + '%');
    for (const id of ['mirror', 'mouthOnly', 'invertScare']) {
      const el = $(id);
      el.checked = !!S[id];
      el.addEventListener('change', () => { S[id] = el.checked; applySettings(); save(); });
    }
    // scare: hold button or S
    const btn = $('testScare');
    const hold = (on) => { scare.force(on, performance.now() / 1000); btn.classList.toggle('held', on); if (window.LMRequestFrames) window.LMRequestFrames(); };
    btn.addEventListener('pointerdown', (e) => { e.preventDefault(); btn.setPointerCapture(e.pointerId); hold(true); });
    btn.addEventListener('pointerup', () => hold(false));
    btn.addEventListener('pointercancel', () => hold(false));
    window.addEventListener('keydown', (e) => {
      if (e.target.tagName === 'SELECT' || e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key.toLowerCase();
      if (k === 's' && !e.repeat) hold(true);
      // invert the scare colours; key repeat is allowed, so holding I strobes
      else if (k === 'i') { S.invertScare = !S.invertScare; applySettings(); if (!e.repeat) save(); }
      else if (k === 'h') toggleClean();
      else if (k === 'c') { S.character = S.character === 'lm' ? 'wizard' : 'lm'; applySettings(); save(); }
      else if (k === 'm') { S.mirror = !S.mirror; $('mirror').checked = S.mirror; applySettings(); save(); }
      else if (k === 'f') { if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen().catch(() => {}); }
    });
    window.addEventListener('keyup', (e) => { if (e.key.toLowerCase() === 's') hold(false); });
    $('cleanBtn').addEventListener('click', toggleClean);
    $('offlineLink').hidden = !window.MP_BASE; // hosted page only: offer the single-file offline copy
    document.querySelectorAll('#charSeg button').forEach((b) => b.addEventListener('click', () => { S.character = b.dataset.char; applySettings(); save(); }));
    $('camSel').addEventListener('change', (e) => { S.camera = e.target.value; save(); startCamera(); });
    meters(null);
  }

  let idleTimer = 0;
  function toggleClean() {
    const on = !document.body.classList.contains('clean');
    document.body.classList.toggle('clean', on);
    const h = $('cleanHint');
    if (on) { h.classList.add('show'); setTimeout(() => h.classList.remove('show'), 2600); }
  }
  window.addEventListener('mousemove', () => {
    document.body.classList.remove('idle');
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => document.body.classList.add('idle'), 1800);
  });

  // ---------------------------------------------------------------- camera
  const video = document.createElement('video');
  video.playsInline = true; video.muted = true; video.autoplay = true;
  let stream = null;

  async function listCameras() {
    const devs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
    const sel = $('camSel');
    sel.innerHTML = '';
    for (const d of devs) {
      const o = document.createElement('option');
      o.value = d.deviceId; o.textContent = d.label || 'Camera';
      // never offer our own outputs as inputs
      if (/OBS Virtual|LM Halloween/i.test(o.textContent)) continue;
      sel.appendChild(o);
    }
    const track = stream && stream.getVideoTracks()[0];
    const cur = track && track.getSettings().deviceId;
    if (cur) sel.value = cur;
  }

  async function startCamera() {
    if (stream) stream.getTracks().forEach((t) => t.stop());
    const want = { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 }, aspectRatio: { ideal: 16 / 9 } };
    if (S.camera) want.deviceId = { exact: S.camera };
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: want, audio: false });
    } catch (e) {
      if (S.camera && e.name === 'OverconstrainedError') { S.camera = ''; save(); return startCamera(); }
      const denied = e.name === 'NotAllowedError' || e.name === 'SecurityError';
      veil(denied ? 'Camera access is blocked. Allow it in the browser’s site settings, then try again.' : 'No camera found (' + e.name + ').', { spin: false, error: true, button: { label: 'Try again', onClick: startCamera } });
      status('No camera', 'warn');
      throw e;
    }
    video.srcObject = stream;
    await video.play().catch(() => {});
    if (!video.videoWidth) await new Promise((r) => video.addEventListener('loadedmetadata', r, { once: true }));
    const tex = new THREE.VideoTexture(video);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.minFilter = THREE.LinearFilter; tex.magFilter = THREE.LinearFilter; tex.generateMipmaps = false;
    if (source && source.texture) source.texture.dispose();
    source = { kind: 'live', texture: tex, width: video.videoWidth, height: video.videoHeight };
    applySettings();
    listCameras().catch(() => {});
    tracker && tracker.reset();
  }

  // ---------------------------------------------------------------- MediaPipe
  async function fetchFirst(urls) {
    let last;
    for (const u of urls) {
      try { const r = await fetch(u); if (r.ok) return new Uint8Array(await r.arrayBuffer()); last = new Error(r.status + ' ' + u); } catch (e) { last = e; }
    }
    throw last;
  }
  const b64Bytes = async (b64) => new Uint8Array(await (await fetch('data:application/octet-stream;base64,' + b64)).arrayBuffer());

  async function loadLandmarker() {
    let vision, fileset, model, wasm = null;
    const inline = !!(window.MPVision && window.MP_INLINE && window.__mpFactory);
    if (inline) {
      // offline build: the wasm runtime and the model are embedded in this file
      vision = window.MPVision;
      wasm = await b64Bytes(window.MP_INLINE.wasm);
      model = await b64Bytes(window.MP_INLINE.model);
      fileset = { wasmLoaderPath: '', wasmBinaryPath: 'inline.wasm' };
    } else {
      // hosted build (GitHub Pages) serves MediaPipe next to the page; the CDN is the fallback
      const local = window.MP_BASE ? new URL(window.MP_BASE, location.href).href.replace(/\/$/, '') : null;
      const bases = local ? [local, MP_CDN] : [MP_CDN];
      let err;
      for (const base of bases) {
        try {
          vision = await import(`${base}/vision_bundle.mjs`);
          fileset = await vision.FilesetResolver.forVisionTasks(`${base}/wasm`);
          break;
        } catch (e) { err = e; vision = null; console.warn('MediaPipe not available from', base, e); }
      }
      if (!vision) throw err;
      model = await fetchFirst(local ? [`${local}/face_landmarker.task`, ...MODEL_URLS] : MODEL_URLS);
    }
    const make = (delegate) => {
      if (inline) { self.ModuleFactory = window.__mpFactory; self.Module = { wasmBinary: wasm.buffer }; }
      return vision.FaceLandmarker.createFromOptions(fileset, {
        baseOptions: { modelAssetBuffer: model, delegate },
        runningMode: 'VIDEO', numFaces: 1,
        minFaceDetectionConfidence: 0.5, minFacePresenceConfidence: 0.5, minTrackingConfidence: 0.5,
        outputFaceBlendshapes: true, outputFacialTransformationMatrixes: true,
      });
    };
    try { return await make('GPU'); } catch (e) {
      console.warn('GPU delegate failed, falling back to CPU', e);
      return make('CPU');
    }
  }

  // ---------------------------------------------------------------- loop
  let lastVideoTime = -1, lastT = performance.now() / 1000, result = null, state = null, meterT = 0;
  function frame() {
    const t = performance.now() / 1000;
    const dt = Math.min(0.1, Math.max(0.001, t - lastT));
    lastT = t;
    if (source) {
      if (source.kind === 'live' && landmarker && video.readyState >= 2 && video.currentTime !== lastVideoTime) {
        lastVideoTime = video.currentTime;
        try { result = landmarker.detectForVideo(video, performance.now()); } catch (e) { console.error(e); }
        state = tracker.update(result, R.mapping, t);
      } else if (source.kind === 'still') {
        state = tracker.update(source.result, R.mapping, t);
        if (window.STILL_EX && state) { state.exA = window.STILL_EX.A; state.exB = window.STILL_EX.B; } // look-dev
        if (window.STILL_JAW !== undefined && state) state.jaw = window.STILL_JAW; // look-dev
      }
      const on = scare.update(state, t, dt);
      if (window.STILL_PROG !== undefined) R.forceProg = window.STILL_PROG; // look-dev: pin the scare reveal
      R.render(state, { on, onset: scare.onset }, t, dt);
      $('badge').classList.toggle('on', on);
      if (t - meterT > 0.066) { meterT = t; meters(state); }
    }
    // a still demo only needs a few frames (keeps look-dev pages idle); live runs forever
    looping = !source || source.kind !== 'still' || (stillFrames += 1) < 24 || (scare.active && t - scare.onset < 2.5);
    if (looping) requestAnimationFrame(frame);
  }
  let stillFrames = 0, looping = false;
  window.LMRequestFrames = () => {
    if (!source || source.kind !== 'still') return; // live mode is always looping
    stillFrames = 0;
    if (!looping) { looping = true; requestAnimationFrame(frame); }
  };

  function meters(s) {
    const live = s && s.present;
    const mouth = live ? scare.mouthScore(s) : 0, eyes = live ? scare.eyeScore(s) : 0;
    const set = (id, v, th) => {
      const p = Math.max(0, Math.min(1, v));
      $(id).style.width = (p * 100).toFixed(1) + '%';
      $(id).classList.toggle('hit', v >= th);
      $(id + 'V').textContent = Math.round(p * 100) + '%';
    };
    set('mMouth', mouth, S.thMouth);
    set('mEyes', eyes, S.thEyes);
    $('tMouth').style.left = `calc(${S.thMouth * 100}% - 1px)`;
    $('tEyes').style.left = `calc(${Math.min(1, S.thEyes) * 100}% - 1px)`;
    if (source && source.kind === 'live' && scare) {
      if (!landmarker) status('Loading face tracking…', 'warn');
      else status(live ? 'Tracking' : 'Looking for a face…', live ? 'live' : 'warn');
    }
  }

  // ---------------------------------------------------------------- boot
  async function boot() {
    veil('Inflating the headpiece…');
    await new Promise((r) => setTimeout(r, 30)); // let the veil paint before the mesh build
    R = new window.LMRender.Renderer(canvas, { preserve: !!window.STILL });
    tracker = new window.LMFace.FaceTracker();
    scare = new window.LMFace.ScareController();
    bindControls();
    applySettings();
    looping = true;
    requestAnimationFrame(frame);

    if (window.STILL) { // look-dev / demo: a still photo with a recorded tracking result
      const D = window.STILL;
      const img = new Image(); img.src = D.img; await img.decode();
      const tex = new THREE.Texture(img); tex.needsUpdate = true; tex.colorSpace = THREE.SRGBColorSpace;
      const colMajor = []; for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) colMajor.push(D.M[r][c]);
      source = {
        kind: 'still', texture: tex, width: img.naturalWidth, height: img.naturalHeight,
        result: { faceLandmarks: [D.L.map(([x, y, z]) => ({ x, y, z }))], facialTransformationMatrixes: [{ data: colMajor }], faceBlendshapes: [{ categories: Object.entries(D.bs).map(([categoryName, score]) => ({ categoryName, score })) }] },
      };
      applySettings();
      status('Demo photo', 'live');
      hideVeil();
      if (window.STILL_SCARE) scare.force(true, performance.now() / 1000 - 2);
      return;
    }

    veil('Waiting for the camera…');
    try { await startCamera(); } catch (e) { return; }
    veil('Loading face tracking…');
    status('Loading face tracking…', 'warn');
    try {
      landmarker = await loadLandmarker();
    } catch (e) {
      console.error(e);
      veil('Face tracking could not load. Check your connection and reload.', { spin: false, error: true, button: { label: 'Reload', onClick: () => location.reload() } });
      status('Tracking unavailable', 'warn');
      return;
    }
    hideVeil();
  }

  window.addEventListener('error', (e) => { console.error(e.error || e.message); veil('Something went wrong: ' + e.message + (e.lineno ? ' (line ' + e.lineno + ')' : ''), { spin: false, error: true }); });
  boot().catch((e) => { console.error(e); veil('Something went wrong: ' + e.message + ' ' + ((e.stack || '').split('\n')[1] || ''), { spin: false, error: true }); });
})();

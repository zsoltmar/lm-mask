// Look-dev: run the real pipeline on a still photo + a recorded FaceLandmarker result.
(async function () {
  const THREE = window.THREE;
  const log = (m) => { const el = document.getElementById('log'); if (el) el.textContent += '\n' + m; };
  window.onerror = (m, s, l) => log('ERR ' + m + ' @' + l);
  try {
    const D = window.STILL; // { img: dataURL, L: [[x,y,z]], M: [[4x4 row-major]], bs: {name: score} }
    const canvas = document.createElement('canvas');
    canvas.style.width = '100%';
    document.getElementById('stage').appendChild(canvas);
    const R = new window.LMRender.Renderer(canvas, { preserve: true });
    log('mask built in ' + R.buildMs + ' ms');
    const img = new Image(); img.src = D.img; await img.decode();
    const tex = new THREE.Texture(img); tex.needsUpdate = true;
    const mirror = !!window.STILL_MIRROR;
    R.setSource(tex, img.naturalWidth, img.naturalHeight, mirror);
    const colMajor = []; for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) colMajor.push(D.M[r][c]);
    const result = {
      faceLandmarks: [D.L.map(([x, y, z]) => ({ x, y, z }))],
      facialTransformationMatrixes: [{ rows: 4, columns: 4, data: colMajor }],
      faceBlendshapes: [{ categories: Object.entries(D.bs).map(([categoryName, score]) => ({ categoryName, score })) }],
    };
    if (window.STILL_JAW !== undefined) result.faceBlendshapes[0].categories.find((c) => c.categoryName === 'jawOpen').score = window.STILL_JAW;
    const tracker = new window.LMFace.FaceTracker();
    const scare = new window.LMFace.ScareController();
    let t = 0, state;
    for (let i = 0; i < 6; i++) { t += 1 / 30; state = tracker.update(result, R.mapping, t); }
    const sc = { on: !!window.STILL_SCARE, onset: t - (window.STILL_SINCE ?? 2) };
    R.vis = 1;
    R.render(state, sc, t, 1 / 30);
    R.render(state, sc, t + 0.0001, 1 / 30);
    log('rendered  iod ' + state.iod.toFixed(1) + '  jaw ' + state.jaw.toFixed(2) + ' eyeWide ' + state.eyeWide.toFixed(2) + ' wideRatio ' + state.wideRatio.toFixed(2));
    if (window.STILL_DEBUG) {
      const c2 = document.createElement('canvas'); c2.width = 1280; c2.height = 720; c2.style.width = '100%';
      const x = c2.getContext('2d'); x.drawImage(canvas, 0, 0);
      x.fillStyle = '#ff0'; for (const e of [state.eyeA, state.eyeB]) { x.fillRect(e.center[0] - 3, e.center[1] - 3, 6, 6); }
      x.fillStyle = '#0ff'; const pa = R.project(...window.LMRender.ANCHORS.eyeA), pb = R.project(...window.LMRender.ANCHORS.eyeB);
      x.fillRect(pa[0] - 3, pa[1] - 3, 6, 6); x.fillRect(pb[0] - 3, pb[1] - 3, 6, 6);
      document.getElementById('stage').appendChild(c2);
      // raw frame as displayed (mirrored if enabled) with the tracked lips + eye corners
      const c3 = document.createElement('canvas'); c3.width = 1280; c3.height = 720; c3.style.width = '100%';
      const y = c3.getContext('2d'); const m = R.mapping;
      y.save(); if (mirror) { y.translate(1280, 0); y.scale(-1, 1); y.drawImage(img, 1280 - m.ox - m.dw, m.oy, m.dw, m.dh); } else y.drawImage(img, m.ox, m.oy, m.dw, m.dh); y.restore();
      y.strokeStyle = '#0f0'; y.lineWidth = 2; y.beginPath(); state.lips.forEach((p, i) => (i ? y.lineTo(p[0], p[1]) : y.moveTo(p[0], p[1]))); y.closePath(); y.stroke();
      y.fillStyle = '#f0f'; y.fillRect(state.lipTop[0] - 3, state.lipTop[1] - 3, 6, 6);
      for (const e of [state.eyeA, state.eyeB]) { y.fillStyle = '#ff0'; y.fillRect(e.outer[0] - 2, e.outer[1] - 2, 4, 4); y.fillRect(e.inner[0] - 2, e.inner[1] - 2, 4, 4); }
      document.getElementById('stage').appendChild(c3);
    }
  } catch (e) { log('EXC ' + e.message + '\n' + (e.stack || '').split('\n').slice(0, 5).join('\n')); }
})();

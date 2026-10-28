// Static look-dev harness: renders the mask with studio lighting, no camera, for screenshots.
(function () {
  const THREE = window.THREE;
  const log = (m) => { const el = document.getElementById('log'); if (el) el.textContent += '\n' + m; };
  window.onerror = (m, s, l) => log('ERR ' + m + ' @' + l);
  try {
    const W = 680, H = 680;
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setPixelRatio(1);
    renderer.setSize(W, H);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 0.95;
    document.getElementById('stage').appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x2b3340);
    const pmrem = new THREE.PMREMGenerator(renderer);
    scene.environment = pmrem.fromScene(new window.LMEnv.RoomEnvironment(), 0.04).texture;

    const camera = new THREE.PerspectiveCamera(32, W / H, 1, 1000);
    camera.position.set(0, -4, 200);

    const key = new THREE.DirectionalLight(0xffffff, 2.2);
    key.position.set(-60, 80, 120);
    scene.add(key);
    const rim = new THREE.DirectionalLight(0xdfe8ff, 1.2);
    rim.position.set(70, 30, -40);
    scene.add(rim);

    const t0 = performance.now();
    const params = Object.assign({}, window.PREVIEW_STYLE || {});
    const mask = window.LMMask.buildMask(params);
    log('built in ' + Math.round(performance.now() - t0) + ' ms');
    scene.add(mask.group);
    mask.group.rotation.y = window.PREVIEW_YAW || 0;
    mask.group.rotation.x = window.PREVIEW_PITCH || 0;

    // fake face behind: a skin-coloured oval so cutouts are visible
    const face = new THREE.Mesh(new THREE.CircleGeometry(30, 64), new THREE.MeshBasicMaterial({ color: 0xc9956f }));
    face.scale.set(0.8, 1, 1);
    face.position.set(-3, -2, -45);
    scene.add(face);

    const L = mask.anchors.leftEye, R = mask.anchors.rightEye;
    mask.cutters.set({
      leftEye: { x: L.x, y: L.y, w: 9, h: 5, rot: 0.05 },
      rightEye: { x: R.x, y: R.y, w: 9, h: 5, rot: -0.05 },
      mouth: { x: (L.x + R.x) / 2 + 1, y: L.y - 17, w: 14, h: 6 },
    });
    if (window.PREVIEW_SCARE) {
      mask.setScareInk(true);
      if (window.LMScare) window.LMScare.attachStencil(mask, 1);
    }
    renderer.render(scene, camera);
    log('rendered');
  } catch (e) { log('EXC ' + e.message + '\n' + (e.stack || '').split('\n').slice(0, 3).join('\n')); }
})();

// Look-dev: the inflatable alone, in a studio, for shape/material iteration.
(function () {
  const THREE = window.THREE;
  const log = (m) => { const el = document.getElementById('log'); if (el) el.textContent += '\n' + m; };
  window.onerror = (m, s, l) => log('ERR ' + m + ' @' + l);
  try {
    const W = 680, H = 640;
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(1);
    renderer.setSize(W, H);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.NeutralToneMapping;
    renderer.toneMappingExposure = 1.0;
    document.getElementById('stage').appendChild(renderer.domElement);
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x24364d);
    const pmrem = new THREE.PMREMGenerator(renderer);
    scene.environment = pmrem.fromScene(new window.LMEnv.RoomEnvironment(), 0.04).texture;
    scene.environmentIntensity = window.STUDIO_ENV ?? 0.9;
    const camera = new THREE.PerspectiveCamera(30, W / H, 1, 2000);
    camera.position.set(0, 0, 175);
    const key = new THREE.DirectionalLight(0xffffff, window.STUDIO_KEY ?? 1.6);
    key.position.set(-50, 70, 110);
    scene.add(key);
    const t0 = performance.now();
    const inf = window.LMInflate.buildInflatable(window.STUDIO_OPTS || {});
    log('build ' + JSON.stringify(inf.stats) + ' total ' + Math.round(performance.now() - t0) + 'ms');
    inf.uniforms.uOverlay.value = new THREE.DataTexture(new Uint8Array(4), 1, 1);
    inf.uniforms.uOverlay.value.needsUpdate = true;
    inf.uniforms.uRes.value.set(W, H);
    if (window.STUDIO_INK) inf.uniforms.uInk.value = 1;
    const grp = new THREE.Group();
    grp.add(inf.mesh);
    inf.mesh.position.set(-3, 2, 0);
    grp.rotation.set(window.STUDIO_PITCH || 0, window.STUDIO_YAW || 0, 0);
    scene.add(grp);
    renderer.render(scene, camera);
    log('rendered');
  } catch (e) { log('EXC ' + e.message + '\n' + (e.stack || '').split('\n').slice(0, 4).join('\n')); }
})();

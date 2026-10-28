// The inflatable LM headpiece: four round white "fingers" (one per logo bar) and a puffy palm behind
// them, with the blue logo baked onto the finger surfaces exactly where the SVG shapes project.
// Units: 1 = 1 SVG unit of the mark (72 wide). Mask-local frame: x right, y up, z toward the viewer,
// origin at the SVG viewBox centre.
(function (THREE) {
  const S = window.LMSvg;
  const CX = S.VIEW.w / 2, CY = S.VIEW.h / 2;
  const toWorld = (x, y) => new THREE.Vector2(x - CX, CY - y);
  const toSvg = (x, y) => [x + CX, CY - y];

  const DEFAULT_STYLE = {
    fingerPad: 1.6,        // extra radius of the inflated finger beyond the printed bar (units)
    fingerSink: 2.2,       // how deep the finger centre sits below the palm's front surface
    palmDepth: 6,          // palm slab thickness before the bevel
    palmBevel: 9,          // palm edge roundness
    palmTop: 34, palmBottom: 90, palmLeft: 3, palmRight: 69, palmRadius: 19,  // SVG coords
    vinylColor: 0xf6f7f9,
    roughness: 0.27,
    clearcoat: 0.9,
    clearcoatRoughness: 0.14,
    printRoughness: 0.33,
    envIntensity: 0.75,
    bakeSize: 1536,
    scareInk: 0x0b0b0d,
  };

  // Where the wearer's eyes sit in mask space (SVG coords): on the axes of the short and tall bars,
  // low enough that the palm is behind the nose bridge.
  const ANCHORS = { leftEye: [24.4, 40], rightEye: [40.7, 40] };

  // ------------------------------------------------------------------ geometry helpers
  function capsuleGeometry(R, L, radial = 72, capSeg = 20, lenSeg = 24) {
    const pts = [];
    for (let i = 0; i <= capSeg; i++) { const a = -Math.PI / 2 + (Math.PI / 2) * (i / capSeg); pts.push(new THREE.Vector2(Math.max(1e-4, R * Math.cos(a)), -L / 2 + R * Math.sin(a))); }
    for (let i = 1; i < lenSeg; i++) pts.push(new THREE.Vector2(R, -L / 2 + L * (i / lenSeg)));
    for (let i = 0; i <= capSeg; i++) { const a = (Math.PI / 2) * (i / capSeg); pts.push(new THREE.Vector2(Math.max(1e-4, R * Math.cos(a)), L / 2 + R * Math.sin(a))); }
    const g = new THREE.LatheGeometry(pts, radial);
    g.computeVertexNormals();
    return g;
  }

  function roundedRectShape(x0, y0, x1, y1, r) {
    const s = new THREE.Shape();
    s.moveTo(x0 + r, y0);
    s.lineTo(x1 - r, y0); s.absarc(x1 - r, y0 + r, r, -Math.PI / 2, 0, false);
    s.lineTo(x1, y1 - r); s.absarc(x1 - r, y1 - r, r, 0, Math.PI / 2, false);
    s.lineTo(x0 + r, y1); s.absarc(x0 + r, y1 - r, r, Math.PI / 2, Math.PI, false);
    s.lineTo(x0, y0 + r); s.absarc(x0 + r, y0 + r, r, Math.PI, Math.PI * 1.5, false);
    return s;
  }

  // Bar axis from the island polygon: PCA-free trick — the two cap centres are the extreme points
  // along the island's long diagonal. We use the known cap-end geometry from the SVG instead.
  const BARS = {
    short: { top: [27.58, 28.41], bottom: [21.52, 50.32], halfW: 4.68 },
    tall: { top: [46.99, 17.17], bottom: [37.89, 50.26], halfW: 4.69 },
    right: { top: [66.54, 5.85], bottom: [54.28, 50.20], halfW: 4.65 },
  };
  // Swoosh centreline (SVG coords), stub at the top-left running down and around to the right.
  const SWOOSH_PTS = [[8.05, 39.8], [6.9, 46.2], [7.3, 53.0], [10.2, 59.6], [15.2, 64.3], [22.0, 66.13], [49.89, 66.13]];
  const SWOOSH_HALF = 4.64;

  // ------------------------------------------------------------------ print bake
  // Island lookup bitmap (SVG space) so the bake tests "inside the logo shape" in O(1).
  const LOOKUP = 2048;
  function islandBitmap(poly) {
    const cv = document.createElement('canvas');
    cv.width = LOOKUP; cv.height = LOOKUP;
    const ctx = cv.getContext('2d');
    const sx = LOOKUP / S.VIEW.w, sy = LOOKUP / S.VIEW.h;
    ctx.fillStyle = '#000';
    ctx.beginPath();
    poly.forEach(([x, y], i) => (i ? ctx.lineTo(x * sx, y * sy) : ctx.moveTo(x * sx, y * sy)));
    ctx.closePath();
    ctx.fill();
    const d = ctx.getImageData(0, 0, LOOKUP, LOOKUP).data;
    const bits = new Uint8Array(LOOKUP * LOOKUP);
    for (let i = 0; i < bits.length; i++) bits[i] = d[i * 4 + 3] > 127 ? 1 : 0;
    return (x, y) => {
      const ix = (x * sx) | 0, iy = (y * sy) | 0;
      if (ix < 0 || iy < 0 || ix >= LOOKUP || iy >= LOOKUP) return 0;
      return bits[iy * LOOKUP + ix];
    };
  }

  // Rasterise the mesh's triangles in UV space; for each texel interpolate the mask-space position
  // and normal, and paint blue where the point projects inside the island and faces the viewer.
  function bakePrint(mesh, inside, size) {
    const geo = mesh.geometry;
    const pos = geo.attributes.position, nrm = geo.attributes.normal, uv = geo.attributes.uv;
    const idx = geo.index;
    const tri = idx ? idx.count / 3 : pos.count / 3;
    mesh.updateMatrixWorld(true);
    const M = mesh.matrixWorld.clone(); // mask group is at identity while baking
    const N = new THREE.Matrix3().getNormalMatrix(M);
    const img = new Uint8ClampedArray(size * size * 4);
    img.fill(255);
    const p = [new THREE.Vector3(), new THREE.Vector3(), new THREE.Vector3()];
    const n = [new THREE.Vector3(), new THREE.Vector3(), new THREE.Vector3()];
    const t = [new THREE.Vector2(), new THREE.Vector2(), new THREE.Vector2()];
    const P = new THREE.Vector3(), Nn = new THREE.Vector3();
    const eps = 0.8; // pixel expansion so seams between triangles close
    for (let f = 0; f < tri; f++) {
      for (let k = 0; k < 3; k++) {
        const vi = idx ? idx.getX(f * 3 + k) : f * 3 + k;
        p[k].fromBufferAttribute(pos, vi).applyMatrix4(M);
        n[k].fromBufferAttribute(nrm, vi).applyMatrix3(N);
        t[k].fromBufferAttribute(uv, vi).multiplyScalar(size);
      }
      // skip triangles entirely facing away (fast path)
      if (n[0].z < -0.2 && n[1].z < -0.2 && n[2].z < -0.2) continue;
      const minX = Math.max(0, Math.floor(Math.min(t[0].x, t[1].x, t[2].x) - eps));
      const maxX = Math.min(size - 1, Math.ceil(Math.max(t[0].x, t[1].x, t[2].x) + eps));
      const minY = Math.max(0, Math.floor(Math.min(t[0].y, t[1].y, t[2].y) - eps));
      const maxY = Math.min(size - 1, Math.ceil(Math.max(t[0].y, t[1].y, t[2].y) + eps));
      const area = (t[1].x - t[0].x) * (t[2].y - t[0].y) - (t[2].x - t[0].x) * (t[1].y - t[0].y);
      if (Math.abs(area) < 1e-6) continue;
      const inv = 1 / area;
      // barycentric tolerance equivalent to `eps` pixels outside each edge
      const tol0 = (eps * t[1].distanceTo(t[2])) / Math.abs(area);
      const tol1 = (eps * t[2].distanceTo(t[0])) / Math.abs(area);
      const tol2 = (eps * t[0].distanceTo(t[1])) / Math.abs(area);
      for (let y = minY; y <= maxY; y++) {
        const py = y + 0.5;
        for (let x = minX; x <= maxX; x++) {
          const px = x + 0.5;
          let w0 = ((t[1].x - px) * (t[2].y - py) - (t[2].x - px) * (t[1].y - py)) * inv;
          let w1 = ((t[2].x - px) * (t[0].y - py) - (t[0].x - px) * (t[2].y - py)) * inv;
          let w2 = 1 - w0 - w1;
          if (w0 < -tol0 || w1 < -tol1 || w2 < -tol2) continue;
          // clamp for interpolation
          w0 = Math.max(0, w0); w1 = Math.max(0, w1); w2 = Math.max(0, w2);
          const sw = w0 + w1 + w2; w0 /= sw; w1 /= sw; w2 /= sw;
          P.set(p[0].x * w0 + p[1].x * w1 + p[2].x * w2, p[0].y * w0 + p[1].y * w1 + p[2].y * w2, p[0].z * w0 + p[1].z * w1 + p[2].z * w2);
          Nn.set(n[0].x * w0 + n[1].x * w1 + n[2].x * w2, n[0].y * w0 + n[1].y * w1 + n[2].y * w2, n[0].z * w0 + n[1].z * w1 + n[2].z * w2);
          if (Nn.z <= 0.04) continue;
          const [sx, sy] = toSvg(P.x, P.y);
          if (!inside(sx, sy)) continue;
          const c = S.gradientAt(sx);
          const o = (y * size + x) * 4;
          img[o] = c[0]; img[o + 1] = c[1]; img[o + 2] = c[2];
        }
      }
    }
    return img;
  }

  function makeTexture(img, size) {
    const tex = new THREE.DataTexture(img, size, size, THREE.RGBAFormat);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.flipY = false;
    tex.generateMipmaps = true;
    tex.minFilter = THREE.LinearMipmapLinearFilter;
    tex.magFilter = THREE.LinearFilter;
    tex.anisotropy = 8;
    tex.needsUpdate = true;
    return tex;
  }

  // Ink variant: every printed texel becomes near-black.
  function inkVariant(img) {
    const out = new Uint8ClampedArray(img.length);
    for (let i = 0; i < img.length; i += 4) {
      const printed = !(img[i] === 255 && img[i + 1] === 255 && img[i + 2] === 255);
      if (printed) { out[i] = 11; out[i + 1] = 11; out[i + 2] = 13; } else { out[i] = out[i + 1] = out[i + 2] = 255; }
      out[i + 3] = 255;
    }
    return out;
  }

  // ------------------------------------------------------------------ build
  function buildMask(styleIn = {}) {
    const style = { ...DEFAULT_STYLE, ...styleIn };
    const islands = S.islands();
    const group = new THREE.Group();
    group.name = 'lmMask';

    const vinyl = () => new THREE.MeshPhysicalMaterial({
      color: style.vinylColor, roughness: style.roughness, metalness: 0,
      clearcoat: style.clearcoat, clearcoatRoughness: style.clearcoatRoughness,
      envMapIntensity: style.envIntensity,
    });

    // Palm (behind the fingers)
    const palmShapeSvg = roundedRectShape(style.palmLeft, style.palmTop, style.palmRight, style.palmBottom, style.palmRadius);
    // convert shape points to world (flip y)
    const palmShape = new THREE.Shape(palmShapeSvg.getPoints(48).map((p) => toWorld(p.x, p.y)));
    const palmGeo = new THREE.ExtrudeGeometry(palmShape, {
      depth: style.palmDepth, bevelEnabled: true, bevelThickness: style.palmBevel, bevelSize: style.palmBevel - 0.01,
      bevelSegments: 14, curveSegments: 24, steps: 1,
    });
    palmGeo.translate(0, 0, -style.palmDepth / 2);
    palmGeo.computeVertexNormals();
    const palm = new THREE.Mesh(palmGeo, vinyl());
    palm.name = 'palm';
    group.add(palm);
    const palmFront = style.palmDepth / 2 + style.palmBevel;

    // Fingers
    const printMeshes = []; // {mesh, island}
    const fingers = {};
    for (const key of ['short', 'tall', 'right']) {
      const b = BARS[key];
      const R = b.halfW + style.fingerPad;
      const top = toWorld(...b.top), bot = toWorld(...b.bottom);
      const dir = new THREE.Vector2().subVectors(top, bot);
      const L = dir.length();
      const mid = new THREE.Vector2().addVectors(top, bot).multiplyScalar(0.5);
      const geo = capsuleGeometry(R, L);
      const mesh = new THREE.Mesh(geo, vinyl());
      mesh.position.set(mid.x, mid.y, palmFront - style.fingerSink);
      mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), new THREE.Vector3(dir.x, dir.y, 0).normalize());
      mesh.name = 'finger_' + key;
      group.add(mesh);
      fingers[key] = mesh;
      printMeshes.push({ mesh, island: islands[key].poly });
    }

    // Swoosh: tube along the centreline + round caps
    {
      const R = SWOOSH_HALF + style.fingerPad;
      const z = palmFront - style.fingerSink;
      const pts = SWOOSH_PTS.map(([x, y]) => { const w = toWorld(x, y); return new THREE.Vector3(w.x, w.y, z); });
      const curve = new THREE.CatmullRomCurve3(pts, false, 'centripetal', 0.5);
      const tubeGeo = new THREE.TubeGeometry(curve, 180, R, 56, false);
      const tube = new THREE.Mesh(tubeGeo, vinyl());
      tube.name = 'swoosh';
      group.add(tube);
      printMeshes.push({ mesh: tube, island: islands.swoosh.poly });
      for (const [i, name] of [[0, 'swoosh_cap_a'], [pts.length - 1, 'swoosh_cap_b']]) {
        const cap = new THREE.Mesh(new THREE.SphereGeometry(R, 48, 32), vinyl());
        cap.position.copy(pts[i]);
        cap.name = name;
        group.add(cap);
        printMeshes.push({ mesh: cap, island: islands.swoosh.poly });
      }
      fingers.swoosh = tube;
    }

    // Bake the print (blue) and the scare variant (ink) for every printed mesh
    group.updateMatrixWorld(true);
    const printed = [];
    const lookups = new Map();
    for (const { mesh, island } of printMeshes) {
      if (!lookups.has(island)) lookups.set(island, islandBitmap(island));
      const img = bakePrint(mesh, lookups.get(island), style.bakeSize);
      const blue = makeTexture(img, style.bakeSize);
      const ink = makeTexture(inkVariant(img), style.bakeSize);
      mesh.material.map = blue;
      mesh.material.roughness = style.printRoughness;
      mesh.material.needsUpdate = true;
      printed.push({ mesh, blue, ink });
    }

    // Cutouts (depth-only occluders by default; black in scare mode)
    const cutters = makeCutters(group);

    const api = {
      group, palm, fingers, printed, cutters, style,
      anchors: {
        leftEye: toWorld(...ANCHORS.leftEye),
        rightEye: toWorld(...ANCHORS.rightEye),
      },
      frontZ: palmFront,
      setScareInk(on) {
        for (const p of printed) { p.mesh.material.map = on ? p.ink : p.blue; p.mesh.material.needsUpdate = true; }
        cutters.setBlack(on);
      },
      dispose() { group.traverse((o) => { if (o.isMesh) { o.geometry.dispose(); o.material.dispose(); } }); },
    };
    return api;
  }

  // ------------------------------------------------------------------ cutouts
  function makeCutters(group) {
    // Prism from well behind the palm to just in front of the finger surface. Keeping the near face
    // close to the surface keeps the perspective magnification of the hole negligible.
    const zBack = -30, zFront = 21, depth = zFront - zBack;
    const occluder = new THREE.MeshBasicMaterial({ colorWrite: false });
    const black = new THREE.MeshBasicMaterial({ color: 0x000000 });
    const eyeShape = new THREE.Shape();
    eyeShape.absellipse(0, 0, 0.5, 0.5, 0, Math.PI * 2, false, 0);
    const stadium = new THREE.Shape();
    // unit stadium: width 1, height 1 (scaled per frame)
    stadium.absarc(-0.25, 0, 0.5, Math.PI / 2, Math.PI * 1.5, false);
    stadium.absarc(0.25, 0, 0.5, -Math.PI / 2, Math.PI / 2, false);
    const mk = (shape, name) => {
      const g = new THREE.ExtrudeGeometry(shape, { depth, bevelEnabled: false, curveSegments: 40 });
      g.translate(0, 0, zBack);
      const m = new THREE.Mesh(g, occluder);
      m.renderOrder = -5;
      m.name = name;
      m.visible = false;
      group.add(m);
      return m;
    };
    const leftEye = mk(eyeShape, 'cut_leftEye');
    const rightEye = mk(eyeShape, 'cut_rightEye');
    const mouth = mk(stadium, 'cut_mouth');
    const place = (m, c, wUnit) => {
      if (!c) { m.visible = false; return; }
      m.visible = true;
      m.position.set(c.x, c.y, 0);
      m.scale.set(Math.max(0.1, c.w) / wUnit, Math.max(0.1, c.h), 1);
      m.rotation.z = c.rot || 0;
    };
    return {
      meshes: [leftEye, rightEye, mouth],
      // all coordinates in mask-local world units (x right, y up); w/h are full sizes
      set({ leftEye: le, rightEye: re, mouth: mo }) { place(leftEye, le, 1); place(rightEye, re, 1); place(mouth, mo, 1.5); },
      setBlack(on) { for (const m of [leftEye, rightEye, mouth]) m.material = on ? black : occluder; },
    };
  }

  window.LMMask = { buildMask, DEFAULT_STYLE, ANCHORS, toWorld, toSvg };
})(window.THREE);

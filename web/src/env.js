// Ports of three.js examples (RoomEnvironment, DecalGeometry) to the global THREE build used here.
// Source: https://github.com/mrdoob/three.js/tree/dev/examples/jsm (MIT).
(function (THREE) {
  // ---------------------------------------------------------------- RoomEnvironment
  class RoomEnvironment extends THREE.Scene {
    constructor() {
      super();
      const geometry = new THREE.BoxGeometry();
      geometry.deleteAttribute('uv');
      const roomMaterial = new THREE.MeshStandardMaterial({ side: THREE.BackSide });
      const boxMaterial = new THREE.MeshStandardMaterial();
      const mainLight = new THREE.PointLight(0xffffff, 900, 28, 2);
      mainLight.position.set(0.418, 16.199, 0.3);
      this.add(mainLight);
      const room = new THREE.Mesh(geometry, roomMaterial);
      room.position.set(-0.757, 13.219, 0.717);
      room.scale.set(31.713, 28.305, 28.591);
      this.add(room);
      const boxes = [
        [[-10.906, 2.009, 1.846], [0, -0.195, 0], [2.328, 7.905, 4.651]],
        [[-5.607, -0.754, -0.758], [0, 0.994, 0], [1.97, 1.534, 3.955]],
        [[6.167, 0.857, 7.803], [0, 0.561, 0], [3.927, 6.285, 3.687]],
        [[-2.017, 0.018, 6.124], [0, 0.333, 0], [2.002, 4.566, 2.064]],
        [[2.947, 0.774, -1.838], [0, 0.112, 0], [1.914, 3.278, 1.953]],
        [[-11.11, 4.76, 0], [0, 0.11, 0], [0.01, 2.0, 6.1]],
      ];
      for (const [p, r, s] of boxes) {
        const b = new THREE.Mesh(geometry, boxMaterial);
        b.position.set(...p); b.rotation.set(...r); b.scale.set(...s);
        this.add(b);
      }
      const lights = [
        [[-16.116, 14.37, 8.208], [0.1, 2.428, 0.1], 50],
        [[-16.109, 18.021, -8.207], [0.1, 2.425, 0.1], 50],
        [[14.904, 12.198, -1.832], [0.15, 4.265, 6.331], 17],
        [[-0.462, 8.89, 14.52], [4.38, 5.441, 0.088], 43],
        [[3.235, 11.486, -12.541], [2.5, 2.0, 0.1], 20],
        [[0, 20, 0], [1.0, 0.1, 1.0], 100],
      ];
      for (const [p, s, i] of lights) {
        const l = new THREE.Mesh(geometry, createAreaLightMaterial(i));
        l.position.set(...p); l.scale.set(...s);
        this.add(l);
      }
    }
    dispose() {
      const resources = new Set();
      this.traverse((o) => { if (o.isMesh) { resources.add(o.geometry); resources.add(o.material); } });
      for (const r of resources) r.dispose();
    }
  }
  function createAreaLightMaterial(intensity) {
    const m = new THREE.MeshBasicMaterial();
    m.color.setScalar(intensity);
    return m;
  }

  // ---------------------------------------------------------------- DecalGeometry
  const _plane = new THREE.Vector3();
  class DecalGeometry extends THREE.BufferGeometry {
    constructor(mesh, position, orientation, size) {
      super();
      const vertices = [], normals = [], uvs = [];
      const projectorMatrix = new THREE.Matrix4().makeRotationFromEuler(orientation).setPosition(position);
      const projectorMatrixInverse = new THREE.Matrix4().copy(projectorMatrix).invert();
      generate();
      this.setAttribute('position', new THREE.Float32BufferAttribute(vertices, 3));
      this.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
      this.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));

      function generate() {
        let decalVertices = [];
        const vertex = new THREE.Vector3(), normal = new THREE.Vector3();
        if (mesh.geometry.isBufferGeometry === false) return;
        const geometry = mesh.geometry;
        const positionAttribute = geometry.attributes.position;
        const normalAttribute = geometry.attributes.normal;
        if (geometry.index !== null) {
          const index = geometry.index;
          for (let i = 0; i < index.count; i++) {
            vertex.fromBufferAttribute(positionAttribute, index.getX(i));
            normal.fromBufferAttribute(normalAttribute, index.getX(i));
            pushDecalVertex(decalVertices, vertex, normal);
          }
        } else {
          for (let i = 0; i < positionAttribute.count; i++) {
            vertex.fromBufferAttribute(positionAttribute, i);
            normal.fromBufferAttribute(normalAttribute, i);
            pushDecalVertex(decalVertices, vertex, normal);
          }
        }
        decalVertices = clipGeometry(decalVertices, _plane.set(1, 0, 0));
        decalVertices = clipGeometry(decalVertices, _plane.set(-1, 0, 0));
        decalVertices = clipGeometry(decalVertices, _plane.set(0, 1, 0));
        decalVertices = clipGeometry(decalVertices, _plane.set(0, -1, 0));
        decalVertices = clipGeometry(decalVertices, _plane.set(0, 0, 1));
        decalVertices = clipGeometry(decalVertices, _plane.set(0, 0, -1));
        for (let i = 0; i < decalVertices.length; i++) {
          const d = decalVertices[i];
          uvs.push(0.5 + d.position.x / size.x, 0.5 + d.position.y / size.y);
          d.position.applyMatrix4(projectorMatrix);
          vertices.push(d.position.x, d.position.y, d.position.z);
          normals.push(d.normal.x, d.normal.y, d.normal.z);
        }
      }
      function pushDecalVertex(decalVertices, vertex, normal) {
        vertex.applyMatrix4(mesh.matrixWorld);
        vertex.applyMatrix4(projectorMatrixInverse);
        normal.transformDirection(mesh.matrixWorld);
        decalVertices.push(new DecalVertex(vertex.clone(), normal.clone()));
      }
      function clipGeometry(inVertices, plane) {
        const outVertices = [];
        const s = 0.5 * Math.abs(size.dot(plane));
        for (let i = 0; i < inVertices.length; i += 3) {
          let total = 0;
          let nV1, nV2, nV3, nV4;
          const d1 = inVertices[i + 0].position.dot(plane) - s;
          const d2 = inVertices[i + 1].position.dot(plane) - s;
          const d3 = inVertices[i + 2].position.dot(plane) - s;
          const v1Out = d1 > 0, v2Out = d2 > 0, v3Out = d3 > 0;
          total = (v1Out ? 1 : 0) + (v2Out ? 1 : 0) + (v3Out ? 1 : 0);
          switch (total) {
            case 0:
              outVertices.push(inVertices[i], inVertices[i + 1], inVertices[i + 2]);
              break;
            case 1:
              if (v1Out) { nV1 = inVertices[i + 1]; nV2 = inVertices[i + 2]; nV3 = clip(inVertices[i], nV1, plane, s); nV4 = clip(inVertices[i], nV2, plane, s); }
              if (v2Out) { nV1 = inVertices[i]; nV2 = inVertices[i + 2]; nV3 = clip(inVertices[i + 1], nV1, plane, s); nV4 = clip(inVertices[i + 1], nV2, plane, s); outVertices.push(nV3, nV2.clone(), nV1); outVertices.push(nV2.clone(), nV3.clone(), nV4); break; }
              if (v3Out) { nV1 = inVertices[i]; nV2 = inVertices[i + 1]; nV3 = clip(inVertices[i + 2], nV1, plane, s); nV4 = clip(inVertices[i + 2], nV2, plane, s); }
              outVertices.push(nV1.clone(), nV2.clone(), nV3); outVertices.push(nV4, nV3.clone(), nV2.clone());
              break;
            case 2:
              if (!v1Out) { nV1 = inVertices[i].clone(); nV2 = clip(nV1, inVertices[i + 1], plane, s); nV3 = clip(nV1, inVertices[i + 2], plane, s); outVertices.push(nV1, nV2, nV3); }
              if (!v2Out) { nV1 = inVertices[i + 1].clone(); nV2 = clip(nV1, inVertices[i + 2], plane, s); nV3 = clip(nV1, inVertices[i], plane, s); outVertices.push(nV1, nV2, nV3); }
              if (!v3Out) { nV1 = inVertices[i + 2].clone(); nV2 = clip(nV1, inVertices[i], plane, s); nV3 = clip(nV1, inVertices[i + 1], plane, s); outVertices.push(nV1, nV2, nV3); }
              break;
            case 3: break;
          }
        }
        return outVertices;
      }
      function clip(v0, v1, p, s) {
        const d0 = v0.position.dot(p) - s, d1 = v1.position.dot(p) - s;
        const s0 = d0 / (d0 - d1);
        const v = new DecalVertex(
          new THREE.Vector3(v0.position.x + s0 * (v1.position.x - v0.position.x), v0.position.y + s0 * (v1.position.y - v0.position.y), v0.position.z + s0 * (v1.position.z - v0.position.z)),
          new THREE.Vector3(v0.normal.x + s0 * (v1.normal.x - v0.normal.x), v0.normal.y + s0 * (v1.normal.y - v0.normal.y), v0.normal.z + s0 * (v1.normal.z - v0.normal.z)),
        );
        return v;
      }
    }
  }
  class DecalVertex {
    constructor(position, normal) { this.position = position; this.normal = normal; }
    clone() { return new this.constructor(this.position.clone(), this.normal.clone()); }
  }

  window.LMEnv = { RoomEnvironment, DecalGeometry };
})(window.THREE);

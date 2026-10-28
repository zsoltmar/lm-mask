// Generic "inflate a 2D shape" mesher: chambers (signed-distance functions in a 2D plane, x right,
// y down) get puffy height profiles, the max of the profiles is the front surface, a thinner back
// closes the solid, and surface nets polygonise it. Used for the wizard's bomber jacket and collar.
(function (THREE) {
  'use strict';

  const segDist = (px, py, ax, ay, bx, by) => {
    const pax = px - ax, pay = py - ay, bax = bx - ax, bay = by - ay;
    let h = (pax * bax + pay * bay) / (bax * bax + bay * bay || 1);
    h = h < 0 ? 0 : h > 1 ? 1 : h;
    return Math.hypot(pax - bax * h, pay - bay * h);
  };
  // chamber helpers: each returns f(x, y) = signed distance, positive inside
  const capsule = (ax, ay, bx, by, r) => (x, y) => r - segDist(x, y, ax, ay, bx, by);
  // capsule whose radius goes from r0 at a to r1 at b
  const taperCapsule = (ax, ay, bx, by, r0, r1) => (x, y) => {
    const pax = x - ax, pay = y - ay, bax = bx - ax, bay = by - ay;
    let h = (pax * bax + pay * bay) / (bax * bax + bay * bay || 1);
    h = h < 0 ? 0 : h > 1 ? 1 : h;
    return r0 + (r1 - r0) * h - Math.hypot(pax - bax * h, pay - bay * h);
  };
  const roundRect = (x0, y0, x1, y1, r) => (x, y) => {
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, hx = (x1 - x0) / 2 - r, hy = (y1 - y0) / 2 - r;
    const qx = Math.abs(x - cx) - hx, qy = Math.abs(y - cy) - hy;
    const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0);
    return r - outside;
  };
  const polygon = (poly) => (px, py) => {
    let d = Infinity, inside = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const [xi, yi] = poly[i], [xj, yj] = poly[j];
      d = Math.min(d, segDist(px, py, xj, yj, xi, yi));
      if ((yi > py) !== (yj > py) && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside ? d : -d;
  };

  function blur(src, nx, ny, r) {
    const tmp = new Float32Array(src.length), out = new Float32Array(src.length);
    const w = []; let ws = 0;
    for (let k = -r; k <= r; k++) { const v = Math.exp(-(k * k) / (2 * Math.max(0.6, r * 0.6) ** 2)); w.push(v); ws += v; }
    for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) { let a = 0; for (let k = -r; k <= r; k++) a += src[j * nx + Math.min(nx - 1, Math.max(0, i + k))] * w[k + r]; tmp[j * nx + i] = a / ws; }
    for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) { let a = 0; for (let k = -r; k <= r; k++) a += tmp[Math.min(ny - 1, Math.max(0, j + k)) * nx + i] * w[k + r]; out[j * nx + i] = a / ws; }
    return out;
  }

  // opts: { chambers: [{ f, dome, domeR, lift }], bounds: [x0, y0, x1, y1], grid, edge, back }
  function inflate(opts) {
    const { chambers, bounds: [x0, y0, x1, y1] } = opts;
    const g = opts.grid || 0.05, E = opts.edge || 0.6, back = opts.back ?? 0.45, soft = opts.soft ?? 0.06;
    const nx = Math.round((x1 - x0) / g) + 1, ny = Math.round((y1 - y0) / g) + 1, N = nx * ny;
    const H = new Float32Array(N);
    const prof = (s, c) => {
      if (s <= 0) return s;
      const roll = s < E ? Math.sqrt(E * E - (E - s) * (E - s)) : E;
      const t = Math.min(s / (c.domeR || 1), 1);
      return roll * (c.edgeScale || 1) + (c.dome || 0) * (1 - (1 - t) * (1 - t)) + (c.lift || 0) * Math.min(1, s / E);
    };
    const smax = (a, b, k) => { const h = Math.max(k - Math.abs(a - b), 0) / k; return Math.max(a, b) + h * h * k * 0.25; };
    for (let j = 0; j < ny; j++) {
      const y = y0 + j * g;
      for (let i = 0; i < nx; i++) {
        const x = x0 + i * g;
        let h = -Infinity;
        for (const c of chambers) { const s = c.f(x, y); const v = prof(s, c); h = s > 0 && h > 0 ? smax(h, v, soft) : Math.max(h, v); }
        H[j * nx + i] = h;
      }
    }
    const Hb = blur(H, nx, ny, 1);
    for (let id = 0; id < N; id++) if (H[id] > 0.25 * E) H[id] = Hb[id];

    // surface nets on F = z − H (front) / −z − back·H (back)
    let hmax = 0; for (let id = 0; id < N; id++) hmax = Math.max(hmax, H[id]);
    const zb = -Math.ceil((hmax * back) / g + 2) * g, zt = hmax + 2 * g;
    const nz = Math.round((zt - zb) / g) + 1;
    const F = new Float32Array(nx * ny * nz);
    for (let k = 0; k < nz; k++) { const z = zb + k * g; for (let id = 0; id < N; id++) { const h = H[id]; F[k * N + id] = z >= 0 ? z - h : -z - (h > 0 ? h * back : h); } }
    const idx = (i, j, k) => k * N + j * nx + i;
    const cellV = new Int32Array(nx * ny * nz).fill(-1);
    const pos = [], tris = [];
    const EDG = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]];
    const cv = new Float32Array(8);
    for (let k = 0; k < nz - 1; k++) for (let j = 0; j < ny - 1; j++) for (let i = 0; i < nx - 1; i++) {
      let mask = 0;
      for (let c = 0; c < 8; c++) { const v = F[idx(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1))]; cv[c] = v; if (v < 0) mask |= 1 << c; }
      if (mask === 0 || mask === 255) continue;
      let sx = 0, sy = 0, sz = 0, n = 0;
      for (const [a, b] of EDG) {
        if (((mask >> a) & 1) === ((mask >> b) & 1)) continue;
        const t = cv[a] / (cv[a] - cv[b]);
        sx += (a & 1) + ((b & 1) - (a & 1)) * t; sy += ((a >> 1) & 1) + (((b >> 1) & 1) - ((a >> 1) & 1)) * t; sz += ((a >> 2) & 1) + (((b >> 2) & 1) - ((a >> 2) & 1)) * t; n++;
      }
      const vi = pos.length / 3;
      cellV[idx(i, j, k)] = vi;
      pos.push(x0 + (i + sx / n) * g, y0 + (j + sy / n) * g, zb + (k + sz / n) * g);
      const in0 = mask & 1;
      const quad = (a, b, c, d) => { if (in0) tris.push(a, b, c, a, c, d); else tris.push(a, c, b, a, d, c); };
      if (((mask >> 1) & 1) !== in0 && j > 0 && k > 0) quad(vi, cellV[idx(i, j - 1, k)], cellV[idx(i, j - 1, k - 1)], cellV[idx(i, j, k - 1)]);
      if (((mask >> 2) & 1) !== in0 && i > 0 && k > 0) quad(vi, cellV[idx(i, j, k - 1)], cellV[idx(i - 1, j, k - 1)], cellV[idx(i - 1, j, k)]);
      if (((mask >> 4) & 1) !== in0 && i > 0 && j > 0) quad(vi, cellV[idx(i - 1, j, k)], cellV[idx(i - 1, j - 1, k)], cellV[idx(i, j - 1, k)]);
    }
    // to world (x right, y up, z out) + uv over bounds + front flag
    const nV = pos.length / 3;
    const P = new Float32Array(nV * 3), UV = new Float32Array(nV * 2), FR = new Float32Array(nV);
    for (let v = 0; v < nV; v++) {
      const x = pos[v * 3], y = pos[v * 3 + 1], z = pos[v * 3 + 2];
      P[v * 3] = x; P[v * 3 + 1] = -y; P[v * 3 + 2] = z;
      UV[v * 2] = (x - x0) / (x1 - x0); UV[v * 2 + 1] = 1 - (y - y0) / (y1 - y0);
      FR[v] = Math.min(1, Math.max(0, z / (0.4 * E)));
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(P, 3));
    geo.setAttribute('uv', new THREE.BufferAttribute(UV, 2));
    geo.setAttribute('aFront', new THREE.BufferAttribute(FR, 1));
    geo.setIndex(nV > 65535 ? new THREE.Uint32BufferAttribute(tris, 1) : new THREE.Uint16BufferAttribute(tris, 1));
    geo.computeVertexNormals();
    // fix winding if the mesh came out inside-out (front normals must face +z)
    const Nn = geo.attributes.normal.array;
    let score = 0;
    for (let v = 0; v < nV; v += 7) if (P[v * 3 + 2] > 0.5 * hmax) score += Nn[v * 3 + 2];
    if (score < 0) {
      const ix = geo.index.array;
      for (let t = 0; t < ix.length; t += 3) { const s = ix[t + 1]; ix[t + 1] = ix[t + 2]; ix[t + 2] = s; }
      geo.index.needsUpdate = true;
      geo.computeVertexNormals();
    }
    geo.computeBoundingSphere();
    const heightAt = (x, y) => {
      const fx = (x - x0) / g, fy = (y - y0) / g;
      const i = Math.max(0, Math.min(nx - 2, Math.floor(fx))), j = Math.max(0, Math.min(ny - 2, Math.floor(fy)));
      const tx = fx - i, ty = fy - j;
      return (H[j * nx + i] * (1 - tx) + H[j * nx + i + 1] * tx) * (1 - ty) + (H[(j + 1) * nx + i] * (1 - tx) + H[(j + 1) * nx + i + 1] * tx) * ty;
    };
    return { geometry: geo, heightAt, bounds: [x0, y0, x1, y1] };
  }

  window.LMInflateGeo = { inflate, capsule, taperCapsule, roundRect, polygon, segDist };
})(window.THREE);

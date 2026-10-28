// Minimal SVG path support for the LM mark: absolute M / L / C / Z only (that is all the file uses).
// Produces flattened polygons in SVG space (y down) and point-in-polygon tests.
(function () {
  const MARK_PATH = 'M20.307 54.885 C22.837 55.563 25.37 54.033 26.032 51.546 L32.091 29.633 C32.758 27.114 31.376 24.238 28.882 23.563 C26.387 22.886 23.728 24.668 23.061 27.188 L17.002 49.102 C16.335 51.622 17.813 54.211 20.307 54.885 Z M36.678 54.828 C39.218 55.508 41.756 53.968 42.417 51.484 L51.52 18.394 C52.188 15.87 50.707 13.277 48.206 12.601 C45.705 11.926 43.136 13.421 42.467 15.945 L33.365 49.034 C32.695 51.559 34.177 54.153 36.678 54.828 Z M49.893 61.486 L21.52 61.486 C14.219 61.486 8.908 54.509 10.777 47.452 L12.534 41.01 C13.197 38.533 11.729 35.987 9.252 35.325 C6.775 34.662 4.231 36.129 3.567 38.606 L1.804 45.074 C-1.608 57.95 8.1 70.769 21.52 70.769 L49.893 70.769 C52.458 70.769 54.534 68.688 54.534 66.126 C54.534 63.564 52.457 61.486 49.893 61.486 Z M67.799 1.294 C65.328 0.586 62.762 2.056 62.069 4.575 L49.81 48.919 C49.117 51.438 50.555 54.053 53.027 54.758 C55.519 55.463 58.064 53.974 58.757 51.477 L71.016 7.133 C71.709 4.614 70.271 1.999 67.799 1.294 Z';
  const VIEW = { w: 72.307, h: 71.885 };

  function parse(d, bezierSteps = 14) {
    const tokens = d.match(/[MLCZ]|-?\d*\.?\d+(?:e-?\d+)?/gi);
    const polys = [];
    let cur = null, pos = [0, 0], i = 0;
    const num = () => parseFloat(tokens[i++]);
    while (i < tokens.length) {
      const t = tokens[i++];
      if (t === 'M') { cur = []; polys.push(cur); pos = [num(), num()]; cur.push(pos); }
      else if (t === 'L') { pos = [num(), num()]; cur.push(pos); }
      else if (t === 'C') {
        const p0 = pos, p1 = [num(), num()], p2 = [num(), num()], p3 = [num(), num()];
        for (let s = 1; s <= bezierSteps; s++) {
          const u = s / bezierSteps, v = 1 - u;
          cur.push([
            v * v * v * p0[0] + 3 * v * v * u * p1[0] + 3 * v * u * u * p2[0] + u * u * u * p3[0],
            v * v * v * p0[1] + 3 * v * v * u * p1[1] + 3 * v * u * u * p2[1] + u * u * u * p3[1],
          ]);
        }
        pos = p3;
      }
      else if (t === 'Z') { /* closed implicitly */ }
    }
    return polys;
  }

  function bbox(poly) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const [x, y] of poly) { if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; }
    return { x0, y0, x1, y1, w: x1 - x0, h: y1 - y0, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
  }

  function pointInPoly(poly, x, y) {
    let inside = false;
    for (let a = 0, b = poly.length - 1; a < poly.length; b = a++) {
      const [xa, ya] = poly[a], [xb, yb] = poly[b];
      if ((ya > y) !== (yb > y) && x < ((xb - xa) * (y - ya)) / (yb - ya) + xa) inside = !inside;
    }
    return inside;
  }

  // Islands in a stable order, identified by bounding box: swoosh = widest, right = tallest,
  // short = shortest of the rest, tall = the other.
  function islands() {
    const polys = parse(MARK_PATH).map((p) => ({ poly: p, box: bbox(p) }));
    const byW = [...polys].sort((a, b) => b.box.w - a.box.w);
    const swoosh = byW[0];
    const rest = polys.filter((p) => p !== swoosh);
    const byH = [...rest].sort((a, b) => b.box.h - a.box.h);
    const right = byH[0];
    const mid = rest.filter((p) => p !== right).sort((a, b) => a.box.h - b.box.h);
    return { short: mid[0], tall: mid[1], swoosh, right, all: polys };
  }

  // Logo gradient (teal -> blue) sampled by SVG x.
  function gradientAt(x) {
    const t = Math.min(1, Math.max(0, (x - 1.116) / (71.19 - 1.116)));
    const a = [0x00, 0xb3, 0xc0], b = [0x00, 0x9c, 0xe4];
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
  }

  window.LMSvg = { MARK_PATH, VIEW, parse, bbox, pointInPoly, islands, gradientAt };
})();

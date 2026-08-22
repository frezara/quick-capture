// Colour math shared by the design generators under design/.
//
// sRGB <-> oklch/oklab conversion (so palette values are derived rather than
// eyeballed), alpha compositing, and WCAG 2.1 contrast. Kept here because two
// generators need the same numbers and a second copy would drift.

// oklch() -> sRGB hex, so the warm neutrals are derived rather than eyeballed.
export function oklch(L, C, H) {
  const a = C * Math.cos((H * Math.PI) / 180);
  const b = C * Math.sin((H * Math.PI) / 180);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
  const lin = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
  const to8 = (v) => {
    const c = v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(Math.max(v, 0), 1 / 2.4) - 0.055;
    return Math.round(Math.min(1, Math.max(0, c)) * 255);
  };
  return "#" + lin.map(to8).map((n) => n.toString(16).padStart(2, "0")).join("").toUpperCase();
}

// Same shape, but returned as an rgba() string at `alpha` — for the tokens the
// app expresses as translucent washes.
export function oklcha(L, C, H, alpha) {
  const hex = oklch(L, C, H);
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  return `rgba(${r},${g},${b},${alpha})`;
}

export function parseColor(css) {
  const m = css.trim().match(/^#([0-9a-f]{6})$/i);
  if (m) return [...[0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16)), 1];
  const r = css.trim().match(/^rgba?\(([^)]+)\)$/i);
  if (!r) return null;
  const p = r[1].split(",").map((s) => parseFloat(s));
  return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
}

export function over(fg, bg) {                       // composite fg (with alpha) on bg
  const f = parseColor(fg), b = parseColor(bg);
  if (!f || !b) return null;
  return [0, 1, 2].map((i) => f[i] * f[3] + b[i] * (1 - f[3])).concat(1);
}

export function luminance([r, g, b]) {
  const c = [r, g, b].map((v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

export function contrast(fgCss, bgCss) {             // WCAG 2.1, fg composited on bg
  const bg = parseColor(bgCss);
  const fg = over(fgCss, bgCss);
  if (!fg || !bg) return null;
  const [a, b] = [luminance(fg), luminance(bg)].sort((x, y) => y - x);
  return (a + 0.05) / (b + 0.05);
}

// oklab mix of two opaque colours at `pct` — mirrors CSS color-mix(in oklab),
// used only to *predict* contrast for the mixes the artboards do in CSS.
export function srgbToOklab(css) {
  const [r, g, b] = parseColor(css);
  const lin = [r, g, b].map((v) => {
    const s = v / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  const l = Math.cbrt(0.4122214708 * lin[0] + 0.5363325363 * lin[1] + 0.0514459929 * lin[2]);
  const m = Math.cbrt(0.2119034982 * lin[0] + 0.6806995451 * lin[1] + 0.1073969566 * lin[2]);
  const s = Math.cbrt(0.0883024619 * lin[0] + 0.2817188376 * lin[1] + 0.6299787005 * lin[2]);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

export function oklabToHex([L, a, b]) {
  const C = Math.hypot(a, b);
  const H = (Math.atan2(b, a) * 180) / Math.PI;
  return oklch(L, C, H);
}

export function mixOklab(cssA, cssB, pct) {
  const A = srgbToOklab(cssA), B = srgbToOklab(cssB);
  const t = pct / 100;
  return oklabToHex([0, 1, 2].map((i) => A[i] * t + B[i] * (1 - t)));
}


/// An opaque colour as #RRGGBB, from the [r,g,b,a] `over()` returns.
export function hex(rgb) {
  return "#" + rgb.slice(0, 3)
    .map((n) => Math.round(n).toString(16).padStart(2, "0")).join("").toUpperCase();
}

/// `fg` composited over `bg`, as a hex string.
export function flatten(fg, bg) {
  return hex(over(fg, bg));
}

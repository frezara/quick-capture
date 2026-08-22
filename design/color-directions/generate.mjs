// Generates the issue #101 colour-direction artboards (.dc.html) + canvas.json.
// One markup template, five token sets — the point being that every difference
// between the directions is a TOKEN difference, not a structural one.
//
//   node design/color-directions/generate.mjs
//
// Geometry, type and colour are lifted verbatim from the app:
//   Sources/QuickCapture/DesignSystem.swift   (Theme, Metrics, TypeScale)
//   Sources/QuickCapture/CaptureView.swift    (capture box + picker anatomy)
//   Sources/QuickCapture/TagColor.swift       (TagPalette + DJB2 hue hash)
//   editor-web/src/editor.ts                  (editor palettes + CodeMirror theme)

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = dirname(fileURLToPath(import.meta.url));
mkdirSync(OUT, { recursive: true });

import {
  oklch, oklcha, parseColor, over, luminance, contrast,
  srgbToOklab, oklabToHex, mixOklab,
} from "../lib/color.mjs";

// ------------------------------------------------------------------ tag hues

// DJB2 with 64-bit two's-complement wrap — byte-for-byte the hash in
// TagColor.swift / editor.ts, so the section dots here are the hues the app
// would actually pick for these section names.
const U64 = (1n << 64n) - 1n;
const I64_MIN = 1n << 63n;
function hueIndex(name) {
  let h = 5381n;
  for (const ch of name.toLowerCase()) h = (h * 33n + BigInt(ch.codePointAt(0))) & U64;
  let signed = h >= I64_MIN ? h - (U64 + 1n) : h;
  if (signed < 0n) signed = -signed;
  return Number(signed % 8n);
}

const HUES_LIGHT = ["#E8643F", "#2A9D8F", "#C2479B", "#4F9E4F", "#3B82F6", "#C77800", "#5856D6", "#64748B"];
const HUES_DARK  = ["#F4795A", "#3DBDAD", "#DA62B4", "#5FBF60", "#5C9DFF", "#E0A33E", "#7D7AFF", "#8B98AB"];

const SECTIONS = ["Quick capture", "design", "shortcuts"];
const HUE_OF = Object.fromEntries(SECTIONS.map((s) => [s, hueIndex(s)]));
const TAG_HUE = hueIndex("design");

// ------------------------------------------------------------------- content

// Realistic capture-file content — the editor mock renders this as CodeMirror
// would with live preview on and the cursor off every line.
const DOC = [
  { h2: "Quick capture", items: [
    { t: "Warm the surface tokens without losing contrast", pri: "high" },
    { t: "Check the hint-bar chips track a rebind", pri: "low" },
    { t: "Cap the capture box at six lines", done: true },
  ]},
  { h2: "design", items: [
    { t: "Section headings should scan by colour", pri: "med" },
    { t: "Pick light + dark pairs for every hue", indent: 1 },
    { attach: "screenshot-2026-06-13-225151.png", indent: 1 },
    { t: "Retire slate from the tag palette", pri: "low" },
  ]},
  { h2: "shortcuts", items: [
    { t: "⌥⌘U refile lands the cursor on the next item", done: true },
    { t: "Editor menu titles come from the registry" },
  ]},
];

const SHOTS = [
  { time: "1:19 PM", day: "Today", sel: true,  cur: true  },
  { time: "1:04 PM", day: "Today", sel: true,  cur: false },
  { time: "12:47 PM", day: "Today", sel: false, cur: false },
  { time: "9:58 AM", day: "Today", sel: false, cur: false },
  { time: "6:32 PM", day: "Yesterday", sel: false, cur: false },
];

// --------------------------------------------------------------- svg helpers

// Abstract stand-in art for the screenshots — placeholders on purpose, so no
// one reads them as real captured content.
function shotArt(w, h, seed) {
  const rows = [[10, 62], [10, 44], [10, 70], [10, 36]];
  const bars = rows.slice(0, seed % 2 ? 4 : 3).map((r, i) =>
    `<rect x="${10}" y="${26 + i * 11}" width="${r[1] - (i === seed % 3 ? 14 : 0)}%" height="5" rx="2.5" fill="var(--ph-line)"/>`).join("");
  return `<svg viewBox="0 0 120 75" preserveAspectRatio="none" style="display:block;width:${w};height:${h};background:var(--ph-bg);">
      <rect x="0" y="0" width="120" height="14" fill="var(--ph-bar)"/>
      <circle cx="8" cy="7" r="2.4" fill="var(--ph-line)"/><circle cx="16" cy="7" r="2.4" fill="var(--ph-line)"/><circle cx="24" cy="7" r="2.4" fill="var(--ph-line)"/>
      ${bars}
    </svg>`;
}

function icon(path, size = 12, stroke = "currentColor") {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="${stroke}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="width:${size}px;height:${size}px;display:block;">${path}</svg>`;
}
const ICON_CHECK = '<polyline points="20 6 9 17 4 12"/>';
const ICON_CLOSE = '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>';
const ICON_IMAGE = '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/>';

// ------------------------------------------------------------------- surfaces

const SANS = "var(--sans)";
const MONO = "var(--mono)";

// Editor mode — opaque window, 1000×470 crop of the full-height editor.
// Values from editor.ts makeTheme(): content padding 36/44, mono 13/1.6,
// H1 22px semibold + 26px accent app-mark, H2 11px semibold uppercase tracked
// 0.8 with a 7px hue dot and a hairline rule, 15px r4 checkbox, 9px priority
// orb with a 3px halo, 33px status bar.
function editorMock(hues) {
  const line = (inner, extra = "") =>
    `<div style="position:relative;padding-right:28px;${extra}">${inner}</div>`;

  // Checked box draws the tick as a child SVG rather than editor.ts's CSS
  // background-image — same 15px/r4 geometry, but it survives being inlined in
  // an HTML style attribute.
  const checkbox = (done) => done
    ? `<span style="display:inline-flex;align-items:center;justify-content:center;width:15px;height:15px;margin:0 10px 0 0;border-radius:4px;vertical-align:-3px;background-color:var(--cb-checked);border:1px solid var(--cb-checked);color:#FFF;">${icon(ICON_CHECK, 10, "#FFF")}</span>`
    : `<span style="display:inline-block;width:15px;height:15px;margin:0 10px 0 0;border-radius:4px;vertical-align:-3px;border:1px solid var(--cb-border);background-color:transparent;"></span>`;

  const orb = (pri) => pri
    ? `<span style="position:absolute;right:8px;top:0.6em;width:9px;height:9px;border-radius:50%;background:var(--pri-${pri});box-shadow:0 0 0 3px color-mix(in oklab, var(--pri-${pri}) var(--pri-halo), transparent);"></span>`
    : "";

  const guide = `<span style="position:absolute;left:1.5ch;top:0;width:1px;height:1.6em;background:var(--guide);"></span>`;

  const body = DOC.map((sec) => {
    const hue = `var(--hue-${hues[sec.h2]})`;
    const rows = sec.items.map((it) => {
      const pad = it.indent ? `padding-left:4ch;` : "";
      const g = it.indent ? guide : "";
      if (it.attach) {
        return line(`${g}<span style="display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:6px;background:var(--field);border:0.5px solid var(--hair);color:var(--ink3);font-size:12px;line-height:1.5;vertical-align:1px;">${icon(ICON_IMAGE, 11)}<span>${it.attach}</span></span>`, pad);
      }
      const label = it.done
        ? `<span style="text-decoration:line-through;text-decoration-color:var(--ink3);color:var(--ink3);">${it.t}</span>`
        : `<span style="color:var(--ink);">${it.t}</span>`;
      return line(`${g}${checkbox(it.done)}${label}${orb(it.pri)}`, pad);
    }).join("");

    return `<div style="--hue:${hue};">
      <div style="display:flex;align-items:center;margin:0 -10px;padding:10px 10px 3px;border-radius:6px 6px 0 0;border-bottom:0.5px solid var(--sec-rule);background:color-mix(in oklab, var(--hue) var(--band-mix), transparent);font-family:${SANS};font-size:11px;font-weight:600;line-height:2;letter-spacing:0.8px;text-transform:uppercase;color:color-mix(in oklab, var(--hue) var(--sec-ink-mix), var(--ink2));">
        <span style="width:7px;height:7px;border-radius:50%;margin-right:8px;background:var(--hue);flex:none;"></span>${sec.h2}
      </div>
      <div style="padding-top:2px;">${rows}</div>
    </div>`;
  }).join("");

  return `<div style="position:relative;width:1000px;height:470px;border-radius:12px;overflow:hidden;background:var(--win);box-shadow:0 0 0 0.5px var(--ring), inset 0 1px 0 var(--edge), 0 24px 70px rgba(0,0,0,0.28), 0 4px 16px rgba(0,0,0,0.10);">
    <div style="padding:36px 44px 0;font-family:${MONO};font-size:13px;line-height:1.6;">
      <div style="display:flex;align-items:center;line-height:1.4;">
        <span style="display:inline-flex;align-items:center;justify-content:center;width:26px;height:26px;margin-right:10px;border-radius:7px;background:linear-gradient(180deg, color-mix(in srgb, var(--accent) 90%, transparent), var(--accent));color:#FFF;font-family:${SANS};font-size:15px;font-weight:700;">#</span>
        <span style="font-family:${SANS};font-size:22px;font-weight:600;letter-spacing:-0.3px;color:var(--ink);">Inbox</span>
      </div>
      ${body}
    </div>
    <div style="position:absolute;left:0;right:0;bottom:0;height:33px;display:flex;align-items:center;gap:16px;padding:0 16px;background:linear-gradient(0deg, var(--rail), var(--rail)) var(--win);border-top:0.5px solid var(--hair);font-family:${SANS};font-size:11px;font-weight:500;letter-spacing:0.2px;color:var(--ink3);">
      <span style="padding:3px 9px;border-radius:5px;font-size:10.5px;font-weight:600;letter-spacing:0.5px;background:var(--mode-bg);color:var(--mode-ink);">NORMAL</span>
      <span style="font-family:${MONO};color:var(--ink2);">~/Notes/INBOX.md</span>
      <span style="margin-left:auto;display:flex;gap:16px;"><span>27 items · 8 done</span><span>UTF-8</span></span>
    </div>
  </div>`;
}

// Capture mode — frosted panel, 680 wide (MainPanel.captureWidth), content
// height. Values from CaptureView.swift: 16pt panel padding, 8pt field radius,
// 15/13 field insets, 180pt tag well, 120×75 preview tiles, 16pt band gaps,
// 0.5px rule, keycaps at mono 10 with 5/2 insets.
function captureMock() {
  const keycap = (glyphs, label) =>
    `<div style="display:flex;align-items:center;gap:6px;">
       <span style="font-family:${MONO};font-size:10px;font-weight:500;padding:2px 5px;border-radius:4px;background:var(--keycap-bg);color:var(--keycap-ink);">${glyphs}</span>
       <span style="font-size:12px;color:var(--ink3);">${label}</span>
     </div>`;

  const tile = (seed) =>
    `<div style="position:relative;width:120px;height:75px;border-radius:8px;overflow:hidden;box-shadow:inset 0 0 0 0.5px var(--hair);flex:none;">
       ${shotArt("120px", "75px", seed)}
       <span style="position:absolute;top:4px;right:4px;width:16px;height:16px;border-radius:50%;background:rgba(0,0,0,0.5);display:flex;align-items:center;justify-content:center;color:#FFF;">${icon(ICON_CLOSE, 9, "#FFF")}</span>
     </div>`;

  return `<div style="width:680px;box-sizing:border-box;padding:16px;border-radius:16px;background:linear-gradient(180deg, var(--edge) 0, transparent 12%), var(--panel);backdrop-filter:blur(30px) saturate(180%);-webkit-backdrop-filter:blur(30px) saturate(180%);box-shadow:0 0 0 0.5px var(--ring), 0 20px 60px rgba(0,0,0,0.25), 0 2px 10px rgba(0,0,0,0.08);">
    <div style="display:flex;align-items:flex-start;gap:10px;">
      <div style="flex:1;box-sizing:border-box;padding:13px 15px;border-radius:8px;background:var(--field);border:1px solid var(--accent);box-shadow:0 0 0 3px var(--focus-ring);font-size:16px;line-height:1.3;color:var(--ink);">Warm the surface tokens without losing contrast</div>
      <div style="width:180px;flex:none;box-sizing:border-box;padding:13px 15px;border-radius:8px;background:var(--tag-bg);border:1px solid var(--tag-border);display:flex;align-items:center;gap:6px;font-size:13px;line-height:1.3;">
        <span style="color:var(--tag-hash);">#</span><span style="color:var(--tag-ink);">design</span>
      </div>
    </div>
    <div style="display:flex;gap:10px;margin-top:16px;">${tile(1)}${tile(2)}</div>
    <div style="height:0.5px;background:var(--hair);margin-top:16px;"></div>
    <div style="display:flex;gap:16px;margin-top:16px;">${keycap("⌥⌘I", "Editor")}${keycap("⌥⌘O", "Screenshots")}</div>
  </div>`;
}

// ⌥⌘O screenshot picker — same frosted recipe, 860 wide (pickerFrame), a 240pt
// list beside a recessed preview well. Highlight (↑↓ cursor) and selection
// (space) are independent states, as in pickerRow.
function pickerMock() {
  const keycap = (glyphs, label) =>
    `<div style="display:flex;align-items:center;gap:6px;">
       <span style="font-family:${MONO};font-size:10px;font-weight:500;padding:2px 5px;border-radius:4px;background:var(--keycap-bg);color:var(--keycap-ink);">${glyphs}</span>
       <span style="font-size:12px;color:var(--ink3);padding-right:2px;">${label}</span>
     </div>`;

  const rows = SHOTS.map((s, i) => `
    <div style="display:flex;align-items:center;gap:10px;padding:7px 8px;border-radius:6px;${s.cur ? "background:var(--sel-bg);box-shadow:inset 0 0 0 1px var(--sel-ring);" : ""}">
      <div style="position:relative;width:52px;height:34px;border-radius:4px;overflow:hidden;flex:none;">
        ${shotArt("52px", "34px", i)}
        ${s.sel ? `<span style="position:absolute;top:2px;left:2px;width:13px;height:13px;border-radius:50%;background:var(--sel-badge);display:flex;align-items:center;justify-content:center;">${icon(ICON_CHECK, 9, "#FFF")}</span>` : ""}
      </div>
      <div style="display:flex;flex-direction:column;gap:1px;min-width:0;">
        <span style="font-size:12px;color:${s.cur ? "var(--sel-ink)" : "var(--ink2)"};">${s.time}</span>
        <span style="font-size:11px;font-weight:600;color:var(--ink3);">${s.day}</span>
      </div>
      ${s.sel ? `<span style="margin-left:auto;color:var(--sel-badge);">${icon(ICON_CHECK, 11, "currentColor")}</span>` : ""}
    </div>`).join("");

  return `<div style="width:860px;height:430px;box-sizing:border-box;padding:16px;border-radius:16px;display:flex;flex-direction:column;gap:16px;background:linear-gradient(180deg, var(--edge) 0, transparent 12%), var(--panel);backdrop-filter:blur(30px) saturate(180%);-webkit-backdrop-filter:blur(30px) saturate(180%);box-shadow:0 0 0 0.5px var(--ring), 0 20px 60px rgba(0,0,0,0.25), 0 2px 10px rgba(0,0,0,0.08);">
    <div style="display:flex;align-items:center;gap:10px;">
      <span style="font-size:15px;font-weight:600;color:var(--ink);">Recent screenshots</span>
      <span style="font-size:12px;padding:3px 8px;border-radius:999px;background:var(--count-bg);color:var(--count-ink);">2 selected</span>
      <span style="margin-left:auto;display:flex;align-items:center;gap:6px;">${keycap("↑↓", "navigate")}${keycap("space", "select")}${keycap("⏎", "attach")}${keycap("esc", "cancel")}</span>
    </div>
    <div style="display:flex;gap:16px;flex:1;min-height:0;">
      <div style="width:240px;flex:none;display:flex;flex-direction:column;gap:4px;">${rows}</div>
      <div style="flex:1;border-radius:8px;background:var(--field);box-shadow:inset 0 0 0 0.5px var(--hair);display:flex;align-items:center;justify-content:center;padding:10px;overflow:hidden;">
        <div style="width:100%;height:100%;border-radius:4px;overflow:hidden;">${shotArt("100%", "100%", 1)}</div>
      </div>
    </div>
  </div>`;
}

// -------------------------------------------------------------------- tokens

// Baseline = today's app, byte-for-byte: Theme.light / Theme.dark in
// DesignSystem.swift and lightPalette / darkPalette in editor.ts.
const BASE_LIGHT = {
  sans: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif',
  mono: 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace',
  win: "#F6F6F8",
  panel: "rgba(252,252,254,0.66)",
  "bd-a": "#E7E8EC", "bd-b": "#D9DBE1",
  field: "rgba(120,120,128,0.10)",
  rail: "rgba(0,0,0,0.025)",
  hair: "rgba(0,0,0,0.14)",
  ring: "rgba(0,0,0,0.18)",
  edge: "rgba(255,255,255,0.55)",
  ink: "rgba(0,0,0,0.88)",
  ink2: "rgba(60,60,67,0.62)",
  ink3: "rgba(60,60,67,0.36)",
  accent: "#007AFF",
  "accent-ink": "#0066D6",
  "accent-soft": "rgba(0,122,255,0.12)",
  "focus-ring": "rgba(0,122,255,0.35)",
  chip: "rgba(120,120,128,0.12)",
  "keycap-bg": "var(--chip)",
  "keycap-ink": "var(--ink2)",
  "pri-high": "#FF3B30", "pri-med": "#FF9500", "pri-low": "#34C759",
  "pri-halo": "22%",
  "band-mix": "0%",
  "sec-ink-mix": "0%",
  "sec-rule": "var(--hair)",
  guide: "var(--hair)",
  "cb-border": "rgba(0,0,0,0.28)",
  "cb-checked": "var(--accent)",
  "sel-bg": "var(--accent-soft)",
  "sel-ring": "rgba(0,122,255,0.42)",
  "sel-ink": "var(--accent-ink)",
  "sel-badge": "var(--accent)",
  "count-bg": "var(--accent-soft)",
  "count-ink": "var(--accent-ink)",
  "tag-bg": "var(--accent-soft)",
  "tag-ink": "var(--accent-ink)",
  "tag-border": "rgba(0,122,255,0.38)",
  "tag-hash": "var(--accent)",
  "mode-bg": "var(--accent-soft)",
  "mode-ink": "var(--accent-ink)",
  "ph-bg": "rgba(255,255,255,0.85)", "ph-line": "rgba(0,0,0,0.14)", "ph-bar": "rgba(0,0,0,0.07)",
};

const BASE_DARK = {
  ...BASE_LIGHT,
  win: "#212125",
  panel: "rgba(38,38,42,0.58)",
  "bd-a": "#17171B", "bd-b": "#0F0F12",
  field: "rgba(120,120,128,0.20)",
  rail: "rgba(255,255,255,0.03)",
  hair: "rgba(255,255,255,0.13)",
  ring: "rgba(255,255,255,0.14)",
  edge: "rgba(255,255,255,0.10)",
  ink: "rgba(255,255,255,0.92)",
  ink2: "rgba(235,235,245,0.60)",
  ink3: "rgba(235,235,245,0.32)",
  accent: "#0A84FF",
  "accent-ink": "#409CFF",
  "accent-soft": "rgba(10,132,255,0.16)",
  "focus-ring": "rgba(10,132,255,0.40)",
  chip: "rgba(120,120,128,0.24)",
  "pri-high": "#FF453A", "pri-med": "#FF9F0A", "pri-low": "#30D158",
  "cb-border": "rgba(255,255,255,0.35)",
  "sel-ring": "rgba(10,132,255,0.42)",
  "tag-border": "rgba(10,132,255,0.38)",
  "ph-bg": "rgba(255,255,255,0.10)", "ph-line": "rgba(255,255,255,0.22)", "ph-bar": "rgba(255,255,255,0.10)",
};

// Warm neutrals, derived in oklch rather than eyeballed: same lightness as the
// tokens they replace, chroma held at/below 0.016, hue parked in the 70–85°
// (paper) band. Accent, tag hues and priority orbs are untouched.
const WARM_LIGHT = {
  win: oklch(0.968, 0.0085, 85),
  panel: oklcha(0.985, 0.006, 85, 0.70),
  "bd-a": oklch(0.905, 0.013, 80), "bd-b": oklch(0.855, 0.016, 76),
  field: oklcha(0.56, 0.014, 72, 0.10),
  rail: oklcha(0.30, 0.02, 70, 0.03),
  hair: oklcha(0.30, 0.02, 70, 0.16),
  ring: oklcha(0.30, 0.02, 70, 0.20),
  ink: oklcha(0.18, 0.012, 70, 0.90),
  ink2: oklcha(0.42, 0.014, 72, 0.66),
  ink3: oklcha(0.42, 0.014, 72, 0.40),
  chip: oklcha(0.60, 0.016, 72, 0.14),
  "cb-border": oklcha(0.30, 0.02, 70, 0.30),
  "ph-line": oklcha(0.30, 0.02, 70, 0.16), "ph-bar": oklcha(0.30, 0.02, 70, 0.08),
};

const WARM_DARK = {
  win: oklch(0.262, 0.008, 72),
  panel: oklcha(0.30, 0.008, 72, 0.60),
  "bd-a": oklch(0.20, 0.008, 72), "bd-b": oklch(0.155, 0.007, 72),
  field: oklcha(0.62, 0.016, 75, 0.20),
  rail: oklcha(0.97, 0.012, 85, 0.035),
  hair: oklcha(0.97, 0.012, 85, 0.14),
  ring: oklcha(0.97, 0.012, 85, 0.15),
  edge: oklcha(0.97, 0.012, 85, 0.10),
  ink: oklcha(0.985, 0.008, 85, 0.93),
  ink2: oklcha(0.93, 0.012, 85, 0.62),
  ink3: oklcha(0.93, 0.012, 85, 0.34),
  chip: oklcha(0.62, 0.016, 75, 0.24),
  "cb-border": oklcha(0.97, 0.012, 85, 0.36),
  "ph-line": oklcha(0.97, 0.012, 85, 0.22), "ph-bar": oklcha(0.97, 0.012, 85, 0.10),
};

// Colour as interaction feedback: the resting chrome stays neutral, the
// keycaps / selection / focus moments carry the accent.
const MOMENTS = (base) => ({
  "keycap-bg": base["accent-soft"],
  "keycap-ink": base["accent-ink"],
  "count-bg": base.accent,
  "count-ink": "#FFFFFF",
  "sel-bg": base === BASE_DARK ? "rgba(10,132,255,0.22)" : "rgba(0,122,255,0.18)",
  "sel-ring": base === BASE_DARK ? "rgba(10,132,255,0.55)" : "rgba(0,122,255,0.55)",
  "focus-ring": base === BASE_DARK ? "rgba(10,132,255,0.45)" : "rgba(0,122,255,0.42)",
  "pri-halo": "30%",
});

// Colour as section identity. `strength` scales how far the heading text
// travels from grey toward its hue; `band` is the tinted heading row.
const SECTION_ID = (hue, strength, band, dark) => ({
  // Mix the heading toward the PRIMARY ink, not the secondary grey: at 70% hue
  // the caption is unmistakably coloured and still lands well above the 3.49:1
  // the current grey caption manages (see the contrast report).
  __secInkFrom: "ink",
  "band-mix": band,
  "sec-ink-mix": strength,
  "sec-rule": "color-mix(in oklab, var(--hue) 32%, transparent)",
  guide: "color-mix(in oklab, var(--hue) 45%, var(--hair))",
  "cb-checked": "var(--hue)",
  "tag-bg": `color-mix(in oklab, ${hue} ${dark ? "16%" : "11%"}, transparent)`,
  "tag-ink": hue,
  "tag-hash": hue,
  "tag-border": `color-mix(in oklab, ${hue} 38%, transparent)`,
});

// ---------------------------------------------------------------- directions

// Today: the hue comes from a DJB2 hash of the section name. These three names
// happen to land on indigo / slate / blue — see the contrast report.
const HASH_HUES = { "Quick capture": 6, design: 7, shortcuts: 4 };
// Proposed: assign by order of first appearance and drop slate (index 7).
const SEQ_HUES = { "Quick capture": 0, design: 1, shortcuts: 2 };

const DIRECTIONS = [
  {
    file: "Main.dc.html", name: "Sectioned", title: "Sectioned", chosen: true, page: "page-1",
    rule: "Hue is section identity, system blue is interaction, neutral is the ground. A section's hue reaches its dot, its caption, its rule, its indent guides and the checkboxes inside it — and the capture box's tag field, which is the same tag. Nothing else in the app borrows a tag hue.",
    changes: "--band-mix 8% / 12% · --sec-ink-mix 70% / 76% mixed toward the PRIMARY ink · --sec-rule hue@32% · --guide hue@45% over the hairline · --cb-checked var(--hue) · tag field takes the matched tag's hue. Surfaces, accent and priority orbs are untouched.",
    tradeoff: "Caption contrast improves (4.70:1 light, 6.69:1 dark, against today's 3.49 / 5.74) — but colour now carries two meanings, identity and interaction, and the picker gets nothing from it. Assumes the settled hue rule on the next artboard; on today's hash these three sections come out indigo, slate and blue.",
    hues: SEQ_HUES,
    light: SECTION_ID(HUES_LIGHT[1], "70%", "8%", false),
    dark: SECTION_ID(HUES_DARK[1], "76%", "12%", true),
  },
  {
    file: "Baseline.dc.html", name: "Current", title: "Current (baseline)", page: "page-2",
    why: "The control: the build as it stands. Frosted neutral surfaces, one system-blue accent, colour reserved for tag dots and priority orbs.",
    tradeoff: "At rest all three surfaces read greyscale — and the hue hash puts these three real section names on indigo, slate and blue, so the colour that is there barely separates.",
    changes: "Nothing. Every other artboard is a diff against this one.",
    hues: HASH_HUES, light: {}, dark: {},
  },
  {
    file: "WarmPaper.dc.html", name: "Warm Paper", title: "Warm Paper", page: "page-2",
    why: "Take the clinical edge off the chrome without giving colour any new job: same accent, same tag hues, surfaces moved from cool grey to a low-chroma paper neutral.",
    tradeoff: "Warm greys sit beside genuinely neutral macOS chrome — menu bar, sheets, native controls — and can read as a slightly yellowed display. Apparent contrast drops a little as neutrals warm.",
    changes: "--win --panel --field --hair --ring --ink/2/3 --chip, both modes. No structural change, no new meaning.",
    hues: HASH_HUES, light: WARM_LIGHT, dark: WARM_DARK,
  },
  {
    file: "AccentMoments.dc.html", name: "Accent Moments", title: "Accent Moments", page: "page-2",
    why: "Keep the chrome neutral and spend the colour where you act: hint-bar keycaps, picker selection and count, the focus ring, the priority halos.",
    tradeoff: "Accent-tinted keycaps compete with the focused field for the eye. And most of what it brightens is transient — a resting editor stays nearly as grey as today.",
    changes: "--keycap-bg --keycap-ink --sel-* --count-* --focus-ring --pri-halo. Smallest diff of the four.",
    hues: HASH_HUES,
    light: MOMENTS(BASE_LIGHT), dark: MOMENTS(BASE_DARK),
  },
  {
    file: "Composite.dc.html", name: "Composite", title: "Composite", page: "page-2",
    why: "All three axes at once: warm ground, hue for identity, accent for interaction. Hue reaches the dot, heading and rule but draws no tinted band; keycaps and picker selection take the accent; checkboxes stay accent so 'interactive' keeps a single colour.",
    tradeoff: "The largest diff, and the warm surfaces pull the light mode's secondary ink and hint labels down (3.33:1 and 1.94:1) rather than up. Sectioned gets most of the legibility win for a fraction of the change.",
    changes: "Warm Paper surfaces + Sectioned headings with no band + Accent Moments keycaps/selection.",
    hues: SEQ_HUES,
    light: { ...WARM_LIGHT, ...MOMENTS(BASE_LIGHT), ...SECTION_ID(HUES_LIGHT[1], "70%", "0%", false), "cb-checked": "var(--accent)" },
    dark:  { ...WARM_DARK,  ...MOMENTS(BASE_DARK),  ...SECTION_ID(HUES_DARK[1], "76%", "0%", true),  "cb-checked": "var(--accent)" },
  },
];

// ----------------------------------------------------------------- artboards

const W = 2280, H = 1540;

function resolve(tokens, value, seen = 0) {
  if (typeof value !== "string" || seen > 6) return value;
  const m = value.match(/^var\(--([a-z0-9-]+)\)$/i);
  return m ? resolve(tokens, tokens[m[1]], seen + 1) : value;
}

function tokenBlock(cls, tokens) {
  const win = resolve(tokens, tokens.win);
  const inkSrc = resolve(tokens, tokens[tokens.__secInkFrom || "ink2"]);
  // Opaque stand-in for the secondary ink, so the heading's hue mix stays
  // predictable (color-mix with a translucent colour would mix alpha too).
  const secInkBase = "#" + over(inkSrc, win).slice(0, 3)
    .map((n) => Math.round(n).toString(16).padStart(2, "0")).join("").toUpperCase();
  const hues = tokens.__hues;
  const lines = Object.entries(tokens)
    .filter(([k]) => !k.startsWith("__"))
    .map(([k, v]) => `    --${k}: ${v};`).join("\n");
  const hueLines = hues.map((h, i) => `    --hue-${i}: ${h};`).join("\n");
  return `  .${cls} {\n${lines}\n    --sec-ink-base: ${secInkBase};\n${hueLines}\n  }`;
}

function column(cls, label, hues) {
  return `<div class="${cls}" style="width:1060px;flex:none;display:flex;flex-direction:column;gap:14px;">
    <div style="font-size:11px;font-weight:600;letter-spacing:1px;text-transform:uppercase;color:#8A8F98;padding-left:2px;">${label}</div>
    <div style="padding:30px;border-radius:14px;background:linear-gradient(160deg, var(--bd-a), var(--bd-b));display:flex;flex-direction:column;align-items:center;gap:26px;">
      ${editorMock(hues)}
      ${captureMock()}
      ${pickerMock()}
    </div>
  </div>`;
}

function artboard(d) {
  const lightTokens = { ...BASE_LIGHT, ...d.light, __hues: HUES_LIGHT };
  const darkTokens = { ...BASE_DARK, ...d.dark, __hues: HUES_DARK };
  const head = (label, text) =>
    `<div style="flex:1;min-width:0;">
       <div style="font-size:10px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:#9AA0A8;">${label}</div>
       <div style="margin-top:7px;font-size:13px;line-height:1.5;color:#3C424A;text-wrap:pretty;">${text}</div>
     </div>`;
  const cols = d.chosen
    ? head("The rule", d.rule) + head("What changes", d.changes) + head("Watch", d.tradeoff)
    : head("Why", d.why) + head("Trade-off", d.tradeoff) + head("What changes", d.changes);

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
    a { color: #0066D6; } a:hover { color: #00509E; }
${tokenBlock("light", lightTokens)}
${tokenBlock("dark", darkTokens)}
  </style>
</helmet>
<div style="width:${W}px;height:${H}px;box-sizing:border-box;padding:56px;background:#F2F3F5;display:flex;flex-direction:column;gap:30px;">
  <div style="display:flex;align-items:flex-start;gap:44px;">
    <div style="flex:none;width:420px;">
      <div style="font-size:10px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:${d.chosen ? "#1E7A46" : "#9AA0A8"};">${d.chosen ? "Chosen direction" : "Explored — not chosen"}</div>
      <div style="margin-top:8px;font-size:32px;font-weight:600;letter-spacing:-0.6px;color:#15181C;">${d.name}</div>
    </div>
    <div style="flex:1;display:flex;gap:36px;">${cols}</div>
  </div>
  <div style="display:flex;gap:48px;">
    ${column("light", "Light", d.hues)}
    ${column("dark", "Dark", d.hues)}
  </div>
</div>
</x-dc>
</body>
</html>
`;
}

// ------------------------------------------------------- tag-hue spec sheet

// The open decision inside Sectioned: which hues exist, and how a section gets
// one. Contrast figures are computed, not asserted.
const HUE_NAMES = ["Coral", "Teal", "Magenta", "Green", "Blue", "Amber", "Indigo", "Slate"];
const SAMPLE_NAMES = ["Quick capture", "design", "shortcuts", "work", "home", "ideas", "reading",
  "errands", "frezara", "admin", "health", "editor", "capture", "bugs", "later", "inbox", "personal"];

function huesArtboard() {
  const HW = 1760, HH = 1420;
  const hex = (rgb) => "#" + rgb.slice(0, 3).map((n) => Math.round(n).toString(16).padStart(2, "0")).join("").toUpperCase();
  const inkLight = hex(over("rgba(0,0,0,0.88)", "#F6F6F8"));
  const inkDark = hex(over("rgba(255,255,255,0.92)", "#212125"));

  const clustered = SAMPLE_NAMES.filter((n) => [4, 6, 7].includes(hueIndex(n))).length;
  const chips = SAMPLE_NAMES.map((n) => {
    const i = hueIndex(n);
    const dim = [4, 6, 7].includes(i);
    return `<span style="display:inline-flex;align-items:center;gap:7px;padding:5px 11px 5px 9px;border-radius:999px;background:${dim ? "#FFF4F2" : "#FFFFFF"};box-shadow:inset 0 0 0 0.5px ${dim ? "rgba(200,60,40,0.28)" : "rgba(0,0,0,0.12)"};font-size:12px;color:#3C424A;">
      <span style="width:8px;height:8px;border-radius:50%;background:${HUES_LIGHT[i]};flex:none;"></span>${n}
    </span>`;
  }).join("");

  const sample = (hueHex, base, bg, mix) => {
    const ink = mixOklab(hueHex, base, mix);
    return `<div style="padding:13px 12px;background:${bg};">
      <div style="display:flex;align-items:center;font-size:11px;font-weight:600;line-height:2;letter-spacing:0.8px;text-transform:uppercase;color:${ink};">
        <span style="width:7px;height:7px;border-radius:50%;margin-right:8px;background:${hueHex};flex:none;"></span>Quick capture
      </div>
      <div style="height:0.5px;background:color-mix(in oklab, ${hueHex} 32%, transparent);"></div>
      <div style="margin-top:9px;display:flex;justify-content:space-between;font-family:${MONO};font-size:10px;color:${bg === "#F6F6F8" ? "#8A8F98" : "#8B9099"};">
        <span>${hueHex}</span><span>${contrast(ink, bg).toFixed(2)}:1</span>
      </div>
    </div>`;
  };

  const cards = HUE_NAMES.map((name, i) => {
    const retired = i === 7;
    return `<div style="width:230px;flex:none;border-radius:10px;overflow:hidden;box-shadow:0 0 0 0.5px rgba(0,0,0,0.13);${retired ? "opacity:0.45;" : ""}">
      <div style="display:flex;align-items:center;justify-content:space-between;padding:9px 12px;background:#FAFAFB;border-bottom:0.5px solid rgba(0,0,0,0.10);">
        <span style="font-size:11px;font-weight:700;letter-spacing:0.6px;text-transform:uppercase;color:#4B5159;">${name}</span>
        ${retired ? `<span style="font-size:9px;font-weight:700;letter-spacing:0.6px;text-transform:uppercase;color:#B0343A;">retire</span>` : ""}
      </div>
      ${sample(HUES_LIGHT[i], inkLight, "#F6F6F8", 70)}
      ${sample(HUES_DARK[i], inkDark, "#212125", 76)}
    </div>`;
  }).join("");

  const option = (title, pros, cons, pick) => `
    <div style="flex:1;min-width:0;padding:16px 18px;border-radius:10px;background:${pick ? "#F1F8F3" : "#FFFFFF"};box-shadow:inset 0 0 0 0.5px ${pick ? "rgba(30,122,70,0.35)" : "rgba(0,0,0,0.12)"};">
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="font-size:14px;font-weight:600;color:#15181C;">${title}</span>
        ${pick ? `<span style="font-size:9px;font-weight:700;letter-spacing:0.7px;text-transform:uppercase;color:#1E7A46;">recommended</span>` : ""}
      </div>
      <div style="margin-top:9px;font-size:12.5px;line-height:1.55;color:#3C424A;text-wrap:pretty;">${pros}</div>
      <div style="margin-top:6px;font-size:12.5px;line-height:1.55;color:#8A8F98;text-wrap:pretty;">${cons}</div>
    </div>`;

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
    a { color: #0066D6; } a:hover { color: #00509E; }
  </style>
</helmet>
<div style="width:${HW}px;height:${HH}px;box-sizing:border-box;padding:56px;background:#F2F3F5;display:flex;flex-direction:column;gap:30px;">
  <div style="max-width:1180px;">
    <div style="font-size:10px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:#1E7A46;">Settled — Sectioned depends on this</div>
    <div style="margin-top:8px;font-size:32px;font-weight:600;letter-spacing:-0.6px;color:#15181C;">Tag hues</div>
    <div style="margin-top:10px;font-size:13.5px;line-height:1.55;color:#3C424A;text-wrap:pretty;">Sectioned only pays off if two sections that sit near each other get hues you can tell apart. Today a section's hue is a DJB2 hash of its name over eight entries — two of which are a grey and a blue a shade off the system accent. <strong style="font-weight:600;color:#15181C;">Decided: a section takes the next unused hue the first time it is seen, and that assignment is remembered.</strong></div>
  </div>

  <div style="padding:20px 22px;border-radius:12px;background:#FFFFFF;box-shadow:0 0 0 0.5px rgba(0,0,0,0.10);">
    <div style="display:flex;align-items:baseline;gap:12px;">
      <span style="font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:#9AA0A8;">Today — hashed</span>
      <span style="font-size:12.5px;color:#B0343A;">${clustered} of ${SAMPLE_NAMES.length} plausible section names land on indigo, blue or slate</span>
    </div>
    <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:14px;">${chips}</div>
  </div>

  <div>
    <div style="font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:#9AA0A8;margin-bottom:12px;">Palette — seven hues, slate retired · caption shown at the Sectioned mix (70% light / 76% dark toward primary ink)</div>
    <div style="display:flex;gap:16px;">${cards}</div>
  </div>

  <div>
    <div style="font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:#9AA0A8;margin-bottom:12px;">How a section gets its hue</div>
    <div style="display:flex;gap:16px;">
      ${option("Hash the name", "Considered. Stable — a section keeps its hue forever, across launches and machines, with nothing to store.", "Clusters: neighbouring sections routinely collide, and a section can land on grey. This is today's behaviour.", false)}
      ${option("Assign by order of appearance", "Considered. Separates reliably — the first seven sections in a file are always seven distinct hues.", "A section's hue moves when you reorder or delete a section above it. Colour that shifts under you is worse than colour that clusters.", false)}
      ${option("Assign on first sight, then remember", "<strong style=\"font-weight:600;\">Chosen.</strong> A section takes the next unused hue the first time it is seen; the map is persisted, so the hue survives reordering, renaming above it, and relaunches. Past seven sections, reuse the least-recently-assigned hue.", "Turns the hue from a pure function into stored state — which means the editor can no longer derive it. Swift owns the map and pushes it into the web layer the way it already pushes refile targets.", true)}
    </div>
  </div>

  <div style="padding:18px 22px;border-radius:12px;background:#FFFFFF;box-shadow:0 0 0 0.5px rgba(0,0,0,0.10);">
    <div style="font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:#9AA0A8;">What the chosen rule changes</div>
    <div style="display:flex;gap:32px;margin-top:12px;font-size:12.5px;line-height:1.55;color:#3C424A;">
      <div style="flex:1;"><span style="font-family:${MONO};font-size:11.5px;color:#15181C;">TagColor.swift</span> — <span style="font-family:${MONO};font-size:11.5px;">TagPalette.entry(for:)</span> stops hashing and reads a stored assignment, allocating on first sight. Slate leaves the palette; seven entries remain.</div>
      <div style="flex:1;"><span style="font-family:${MONO};font-size:11.5px;color:#15181C;">AppState.swift</span> — the map is persisted alongside the recent-tag scan, which already walks the capture file for section names.</div>
      <div style="flex:1;"><span style="font-family:${MONO};font-size:11.5px;color:#15181C;">editor.ts</span> — <span style="font-family:${MONO};font-size:11.5px;">tagHue()</span> becomes a lookup instead of a hash. The two implementations no longer need to stay in sync by hand; instead Swift pushes the map in on editor boot and on change, like <span style="font-family:${MONO};font-size:11.5px;">setRefileTargets</span>.</div>
    </div>
  </div>
</div>
</x-dc>
</body>
</html>
`;
}

// ------------------------------------------------------------------- emit

const GAP_X = 140;
const PAGE_POS = { "page-1": 0, "page-2": 0 };
const artboards = [];
for (const d of DIRECTIONS) {
  artboards.push({ file: d.file, title: d.title, page: d.page, x: PAGE_POS[d.page], y: 0, w: W, h: H });
  PAGE_POS[d.page] += W + GAP_X;
}
artboards.push({ file: "Hues.dc.html", title: "Tag hues", page: "page-1", x: PAGE_POS["page-1"], y: 0, w: 1760, h: 1420 });

for (const d of DIRECTIONS) writeFileSync(join(OUT, d.file), artboard(d));
writeFileSync(join(OUT, "Hues.dc.html"), huesArtboard());

const canvas = {
  artboards,
  pages: [
    { id: "page-1", name: "Sectioned" },
    { id: "page-2", name: "Explored" },
  ],
  annotations: [
    { id: "decision", page: "page-1", x: 0, y: -196, w: 900,
      text: "Issue #101 — Sectioned is the chosen direction.\nEach section owns a hue: dot, caption, rule, indent guides and the checkboxes inside it, plus the capture box's tag field. Surfaces, accent and priority orbs stay exactly as they are.\nEvery difference from today is a token value — no surface is restructured. The Explored page holds the four directions that were not picked." },
    { id: "next", page: "page-1", x: 2 * (W + GAP_X), y: -196, w: 620,
      text: "Settled: a section takes the next unused hue on first sight and keeps it. That makes the hue stored state rather than a hash, so Swift owns the map and pushes it into the editor — the one structural change Sectioned asks for." },
    { id: "explored", page: "page-2", x: 0, y: -168, w: 900,
      text: "Not chosen — kept for the record. Current is the control; Warm Paper, Accent Moments and Composite were the other axes considered." },
  ],
  launch: { view: "canvas", page: "page-1" },
};
writeFileSync(join(OUT, "canvas.json"), JSON.stringify(canvas, null, 2) + "\n");

// ------------------------------------------------------- contrast diagnostics

const rows = [];
for (const d of DIRECTIONS) {
  for (const [mode, base, over_] of [["light", BASE_LIGHT, d.light], ["dark", BASE_DARK, d.dark]]) {
    const t = { ...base, ...over_ };
    const R = (v) => resolve(t, v);
    const win = R(t.win);
    const hex = (rgb) => "#" + rgb.slice(0, 3).map((n) => Math.round(n).toString(16).padStart(2, "0")).join("");
    const secBase = hex(over(R(t[t.__secInkFrom || "ink2"]), win));
    const hues = mode === "light" ? HUES_LIGHT : HUES_DARK;
    const hue = hues[d.hues["design"]];
    const band = parseFloat(t["band-mix"]) > 0 ? hex(over(`rgba(${parseColor(hue).slice(0,3).join(",")},${parseFloat(t["band-mix"]) / 100})`, win)) : win;
    const secInk = mixOklab(hue, secBase, parseFloat(t["sec-ink-mix"]));
    const panelOnDesk = hex(over(R(t.panel), R(t["bd-a"])));
    const keycapBg = hex(over(R(t["keycap-bg"]), panelOnDesk));
    const selBg = hex(over(R(t["sel-bg"]), panelOnDesk));
    rows.push({
      direction: d.name, mode,
      "body ink": contrast(R(t.ink), win).toFixed(2),
      "ink2/status": contrast(R(t.ink2), win).toFixed(2),
      "ink3/hint": contrast(R(t.ink3), panelOnDesk).toFixed(2),
      "H2 heading": contrast(secInk, band).toFixed(2),
      keycap: contrast(R(t["keycap-ink"]), keycapBg).toFixed(2),
      "picker sel": contrast(R(t["sel-ink"]), selBg).toFixed(2),
    });
  }
}
console.table(rows);
console.log(`\nWrote ${artboards.length} artboards + canvas.json to ${OUT}`);

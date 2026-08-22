// Generates the #111 ink-ramp artboards. The decision is which shape the
// light-mode ink ramp should take, and the issue's own words are that it is a
// look-at-it decision rather than an arithmetic one — so these render the real
// surfaces where secondary text lives, at real sizes, with the measured ratios
// beside them.
//
//   node design/ink-ramp/generate.mjs
//
// Values lifted from Sources/QuickCapture/DesignSystem.swift (Theme) and
// editor-web/src/editor.ts (palettes).

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { contrast, flatten } from "../lib/color.mjs";

const OUT = dirname(fileURLToPath(import.meta.url));
mkdirSync(OUT, { recursive: true });

const W = 2000, H = 1180;
const SANS = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';
const MONO = 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace';

// --------------------------------------------------------------- appearances

// The three backgrounds secondary text actually lands on. The frosted ones are
// resolved over Theme.bg — the behind-window haze, i.e. the light-desktop case
// #106 settled on. (Over a dark wallpaper they get worse; that's #112.)
const MODES = {
  light: {
    label: "Light",
    channel: (a) => `rgba(60,60,67,${a})`,
    primary: "rgba(0,0,0,0.88)",
    desk: "#ECEDF0",
    panel: flatten("rgba(252,252,254,0.66)", "#ECEDF0"),
    chip: flatten("rgba(120,120,128,0.12)", flatten("rgba(252,252,254,0.66)", "#ECEDF0")),
    rail: flatten("rgba(0,0,0,0.025)", "#F6F6F8"),
    surface: "#F6F6F8",
    hair: "rgba(0,0,0,0.14)",
    ring: "rgba(0,0,0,0.18)",
    field: "rgba(120,120,128,0.10)",
    accent: "#007AFF",
    accentSoft: "rgba(0,122,255,0.12)",
    accentInk: "#0066D6",
    bd: ["#E7E8EC", "#D9DBE1"],
  },
  dark: {
    label: "Dark",
    channel: (a) => `rgba(235,235,245,${a})`,
    primary: "rgba(255,255,255,0.92)",
    desk: "#1E1E22",
    panel: flatten("rgba(38,38,42,0.58)", "#1E1E22"),
    chip: flatten("rgba(120,120,128,0.24)", flatten("rgba(38,38,42,0.58)", "#1E1E22")),
    rail: flatten("rgba(255,255,255,0.03)", "#212125"),
    surface: "#212125",
    hair: "rgba(255,255,255,0.13)",
    ring: "rgba(255,255,255,0.14)",
    field: "rgba(120,120,128,0.20)",
    accent: "#0A84FF",
    accentSoft: "rgba(10,132,255,0.16)",
    accentInk: "#409CFF",
    bd: ["#17171B", "#0F0F12"],
  },
};

// ------------------------------------------------------------------- options

// `hint: null` means the ramp has no separate hint level — everything readable
// sits on `secondary`.
const OPTIONS = [
  {
    file: "Main.dc.html", name: "Three levels", title: "Three levels", lead: true,
    what: "Primary, one readable secondary, placeholder. `inkHint` is absorbed into `inkSecondary`, which rises to the value that clears AA on the worst of its backgrounds — the keycap chip.",
    cost: "Loses the ability to distinguish a hint from a secondary label by weight. Keycap glyphs and picker times get noticeably darker; the hint bar gains presence it may not want.",
    light: { ink: 0.88, secondary: 0.75, hint: null, tertiary: 0.36 },
    dark:  { ink: 0.92, secondary: 0.60, hint: null, tertiary: 0.32 },
  },
  {
    file: "Current.dc.html", name: "Current", title: "Current (after #106)",
    what: "What is on main today. `inkHint` was added at 0.73 to fix the hint bar and status bar; `inkSecondary` was left at 0.62.",
    cost: "The ramp is non-monotonic in light mode — a hint is darker, and reads as more prominent, than a secondary label. And secondary text still fails AA everywhere it lands.",
    light: { ink: 0.88, secondary: 0.62, hint: 0.73, tertiary: 0.36 },
    dark:  { ink: 0.92, secondary: 0.60, hint: 0.55, tertiary: 0.32 },
  },
  {
    file: "FourLevels.dc.html", name: "Four levels", title: "Four levels, re-ordered",
    what: "Keeps a separate hint level but puts it back below secondary: `inkSecondary` rises to 0.75, `inkHint` drops under it.",
    cost: "Reopens #106 — hints fall back below AA at 3.5:1. Buys a visible hierarchy between a label and a hint, and pays for it in the legibility that was just fixed.",
    light: { ink: 0.88, secondary: 0.75, hint: 0.62, tertiary: 0.36 },
    dark:  { ink: 0.92, secondary: 0.60, hint: 0.50, tertiary: 0.32 },
  },
];

// ------------------------------------------------------------------- pieces

const AA = 4.5;

function ratio(mode, alpha, bg) {
  return contrast(MODES[mode].channel(alpha), bg);
}

function verdict(r) {
  const pass = r >= AA;
  return `<span style="display:inline-flex;align-items:center;gap:5px;font-size:11px;font-weight:600;color:${pass ? "#1E7A46" : "#B0343A"};">
    <span style="width:6px;height:6px;border-radius:50%;background:currentColor;"></span>${r.toFixed(2)}:1</span>`;
}

/// The ramp as a table: every level, what it carries, and how it measures on
/// each of the three backgrounds it lands on.
function rampTable(opt, mode) {
  const m = MODES[mode];
  const t = opt[mode];
  const rows = [
    { key: "ink", label: "ink", alpha: t.ink, carries: "primary text", css: m.primary },
    { key: "secondary", label: "inkSecondary", alpha: t.secondary,
      carries: t.hint === null ? "keycaps, picker times, dropdown rows, status bar, hint labels" : "keycaps, picker times, dropdown rows, status filename" },
    ...(t.hint === null ? [] : [{ key: "hint", label: "inkHint", alpha: t.hint, carries: "hint-bar labels, picker day lines, status counts" }]),
    { key: "tertiary", label: "inkTertiary", alpha: t.tertiary, carries: "placeholders only — exempt by design" },
  ];

  const body = rows.map((r) => {
    const css = r.css ?? m.channel(r.alpha);
    const exempt = r.key === "tertiary";
    const cells = [m.panel, m.chip, m.rail].map((bg) => {
      const v = contrast(css, bg);
      return `<td style="padding:9px 10px;text-align:right;">${exempt
        ? `<span style="font-size:11px;color:${m.channel(0.5)};">${v.toFixed(2)}:1</span>`
        : verdict(v)}</td>`;
    }).join("");
    return `<tr>
      <td style="padding:9px 10px;">
        <span style="display:inline-flex;align-items:center;gap:9px;">
          <span style="width:22px;height:22px;border-radius:5px;background:${css};box-shadow:inset 0 0 0 0.5px ${m.hair};"></span>
          <span style="font-family:${MONO};font-size:12px;color:${m.primary};">${r.label}</span>
          <span style="font-family:${MONO};font-size:11px;color:${m.channel(0.5)};">${r.alpha}</span>
        </span>
      </td>
      <td style="padding:9px 10px;font-size:12px;color:${m.channel(0.62)};">${r.carries}</td>
      ${cells}
    </tr>`;
  }).join("");

  const head = ["level", "carries", "panel", "keycap chip", "status rail"]
    .map((h, i) => `<th style="padding:0 10px 8px;text-align:${i < 2 ? "left" : "right"};font-size:10px;font-weight:700;letter-spacing:0.8px;text-transform:uppercase;color:${m.channel(0.45)};">${h}</th>`).join("");

  return `<table style="width:100%;border-collapse:collapse;">
    <thead><tr>${head}</tr></thead>
    <tbody>${body}</tbody>
  </table>`;
}

/// The capture box's hint bar, at its real 680pt width.
function hintBar(opt, mode) {
  const m = MODES[mode];
  const t = opt[mode];
  const hintInk = m.channel(t.hint ?? t.secondary);
  const cap = (glyphs, label) => `<div style="display:flex;align-items:center;gap:6px;">
      <span style="font-family:${MONO};font-size:10px;font-weight:500;padding:2px 5px;border-radius:4px;background:${m.chip};color:${m.channel(t.secondary)};">${glyphs}</span>
      <span style="font-size:12px;color:${hintInk};">${label}</span>
    </div>`;
  return `<div style="width:680px;box-sizing:border-box;padding:16px;border-radius:16px;background:${m.panel};box-shadow:0 0 0 0.5px ${m.ring}, 0 18px 50px rgba(0,0,0,0.22);">
    <div style="height:0.5px;background:${m.hair};margin-bottom:16px;"></div>
    <div style="display:flex;gap:16px;">${cap("⌥⌘I", "Editor")}${cap("⌥⌘O", "Screenshots")}</div>
  </div>`;
}

/// Picker header + three rows — times on secondary, day lines on hint.
function pickerRows(opt, mode) {
  const m = MODES[mode];
  const t = opt[mode];
  const hintInk = m.channel(t.hint ?? t.secondary);
  const cap = (g, l) => `<span style="display:inline-flex;align-items:center;gap:6px;">
      <span style="font-family:${MONO};font-size:10px;font-weight:500;padding:2px 5px;border-radius:4px;background:${m.chip};color:${m.channel(t.secondary)};">${g}</span>
      <span style="font-size:12px;color:${hintInk};padding-right:2px;">${l}</span></span>`;
  const row = (time, day, cur) => `<div style="display:flex;align-items:center;gap:10px;padding:7px 8px;border-radius:6px;${cur ? `background:${m.accentSoft};box-shadow:inset 0 0 0 1px ${m.accent}6b;` : ""}">
      <span style="width:52px;height:34px;border-radius:4px;background:${m.field};flex:none;"></span>
      <span style="display:flex;flex-direction:column;gap:1px;">
        <span style="font-size:12px;color:${cur ? m.accentInk : m.channel(t.secondary)};">${time}</span>
        <span style="font-size:11px;font-weight:600;color:${hintInk};">${day}</span>
      </span>
    </div>`;
  return `<div style="width:860px;box-sizing:border-box;padding:16px;border-radius:16px;background:${m.panel};box-shadow:0 0 0 0.5px ${m.ring}, 0 18px 50px rgba(0,0,0,0.22);">
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:14px;">
      <span style="font-size:15px;font-weight:600;color:${m.primary};">Recent screenshots</span>
      <span style="margin-left:auto;display:flex;align-items:center;gap:6px;">${cap("↑↓", "navigate")}${cap("space", "select")}${cap("⏎", "attach")}</span>
    </div>
    <div style="width:300px;display:flex;flex-direction:column;gap:4px;">
      ${row("1:19 PM", "Today", true)}${row("1:04 PM", "Today", false)}${row("6:32 PM", "Yesterday", false)}
    </div>
  </div>`;
}

/// The editor status bar — filename on secondary, counts on hint.
function statusBar(opt, mode) {
  const m = MODES[mode];
  const t = opt[mode];
  const hintInk = m.channel(t.hint ?? t.secondary);
  return `<div style="width:900px;box-sizing:border-box;border-radius:8px;overflow:hidden;box-shadow:0 0 0 0.5px ${m.ring};">
    <div style="height:34px;background:${m.surface};"></div>
    <div style="height:33px;display:flex;align-items:center;gap:16px;padding:0 16px;background:${m.rail};border-top:0.5px solid ${m.hair};font-family:${SANS};font-size:11px;font-weight:500;letter-spacing:0.2px;color:${hintInk};">
      <span style="padding:3px 9px;border-radius:5px;font-size:10.5px;font-weight:600;letter-spacing:0.5px;background:${m.accentSoft};color:${m.accentInk};">NORMAL</span>
      <span style="font-family:${MONO};color:${m.channel(t.secondary)};">~/Notes/INBOX.md</span>
      <span style="margin-left:auto;display:flex;gap:16px;"><span>27 items · 8 done</span><span>UTF-8</span></span>
    </div>
  </div>`;
}

function column(opt, mode) {
  const m = MODES[mode];
  const cap = (s) => `<div style="font-size:10px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:#9AA0A8;">${s}</div>`;
  return `<div style="width:900px;flex:none;display:flex;flex-direction:column;gap:16px;">
    <div style="font-size:11px;font-weight:600;letter-spacing:1px;text-transform:uppercase;color:#8A8F98;">${m.label}</div>
    <div style="padding:20px;border-radius:12px;background:linear-gradient(160deg, ${m.bd[0]}, ${m.bd[1]});display:flex;flex-direction:column;gap:16px;">
      ${rampTable(opt, mode)}
    </div>
    ${cap("Capture hint bar")}
    ${hintBar(opt, mode)}
    ${cap("Screenshot picker")}
    ${pickerRows(opt, mode)}
    ${cap("Editor status bar")}
    ${statusBar(opt, mode)}
  </div>`;
}

function artboard(opt) {
  const eyebrow = opt.lead ? "Leading candidate" : (opt.name === "Current" ? "Today — the control" : "Alternative");
  const eyebrowColor = opt.lead ? "#1E7A46" : "#9AA0A8";
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
    body { margin: 0; font-family: ${SANS}; }
    a { color: #0066D6; } a:hover { color: #00509E; }
    table { border-collapse: collapse; }
  </style>
</helmet>
<div style="width:${W}px;height:${H}px;box-sizing:border-box;padding:64px;background:#F2F3F5;display:flex;flex-direction:column;gap:28px;">
  <div style="display:flex;align-items:flex-start;gap:44px;">
    <div style="flex:none;width:360px;">
      <div style="font-size:10px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:${eyebrowColor};">${eyebrow}</div>
      <div style="margin-top:8px;font-size:30px;font-weight:600;letter-spacing:-0.5px;color:#15181C;">${opt.name}</div>
    </div>
    <div style="flex:1;display:flex;gap:40px;">
      <div style="flex:1;">
        <div style="font-size:10px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:#9AA0A8;">What it does</div>
        <div style="margin-top:7px;font-size:13px;line-height:1.5;color:#3C424A;text-wrap:pretty;">${opt.what}</div>
      </div>
      <div style="flex:1;">
        <div style="font-size:10px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:#9AA0A8;">Cost</div>
        <div style="margin-top:7px;font-size:13px;line-height:1.5;color:#3C424A;text-wrap:pretty;">${opt.cost}</div>
      </div>
    </div>
  </div>
  <div style="display:flex;gap:60px;">
    ${column(opt, "light")}
    ${column(opt, "dark")}
  </div>
</div>
</x-dc>
</body>
</html>
`;
}

// --------------------------------------------------------------------- emit

const GAP = 140;
const artboards = OPTIONS.map((o, i) => ({
  file: o.file, title: o.title, x: i * (W + GAP), y: 0, w: W, h: H,
}));

for (const o of OPTIONS) writeFileSync(join(OUT, o.file), artboard(o));

writeFileSync(join(OUT, "canvas.json"), JSON.stringify({
  artboards,
  annotations: [
    { id: "brief", x: 0, y: -210, w: 940,
      text: "Issue #111 — what shape should the light-mode ink ramp be?\nSecondary text fails AA in light mode (3.33–3.52:1), and #106 left the ramp non-monotonic: inkHint at 0.73 sits above inkSecondary at 0.62.\nDark mode already passes everywhere and is shown only to confirm nothing gets heavier there." },
    { id: "worst", x: 1020, y: -210, w: 700,
      text: "The keycap chip is the worst background, not the panel: its own fill darkens what sits behind the glyph. 0.74 clears the panel but not the chip — 0.75 is the lowest value that clears all three." },
  ],
  launch: { view: "canvas" },
}, null, 2) + "\n");

// Print the numbers under decision, so the values in the artboards are checkable.
for (const o of OPTIONS) {
  const t = o.light;
  const m = MODES.light;
  const sec = m.channel(t.secondary);
  const hint = m.channel(t.hint ?? t.secondary);
  console.log(o.name.padEnd(14),
    "light secondary", String(t.secondary).padEnd(5),
    "panel", contrast(sec, m.panel).toFixed(2),
    "chip", contrast(sec, m.chip).toFixed(2),
    "rail", contrast(sec, m.rail).toFixed(2),
    "| hint", String(t.hint ?? "—").padEnd(5),
    "panel", contrast(hint, m.panel).toFixed(2));
}
console.log(`\nWrote ${artboards.length} artboards + canvas.json to ${OUT}`);

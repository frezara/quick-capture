import { EditorState, RangeSetBuilder, Compartment, StateEffect } from "@codemirror/state";
import {
    EditorView, keymap, drawSelection, highlightActiveLine,
    WidgetType, Decoration, DecorationSet, ViewPlugin, ViewUpdate,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentMore, indentLess, insertTab } from "@codemirror/commands";
import { search, searchKeymap } from "@codemirror/search";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { syntaxHighlighting, HighlightStyle, bracketMatching, indentOnInput, indentUnit, syntaxTree } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { vim, Vim, getCM } from "@replit/codemirror-vim";

// Route yank / paste / delete / change through the `+` register, which the
// vim implementation pipes to navigator.clipboard. Without these maps, yank
// only lives in vim's internal `"` register and isn't reachable from other
// apps or from ⌘V.
for (const key of ["y", "Y", "p", "P", "d", "D", "x", "X", "c", "C", "s", "S"]) {
    Vim.noremap(key, `"+${key}`, "normal");
    Vim.noremap(key, `"+${key}`, "visual");
}

// Vim's `]]` / `[[` section motions, redefined for markdown `##` headings
// (the library only ships `]<char>` symbol jumps). Registered as real
// *motions* so counts (`3]]`) and operators (`d]]`) compose for free. Like
// vim, running out of sections lands on the last/first line (#67).
function markdownSectionPos(
    cm: { lastLine: () => number; getLine: (n: number) => string },
    head: { line: number; ch: number },
    repeat: number,
    dir: 1 | -1
): { line: number; ch: number } {
    const lastLine = cm.lastLine();
    let line = head.line;
    for (let i = 0; i < repeat; i++) {
        let found = -1;
        for (let n = line + dir; n >= 0 && n <= lastLine; n += dir) {
            if (/^##\s/.test(cm.getLine(n))) { found = n; break; }
        }
        if (found === -1) return { line: dir > 0 ? lastLine : 0, ch: 0 };
        line = found;
    }
    return { line, ch: 0 };
}
Vim.defineMotion("moveToNextMarkdownSection", (cm: any, head: any, motionArgs: any) =>
    markdownSectionPos(cm, head, motionArgs?.repeat ?? 1, 1));
Vim.defineMotion("moveToPrevMarkdownSection", (cm: any, head: any, motionArgs: any) =>
    markdownSectionPos(cm, head, motionArgs?.repeat ?? 1, -1));
Vim.mapCommand("]]", "motion", "moveToNextMarkdownSection", {}, {});
Vim.mapCommand("[[", "motion", "moveToPrevMarkdownSection", {}, {});

// Native-v2 ("Pure System + Color") palettes — mirror DesignSystem.swift
// (Theme.light / .dark); see design/native-v2/HANDOFF.md. The active one
// follows the system appearance (prefers-color-scheme). Functional colour
// only: priority orbs and the per-section tag hues.
// NOTE: priHigh/Med/Low and accent must stay 6-digit hex — alpha is appended
// as a hex suffix (`${...}38`) in a few rules below.
type Palette = typeof lightPalette;

const lightPalette = {
    surface: "#F6F6F8",                       // window
    surfaceField: "rgba(120, 120, 128, 0.10)", // well
    surfaceRail: "rgba(0, 0, 0, 0.025)",       // bar
    highlight: "rgba(255, 255, 255, 0.55)",
    text: "rgba(0, 0, 0, 0.88)",               // text-1
    soft: "rgba(60, 60, 67, 0.62)",            // text-2
    muted: "rgba(60, 60, 67, 0.36)",           // text-3
    accent: "#007AFF",
    accentInk: "#0066D6",
    accentSoft: "rgba(0, 122, 255, 0.12)",
    onAccent: "#FFFFFF",
    codeBg: "rgba(120, 120, 128, 0.10)",       // recessed wells
    selection: "rgba(0, 122, 255, 0.20)",      // accent-tint-2
    borderSoft: "rgba(0, 0, 0, 0.14)",         // hairline
    borderStrong: "rgba(0, 0, 0, 0.28)",       // unchecked checkbox border
    priHigh: "#FF3B30",
    priMed: "#FF9500",
    priLow: "#34C759",
};

const darkPalette: Palette = {
    surface: "#212125",
    surfaceField: "rgba(120, 120, 128, 0.20)",
    surfaceRail: "rgba(255, 255, 255, 0.03)",
    highlight: "rgba(255, 255, 255, 0.10)",
    text: "rgba(255, 255, 255, 0.92)",
    soft: "rgba(235, 235, 245, 0.60)",
    muted: "rgba(235, 235, 245, 0.32)",
    accent: "#0A84FF",
    accentInk: "#409CFF",
    accentSoft: "rgba(10, 132, 255, 0.16)",
    onAccent: "#FFFFFF",
    codeBg: "rgba(120, 120, 128, 0.20)",
    selection: "rgba(10, 132, 255, 0.28)",
    borderSoft: "rgba(255, 255, 255, 0.13)",
    borderStrong: "rgba(255, 255, 255, 0.35)",
    priHigh: "#FF453A",
    priMed: "#FF9F0A",
    priLow: "#30D158",
};

// Finder-tag-style hues for `##` section headings — mirrors TagPalette in
// TagColor.swift (same DJB2 hash, same curated entries) so a tag's dot in the
// capture box matches its section dot here. Keep the two in sync.
const tagHuesLight = ["#E8643F", "#2A9D8F", "#C2479B", "#4F9E4F", "#3B82F6", "#C77800", "#5856D6", "#64748B"];
const tagHuesDark  = ["#F4795A", "#3DBDAD", "#DA62B4", "#5FBF60", "#5C9DFF", "#E0A33E", "#7D7AFF", "#8B98AB"];

const U64 = (1n << 64n) - 1n;
const I64_MIN = 1n << 63n;

function tagHue(name: string): string {
    const normalized = name.toLowerCase();
    // BigInt with a 64-bit two's-complement wrap — Swift's `Int` is 64-bit and
    // the hash overflows past ~6 characters, so 32-bit JS arithmetic would
    // pick different hues than the capture box.
    let h = 5381n;
    for (const ch of normalized) {
        h = (h * 33n + BigInt(ch.codePointAt(0) ?? 0)) & U64;
    }
    let signed = h >= I64_MIN ? h - (U64 + 1n) : h;
    if (signed < 0n) signed = -signed;
    const hues = palette === darkPalette ? tagHuesDark : tagHuesLight;
    return hues[Number(signed % BigInt(hues.length))];
}

const prefersDark = window.matchMedia("(prefers-color-scheme: dark)");
// Mutable so makeHighlight()/makeTheme() (below) read the active palette; the
// appearance listener reassigns it and reconfigures the theme compartment.
let palette: Palette = prefersDark.matches ? darkPalette : lightPalette;

const sansFamily = '-apple-system, BlinkMacSystemFont, system-ui, "Helvetica Neue", sans-serif';

function makeHighlight() {
    return HighlightStyle.define([
    // Headings are CHROME, not content — sans, per the native-v2 spec. H1 is
    // the window title; H2s are small tracked-uppercase section captions
    // (uppercasing itself is done by the .cm-heading-2 line class so the raw
    // text keeps its case when revealed for editing).
    { tag: tags.heading1, fontFamily: sansFamily, fontSize: "22px", fontWeight: "600", letterSpacing: "-0.3px", color: palette.text, lineHeight: "1.4" },
    { tag: tags.heading2, fontFamily: sansFamily, fontSize: "11px", fontWeight: "600", letterSpacing: "0.8px", color: palette.soft, lineHeight: "2" },
    { tag: tags.heading3, fontFamily: sansFamily, fontSize: "1.1em", fontWeight: "600", color: palette.text },
    { tag: tags.heading4, fontFamily: sansFamily, fontSize: "1em", fontWeight: "600", color: palette.text },
    { tag: tags.heading5, fontWeight: "700", color: palette.text },
    { tag: tags.heading6, fontWeight: "700", color: palette.soft },

    { tag: tags.strong, fontWeight: "700", color: palette.text },
    { tag: tags.emphasis, fontStyle: "italic", color: palette.text },
    { tag: tags.strikethrough, textDecoration: "line-through", color: palette.soft },

    { tag: tags.link, color: palette.accent, textDecoration: "underline" },
    { tag: tags.url, color: palette.accent },

    { tag: tags.monospace,
      fontFamily: "ui-monospace, SF Mono, Menlo, monospace",
      color: palette.text,
      fontSize: "0.92em",
    },
    { tag: tags.list, color: palette.text },
    { tag: tags.quote, color: palette.soft, fontStyle: "italic" },

    // Markdown syntax characters (#, *, `, etc.) — muted so they recede.
    { tag: tags.processingInstruction, color: palette.muted },
    { tag: tags.meta, color: palette.muted },
    { tag: tags.contentSeparator, color: palette.muted },
    ]);
}

// MARK: - Live preview (Obsidian-style)
//
// Two decorations applied via a ViewPlugin:
//   1. TaskMarker (`[ ]` / `[x]`) is replaced with an interactive checkbox.
//   2. HeaderMark (`#`, `##`, …) is hidden so headings render without their
//      syntax characters.
// Both reveal back to raw syntax when the cursor (or selection) is on that
// line — so editing stays direct and obvious, like Obsidian's Live Preview.

class CheckboxWidget extends WidgetType {
    /// `widthInChars` is the width of the raw text the widget replaces
    /// (e.g. `- [ ] ` is 6 chars). The wrapper span is sized to that width
    /// so when the cursor enters the line and the raw text is revealed,
    /// nothing shifts horizontally.
    /// `taskOffset` is the offset from the start of the replacement to the
    /// `[` character — used by the click handler to locate the marker.
    constructor(
        readonly checked: boolean,
        readonly widthInChars: number,
        readonly taskOffset: number,
    ) { super(); }

    toDOM(view: EditorView): HTMLElement {
        const wrap = document.createElement("span");
        wrap.className = "cm-task-checkbox-wrap";
        wrap.style.display = "inline-block";
        // Natural width — checkbox sits tight against the task text. Trade-off:
        // when the cursor enters the line and raw `- [ ] ` is revealed, the
        // text shifts right by the syntax width. Visual cleanliness wins.

        const box = document.createElement("input");
        box.type = "checkbox";
        box.checked = this.checked;
        box.className = "cm-task-checkbox";
        box.addEventListener("click", (e) => {
            e.preventDefault();
            e.stopPropagation();
            const widgetPos = view.posAtDOM(wrap);
            toggleTaskAtMarker(view, widgetPos + this.taskOffset);
        });

        wrap.appendChild(box);
        return wrap;
    }

    eq(other: WidgetType): boolean {
        return other instanceof CheckboxWidget
            && other.checked === this.checked
            && other.widthInChars === this.widthInChars
            && other.taskOffset === this.taskOffset;
    }

    ignoreEvent(): boolean { return true; }
}

function selectionOverlaps(state: EditorState, from: number, to: number): boolean {
    for (const range of state.selection.ranges) {
        if (range.from <= to && range.to >= from) return true;
    }
    return false;
}

// MARK: - Attachment image lines (always-on inline preview)
//
// An indented `![label](path)` child line (written under a todo by the
// capture flow) renders its image inline at a modest size, always visible —
// no click to expand (#43). Image bytes come over the JS↔Swift bridge as a
// data URL — the web view's file read-access is scoped to the app bundle, so
// a relative <img src> could never resolve against the capture file's folder.

/// path → data URL, or null when Swift reported the file missing.
const attachmentCache = new Map<string, string | null>();
// An empty dispatch does not satisfy the livePreview update guard, so
// attachment state changes (cache fill) carry an explicit effect — livePreview
// checks for it and rebuilds decorations deterministically.
const attachmentStateChanged = StateEffect.define<null>();

class ImageWidget extends WidgetType {
    constructor(readonly path: string, readonly label: string) { super(); }

    toDOM(): HTMLElement {
        const wrap = document.createElement("span");
        wrap.className = "cm-attachment";
        wrap.dataset.path = this.path;
        wrap.dataset.label = this.label;
        // Pull the bytes the moment the widget mounts so the preview shows
        // without any interaction (#43).
        requestAttachmentIfNeeded(this.path);
        renderAttachment(wrap, this.path, this.label);
        // Keep CodeMirror from treating a click on the image as a cursor
        // placement — a cursor on the line would reveal the raw markdown and
        // replace the widget mid-click.
        wrap.addEventListener("mousedown", (e) => {
            e.preventDefault();
            e.stopPropagation();
        });
        return wrap;
    }

    eq(other: WidgetType): boolean {
        return other instanceof ImageWidget
            && other.path === this.path
            && other.label === this.label;
    }

    ignoreEvent(): boolean { return true; }
}

function attachmentElements(path: string): HTMLElement[] {
    return Array.from(document.querySelectorAll<HTMLElement>(".cm-attachment"))
        .filter((el) => el.dataset.path === path);
}

function requestAttachmentIfNeeded(path: string) {
    if (attachmentCache.has(path)) return;
    sendToSwift({ type: "attachment", path });
}

function renderAttachment(el: HTMLElement, path: string, label: string) {
    el.innerHTML = "";
    const data = attachmentCache.get(path);
    if (data === undefined) {
        el.appendChild(makeAttachmentPill("Loading…", "loading"));
    } else if (data === null) {
        el.appendChild(makeAttachmentPill("Attachment not found", "missing"));
    } else {
        const img = document.createElement("img");
        img.className = "cm-attachment-img";
        img.src = data;
        img.alt = label;
        img.addEventListener("load", () => view?.requestMeasure());
        el.appendChild(img);
    }
}

function makeAttachmentPill(text: string, kind: "loading" | "missing"): HTMLElement {
    const pill = document.createElement("span");
    pill.className = `cm-attachment-pill cm-attachment-pill--${kind}`;
    pill.innerHTML = kind === "missing"
        ? `<svg width="12" height="12" viewBox="0 0 24 24" fill="none"
                stroke="currentColor" stroke-width="2"
                stroke-linecap="round" stroke-linejoin="round">
               <rect x="3" y="3" width="18" height="18" rx="2"/>
               <line x1="3" y1="3" x2="21" y2="21"/>
           </svg>`
        : `<svg width="12" height="12" viewBox="0 0 24 24" fill="none"
                stroke="currentColor" stroke-width="2"
                stroke-linecap="round" stroke-linejoin="round">
               <rect x="3" y="3" width="18" height="18" rx="2"/>
               <circle cx="8.5" cy="8.5" r="1.5"/>
               <path d="M21 15l-5-5L5 21"/>
           </svg>`;
    const span = document.createElement("span");
    span.textContent = text;
    pill.appendChild(span);
    return pill;
}

/// The app-mark that stands in for the H1 mark — a small accent-gradient
/// rounded square with a white hash, per the native-v2 mockup. H2–H6 marks
/// stay hidden.
class H1MarkWidget extends WidgetType {
    toDOM(): HTMLElement {
        const mark = document.createElement("span");
        mark.className = "cm-h1-mark";
        mark.textContent = "#";
        return mark;
    }
    eq(other: WidgetType): boolean { return other instanceof H1MarkWidget; }
    ignoreEvent(): boolean { return true; }
}

function buildLivePreview(view: EditorView): DecorationSet {
    // In read mode (Cmd+E) all syntax stays hidden regardless of cursor
    // position — the cursor is invisible anyway and reveal would be confusing.
    const readMode = view.state.readOnly;
    // Line decorations and inline marks share a sorted list so we can emit in
    // any tree-iteration order. Decoration.set(_, true) sorts before applying.
    const ranges: { from: number; to: number; deco: Decoration }[] = [];

    for (const { from, to } of view.visibleRanges) {
        syntaxTree(view.state).iterate({
            from, to,
            enter: (node) => {
                const line = view.state.doc.lineAt(node.from);

                // Line class on headings (always on, so layout doesn't shift
                // when the cursor moves onto the line). H2 section headings
                // additionally carry their tag hue as a CSS variable — the
                // heading text IS the tag name, so its dot matches the capture
                // box chip (drawn by the .cm-heading-2::before rule).
                const headingLevel = atxHeadingLevel(node.name);
                if (headingLevel) {
                    const attrs: Record<string, string> = {};
                    if (headingLevel === 2) {
                        const name = line.text.replace(/^#{1,6}\s*/, "").trim();
                        if (name) attrs.style = `--qc-section-hue: ${tagHue(name)}`;
                    }
                    ranges.push({
                        from: line.from, to: line.from,
                        deco: Decoration.line({
                            class: `cm-heading cm-heading-${headingLevel}`,
                            ...(attrs.style ? { attributes: attrs } : {}),
                        }),
                    });
                    return;
                }

                // TaskMarker is handled outside the tree iteration via a
                // line scan — the parser drops it for indented tasks that
                // lack a parent list item (treats them as code blocks).

                if (node.name === "HeaderMark") {
                    let end = node.to;
                    if (view.state.doc.sliceString(end, end + 1) === " ") end += 1;
                    // Reveal when the cursor is anywhere on the heading line.
                    if (!readMode && selectionOverlaps(view.state, line.from, line.to)) return;
                    // H1's mark becomes the accent app-mark (rounded square
                    // with a white "#"); other levels just hide their marks.
                    const isH1 = /^#\s/.test(line.text);
                    ranges.push({
                        from: node.from, to: end,
                        deco: isH1
                            ? Decoration.replace({ widget: new H1MarkWidget() })
                            : Decoration.replace({}),
                    });
                    return;
                }

                // Inline emphasis (`*` / `_` for italic, `**` / `__` for bold),
                // inline code backticks, and strikethrough `~~`. Hide on
                // non-cursor lines; the surrounding text keeps its bold/italic/
                // monospace styling because the highlight rules style the
                // content nodes (Strong, Emphasis, etc.) directly.
                if (node.name === "EmphasisMark" || node.name === "CodeMark" || node.name === "StrikethroughMark") {
                    if (!readMode && selectionOverlaps(view.state, line.from, line.to)) return;
                    ranges.push({
                        from: node.from, to: node.to,
                        deco: Decoration.replace({}),
                    });
                    return;
                }

                // Inline `code` gets a pink pill background — but only when
                // the cursor isn't on the line. With the cursor on the line
                // the backticks reveal (above) and the pill drops so editing
                // feels direct.
                if (node.name === "InlineCode") {
                    if (!readMode && selectionOverlaps(view.state, line.from, line.to)) return;
                    // Inner content range — skip the leading/trailing backticks.
                    const innerFrom = node.from + 1;
                    const innerTo = node.to - 1;
                    if (innerTo > innerFrom) {
                        ranges.push({
                            from: innerFrom, to: innerTo,
                            deco: Decoration.mark({ class: "cm-inline-code-pill" }),
                        });
                    }
                    return;
                }
            },
        });
    }
    // Line-based scan for task widgets and indent guides. Independent of the
    // syntax tree so indented tasks render with the checkbox even when the
    // parser saw an indented code block.
    for (const range of view.visibleRanges) {
        const fromLine = view.state.doc.lineAt(range.from).number;
        const toLine = view.state.doc.lineAt(range.to).number;
        for (let n = fromLine; n <= toLine; n++) {
            const line = view.state.doc.line(n);

            // Indent guide: thin vertical line for each indent level on
            // list/task lines, signalling that the item is nested under
            // something above.
            const listIndent = line.text.match(/^(\s*)([-*+]|\d+\.)\s/);
            if (listIndent && listIndent[1].length >= 4) {
                const level = Math.min(Math.floor(listIndent[1].length / 4), 4);
                ranges.push({
                    from: line.from, to: line.from,
                    deco: Decoration.line({ class: `cm-indented cm-indent-${level}` }),
                });
            }

            // Attachment image child line — fold to a pill (or the expanded
            // preview) unless the cursor is on the line, which reveals the
            // raw markdown like every other live-preview element.
            const imageMatch = line.text.match(/^( {2,}|\t)!\[[^\]]*\]\((\S+?)\)\s*$/);
            if (imageMatch) {
                if (readMode || !selectionOverlaps(view.state, line.from, line.to)) {
                    const path = imageMatch[2];
                    const rawName = path.split("/").pop() ?? "screenshot";
                    let label: string;
                    try { label = decodeURIComponent(rawName); }
                    catch { label = rawName; }   // malformed %-sequences (e.g. 100%done.png) must not throw inside a ViewPlugin update
                    ranges.push({
                        from: line.from + imageMatch[1].length, to: line.to,
                        deco: Decoration.replace({ widget: new ImageWidget(path, label) }),
                    });
                }
                continue;
            }

            const match = line.text.match(/^(\s*)([-*+]\s+)(\[[\sxX]\])/);
            if (match) {
                const startPos = line.from + match[1].length;
                const taskMarkerFrom = startPos + match[2].length;
                let endPos = taskMarkerFrom + 3;
                if (view.state.doc.sliceString(endPos, endPos + 1) === " ") endPos += 1;
                const onLine = !readMode && selectionOverlaps(view.state, line.from, line.to);

                // Hidden creation-time token: `<!--qc:…-->` appended by capture
                // (after any `➕` marker). Never displayed — hide it off-cursor,
                // exactly like Obsidian reading view drops HTML comments. The
                // priority suffix-hide below stops before it so the two replace
                // ranges never overlap. `contentEnd` is the line length minus the
                // token, so priority/label logic ignores the token entirely.
                const tokenMatch = line.text.match(/\s*<!--qc:[^>]*-->\s*$/);
                const contentEnd = tokenMatch && tokenMatch.index !== undefined
                    ? line.from + tokenMatch.index
                    : line.from + line.text.length;
                if (tokenMatch && tokenMatch.index !== undefined && !onLine) {
                    ranges.push({
                        from: contentEnd, to: line.from + line.text.length,
                        deco: Decoration.replace({}),
                    });
                }

                // Checkbox widget — only render when the cursor isn't in the
                // syntax range (same condition as before).
                if (readMode || !selectionOverlaps(view.state, startPos, endPos)) {
                    const checked = /[xX]/.test(match[3]);
                    const widthInChars = endPos - startPos;
                    const taskOffset = taskMarkerFrom - startPos;
                    ranges.push({
                        from: startPos, to: endPos,
                        deco: Decoration.replace({
                            widget: new CheckboxWidget(checked, widthInChars, taskOffset),
                        }),
                    });
                    // Strike + mute the label of a completed task. The hidden
                    // token is excluded (contentEnd) so the strike never spans it.
                    const labelEnd = contentEnd;
                    if (checked && labelEnd > endPos) {
                        ranges.push({
                            from: endPos, to: labelEnd,
                            deco: Decoration.mark({ class: "cm-done-label" }),
                        });
                    }
                }

                // Priority suffix: trailing ` !`/` !!`/` !!!` paints a colored
                // dot at the far-right of the line via a ::after pseudo (line
                // class), and hides the raw `!`s off-cursor. Matched against the
                // line with the hidden token stripped, so a captured
                // `task !!! <!--qc:…-->` still classifies and hides correctly.
                const priorityText = line.text.slice(0, contentEnd - line.from);
                const priority = priorityText.match(/(\s+)(!{1,3})(?:\s+➕\s+\S+\s+\S+)?\s*$/);
                if (priority && priority.index !== undefined) {
                    const level = priority[2].length;
                    const priorityLabel = level === 3 ? "High priority (!!!)"
                                       : level === 2 ? "Medium priority (!!)"
                                                     : "Low priority (!)";
                    ranges.push({
                        from: line.from, to: line.from,
                        deco: Decoration.line({
                            class: `cm-priority-dot cm-priority-dot-${level}`,
                            attributes: { "data-priority-label": priorityLabel },
                        }),
                    });
                    if (!onLine) {
                        const suffixStart = line.from + priority.index;
                        ranges.push({
                            from: suffixStart, to: contentEnd,
                            deco: Decoration.replace({}),
                        });
                    }
                }
            }
        }
    }

    return Decoration.set(ranges.map(r => r.deco.range(r.from, r.to)), true);
}

function atxHeadingLevel(name: string): number | null {
    const match = /^ATXHeading([1-6])$/.exec(name);
    return match ? Number(match[1]) : null;
}

const livePreview = ViewPlugin.fromClass(class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
        this.decorations = buildLivePreview(view);
    }

    update(update: ViewUpdate) {
        if (update.docChanged || update.viewportChanged || update.selectionSet
            || update.transactions.some(tr => tr.effects.some(e => e.is(attachmentStateChanged)))) {
            this.decorations = buildLivePreview(update.view);
        }
    }
}, {
    decorations: (v) => v.decorations,
});

function makeTheme() {
    return EditorView.theme({
    "&": {
        backgroundColor: palette.surface,
        color: palette.text,
        height: "100%",
    },
    ".cm-content": {
        fontFamily: 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace',
        fontSize: "13px",
        lineHeight: "1.6",
        // Full-width content (no left rail, no centered column) per the mockup;
        // generous side padding, extra bottom clearance for the status bar + fab.
        padding: "36px 44px 110px",
        caretColor: palette.text,
    },
    ".cm-scroller": {
        overflow: "auto",
        fontFamily: 'inherit',
    },
    ".cm-line": {
        padding: "0",
    },
    // Caret styling — scoped to the default cursor layer so it doesn't bleed
    // onto vim's block cursor (which lives in .cm-vimCursorLayer). Without
    // this scoping, the margin-left + thicker border on the block cursor
    // leaves stale paint trails as it moves.
    ".cm-cursorLayer:not(.cm-vimCursorLayer) .cm-cursor, .cm-dropCursor": {
        borderLeftColor: palette.text,
        borderLeftWidth: "2.5px",
        marginLeft: "-1px",   // re-center the thicker stem on the insertion point
    },
    // Vim block cursor — steel accent (pops against the misted surface).
    ".cm-fat-cursor": {
        backgroundColor: `${palette.accent} !important`,
        color: `${palette.onAccent} !important`,
    },
    "&:not(.cm-focused) .cm-fat-cursor": {
        backgroundColor: "transparent !important",
        outline: `solid 1px ${palette.accent}`,
        color: "transparent !important",
    },
    // Read mode (Cmd+E): no cursor. drawSelection wraps the caret in
    // .cm-cursorLayer with its own animations, so hide the entire layer.
    // !important defeats the animation/inline-style chain CodeMirror sets.
    "&.cm-read-mode .cm-cursorLayer": {
        display: "none !important",
    },
    "&.cm-read-mode .cm-cursor, &.cm-read-mode .cm-cursor-primary, &.cm-read-mode .cm-dropCursor": {
        display: "none !important",
    },
    "&.cm-read-mode .cm-content": {
        caretColor: "transparent !important",
    },
    // Bottom status bar (surfaceRail) — home of the vim mode pill, filename,
    // item count, and encoding. Pinned across the foot of the editor, above the
    // scroller.
    ".cm-statusbar": {
        position: "absolute",
        left: "0",
        right: "0",
        bottom: "0",
        display: "flex",
        alignItems: "center",
        gap: "16px",
        height: "33px",
        padding: "0 16px",
        // Floats over the scroller (zIndex 8), which fills the full editor
        // height, so document lines scroll behind this band. surfaceRail is a
        // translucent tint in the native-v2 palette — on its own the bar is
        // ~97% see-through and content bleeds through / reads as clipped under
        // it. Layer the tint on the opaque surface so it fully occludes, in
        // both palettes (same fix family as the floating cards, 56b274f).
        background: `linear-gradient(0deg, ${palette.surfaceRail}, ${palette.surfaceRail}) ${palette.surface}`,
        borderTop: `0.5px solid ${palette.borderSoft}`,
        fontFamily: sansFamily,
        fontSize: "11px",
        fontWeight: "500",
        letterSpacing: "0.2px",
        color: palette.muted,
        userSelect: "none",
        zIndex: "8",
    },
    // Filename is a path — the one mono element in the status bar.
    ".cm-status-file": {
        color: palette.soft,
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
    },
    ".cm-status-right": { marginLeft: "auto", display: "flex", gap: "16px" },
    // Empty-state overlay — shown when the document has zero todo lines.
    ".cm-empty-state": {
        position: "absolute",
        inset: "0",
        bottom: "33px",   // clear the status bar
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: "6px",
        pointerEvents: "none",
        userSelect: "none",
        color: palette.muted,
        fontFamily: sansFamily,
        fontSize: "12px",
        lineHeight: "1.6",
        textAlign: "center",
        zIndex: "1",
    },
    // Mode pill — accentSoft (NORMAL) by default; the other vim modes keep the
    // conventional green/amber/red cues so the mode reads at a glance.
    ".cm-mode-badge": {
        padding: "3px 9px",
        borderRadius: "5px",
        fontFamily: sansFamily,
        fontSize: "10.5px",
        fontWeight: "600",
        letterSpacing: "0.5px",
        textTransform: "uppercase",
        backgroundColor: palette.accentSoft,
        color: palette.accentInk,
        userSelect: "none",
    },
    // Monochrome mode tints — distinguished by fill weight, not hue, so warm
    // colour stays confined to the priority orbs. Normal = soft, Insert = solid
    // accent (active editing), Visual = neutral well, Replace = strong ink.
    ".cm-mode-badge--read": {
        backgroundColor: palette.text,
        color: palette.onAccent,
    },
    ".cm-mode-badge--normal": {
        backgroundColor: palette.accentSoft,
        color: palette.accentInk,
    },
    ".cm-mode-badge--insert": {
        backgroundColor: palette.accent,
        color: palette.onAccent,
    },
    ".cm-mode-badge--visual": {
        backgroundColor: palette.surfaceField,
        color: palette.soft,
    },
    ".cm-mode-badge--replace": {
        backgroundColor: palette.accentInk,
        color: palette.onAccent,
    },
    // Transient "Saved" badge — appears under the mode badge on ⌘S, fades out
    // after a moment. Subtle Apple-like green so it reads as success without
    // shouting.
    ".cm-saved-badge": {
        position: "absolute",
        top: "14px",
        right: "16px",
        display: "flex",
        alignItems: "center",
        gap: "4px",
        padding: "3px 10px 3px 8px",
        borderRadius: "8px",
        fontFamily: sansFamily,
        fontSize: "10.5px",
        fontWeight: "600",
        letterSpacing: "0.6px",
        textTransform: "uppercase",
        // Floats over content — accentSoft is translucent in the native-v2
        // palette, so layer it on the opaque surface or text bleeds through.
        background: `linear-gradient(0deg, ${palette.accentSoft}, ${palette.accentSoft}) ${palette.surface}`,
        color: palette.accentInk,
        border: `1px solid ${palette.accent}33`,
        opacity: "0",
        transform: "translateY(-4px)",
        transition: "opacity 0.18s ease, transform 0.18s ease",
        pointerEvents: "none",
        zIndex: "10",
    },
    ".cm-saved-badge--visible": {
        opacity: "1",
        transform: "translateY(0)",
    },
    // Cursor-anchored refile dropdown (⌥⌘U). A small surface card listing the
    // configured refile targets; arrow keys navigate, Enter selects, Esc cancels.
    ".cm-refile-dropdown": {
        position: "fixed",
        zIndex: "30",
        minWidth: "180px",
        maxWidth: "320px",
        padding: "4px",
        borderRadius: "10px",
        // Floating card — must be opaque (surfaceField is a translucent well
        // tint in the native-v2 palette; content would bleed through).
        backgroundColor: palette.surface,
        border: `0.5px solid ${palette.borderSoft}`,
        boxShadow: "0 8px 28px rgba(0,0,0,0.28)",
        fontFamily: sansFamily,
        fontSize: "12px",
        color: palette.text,
        overflow: "hidden",
    },
    ".cm-refile-item": {
        padding: "6px 10px",
        borderRadius: "6px",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis",
        cursor: "pointer",
    },
    ".cm-refile-item--selected": {
        backgroundColor: palette.accentSoft,
        color: palette.accentInk,
    },
    // Transient refile toast (success / off-item / empty-targets), centred at
    // the bottom above the status bar. Distinct from the ⌘S "Saved" badge.
    ".cm-refile-toast": {
        position: "absolute",
        left: "50%",
        bottom: "52px",
        transform: "translateX(-50%) translateY(6px)",
        padding: "6px 14px",
        borderRadius: "9px",
        // Floating toast — opaque surface, not the translucent well tint.
        backgroundColor: palette.surface,
        border: `0.5px solid ${palette.borderSoft}`,
        boxShadow: "0 6px 20px rgba(0,0,0,0.22)",
        fontFamily: sansFamily,
        fontSize: "11px",
        letterSpacing: "0.4px",
        color: palette.text,
        opacity: "0",
        transition: "opacity 0.18s ease, transform 0.18s ease",
        pointerEvents: "none",
        zIndex: "20",
    },
    ".cm-refile-toast--visible": {
        opacity: "1",
        transform: "translateX(-50%) translateY(0)",
    },
    // Native find (⌘F) — restyle CodeMirror's search panel from its unthemed
    // defaults to the native-v2 palette. Top-anchored (search({top:true})) so
    // it never collides with the bottom status bar.
    ".cm-panels": {
        backgroundColor: palette.surface,
        color: palette.text,
        zIndex: "25",
    },
    ".cm-panels.cm-panels-top": {
        borderBottom: `0.5px solid ${palette.borderSoft}`,
    },
    ".cm-panel.cm-search": {
        fontFamily: sansFamily,
        fontSize: "12px",
        padding: "8px 10px",
    },
    ".cm-panel.cm-search input.cm-textfield": {
        backgroundColor: palette.surfaceField,
        border: `0.5px solid ${palette.borderSoft}`,
        borderRadius: "6px",
        color: palette.text,
        outline: "none",
    },
    ".cm-panel.cm-search input.cm-textfield:focus": {
        borderColor: palette.accent,
    },
    ".cm-panel.cm-search button.cm-button": {
        background: palette.surfaceField,
        backgroundImage: "none",
        border: `0.5px solid ${palette.borderSoft}`,
        borderRadius: "6px",
        color: palette.text,
        cursor: "pointer",
    },
    ".cm-panel.cm-search label": {
        color: palette.soft,
        fontSize: "11px",
    },
    ".cm-panel.cm-search button[name=close]": {
        color: palette.soft,
        cursor: "pointer",
        fontSize: "14px",
    },
    ".cm-searchMatch": {
        backgroundColor: `${palette.accent}38`,
        borderRadius: "2px",
    },
    ".cm-searchMatch.cm-searchMatch-selected": {
        backgroundColor: `${palette.accent}66`,
    },
    // Floating action cluster, bottom-right (replaces the old left rail). A
    // small surface card holding the reorg + archive buttons; clears the
    // status bar.
    ".cm-sidebar": {
        position: "absolute",
        right: "18px",
        bottom: "52px",
        top: "auto",
        left: "auto",
        transform: "none",
        display: "flex",
        flexDirection: "column",
        gap: "5px",
        padding: "5px",
        borderRadius: "10px",
        backgroundColor: palette.surface,
        border: `0.5px solid ${palette.borderSoft}`,
        boxShadow: "0 12px 28px -16px rgba(0, 0, 0, 0.45)",
        zIndex: "9",
    },
    ".cm-sidebar-btn": {
        width: "34px",
        height: "34px",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        border: "none",
        backgroundColor: "transparent",
        color: palette.soft,
        borderRadius: "8px",
        cursor: "pointer",
        padding: "0",
        transition: "background-color 0.12s ease, color 0.12s ease",
    },
    ".cm-sidebar-btn:hover": {
        backgroundColor: palette.accentSoft,
        color: palette.accentInk,
    },
    ".cm-sidebar-btn:active": {
        backgroundColor: palette.accentSoft,
    },
    // CSS tooltip for sidebar buttons — replaces the slow native title tooltip.
    ".cm-btn-tooltip": {
        position: "absolute",
        right: "calc(100% + 8px)",
        top: "50%",
        transform: "translateY(-50%)",
        whiteSpace: "nowrap",
        backgroundColor: palette.surfaceRail,
        color: palette.soft,
        border: `0.5px solid ${palette.borderSoft}`,
        borderRadius: "6px",
        padding: "4px 8px",
        fontFamily: sansFamily,
        fontSize: "11px",
        fontWeight: "600",
        letterSpacing: "0.3px",
        pointerEvents: "none",
        opacity: "0",
        transition: "opacity 0.12s ease",
        transitionDelay: "0s",
        zIndex: "20",
    },
    ".cm-sidebar-btn:hover .cm-btn-tooltip": {
        opacity: "1",
        transitionDelay: "200ms",
    },
    // Priority orb tooltip — shared div injected by the mousemove handler.
    ".cm-priority-tooltip": {
        position: "fixed",
        backgroundColor: palette.surfaceRail,
        color: palette.soft,
        border: `0.5px solid ${palette.borderSoft}`,
        borderRadius: "6px",
        padding: "4px 8px",
        fontFamily: sansFamily,
        fontSize: "11px",
        fontWeight: "600",
        letterSpacing: "0.3px",
        pointerEvents: "none",
        zIndex: "20",
        display: "none",
    },
    "&.cm-focused .cm-selectionBackground, ::selection": {
        backgroundColor: palette.selection,
    },
    ".cm-activeLine": {
        backgroundColor: "transparent",
    },
    ".cm-focused": {
        outline: "none",
    },
    // Hides markdown syntax marks while keeping their width — the text is
    // still in the DOM so the cursor lands where the user clicks, and revealing
    // them on the active line doesn't shift surrounding text horizontally.
    ".cm-md-hidden": {
        color: "transparent",
    },
    // Recessed-well pill behind inline `code`. Applied via decoration only
    // when the cursor isn't on the line, so editing the raw markdown drops it.
    ".cm-inline-code-pill": {
        backgroundColor: palette.codeBg,
        color: palette.text,
        borderRadius: "5px",
        padding: "1px 6px",
        margin: "0 1px",
    },
    // Attachment image line — folded pill / expanded inline preview.
    ".cm-attachment": {
        cursor: "default",
    },
    ".cm-attachment-pill": {
        display: "inline-flex",
        alignItems: "center",
        gap: "6px",
        padding: "2px 10px",
        borderRadius: "6px",
        backgroundColor: palette.surfaceField,
        border: `0.5px solid ${palette.borderSoft}`,
        color: palette.muted,
        fontSize: "12px",
        lineHeight: "1.5",
        verticalAlign: "1px",
        transition: "border-color 0.12s ease, color 0.12s ease",
    },
    ".cm-attachment:hover .cm-attachment-pill": {
        borderColor: palette.accent,
        color: palette.soft,
    },
    ".cm-attachment-pill--missing": {
        fontStyle: "italic",
    },
    ".cm-attachment-img": {
        display: "block",
        // Modest always-on preview (#43) — readable, not a hero image.
        maxWidth: "min(360px, 92%)",
        maxHeight: "200px",
        margin: "4px 0",
        borderRadius: "8px",
        border: `0.5px solid ${palette.borderSoft}`,
        boxShadow: "0 12px 28px -16px rgba(28, 42, 60, 0.45)",
    },
    // Completed task label — struck through and muted (the checkbox keeps its
    // accent fill). Applied only when the checkbox widget is rendered (cursor
    // off the line), so editing the raw markdown reads normally.
    ".cm-done-label": {
        textDecoration: "line-through",
        textDecorationColor: palette.muted,
        color: palette.muted,
    },
    // Priority dot — a single colored circle at the far-right of the line,
    // drawn via a ::after pseudo-element so it doesn't disturb text layout.
    // Aligned to the first visual line so wrapped tasks still show the dot
    // at the top right.
    ".cm-line.cm-priority-dot": {
        position: "relative",
        paddingRight: "28px",   // clear the 9px orb + 3px halo + 8px right offset
    },
    ".cm-line.cm-priority-dot::after": {
        content: '""',
        position: "absolute",
        right: "8px",
        top: "0.6em",
        width: "9px",
        height: "9px",
        borderRadius: "50%",
        pointerEvents: "none",
    },
    // Colour-coded priority orbs, each with a soft same-colour halo
    // (`!!!` = high, `!!` = med, `!` = low). The only warm colour in the editor.
    // `38` ≈ 22% alpha as an 8-digit hex, so the halo tracks the active palette.
    ".cm-line.cm-priority-dot-3::after": {
        backgroundColor: palette.priHigh,
        boxShadow: `0 0 0 3px ${palette.priHigh}38`,
    },
    ".cm-line.cm-priority-dot-2::after": {
        backgroundColor: palette.priMed,
        boxShadow: `0 0 0 3px ${palette.priMed}38`,
    },
    ".cm-line.cm-priority-dot-1::after": {
        backgroundColor: palette.priLow,
        boxShadow: `0 0 0 3px ${palette.priLow}38`,
    },
    // Indent guides — thin vertical lines under each indent level on nested
    // list/task lines. Drawn via ::before + box-shadow so a single pseudo
    // element can render multiple lines (one per level) without extra DOM.
    ".cm-line.cm-indented": {
        position: "relative",
    },
    ".cm-line.cm-indented::before": {
        content: '""',
        position: "absolute",
        left: "1.5ch",
        top: "0",
        // Match the editor's line-height (1.6 × 13px). Bounding the height
        // means the guide only spans the FIRST visual line — when the logical
        // line wraps, the guide doesn't bleed down across the wrapped text.
        height: "1.6em",
        width: "1px",
        backgroundColor: palette.borderSoft,
        pointerEvents: "none",
    },
    ".cm-line.cm-indent-2::before": {
        boxShadow: `4ch 0 0 0 ${palette.borderSoft}`,
    },
    ".cm-line.cm-indent-3::before": {
        boxShadow: `4ch 0 0 0 ${palette.borderSoft}, 8ch 0 0 0 ${palette.borderSoft}`,
    },
    ".cm-line.cm-indent-4::before": {
        boxShadow: `4ch 0 0 0 ${palette.borderSoft}, 8ch 0 0 0 ${palette.borderSoft}, 12ch 0 0 0 ${palette.borderSoft}`,
    },
    ".cm-task-checkbox": {
        // Custom-styled square checkbox to match the target design: light
        // gray outline, no fill until checked. Resets the native appearance
        // and draws our own border + checkmark.
        appearance: "none",
        WebkitAppearance: "none",
        width: "15px",
        height: "15px",
        margin: "0 10px 0 0",
        border: `1px solid ${palette.borderStrong}`,
        borderRadius: "4px",
        verticalAlign: "-3px",
        cursor: "pointer",
        backgroundColor: palette.surface,
        transition: "border-color 0.12s ease, background-color 0.12s ease",
    },
    ".cm-task-checkbox:hover": {
        borderColor: palette.accent,
    },
    ".cm-task-checkbox:checked": {
        backgroundColor: palette.accent,
        borderColor: palette.accent,
        backgroundImage: "url('data:image/svg+xml;utf8,<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M4 8.5l2.5 2.5L12 5.5\" stroke=\"white\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>')",
        backgroundSize: "14px",
        backgroundPosition: "center",
        backgroundRepeat: "no-repeat",
    },
    // Heading line treatment. Margins on line decorations break vertical
    // cursor navigation (Down arrow lands in the margin gap and skips lines),
    // so we use padding — which CodeMirror's cursor logic handles correctly —
    // and keep the values small.
    // H2 = tracked-uppercase section caption with its tag-hue dot (the hue
    // arrives as --qc-section-hue on the line, set by buildLivePreview) and a
    // hairline rule. The uppercasing is visual only — raw text keeps its case.
    ".cm-heading-2": {
        paddingTop: "10px",
        paddingBottom: "3px",
        borderBottom: `0.5px solid ${palette.borderSoft}`,
        textTransform: "uppercase",
    },
    ".cm-heading-2::before": {
        content: '""',
        display: "inline-block",
        width: "7px",
        height: "7px",
        borderRadius: "50%",
        marginRight: "8px",
        verticalAlign: "1px",
        backgroundColor: "var(--qc-section-hue, transparent)",
    },
    // The H1 app-mark: accent-gradient rounded square with a white hash,
    // standing in for the hidden `# ` mark.
    ".cm-h1-mark": {
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: "26px",
        height: "26px",
        marginRight: "10px",
        borderRadius: "7px",
        background: `linear-gradient(180deg, ${palette.accent}E6, ${palette.accent})`,
        color: "#FFFFFF",
        fontFamily: sansFamily,
        fontSize: "15px",
        fontWeight: "700",
        // Centers the 26px chip on the H1 text (22px / 1.4 line-height →
        // ~26px inline box). Measured in the harness: at -6px the chip's
        // center sat 8px below the text's center, so raise by 8 → +2px,
        // which puts the two centers within 0px of each other without
        // growing the 30.8px line box (no shift when the cursor swaps the
        // chip for the raw "#").
        verticalAlign: "2px",
        userSelect: "none",
    },
    }, { dark: palette === darkPalette });
}

// Active theme + syntax highlight, swapped in a compartment when the system
// appearance changes.
const themeComp = new Compartment();
function themeExtensions() {
    return [syntaxHighlighting(makeHighlight()), makeTheme()];
}

declare global {
    interface Window {
        webkit?: {
            messageHandlers: {
                editorBridge: { postMessage: (msg: unknown) => void };
            };
        };
        qcEditor: {
            setContent: (content: string) => void;
            getContent: () => string;
            focus: () => void;
            setFilename: (name: string) => void;
            setVimEnabled: (on: boolean) => void;
            flushSave: () => void;
            attachmentLoaded: (path: string, dataURL: string | null) => void;
            setRefileTargets: (names: string[]) => void;
            refileDidComplete: (targetName: string) => void;
            startRefile: () => void;
            setKeymap: (map: Record<string, string>) => void;
            invoke: (actionId: string) => void;
            revealLine: (line: number) => void;
            revealSection: (name: string) => void;
        };
    }
}

let view: EditorView | null = null;
let saveTimer: number | null = null;
let suppressNextSave = false;

// Refile targets pushed from Swift (display names, dropdown order). The editor
// can't read settings, so it relies on this being kept current (R35).
let refileTargets: string[] = [];
let refileOpen = false;
// 0-based line where the just-refiled subtree started. After Swift removes it
// and the file watcher reloads us, `mount()` lands the cursor on the item now
// at this line (the next item) so a run of ⌥⌘U refiles keeps flowing (#98).
let pendingRefileCursorLine: number | null = null;

// Compartment for the read-mode extensions so Cmd+E can toggle them at runtime.
// Reconfiguring a Compartment is the supported way to swap a group of
// extensions in/out without rebuilding the entire EditorState.
const readModeComp = new Compartment();
let readMode = false;

// Vim is always on for now; the Compartment is here so a future settings
// toggle can swap it in/out without rebuilding the editor.
const vimComp = new Compartment();
let vimEnabled = true;
let vimMode: "normal" | "insert" | "visual" | "replace" = "normal";

// App-level shortcut bindings. Swift's ShortcutRegistry is the source of
// truth and pushes `{actionId: key spec}` via qcEditor.setKeymap on boot
// (same pattern as setRefileTargets); these defaults exist so the browser
// harness — which has no bridge — gets working bindings. The command map is
// also the bridge dispatch table: window-intercepted actions that must run
// in the editor (⌥⌘U refile) arrive as qcEditor.invoke(actionId).
const appKeymapComp = new Compartment();
const defaultAppKeymap: Record<string, string> = {
    readMode: "Mod-e",
    toggleTask: "Mod-l",
    save: "Mod-s",
    reorg: "Mod-'",
    nextSection: "Alt-Mod-ArrowDown",
    prevSection: "Alt-Mod-ArrowUp",
};
let appKeymap: Record<string, string> = { ...defaultAppKeymap };

const appCommands: Record<string, (v: EditorView) => boolean> = {
    readMode: (v) => { setReadMode(v, !readMode); return true; },
    toggleTask: (v) => toggleTaskCommand(v),
    save: (v) => { saveNow(v); return true; },
    reorg: (v) => { moveCompletedToBottom(v); return true; },
    refile: (v) => startRefile(v),
    nextSection: (v) => jumpToSection(v, 1),
    prevSection: (v) => jumpToSection(v, -1),
};

/// ⌥⌘↓ / ⌥⌘↑ — move the cursor to the next/previous `##` section heading
/// (column 0, so a follow-up refile acts on the heading's subtree) and pin
/// it near the viewport top: a jump-to-section wants the section's content
/// on screen, not the heading centered. Boundary = silent no-op (#67).
function jumpToSection(view: EditorView, dir: 1 | -1): boolean {
    const doc = view.state.doc;
    const current = doc.lineAt(view.state.selection.main.head).number;
    let target = -1;
    for (let n = current + dir; n >= 1 && n <= doc.lines; n += dir) {
        if (/^##\s/.test(doc.line(n).text)) { target = n; break; }
    }
    if (target === -1) return true;
    const pos = doc.line(target).from;
    view.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }),
    });
    return true;
}

/// Clamp a requested 1-based line number into `[1, lines]`. The palette parses
/// the file independently and may hand us a line that no longer exists (the file
/// shrank between parse and reveal), so we reveal the nearest valid line rather
/// than erroring. Exported for unit testing.
export function clampLine(requested: number, lines: number): number {
    if (lines < 1) return 1;
    if (!Number.isFinite(requested)) return 1;
    return Math.min(lines, Math.max(1, Math.round(requested)));
}

/// Scroll a 1-based line to the top of the viewport and place the cursor at its
/// start — the shared mechanics behind reveal-by-line and reveal-section.
function revealAt(view: EditorView, line1: number): void {
    const doc = view.state.doc;
    const pos = doc.line(clampLine(line1, doc.lines)).from;
    view.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }),
    });
}

function buildAppKeymap() {
    return keymap.of(
        Object.entries(appKeymap)
            .filter(([id]) => appCommands[id])
            .map(([id, key]) => ({ key, run: appCommands[id] }))
    );
}

function setReadMode(v: EditorView, on: boolean) {
    readMode = on;
    v.dispatch({
        // Only `readOnly`, not `editable.of(false)` — the latter strips the
        // content's contenteditable attribute, which blocks the Cmd+E keydown
        // from reaching the keymap so you can't toggle back. We hide the
        // cursor visually via CSS instead.
        effects: readModeComp.reconfigure(on ? [
            EditorState.readOnly.of(true),
        ] : []),
    });
    v.dom.classList.toggle("cm-read-mode", on);
    updateBadge(v);
}

/// Toggles `[ ]` ↔ `[x]` at the given position. Toggle in place — no reorder.
function toggleTaskAtMarker(view: EditorView, markerPos: number): void {
    const current = view.state.doc.sliceString(markerPos, markerPos + 3);
    if (!/\[[\sxX]\]/.test(current)) return;
    const next = /\[[xX]\]/.test(current) ? "[ ]" : "[x]";
    view.dispatch({ changes: { from: markerPos, to: markerPos + 3, insert: next } });
}

/// Pulls every completed (`- [x]`) line in each `##` section to the end of
/// that section, preserving the order of both checked and unchecked items
/// within the section. Trailing blank lines (section separators) are kept
/// where they were. Cursor stays at its (line, column) position so focus
/// doesn't drift, and moved lines slide into their new spots via a FLIP
/// (first/last/invert/play) animation.
function moveCompletedToBottom(view: EditorView): void {
    const original = view.state.doc.toString();
    const lines = original.split("\n");

    // Group lines into sections.
    const sections: string[][] = [];
    let current: string[] = [];
    for (const line of lines) {
        if (/^#+\s/.test(line) && current.length > 0) {
            sections.push(current);
            current = [];
        }
        current.push(line);
    }
    sections.push(current);

    // Sort each section's tasks by priority + state:
    //   1. unchecked  !!!
    //   2. unchecked  !!
    //   3. unchecked  !
    //   4. unchecked  (no priority)
    //   5. checked    (priority stripped, indentation stripped)
    // A task line and any immediately-following INDENTED lines (sub-bullets,
    // notes, sub-tasks) move together as one group so children don't get
    // orphaned at the top. Order within each bucket is preserved (stable sort).
    // Non-task top-level lines (headings, paragraphs) stay above the tasks.
    interface TaskGroup { bucket: number; lines: string[] }
    const processed = sections.map(section => {
        const groups: TaskGroup[] = [];
        const rest: string[] = [];
        let touched = false;
        let i = 0;
        while (i < section.length) {
            const line = section[i];
            const taskMatch = line.match(/^(\s*)([-*+]\s+)\[([\sxX])\]/);
            if (!taskMatch) {
                rest.push(line);
                i++;
                continue;
            }
            touched = true;
            // Collect consecutive indented children.
            const groupLines = [line];
            i++;
            while (i < section.length && /^( {2,}|\t)\S/.test(section[i])) {
                groupLines.push(section[i]);
                i++;
            }
            const isChecked = /[xX]/.test(taskMatch[3]);
            if (isChecked) {
                // Split off the hidden `<!--qc:…-->` creation token first so it
                // survives the priority-marker strip, then re-append it. Strip
                // priority (and the `➕` group, preserved as $1) from the body.
                const tokenSplit = groupLines[0].match(/^(.*?)(\s*<!--qc:[^>]*-->)?\s*$/s);
                const body = tokenSplit ? tokenSplit[1] : groupLines[0];
                const token = tokenSplit && tokenSplit[2] ? tokenSplit[2] : "";
                groupLines[0] = body
                    .replace(/^\s+/, "")
                    .replace(/\s+!{1,3}(\s+➕\s+\S+\s+\S+)?\s*$/, "$1")
                    + token;
                groups.push({ bucket: 4, lines: groupLines });
            } else {
                // Optional ` ➕ DATE TIME` timestamp tail and the hidden
                // `<!--qc:…-->` token are tolerated, so a captured
                // `task !!! ➕ … <!--qc:…-->` still classifies as priority 3.
                const priority = line.match(/\s+(!{1,3})(?:\s+➕\s+\S+\s+\S+)?(?:\s*<!--qc:[^>]*-->)?\s*$/);
                const level = priority ? priority[1].length : 0;
                const bucket = level === 0 ? 3 : 3 - level;
                groups.push({ bucket, lines: groupLines });
            }
        }
        if (!touched) return section;
        const sorted = [...groups].sort((a, b) => a.bucket - b.bucket);
        const allTasks = sorted.flatMap(g => g.lines);
        const hadTrailingBlank = rest[rest.length - 1] === "";
        while (rest.length > 0 && rest[rest.length - 1] === "") rest.pop();
        const result = [...rest, ...allTasks];
        if (hadTrailingBlank) result.push("");
        return result;
    });

    const next = processed.map(s => s.join("\n")).join("\n");
    if (next === original) return;

    // Preserve cursor at (line, column) — without this CodeMirror remaps the
    // absolute position through the whole-doc replace, which puts the cursor
    // wherever the moved text ended up. Anchoring by line keeps the focus
    // visually in place.
    const sel = view.state.selection.main;
    const oldLine = view.state.doc.lineAt(sel.head);
    const lineNum = oldLine.number;
    const col = sel.head - oldLine.from;

    const nextLines = next.split("\n");
    const targetLineIdx = Math.min(lineNum - 1, nextLines.length - 1);
    let lineStart = 0;
    for (let i = 0; i < targetLineIdx; i++) lineStart += nextLines[i].length + 1;
    const targetLineLength = nextLines[targetLineIdx]?.length ?? 0;
    const newAnchor = lineStart + Math.min(col, targetLineLength);

    // FLIP animation: capture each line's vertical position before the change.
    const content = view.dom.querySelector(".cm-content") as HTMLElement | null;
    const startPositions = new Map<string, number>();
    if (content) {
        for (const el of content.querySelectorAll<HTMLElement>(".cm-line")) {
            startPositions.set(el.textContent ?? "", el.offsetTop);
        }
    }

    // Anchor the viewport, not the cursor. Re-org only reorders existing lines,
    // so the document's total height is invariant — restoring the raw scrollTop
    // keeps the exact same pixel region visible. Without this, the whole-doc
    // replace makes CodeMirror re-anchor the viewport (and `scrollIntoView:false`
    // alone doesn't stop the jump), so the visible region shifts whenever the
    // sorted lines or the cursor are far from where the user was looking.
    const scroller = view.scrollDOM;
    const prevScrollTop = scroller.scrollTop;

    view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: next },
        selection: { anchor: newAnchor },
        scrollIntoView: false,
    });
    scroller.scrollTop = prevScrollTop;

    if (!content) return;

    requestAnimationFrame(() => {
        // CodeMirror may re-measure on the frame after a whole-doc replace and
        // nudge the scroll; re-assert the anchor before measuring FLIP offsets
        // so the animation plays within a stable viewport.
        if (scroller.scrollTop !== prevScrollTop) scroller.scrollTop = prevScrollTop;
        const moved: { el: HTMLElement; delta: number }[] = [];
        for (const el of content.querySelectorAll<HTMLElement>(".cm-line")) {
            const oldTop = startPositions.get(el.textContent ?? "");
            if (oldTop === undefined) continue;
            const delta = oldTop - el.offsetTop;
            if (Math.abs(delta) < 1) continue;
            moved.push({ el, delta });
        }
        // Invert: place each line back at its starting Y with no transition.
        for (const { el, delta } of moved) {
            el.style.transition = "none";
            el.style.transform = `translateY(${delta}px)`;
        }
        // Force a reflow so the browser sees the inverted position before we
        // animate back to identity.
        void content.offsetHeight;
        // Play: animate transforms to zero — lines slide into final spots.
        requestAnimationFrame(() => {
            for (const { el } of moved) {
                el.style.transition = "transform 0.32s cubic-bezier(0.2, 0.9, 0.3, 1)";
                el.style.transform = "translateY(0)";
            }
            window.setTimeout(() => {
                for (const { el } of moved) {
                    el.style.transition = "";
                    el.style.transform = "";
                }
            }, 360);
        });
    });
}

/// Floating vertical toolbar on the left edge of the editor. Built once and
/// reused; each button's click handler captures `view`.
function ensureSidebar(view: EditorView) {
    if (view.dom.querySelector(".cm-sidebar")) return;
    const sidebar = document.createElement("div");
    sidebar.className = "cm-sidebar";

    sidebar.appendChild(makeSidebarButton(view, {
        title: "Move completed items to the bottom of each section (⌘')",
        label: "Re-org ⌘'",
        svg: `
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="2"
                 stroke-linecap="round" stroke-linejoin="round">
                <path d="M12 4v12"/>
                <path d="M6 12l6 6 6-6"/>
                <path d="M4 21h16"/>
            </svg>`,
        action: (v) => moveCompletedToBottom(v),
    }));

    sidebar.appendChild(makeSidebarButton(view, {
        title: "Archive completed items to <name>_archive.md",
        label: "Archive",
        svg: `
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="2"
                 stroke-linecap="round" stroke-linejoin="round">
                <rect x="3" y="4" width="18" height="4" rx="1"/>
                <path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8"/>
                <line x1="10" y1="13" x2="14" y2="13"/>
            </svg>`,
        action: () => sendToSwift({ type: "archive" }),
    }));

    view.dom.appendChild(sidebar);

    // Priority orb tooltip — a single shared div positioned via mousemove.
    // The orb is a CSS ::after pseudo (not a real DOM element), so we detect
    // proximity to the right edge of any priority-dot line instead.
    const orbTooltip = document.createElement("div");
    orbTooltip.className = "cm-priority-tooltip";
    document.body.appendChild(orbTooltip);

    let orbHideTimer: number | null = null;
    view.dom.addEventListener("mousemove", (e) => {
        const target = e.target as HTMLElement;
        const line = target.closest(".cm-priority-dot") as HTMLElement | null;
        if (!line) {
            if (orbHideTimer === null) {
                orbHideTimer = window.setTimeout(() => {
                    orbTooltip.style.display = "none";
                    orbHideTimer = null;
                }, 80);
            }
            return;
        }
        if (orbHideTimer !== null) {
            window.clearTimeout(orbHideTimer);
            orbHideTimer = null;
        }
        // Only show when hovering the right ~28px where the orb lives.
        const rect = line.getBoundingClientRect();
        if (e.clientX < rect.right - 28) {
            orbTooltip.style.display = "none";
            return;
        }
        const label = line.getAttribute("data-priority-label") ?? "";
        orbTooltip.textContent = label;
        orbTooltip.style.display = "block";
        orbTooltip.style.left = `${rect.right - orbTooltip.offsetWidth - 4}px`;
        orbTooltip.style.top = `${rect.top - orbTooltip.offsetHeight - 6}px`;
    });

    view.dom.addEventListener("mouseleave", () => {
        orbTooltip.style.display = "none";
    });
}

function makeSidebarButton(
    view: EditorView,
    opts: { title: string; label: string; svg: string; action: (v: EditorView) => void },
): HTMLButtonElement {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "cm-sidebar-btn";
    btn.style.position = "relative";
    btn.innerHTML = opts.svg;
    // CSS tooltip — faster and theme-matched vs the native title tooltip.
    const tooltip = document.createElement("span");
    tooltip.className = "cm-btn-tooltip";
    tooltip.textContent = opts.label;
    btn.appendChild(tooltip);
    // Stop mousedown from bubbling to CodeMirror, which would otherwise treat
    // the button press as the start of a drag-select — and complete the
    // selection when the user next clicks in the editor.
    btn.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
    });
    btn.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        opts.action(view);
    });
    return btn;
}

/// True for bulleted (`-`, `*`, `+`) or ordered (`1.`) list lines, including
/// task items. Used by the Tab handler to decide indent-vs-insert-tab.
function isListLike(text: string): boolean {
    return /^\s*([-*+]|\d+\.)\s/.test(text);
}

/// Cmd+L on the cursor's line:
///   - a task line (`- [ ] foo` / `- [x] foo`)  → toggle the checkbox
///   - a bullet line (`- foo` / `* foo`)        → insert `[ ] ` after the bullet
///   - anything else (plain text, empty, indented) → prepend `- [ ] ` (indent kept)
function toggleTaskOnCurrentLine(view: EditorView): boolean {
    const line = view.state.doc.lineAt(view.state.selection.main.head);

    const taskMatch = line.text.match(/^(\s*[-*+]\s+)(\[[\sxX]\])/);
    if (taskMatch) {
        toggleTaskAtMarker(view, line.from + taskMatch[1].length);
        return true;
    }

    const bulletMatch = line.text.match(/^(\s*[-*+]\s+)/);
    if (bulletMatch) {
        view.dispatch({
            changes: { from: line.from + bulletMatch[1].length, insert: "[ ] " },
        });
        return true;
    }

    const indent = line.text.match(/^(\s*)/)?.[1] ?? "";
    view.dispatch({
        changes: { from: line.from + indent.length, insert: "- [ ] " },
    });
    return true;
}

/// Batch toggle for a multi-line (or multi-range) selection. Direction rule:
/// any unchecked task in the selection → check ALL of them; only when every
/// task is already checked does the gesture uncheck — a batch never produces
/// a mixed result. Bare bullets gain a `[ ] ` box (same as single-line ⌘L);
/// prose lines are skipped — batch mode must not convert paragraphs to tasks
/// wholesale. One dispatch, so ⌘Z reverts the whole batch and the selection
/// survives via CodeMirror's change mapping.
function toggleTasksInSelection(view: EditorView): boolean {
    const doc = view.state.doc;
    const lines = new Map<number, { from: number; text: string }>();
    for (const range of view.state.selection.ranges) {
        const last = doc.lineAt(range.to).number;
        for (let n = doc.lineAt(range.from).number; n <= last; n++) {
            if (!lines.has(n)) {
                const line = doc.line(n);
                lines.set(n, { from: line.from, text: line.text });
            }
        }
    }

    const markers: { pos: number; checked: boolean }[] = [];
    const bullets: number[] = [];
    for (const line of lines.values()) {
        const taskMatch = line.text.match(/^(\s*[-*+]\s+)(\[[\sxX]\])/);
        if (taskMatch) {
            markers.push({
                pos: line.from + taskMatch[1].length,
                checked: /[xX]/.test(taskMatch[2]),
            });
            continue;
        }
        const bulletMatch = line.text.match(/^(\s*[-*+]\s+)/);
        if (bulletMatch) bullets.push(line.from + bulletMatch[1].length);
    }
    if (markers.length === 0 && bullets.length === 0) return true;

    const checkAll = markers.some((m) => !m.checked);
    const changes = [
        ...markers
            .filter((m) => m.checked !== checkAll)
            .map((m) => ({ from: m.pos, to: m.pos + 3, insert: checkAll ? "[x]" : "[ ]" })),
        ...bullets.map((pos) => ({ from: pos, insert: "[ ] " })),
    ];
    if (changes.length) view.dispatch({ changes });
    return true;
}

/// ⌘L: single-line toggle when the selection is a caret (or sits within one
/// line); batch toggle when it spans lines or has multiple ranges (mouse
/// drag, vim visual, multi-cursor).
function toggleTaskCommand(view: EditorView): boolean {
    const doc = view.state.doc;
    const sel = view.state.selection;
    const isBatch = sel.ranges.length > 1
        || sel.ranges.some((r) => doc.lineAt(r.from).number !== doc.lineAt(r.to).number);
    return isBatch ? toggleTasksInSelection(view) : toggleTaskOnCurrentLine(view);
}

// Filename shown in the status bar. Swift sets the real name via
// `qcEditor.setFilename`; this is just the fallback before that lands.
let filename = "inbox.md";

/// Builds the bottom status bar once (mode pill · filename · item count · UTF-8)
/// and returns it for updates.
function ensureStatusBar(v: EditorView): HTMLDivElement {
    let bar = v.dom.querySelector(".cm-statusbar") as HTMLDivElement | null;
    if (bar) return bar;
    bar = document.createElement("div");
    bar.className = "cm-statusbar";

    const mode = document.createElement("div");
    mode.className = "cm-mode-badge";
    const file = document.createElement("div");
    file.className = "cm-status-file";
    const right = document.createElement("div");
    right.className = "cm-status-right";
    const count = document.createElement("span");
    count.className = "cm-status-count";
    const enc = document.createElement("span");
    enc.textContent = "UTF-8";
    right.append(count, enc);
    bar.append(mode, file, right);
    v.dom.appendChild(bar);
    return bar;
}

function updateBadge(v: EditorView) {
    const bar = ensureStatusBar(v);
    const badge = bar.querySelector(".cm-mode-badge") as HTMLDivElement;
    badge.classList.remove(
        "cm-mode-badge--read",
        "cm-mode-badge--normal",
        "cm-mode-badge--insert",
        "cm-mode-badge--visual",
        "cm-mode-badge--replace",
    );

    // Read mode takes precedence — the file is uneditable so vim mode is moot.
    if (readMode) {
        badge.textContent = "Reading";
        badge.classList.add("cm-mode-badge--read");
    } else if (!vimEnabled) {
        badge.textContent = "Editing";
    } else {
        badge.textContent =
            vimMode === "insert" ? "Insert" :
            vimMode === "visual" ? "Visual" :
            vimMode === "replace" ? "Replace" :
            "Normal";
        badge.classList.add(`cm-mode-badge--${vimMode}`);
    }

    (bar.querySelector(".cm-status-file") as HTMLElement).textContent = filename;
    updateCounts(v);
}

/// Refreshes the "N items · M done" tally from the document. Counts every
/// `- [ ]` / `- [x]` task line (any indent), done = the checked ones.
/// Also shows/hides the empty-state overlay when the count crosses zero.
function updateCounts(v: EditorView) {
    const bar = v.dom.querySelector(".cm-statusbar");
    if (!bar) return;
    const text = v.state.doc.toString();
    const items = (text.match(/^\s*[-*+]\s+\[[ xX]\]/gm) ?? []).length;
    const done = (text.match(/^\s*[-*+]\s+\[[xX]\]/gm) ?? []).length;
    (bar.querySelector(".cm-status-count") as HTMLElement).textContent =
        `${items} item${items === 1 ? "" : "s"} · ${done} done`;

    // Empty-state overlay — appears when there are no todos at all.
    const editorRoot = v.dom.closest(".cm-editor") as HTMLElement | null ?? v.dom;
    let overlay = editorRoot.querySelector(".cm-empty-state") as HTMLElement | null;
    if (items === 0) {
        if (!overlay) {
            overlay = document.createElement("div");
            overlay.className = "cm-empty-state";
            overlay.innerHTML =
                "<span>Nothing here yet.</span>" +
                "<span>Press ⌥T to capture your first thought.</span>";
            editorRoot.appendChild(overlay);
        }
    } else {
        overlay?.remove();
    }
}

function sendToSwift(message: Record<string, unknown>) {
    window.webkit?.messageHandlers?.editorBridge?.postMessage(message);
}

// MARK: - Refile (⌥⌘U)
//
// Resolve the subtree under the cursor with the SAME child-indent rule mirrored
// from FileWriter (`/^( {2,}|\t)\S/`, here via indent-width comparison), open a
// cursor-anchored arrow-key dropdown of the pushed targets, and post a `refile`
// message with the exact subtree text + its 0-based line range. The byte-for-
// byte verification on the Swift side doubles as a check that both sides agree
// on the span (issue #32).

function refileIndentWidth(text: string): number {
    let w = 0;
    for (const ch of text) {
        if (ch === " ") w += 1;
        else if (ch === "\t") w += 4;
        else break;
    }
    return w;
}

function isRefileItemLine(text: string): boolean {
    return /^\s*[-*+]\s/.test(text);
}

interface SubtreeSpan { from: number; to: number; text: string }

/// Resolve the subtree owning `pos`: the item line plus every more-indented
/// line below it, with a cursor on a child/continuation line resolving up to
/// its owning item. Returns 0-based half-open line indices (matching Swift's
/// `\n`-split indexing) and the exact slice text, or null when off-item.
function resolveSubtreeSpan(state: EditorState, pos: number): SubtreeSpan | null {
    const doc = state.doc;
    const total = doc.lines;
    const lineText = (i0: number) => doc.line(i0 + 1).text;
    const cur = doc.lineAt(pos).number - 1;

    let root = cur;
    if (!isRefileItemLine(lineText(cur))) {
        const trimmed = lineText(cur).trim();
        if (trimmed === "" || trimmed.startsWith("#")) return null;
        const childWidth = refileIndentWidth(lineText(cur));
        let i = cur - 1;
        root = -1;
        while (i >= 0) {
            const t = lineText(i).trim();
            if (t === "" || t.startsWith("#")) break;
            if (isRefileItemLine(lineText(i)) && refileIndentWidth(lineText(i)) < childWidth) { root = i; break; }
            i--;
        }
        if (root < 0) return null;
    }

    const rootWidth = refileIndentWidth(lineText(root));
    let end = root + 1;
    while (end < total) {
        const t = lineText(end).trim();
        if (t === "") break;
        if (t.startsWith("#")) break;
        if (refileIndentWidth(lineText(end)) <= rootWidth) break;
        end++;
    }

    const fromPos = doc.line(root + 1).from;
    const toPos = doc.line(end).to;   // `end` 0-based exclusive → 1-based last included line
    return { from: root, to: end, text: doc.sliceString(fromPos, toPos) };
}

/// Land the cursor on the item now at `targetLine0` (0-based) — the next item,
/// after the refiled subtree was removed and the doc reloaded. Skips blank lines
/// and headings so a follow-up ⌥⌘U resolves a real subtree; clamps to the last
/// line when the refiled subtree was the tail of its section/file.
function placeCursorAfterRefile(v: EditorView, targetLine0: number) {
    const doc = v.state.doc;
    let i = Math.min(Math.max(targetLine0, 0), doc.lines - 1);
    while (i < doc.lines - 1) {
        const trimmed = doc.line(i + 1).text.trim();
        if (trimmed !== "" && !trimmed.startsWith("#")) break;
        i++;
    }
    const pos = doc.line(i + 1).from;
    v.dispatch({ selection: { anchor: pos, head: pos }, scrollIntoView: true });
}

function startRefile(v: EditorView): boolean {
    if (refileOpen) return true;
    const span = resolveSubtreeSpan(v.state, v.state.selection.main.head);
    if (!span) { showRefileToast(v, "Put the cursor on an item to refile."); return true; }
    if (refileTargets.length === 0) { showRefileToast(v, "Add refile targets in Settings (⌘,)."); return true; }
    openRefileDropdown(v, span);
    return true;
}

function openRefileDropdown(v: EditorView, span: SubtreeSpan) {
    refileOpen = true;
    const menu = document.createElement("div");
    menu.className = "cm-refile-dropdown";

    let selected = 0;
    const items = refileTargets.map((name, i) => {
        const el = document.createElement("div");
        el.className = "cm-refile-item";
        el.textContent = name;
        el.addEventListener("mousedown", (e) => { e.preventDefault(); selected = i; commit(); });
        menu.appendChild(el);
        return el;
    });
    const render = () =>
        items.forEach((el, i) => el.classList.toggle("cm-refile-item--selected", i === selected));
    render();

    // Append inside the editor DOM, not document.body: EditorView.theme() scopes
    // .cm-refile-dropdown styles under the editor wrapper class, so a menu on
    // document.body would render completely unstyled (and invisible). The toasts
    // live in v.dom for the same reason. Appended before positioning so the
    // menu has a measurable size to clamp against the viewport.
    v.dom.appendChild(menu);

    const coords = v.coordsAtPos(v.state.selection.main.head);
    if (coords) {
        // Anchor below the cursor, kept fully on screen (#56): long target
        // names near the right edge clamp left, and a cursor near the bottom
        // flips the menu above the line instead of running off the window.
        const margin = 8;
        const rect = menu.getBoundingClientRect();
        const left = Math.min(
            Math.max(coords.left, margin),
            Math.max(window.innerWidth - rect.width - margin, margin)
        );
        let top = coords.bottom + 4;
        if (top + rect.height > window.innerHeight - margin) {
            top = Math.max(coords.top - rect.height - 4, margin);
        }
        menu.style.left = `${Math.round(left)}px`;
        menu.style.top = `${Math.round(top)}px`;
    }

    const close = () => {
        if (!refileOpen) return;
        refileOpen = false;
        document.removeEventListener("keydown", onKey, true);
        document.removeEventListener("mousedown", onOutside, true);
        menu.remove();
        v.focus();
    };

    const commit = () => {
        const target = selected;
        close();
        // Flush the current content to disk (no "Saved" badge — the refile toast
        // is the feedback) so the file matches the snapshot whose range we send.
        if (saveTimer !== null) { window.clearTimeout(saveTimer); saveTimer = null; }
        // After the subtree is removed and the watcher reloads us, land on the
        // item now occupying the subtree's start line (the next item) — see mount().
        pendingRefileCursorLine = span.from;
        sendToSwift({ type: "save", content: v.state.doc.toString() });
        sendToSwift({ type: "refile", target, fromLine: span.from, toLine: span.to, subtree: span.text });
    };

    const onKey = (e: KeyboardEvent) => {
        // Modal while open: swallow every key so nothing edits the doc beneath.
        e.preventDefault();
        e.stopPropagation();
        if (e.key === "ArrowDown") { selected = (selected + 1) % items.length; render(); }
        else if (e.key === "ArrowUp") { selected = (selected - 1 + items.length) % items.length; render(); }
        else if (e.key === "Enter") { commit(); }
        else if (e.key === "Escape") { close(); }
    };
    const onOutside = (e: MouseEvent) => {
        if (!menu.contains(e.target as Node)) close();
    };
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("mousedown", onOutside, true);
}

let refileToastTimer: number | null = null;
function showRefileToast(v: EditorView, message: string) {
    let toast = v.dom.querySelector(".cm-refile-toast") as HTMLDivElement | null;
    if (!toast) {
        toast = document.createElement("div");
        toast.className = "cm-refile-toast";
        v.dom.appendChild(toast);
    }
    toast.textContent = message;
    // Force a reflow so the transition replays on a re-shown toast.
    void toast.offsetWidth;
    toast.classList.add("cm-refile-toast--visible");
    if (refileToastTimer) window.clearTimeout(refileToastTimer);
    refileToastTimer = window.setTimeout(() => {
        toast!.classList.remove("cm-refile-toast--visible");
    }, 1800);
}

function scheduleSave() {
    if (suppressNextSave) {
        suppressNextSave = false;
        return;
    }
    if (saveTimer !== null) window.clearTimeout(saveTimer);
    saveTimer = window.setTimeout(() => {
        if (view) sendToSwift({ type: "save", content: view.state.doc.toString() });
        saveTimer = null;
    }, 400);
}

/// Cmd+S handler: cancel any pending debounce, flush the current content to
/// Swift, and flash a "Saved" badge so the user gets explicit feedback.
function saveNow(v: EditorView) {
    if (saveTimer !== null) {
        window.clearTimeout(saveTimer);
        saveTimer = null;
    }
    sendToSwift({ type: "save", content: v.state.doc.toString() });
    showSavedBadge(v);
}

function showSavedBadge(v: EditorView) {
    let badge = v.dom.querySelector(".cm-saved-badge") as HTMLDivElement | null;
    if (!badge) {
        badge = document.createElement("div");
        badge.className = "cm-saved-badge";
        badge.innerHTML = `
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="3.5"
                 stroke-linecap="round" stroke-linejoin="round">
                <polyline points="20 6 9 17 4 12"/>
            </svg>
            <span>Saved</span>`;
        v.dom.appendChild(badge);
    }
    badge.classList.add("cm-saved-badge--visible");
    // Reset hide timer so rapid Cmd+S presses don't blink the badge off mid-fade.
    const existing = (badge as unknown as { _qcTimer?: number })._qcTimer;
    if (existing) window.clearTimeout(existing);
    (badge as unknown as { _qcTimer?: number })._qcTimer = window.setTimeout(() => {
        badge!.classList.remove("cm-saved-badge--visible");
    }, 1400);
}

function mount(content: string) {
    const parent = document.getElementById("editor")!;
    suppressNextSave = true;

    // Reload = fresh disk truth: the cache may be stale (file replaced on disk).
    attachmentCache.clear();

    if (view) {
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: content } });
        if (pendingRefileCursorLine !== null) {
            placeCursorAfterRefile(view, pendingRefileCursorLine);
            pendingRefileCursorLine = null;
        }
        return;
    }

    const state = EditorState.create({
        doc: content,
        extensions: [
            // Vim has to be loaded BEFORE other keymaps so its normal-mode
            // bindings win over defaultKeymap's Insert-mode-only assumptions.
            vimComp.of(vimEnabled ? vim() : []),
            history(),
            drawSelection(),
            bracketMatching(),
            indentOnInput(),
            EditorView.lineWrapping,
            markdown({ base: markdownLanguage, codeLanguages: languages, addKeymap: true }),
            indentUnit.of("    "),   // 4-space indent matches Obsidian's defaults
            themeComp.of(themeExtensions()),
            livePreview,
            readModeComp.of([]),
            // Editor-local app shortcuts (read mode, toggle task, save,
            // re-org) — built from the registry-pushed bindings, swappable
            // live via the compartment when Swift re-pushes.
            appKeymapComp.of(buildAppKeymap()),
            // Native find (⌘F / ⌘G / ⇧⌘G). The panel renders at the top so it
            // doesn't collide with the bottom status bar. searchKeymap must
            // precede the Escape→dismiss binding below: its Escape entry
            // (close panel) returns false when no panel is open, falling
            // through to dismiss — the reverse order would dismiss the whole
            // window while searching with vim off.
            search({ top: true }),
            keymap.of([
                ...searchKeymap,
                {
                    // Esc dismisses the panel. This only fires when vim is OFF —
                    // with vim on, its keymap (loaded earlier) owns Escape, so
                    // this never runs. See ADR-0004.
                    key: "Escape",
                    run: () => { sendToSwift({ type: "dismiss" }); return true; },
                },
                {
                    // Alt+Mod+U mirrors the app's ⌥⌘U refile here for the
                    // browser harness; in the app the window intercepts the
                    // chord and drives qcEditor.invoke("refile") over the
                    // bridge before the web view ever sees it.
                    key: "Alt-Mod-u",
                    run: (v) => { startRefile(v); return true; },
                },
                // Obsidian-style Tab / Shift-Tab: indent or outdent a list/task
                // line when the cursor is on one; otherwise fall back to a real
                // tab character so prose lines aren't intercepted.
                {
                    key: "Tab",
                    run: (v) => {
                        const line = v.state.doc.lineAt(v.state.selection.main.head);
                        if (isListLike(line.text)) return indentMore(v);
                        return insertTab(v);
                    },
                },
                {
                    key: "Shift-Tab",
                    run: (v) => {
                        const line = v.state.doc.lineAt(v.state.selection.main.head);
                        if (isListLike(line.text)) return indentLess(v);
                        return false;
                    },
                },
                ...defaultKeymap,
                ...historyKeymap,
            ]),
            EditorView.updateListener.of((update) => {
                if (update.docChanged) {
                    scheduleSave();
                    updateCounts(update.view);
                }
            }),
        ],
    });

    view = new EditorView({ state, parent });
    attachVimModeListener(view);
    updateBadge(view);
    ensureSidebar(view);
    // Deliberately NOT auto-focused. On a cold launch the editor mounts in the
    // background while the capture box is showing; focusing here would make the
    // (hidden) web view the window's first responder and steal focus off the
    // capture input. Swift drives editor focus (focusEditor / qcEditor.focus)
    // when the editor is actually the active surface.
}

function attachVimModeListener(v: EditorView) {
    if (!vimEnabled) return;
    const cm = getCM(v);
    if (!cm) return;
    cm.on("vim-mode-change", (e: { mode: string }) => {
        // The lib reports mode as "normal" | "insert" | "visual" | "replace".
        vimMode = (e.mode as typeof vimMode) ?? "normal";
        updateBadge(v);
    });
}

window.qcEditor = {
    setContent: (content: string) => mount(content),
    getContent: () => view?.state.doc.toString() ?? "",
    focus: () => view?.focus(),
    setFilename: (name: string) => {
        filename = name || "inbox.md";
        if (view) updateBadge(view);
    },
    // Toggle vim live by reconfiguring its compartment (placed first in the
    // extension list, so vim's normal-mode bindings still win). Before the view
    // mounts this just records the flag; mount() reads it.
    setVimEnabled: (on: boolean) => {
        vimEnabled = on;
        if (!view) return;
        view.dispatch({ effects: vimComp.reconfigure(on ? vim() : []) });
        if (on) attachVimModeListener(view);
        else vimMode = "normal";
        updateBadge(view);
    },
    // Flush the debounced autosave immediately. Swift calls this before leaving
    // editor mode so the file on disk is canonical before capture mode can write
    // (ADR-0004 — disk is the single source of truth).
    flushSave: () => {
        if (saveTimer !== null) { window.clearTimeout(saveTimer); saveTimer = null; }
        if (view) sendToSwift({ type: "save", content: view.state.doc.toString() });
    },
    // Swift's reply to an `attachment` bridge request: a data URL, or null
    // when the file is missing (R22 — render the missing state, never hang).
    attachmentLoaded: (path: string, dataURL: string | null) => {
        attachmentCache.set(path, dataURL);
        for (const el of attachmentElements(path)) {
            renderAttachment(el, path, el.dataset.label ?? "screenshot");
        }
        // Dispatch the effect so decoration rebuilds reuse fresh cache state;
        // an empty dispatch alone would not satisfy the update guard.
        view?.dispatch({ effects: attachmentStateChanged.of(null) });
        view?.requestMeasure();
    },
    // Swift pushes the effective refile-target display names (dropdown order).
    setRefileTargets: (names: string[]) => { refileTargets = Array.isArray(names) ? names : []; },
    // Swift's success ack after the disk move — flash the confirmation toast
    // (the file watcher separately reloads the editor without the subtree).
    refileDidComplete: (targetName: string) => {
        if (view) showRefileToast(view, `Refiled to ${targetName}`);
    },
    // Legacy entry point for the refile gesture (superseded by invoke("refile");
    // kept so an older Swift layer or external driver can still trigger it).
    startRefile: () => { if (view) startRefile(view); },
    // Editor-local bindings pushed from Swift's ShortcutRegistry — the single
    // source of truth for shortcuts. Before mount this just records the map;
    // mount() builds the keymap from it.
    setKeymap: (map: Record<string, string>) => {
        appKeymap = { ...defaultAppKeymap, ...(map ?? {}) };
        view?.dispatch({ effects: appKeymapComp.reconfigure(buildAppKeymap()) });
    },
    // Generic dispatch for registry actions driven over the bridge (window
    // intercepts and Editor-menu items).
    invoke: (actionId: string) => {
        if (view && appCommands[actionId]) appCommands[actionId](view);
    },
    // Palette navigation (epic #82, U6): reveal a capture by its 0-based file
    // line (clamped — the file may have changed since the palette parsed it).
    revealLine: (line: number) => {
        if (view) revealAt(view, line + 1);
    },
    // Palette navigation: reveal a `## <name>` section heading. Falls back to a
    // no-op if no matching heading exists (the section may have been renamed or
    // emptied since the palette parsed the file).
    revealSection: (name: string) => {
        if (!view) return;
        const doc = view.state.doc;
        for (let n = 1; n <= doc.lines; n++) {
            const text = doc.line(n).text;
            const m = /^##\s+(.*?)\s*$/.exec(text);
            if (m && m[1] === name) { revealAt(view, n); return; }
        }
    },
};

// Follow the system appearance: swap the palette and reconfigure the theme
// compartment when prefers-color-scheme flips.
prefersDark.addEventListener("change", (e) => {
    palette = e.matches ? darkPalette : lightPalette;
    // attachmentStateChanged forces a livePreview rebuild — the section-hue
    // CSS vars are baked into line attributes from the palette-dependent
    // tagHue(), so a theme swap alone would leave stale light/dark hues.
    view?.dispatch({
        effects: [themeComp.reconfigure(themeExtensions()), attachmentStateChanged.of(null)],
    });
});

sendToSwift({ type: "ready" });

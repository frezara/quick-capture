import { EditorState, RangeSetBuilder, Compartment, StateEffect } from "@codemirror/state";
import {
    EditorView, keymap, drawSelection, highlightActiveLine,
    WidgetType, Decoration, DecorationSet, ViewPlugin, ViewUpdate,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentMore, indentLess, insertTab } from "@codemirror/commands";
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

// "Misted Steel" palettes — mirror DesignSystem.swift (Theme.light / .dark) so
// the editor reads as the same surface as the capture bar. The active one
// follows the system appearance (prefers-color-scheme). Warm colour is confined
// to the priority orbs.
type Palette = typeof lightPalette;

const lightPalette = {
    surface: "#F7F9FB",
    surfaceField: "#E8EEF3",
    surfaceRail: "#EEF2F6",
    highlight: "#FFFFFF",
    text: "#1B222B",          // ink
    soft: "#54616E",          // inkSecondary
    muted: "#8B97A4",         // inkTertiary
    accent: "#2F6FA3",
    accentInk: "#245A86",
    accentSoft: "#D4E3F1",
    onAccent: "#FFFFFF",
    codeBg: "#E8EEF3",        // surfaceField (recessed wells / badge fallback)
    selection: "#D4E3F1",     // accentSoft
    borderSoft: "#C2CCD7",    // border
    borderStrong: "#A7B4C2",
    priHigh: "#DB5560",
    priMed: "#D99A3C",
    priLow: "#4E9E84",
};

const darkPalette: Palette = {
    surface: "#242C35",
    surfaceField: "#1A212A",
    surfaceRail: "#1E252E",
    highlight: "#404B57",
    text: "#EDF1F5",
    soft: "#A2AEBB",
    muted: "#6B7682",
    accent: "#5AA2E0",
    accentInk: "#8FC2EE",
    accentSoft: "#23364A",
    onAccent: "#161B21",
    codeBg: "#1A212A",
    selection: "#23364A",
    borderSoft: "#38424E",
    borderStrong: "#4A5663",
    priHigh: "#F0727C",
    priMed: "#E7B05A",
    priLow: "#6FBBA0",
};

const prefersDark = window.matchMedia("(prefers-color-scheme: dark)");
// Mutable so makeHighlight()/makeTheme() (below) read the active palette; the
// appearance listener reassigns it and reconfigures the theme compartment.
let palette: Palette = prefersDark.matches ? darkPalette : lightPalette;

function makeHighlight() {
    return HighlightStyle.define([
    // Headings — Obsidian-ish sizing curve, bumped to match the target design.
    { tag: tags.heading1, fontSize: "2.4em", fontWeight: "800", color: palette.text, lineHeight: "1.2" },
    { tag: tags.heading2, fontSize: "1.55em", fontWeight: "700", color: palette.text, lineHeight: "1.3" },
    { tag: tags.heading3, fontSize: "1.25em", fontWeight: "700", color: palette.text },
    { tag: tags.heading4, fontSize: "1.1em", fontWeight: "700", color: palette.text },
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

// MARK: - Attachment image lines (folded preview)
//
// An indented `![label](path)` child line (written under a todo by the
// capture flow) renders as a compact folded pill; clicking it expands an
// inline preview. Image bytes come over the JS↔Swift bridge as a data URL —
// the web view's file read-access is scoped to the app bundle, so a relative
// <img src> could never resolve against the capture file's folder.

/// Expansion is view-local by design: reloads (external file changes) reset
/// to folded. Keyed by the link's relative path.
const expandedAttachments = new Set<string>();
/// path → data URL, or null when Swift reported the file missing.
const attachmentCache = new Map<string, string | null>();
// An empty dispatch does not satisfy the livePreview update guard, so
// attachment state changes (cache fill, expansion toggle) carry an explicit
// effect — livePreview checks for it and rebuilds decorations deterministically.
const attachmentStateChanged = StateEffect.define<null>();

class ImageWidget extends WidgetType {
    constructor(readonly path: string, readonly label: string) { super(); }

    toDOM(): HTMLElement {
        const wrap = document.createElement("span");
        wrap.className = "cm-attachment";
        wrap.dataset.path = this.path;
        wrap.dataset.label = this.label;
        renderAttachment(wrap, this.path, this.label);
        // Keep CodeMirror from treating the click as a cursor placement —
        // a cursor on the line would reveal the raw markdown and replace the
        // widget mid-click.
        wrap.addEventListener("mousedown", (e) => {
            e.preventDefault();
            e.stopPropagation();
        });
        wrap.addEventListener("click", (e) => {
            e.preventDefault();
            e.stopPropagation();
            if (expandedAttachments.has(this.path)) {
                expandedAttachments.delete(this.path);
            } else {
                expandedAttachments.add(this.path);
                requestAttachmentIfNeeded(this.path);
            }
            for (const el of attachmentElements(this.path)) {
                renderAttachment(el, this.path, this.label);
            }
            // Expansion state changed — carry an explicit effect so the
            // livePreview update guard fires and decorations are reconciled.
            view?.dispatch({ effects: attachmentStateChanged.of(null) });
            view?.requestMeasure();
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
    const expanded = expandedAttachments.has(path);
    el.classList.toggle("cm-attachment--expanded", expanded);
    el.innerHTML = "";
    if (!expanded) {
        el.appendChild(makeAttachmentPill(label, "folded"));
        return;
    }
    const data = attachmentCache.get(path);
    if (data === undefined) {
        el.appendChild(makeAttachmentPill("Loading…", "loading"));
    } else if (data === null) {
        el.appendChild(makeAttachmentPill("Attachment not found", "missing"));
    } else {
        const img = document.createElement("img");
        img.className = "cm-attachment-img";
        img.src = data;
        img.addEventListener("load", () => view?.requestMeasure());
        el.appendChild(img);
    }
}

function makeAttachmentPill(text: string, kind: "folded" | "loading" | "missing"): HTMLElement {
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

/// The accent "#" glyph that stands in for the H1 mark — a small filled accent
/// box with a white hash, matching the editor mockup. H2–H6 marks stay hidden.

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
                // when the cursor moves onto the line).
                const headingLevel = atxHeadingLevel(node.name);
                if (headingLevel) {
                    ranges.push({
                        from: line.from, to: line.from,
                        deco: Decoration.line({ class: `cm-heading cm-heading-${headingLevel}` }),
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
                    ranges.push({
                        from: node.from, to: end,
                        deco: Decoration.replace({}),
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
                    // Strike + mute the label of a completed task.
                    const labelEnd = line.from + line.text.length;
                    if (checked && labelEnd > endPos) {
                        ranges.push({
                            from: endPos, to: labelEnd,
                            deco: Decoration.mark({ class: "cm-done-label" }),
                        });
                    }
                }

                // Priority suffix: trailing ` !`/` !!`/` !!!` paints a colored
                // dot at the far-right of the line via a ::after pseudo (line
                // class), and hides the raw `!`s off-cursor. Tolerant of an
                // optional ` ➕ DATE TIME` timestamp tail that appendTodo adds.
                const priority = line.text.match(/(\s+)(!{1,3})(?:\s+➕\s+\S+\s+\S+)?\s*$/);
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
                            from: suffixStart, to: line.from + line.text.length,
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
        fontSize: "15px",
        lineHeight: "1.7",
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
        backgroundColor: palette.surfaceRail,
        borderTop: `1px solid ${palette.borderSoft}`,
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
        fontSize: "11px",
        fontWeight: "600",
        letterSpacing: "0.3px",
        color: palette.muted,
        userSelect: "none",
        zIndex: "8",
    },
    ".cm-status-file": { color: palette.soft },
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
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
        fontSize: "12px",
        lineHeight: "1.6",
        textAlign: "center",
        zIndex: "1",
    },
    // Mode pill — accentSoft (NORMAL) by default; the other vim modes keep the
    // conventional green/amber/red cues so the mode reads at a glance.
    ".cm-mode-badge": {
        padding: "4px 11px",
        borderRadius: "6px",
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
        fontSize: "10.5px",
        fontWeight: "600",
        letterSpacing: "1px",
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
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
        fontSize: "10.5px",
        fontWeight: "600",
        letterSpacing: "0.6px",
        textTransform: "uppercase",
        backgroundColor: palette.accentSoft,
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
        borderRadius: "12px",
        backgroundColor: palette.surface,
        border: `1px solid ${palette.borderSoft}`,
        boxShadow: "0 12px 28px -16px rgba(28, 42, 60, 0.45)",
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
        border: `1px solid ${palette.borderSoft}`,
        borderRadius: "6px",
        padding: "4px 8px",
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
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
        border: `1px solid ${palette.borderSoft}`,
        borderRadius: "6px",
        padding: "4px 8px",
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
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
    // Pink pill behind inline `code`. Applied via decoration only when the
    // cursor isn't on the line, so editing the raw markdown drops the pill.
    ".cm-inline-code-pill": {
        backgroundColor: palette.accentSoft,
        color: palette.accentInk,
        borderRadius: "6px",
        padding: "1px 6px",
        margin: "0 1px",
    },
    // Attachment image line — folded pill / expanded inline preview.
    ".cm-attachment": {
        cursor: "pointer",
    },
    ".cm-attachment-pill": {
        display: "inline-flex",
        alignItems: "center",
        gap: "6px",
        padding: "2px 10px",
        borderRadius: "6px",
        backgroundColor: palette.surfaceField,
        border: `1px solid ${palette.borderSoft}`,
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
        maxWidth: "min(560px, 92%)",
        maxHeight: "360px",
        margin: "4px 0",
        borderRadius: "8px",
        border: `1px solid ${palette.borderSoft}`,
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
        // Match the editor's line-height (1.7 × 15px). Bounding the height
        // means the guide only spans the FIRST visual line — when the logical
        // line wraps, the guide doesn't bleed down across the wrapped text.
        height: "1.7em",
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
        width: "16px",
        height: "16px",
        margin: "0 10px 0 0",
        border: `1.5px solid ${palette.borderStrong}`,
        borderRadius: "5px",
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
    // and keep the values small. The H2 gets a thin separator below it.
    ".cm-heading-2": {
        paddingBottom: "4px",
        borderBottom: `1px solid ${palette.borderSoft}`,
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
        };
    }
}

let view: EditorView | null = null;
let saveTimer: number | null = null;
let suppressNextSave = false;

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
                groupLines[0] = groupLines[0]
                    .replace(/^\s+/, "")
                    .replace(/\s+!{1,3}(\s+➕\s+\S+\s+\S+)?\s*$/, "$1");
                groups.push({ bucket: 4, lines: groupLines });
            } else {
                // Optional ` ➕ DATE TIME` timestamp tail is tolerated, so a
                // captured `task !!! ➕ ...` still classifies as priority 3.
                const priority = line.match(/\s+(!{1,3})(?:\s+➕\s+\S+\s+\S+)?\s*$/);
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

    view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: next },
        selection: { anchor: newAnchor },
        scrollIntoView: false,
    });

    if (!content) return;

    requestAnimationFrame(() => {
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

    // Reload = fresh disk truth: the cache may be stale (file replaced on disk)
    // and fold state resets to folded by design.
    expandedAttachments.clear();
    attachmentCache.clear();

    if (view) {
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: content } });
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
            keymap.of([
                {
                    // Esc dismisses the panel. This only fires when vim is OFF —
                    // with vim on, its keymap (loaded earlier) owns Escape, so
                    // this never runs. See ADR-0004.
                    key: "Escape",
                    run: () => { sendToSwift({ type: "dismiss" }); return true; },
                },
                {
                    key: "Mod-e",
                    run: (v) => { setReadMode(v, !readMode); return true; },
                },
                {
                    key: "Mod-l",
                    run: toggleTaskOnCurrentLine,
                },
                {
                    key: "Mod-s",
                    // Return true so AppKit doesn't beep ("unhandled key").
                    run: (v) => { saveNow(v); return true; },
                },
                {
                    // Cmd+' — sweep completed tasks to the bottom of each
                    // section (same as the sidebar button).
                    key: "Mod-'",
                    run: (v) => { moveCompletedToBottom(v); return true; },
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
};

// Follow the system appearance: swap the palette and reconfigure the theme
// compartment when prefers-color-scheme flips.
prefersDark.addEventListener("change", (e) => {
    palette = e.matches ? darkPalette : lightPalette;
    view?.dispatch({ effects: themeComp.reconfigure(themeExtensions()) });
});

sendToSwift({ type: "ready" });

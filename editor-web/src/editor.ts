import { EditorState, RangeSetBuilder, Compartment } from "@codemirror/state";
import {
    EditorView, keymap, drawSelection, highlightActiveLine,
    WidgetType, Decoration, DecorationSet, ViewPlugin, ViewUpdate,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { syntaxHighlighting, HighlightStyle, bracketMatching, indentOnInput, syntaxTree } from "@codemirror/language";
import { tags } from "@lezer/highlight";

// Paper palette — keep visually cohesive with Quick Capture's capture panel.
const palette = {
    text: "#1F1F24",
    muted: "#8A8A8E",
    soft: "#6E6E72",
    accent: "#0066cc",
    codeBg: "#F4F4F7",
    selection: "#D6E4FF",
    borderSoft: "#E5E5EA",
};

const highlight = HighlightStyle.define([
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

    { tag: tags.monospace, fontFamily: "ui-monospace, SF Mono, Menlo, monospace", color: palette.text },
    { tag: tags.list, color: palette.text },
    { tag: tags.quote, color: palette.soft, fontStyle: "italic" },

    // Markdown syntax characters (#, *, `, etc.) — muted so they recede.
    { tag: tags.processingInstruction, color: palette.muted },
    { tag: tags.meta, color: palette.muted },
    { tag: tags.contentSeparator, color: palette.muted },
]);

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

                if (node.name === "TaskMarker") {
                    // Bundle the leading list marker (`- ` / `* ` / `+ ` with
                    // optional indentation), the `[ ]`, and the trailing space
                    // into one replacement so the checkbox sits tight against
                    // the task text.
                    const text = view.state.doc.sliceString(node.from, node.to);
                    const checked = /[xX]/.test(text);
                    const before = view.state.doc.sliceString(line.from, node.from);
                    const indentMatch = before.match(/^(\s*)([-*+]\s+)$/);
                    const start = indentMatch
                        ? line.from + indentMatch[1].length
                        : node.from;
                    let end = node.to;
                    if (view.state.doc.sliceString(end, end + 1) === " ") end += 1;

                    // Reveal the raw `- [ ] ` only when the cursor/selection
                    // is actually inside (or touching) that syntax range. Clicking
                    // on the task body leaves the checkbox in place — no reveal,
                    // no horizontal shift. Read mode never reveals.
                    if (!readMode && selectionOverlaps(view.state, start, end)) return;

                    const widthInChars = end - start;
                    const taskOffset = node.from - start;
                    ranges.push({
                        from: start, to: end,
                        deco: Decoration.replace({
                            widget: new CheckboxWidget(checked, widthInChars, taskOffset),
                        }),
                    });
                    return;
                }

                // ListMark is intentionally not decorated here — on task lines
                // it's swallowed by the TaskMarker widget above; on plain lists
                // we want the bullet to remain visible.

                if (node.name === "HeaderMark") {
                    let end = node.to;
                    if (view.state.doc.sliceString(end, end + 1) === " ") end += 1;
                    // Reveal when the cursor is anywhere on the heading line.
                    if (!readMode && selectionOverlaps(view.state, line.from, line.to)) return;
                    // Replace (zero-width) rather than mark — the latter leaves
                    // a transparent-but-visible-width gap before the heading.
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
            },
        });
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
        if (update.docChanged || update.viewportChanged || update.selectionSet) {
            this.decorations = buildLivePreview(update.view);
        }
    }
}, {
    decorations: (v) => v.decorations,
});

const theme = EditorView.theme({
    "&": {
        backgroundColor: "#ffffff",
        color: palette.text,
        height: "100%",
    },
    ".cm-content": {
        fontFamily: 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace',
        fontSize: "15px",
        lineHeight: "1.7",
        padding: "40px 56px 96px",
        caretColor: palette.text,
        maxWidth: "780px",
        margin: "0 auto",
    },
    ".cm-scroller": {
        overflow: "auto",
        fontFamily: 'inherit',
    },
    ".cm-line": {
        padding: "0",
    },
    ".cm-cursor, .cm-dropCursor": {
        borderLeftColor: palette.text,
        borderLeftWidth: "2.5px",
        marginLeft: "-1px",   // re-center the thicker stem on the insertion point
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
    // Mode badge — floats over the top-right corner of the editor.
    ".cm-mode-badge": {
        position: "absolute",
        top: "12px",
        right: "16px",
        padding: "3px 10px",
        borderRadius: "10px",
        fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
        fontSize: "10.5px",
        fontWeight: "600",
        letterSpacing: "0.4px",
        textTransform: "uppercase",
        backgroundColor: palette.codeBg,
        color: palette.soft,
        border: `1px solid ${palette.borderSoft}`,
        userSelect: "none",
        pointerEvents: "none",
        zIndex: "10",
    },
    ".cm-mode-badge--read": {
        backgroundColor: palette.text,
        color: "#ffffff",
        borderColor: palette.text,
    },
    // Floating vertical toolbar on the left edge. Sits over the editor's
    // padding so it doesn't disrupt the centered content column.
    ".cm-sidebar": {
        position: "absolute",
        top: "50%",
        left: "12px",
        transform: "translateY(-50%)",
        display: "flex",
        flexDirection: "column",
        gap: "4px",
        padding: "4px",
        borderRadius: "10px",
        backgroundColor: "rgba(255, 255, 255, 0.95)",
        border: `1px solid ${palette.borderSoft}`,
        boxShadow: "0 1px 4px rgba(0, 0, 0, 0.06)",
        zIndex: "5",
    },
    ".cm-sidebar-btn": {
        width: "32px",
        height: "32px",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        border: "none",
        backgroundColor: "transparent",
        color: palette.soft,
        borderRadius: "6px",
        cursor: "pointer",
        padding: "0",
        transition: "background-color 0.12s ease, color 0.12s ease",
    },
    ".cm-sidebar-btn:hover": {
        backgroundColor: palette.codeBg,
        color: palette.text,
    },
    ".cm-sidebar-btn:active": {
        backgroundColor: palette.borderSoft,
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
    ".cm-task-checkbox": {
        // Custom-styled square checkbox to match the target design: light
        // gray outline, no fill until checked. Resets the native appearance
        // and draws our own border + checkmark.
        appearance: "none",
        WebkitAppearance: "none",
        width: "16px",
        height: "16px",
        margin: "0 10px 0 0",
        border: `1.5px solid ${palette.muted}`,
        borderRadius: "3px",
        verticalAlign: "-3px",
        cursor: "pointer",
        backgroundColor: "transparent",
        transition: "border-color 0.12s ease, background-color 0.12s ease",
    },
    ".cm-task-checkbox:hover": {
        borderColor: palette.text,
    },
    ".cm-task-checkbox:checked": {
        backgroundColor: palette.text,
        borderColor: palette.text,
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
}, { dark: false });

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

    const taskRegex = /^\s*[-*+]\s+\[[xX]\]/;
    const processed = sections.map(section => {
        const checked: string[] = [];
        const rest: string[] = [];
        for (const line of section) {
            (taskRegex.test(line) ? checked : rest).push(line);
        }
        if (checked.length === 0) return section;
        const hadTrailingBlank = rest[rest.length - 1] === "";
        while (rest.length > 0 && rest[rest.length - 1] === "") rest.pop();
        const result = [...rest, ...checked];
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

/// Floating vertical toolbar on the left edge of the editor. One button for
/// now — sweep completed tasks to the bottom of each section. Built once and
/// reused; click handler captures `view`.
function ensureSidebar(view: EditorView) {
    if (view.dom.querySelector(".cm-sidebar")) return;
    const sidebar = document.createElement("div");
    sidebar.className = "cm-sidebar";

    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "cm-sidebar-btn";
    btn.title = "Move completed items to the bottom of each section";
    btn.innerHTML = `
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none"
             stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 4v12"/>
            <path d="M6 12l6 6 6-6"/>
            <path d="M4 21h16"/>
        </svg>`;
    btn.addEventListener("click", (e) => {
        e.preventDefault();
        moveCompletedToBottom(view);
    });

    sidebar.appendChild(btn);
    view.dom.appendChild(sidebar);
}

/// Cmd+L toggles `- [ ]` ↔ `- [x]` on the cursor's line. No-op (and lets
/// the keymap fall through) when the line isn't a task.
function toggleTaskOnCurrentLine(view: EditorView): boolean {
    const line = view.state.doc.lineAt(view.state.selection.main.head);
    const match = line.text.match(/^(\s*[-*+]\s+)(\[[\sxX]\])/);
    if (!match) return false;
    toggleTaskAtMarker(view, line.from + match[1].length);
    return true;
}

function updateBadge(v: EditorView) {
    let badge = v.dom.querySelector(".cm-mode-badge") as HTMLDivElement | null;
    if (!badge) {
        badge = document.createElement("div");
        badge.className = "cm-mode-badge";
        v.dom.appendChild(badge);
    }
    badge.textContent = readMode ? "Reading" : "Editing";
    badge.classList.toggle("cm-mode-badge--read", readMode);
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

function mount(content: string) {
    const parent = document.getElementById("editor")!;
    suppressNextSave = true;

    if (view) {
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: content } });
        return;
    }

    const state = EditorState.create({
        doc: content,
        extensions: [
            history(),
            drawSelection(),
            bracketMatching(),
            indentOnInput(),
            EditorView.lineWrapping,
            markdown({ base: markdownLanguage, codeLanguages: languages, addKeymap: true }),
            syntaxHighlighting(highlight),
            livePreview,
            readModeComp.of([]),
            keymap.of([
                {
                    key: "Mod-e",
                    run: (v) => { setReadMode(v, !readMode); return true; },
                },
                {
                    key: "Mod-l",
                    run: toggleTaskOnCurrentLine,
                },
                ...defaultKeymap,
                ...historyKeymap,
            ]),
            theme,
            EditorView.updateListener.of((update) => {
                if (update.docChanged) scheduleSave();
            }),
        ],
    });

    view = new EditorView({ state, parent });
    updateBadge(view);
    ensureSidebar(view);
    view.focus();
}

window.qcEditor = {
    setContent: (content: string) => mount(content),
    getContent: () => view?.state.doc.toString() ?? "",
};

sendToSwift({ type: "ready" });

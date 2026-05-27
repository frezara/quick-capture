import { EditorState, RangeSetBuilder } from "@codemirror/state";
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
            const markerPos = widgetPos + this.taskOffset;
            const current = view.state.doc.sliceString(markerPos, markerPos + 3);
            const next = /\[[xX]\]/.test(current) ? "[ ]" : "[x]";
            view.dispatch({ changes: { from: markerPos, to: markerPos + 3, insert: next } });
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
                    // no horizontal shift.
                    if (selectionOverlaps(view.state, start, end)) return;

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
                    if (selectionOverlaps(view.state, node.from, end)) return;
                    ranges.push({
                        from: node.from, to: end,
                        deco: Decoration.mark({ class: "cm-md-hidden" }),
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
            keymap.of([...defaultKeymap, ...historyKeymap]),
            theme,
            EditorView.updateListener.of((update) => {
                if (update.docChanged) scheduleSave();
            }),
        ],
    });

    view = new EditorView({ state, parent });
    view.focus();
}

window.qcEditor = {
    setContent: (content: string) => mount(content),
    getContent: () => view?.state.doc.toString() ?? "",
};

sendToSwift({ type: "ready" });

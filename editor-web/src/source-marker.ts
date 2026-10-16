/**
 * Source markers: the trailing `<!--qc-source:…-->` identity a delivered item
 * carries (ADR-0008), plus the older `<!--qc:…-->` creation tokens. They are
 * never shown, and they live and die with their line.
 */

const TRAILING = /(?:\s*<!--(?:qc:|qc-source:)[^>]*-->)+\s*$/;

/** Offsets within `lineText` of its trailing marker run, including the whitespace before it. */
export function trailingMarkerSpan(lineText: string): { from: number; to: number } | null {
    const match = lineText.match(TRAILING);
    if (!match || match.index === undefined) return null;
    return { from: match.index, to: lineText.length };
}

export interface LineSource {
    readonly length: number;
    lineAt(pos: number): { from: number; to: number; text: string };
}
export interface Change { from: number; to: number; insert: string }

/**
 * Confine one document change so every trailing marker it touches survives,
 * unless the change removes that marker's whole line. Text typed at or after
 * a marker lands before it; a newline typed there goes after it, so the item
 * keeps its identity and the continuation starts clean. Deletions that reach
 * into a marker stop at its edge. Returns the replacement change(s).
 */
export function confineChange(doc: LineSource, change: Change): Change[] {
    return plan(doc, change).changes;
}

/**
 * `confineChange` plus where the caret belongs afterwards, in new-document
 * coordinates: after the typed text (before the marker), after a newline typed
 * at the end, or at the join point when lines merge. `null` when the change
 * was passed through untouched.
 */
export function confineEdit(doc: LineSource, change: Change): { changes: Change[]; cursor: number | null } {
    const { changes, caret } = plan(doc, change);
    const untouched = changes.length === 1 && changes[0].from === change.from
        && changes[0].to === change.to && changes[0].insert === change.insert;
    if (!caret || untouched) return { changes, cursor: null };
    let pos = caret.pos;
    for (const c of changes) {
        if (c.to <= caret.pos && c.from < c.to) pos -= c.to - c.from;
        if (c.from < caret.pos) pos += c.insert.length;
    }
    return { changes, cursor: pos + caret.after };
}

/** A caret lives at an old-document position, after `after` inserted characters there. */
type Caret = { pos: number; after: number } | null;

function plan(doc: LineSource, change: Change): { changes: Change[]; caret: Caret } {
    const { from, to, insert } = change;
    const first = doc.lineAt(from);
    const firstSpan = trailingMarkerSpan(first.text);
    const firstKept = firstSpan && !(from <= first.from && to >= first.to)
        ? { s: first.from + firstSpan.from, e: first.to } : null;

    // Merging lines: the first line keeps its identity, at the end of the
    // merged line; the lines pulled into it give theirs up.
    if (firstKept && to > first.to) {
        const last = doc.lineAt(to);
        const lastSpan = trailingMarkerSpan(last.text);
        const restEnd = lastSpan ? Math.max(to, last.from + lastSpan.from) : last.to;
        const rest = last.text.slice(to - last.from, restEnd - last.from);
        const joinAt = Math.min(from, firstKept.s);
        return {
            changes: [
                { from: joinAt, to: firstKept.s, insert: insert + rest },
                { from: firstKept.e, to: last.to, insert: "" },
            ].filter(c => c.from !== c.to || c.insert !== ""),
            caret: { pos: joinAt, after: insert.length },
        };
    }

    const kept: { s: number; e: number }[] = [];
    for (let line = first; ; line = doc.lineAt(line.to + 1)) {
        const span = trailingMarkerSpan(line.text);
        const wholeLine = from <= line.from && to >= line.to;
        if (span && !wholeLine) kept.push({ s: line.from + span.from, e: line.to });
        if (line.to >= to || line.to >= doc.length) break;
    }
    if (kept.length === 0) return { changes: [change], caret: null };

    // Carve every kept marker out of the deleted range.
    let pieces: { from: number; to: number }[] = [{ from, to }];
    for (const { s, e } of kept) {
        pieces = pieces.flatMap(p => {
            if (p.to <= s || p.from >= e) return [p];
            const out: { from: number; to: number }[] = [];
            if (p.from < s) out.push({ from: p.from, to: s });
            if (p.to > e) out.push({ from: e, to: p.to });
            return out;
        });
    }

    // Text typed at or after the first line's marker lands before it; a
    // newline typed there goes after it.
    const anchor = kept[0];
    const atMarker = from >= anchor.s && from <= anchor.e;
    const newline = insert.indexOf("\n");
    const head = atMarker && newline >= 0 ? insert.slice(0, newline) : insert;
    const tail = atMarker && newline >= 0 ? insert.slice(newline) : "";

    const changes: Change[] = pieces.map(p => ({ ...p, insert: "" }));
    const headAt = atMarker ? anchor.s : from;
    const headPiece = changes.find(c => c.from === headAt);
    if (headPiece) headPiece.insert = head;
    else changes.push({ from: headAt, to: headAt, insert: head });
    if (tail) {
        const tailPiece = changes.find(c => c.from === anchor.e);
        if (tailPiece) tailPiece.insert = tail + tailPiece.insert;
        else changes.push({ from: anchor.e, to: anchor.e, insert: tail });
    }
    return {
        changes: changes.filter(c => c.from !== c.to || c.insert !== "").sort((a, b) => a.from - b.from),
        caret: tail ? { pos: anchor.e, after: tail.length } : { pos: headAt, after: head.length },
    };
}

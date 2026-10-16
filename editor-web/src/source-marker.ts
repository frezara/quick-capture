/**
 * Source markers: the trailing `<!--qc-source:…-->` identity a delivered item
 * carries (ADR-0008), plus the older `<!--qc:…-->` creation tokens.
 *
 * They live in the file but never in the editor's text. On load the editor
 * strips them and remembers which line each belonged to; every edit maps those
 * identities along with their lines; everything the editor hands to Swift is
 * serialised back to the file form. Vim then only ever sees plain text.
 */

const TRAILING = /(?:\s*<!--(?:qc:|qc-source:)[^>]*-->)+\s*$/;
const SOURCE = /<!--qc-source:([0-9a-fA-F-]{36})-->/;
const GRAVEYARD_LIMIT = 200;

/** A line's trailing marker run, kept verbatim so serialising is byte-exact. */
export interface Mark { line: number; run: string }

/**
 * The editor's identity state. `graveyard` holds identities whose line was
 * deleted or joined away during this session, with the line's text, so an
 * undo or a `dd`/`p` move that puts the same text back gets them back.
 */
export interface Identities { marks: Mark[]; graveyard: { text: string; run: string }[] }

export interface Line { from: number; to: number; text: string; number: number }
export interface LineSource { lineAt(pos: number): Line; line(n: number): Line }
export interface Change { from: number; to: number; insert: string }

export function strip(file: string): { text: string; marks: Mark[] } {
    const marks: Mark[] = [];
    const lines = file.split("\n").map((line, i) => {
        const match = line.match(TRAILING);
        if (!match || match.index === undefined) return line;
        marks.push({ line: i, run: line.slice(match.index) });
        return line.slice(0, match.index);
    });
    return { text: lines.join("\n"), marks };
}

export function serialise(text: string, marks: Mark[]): string {
    const lines = text.split("\n");
    for (const { line, run } of marks) if (line < lines.length) lines[line] += run;
    return lines.join("\n");
}

/** The organiser identity in each mark's run, or null for a legacy-only token. */
export function sourceIDs(marks: Mark[]): (string | null)[] {
    return marks.map(m => m.run.match(SOURCE)?.[1].toLowerCase() ?? null);
}

/** True when the line's run carries more than one identity, or its identity is on another line too. */
export function hasDuplicateIdentity(marks: Mark[], line: number): boolean {
    const mark = marks.find(m => m.line === line);
    if (!mark) return false;
    if ((mark.run.match(new RegExp(SOURCE.source, "g")) ?? []).length > 1) return true;
    const id = sourceIDs([mark])[0];
    return id !== null && sourceIDs(marks).filter(x => x === id).length > 1;
}

/**
 * Where each identity lives after one change, in the document as it was
 * before it. A line keeps its identity through edits; on a split the first
 * half keeps it; on a join the first line's wins; a fully deleted or joined
 * away line's identity goes to the graveyard with that line's text.
 */
export function mapIdentities(before: LineSource, ids: Identities, change: Change): Identities {
    const { from, to, insert } = change;
    const fl = before.lineAt(from).number - 1;
    const tl = before.lineAt(to).number - 1;
    const added = insert.split("\n").length - 1;
    const delta = added - (tl - fl);
    const removed = (i: number) => {
        const line = before.line(i + 1);
        return from <= line.from && to >= line.to && (to > line.to || from < line.from);
    };
    const firstSurvives = !removed(fl);

    const marks: Mark[] = [];
    const graveyard = [...ids.graveyard];
    const bury = (i: number, run: string) => graveyard.push({ text: before.line(i + 1).text, run });
    for (const mark of ids.marks) {
        const i = mark.line;
        if (i < fl) marks.push(mark);
        else if (i > tl) marks.push({ line: i + delta, run: mark.run });
        else if (removed(i)) bury(i, mark.run);
        else if (i === fl) marks.push({ line: from > before.line(i + 1).from ? fl : fl + added, run: mark.run });
        else if (firstSurvives) bury(i, mark.run);
        else marks.push({ line: fl + added, run: mark.run });
    }
    return { marks, graveyard: graveyard.slice(-GRAVEYARD_LIMIT) };
}

/**
 * A pasted or moved line that exactly matches a deleted one gets its identity
 * back, provided no line holds it (the ADR-0008 same-session exception). Only
 * the `lines` a transaction touched are considered, and typing never calls
 * this, so a freshly typed line can't take an identity.
 */
export function recoverIdentities(doc: LineSource, ids: Identities, lines: number[]): Identities {
    const marks = [...ids.marks];
    const graveyard = [...ids.graveyard];
    const idOf = (run: string) => sourceIDs([{ line: 0, run }])[0];
    const inUse = new Set(sourceIDs(marks).filter(id => id !== null));
    for (const i of lines) {
        if (marks.some(m => m.line === i)) continue;
        const text = doc.line(i + 1).text;
        let found = -1;
        for (let g = graveyard.length - 1; g >= 0 && found < 0; g--) {
            const buried = idOf(graveyard[g].run);
            if (graveyard[g].text === text && !(buried && inUse.has(buried))) found = g;
        }
        if (found < 0) continue;
        const [{ run }] = graveyard.splice(found, 1);
        marks.push({ line: i, run });
        const id = idOf(run);
        if (id) inUse.add(id);
    }
    marks.sort((a, b) => a.line - b.line);
    return { marks, graveyard };
}

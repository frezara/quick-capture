/**
 * Ticked parents (CONTEXT.md): a ticked item means everything under it is
 * ticked. Ticking a parent ticks its descendants; unticking a child unticks
 * every ticked ancestor; unticking a parent leaves its children alone; ticking
 * the last child does not tick the parent.
 *
 * Lines are grouped by the same rule as refile's subtree span: a child is a
 * more-indented line below its item, and blank lines and headings end a group.
 */

const TASK = /^(\s*[-*+]\s+)\[([\sxX])\]/;
const ITEM = /^\s*[-*+]\s/;

/** A checkbox to set: 0-based line index and the state it should end in. */
export interface Tick { line: number; checked: boolean }

function width(text: string): number {
    let w = 0;
    for (const ch of text) {
        if (ch === " ") w += 1;
        else if (ch === "\t") w += 4;
        else break;
    }
    return w;
}

function endsGroup(text: string): boolean {
    const t = text.trim();
    return t === "" || t.startsWith("#");
}

function isChecked(text: string): boolean | null {
    const m = text.match(TASK);
    return m ? m[2] !== " " : null;
}

/** Column of a task line's `[`, or null when the line has no checkbox. */
export function markerColumn(text: string): number | null {
    const m = text.match(TASK);
    return m ? m[1].length : null;
}

/**
 * Every checkbox that must change when `requested` are applied, including the
 * requested ones themselves. Lines already in the right state are omitted.
 */
export function cascadeTicks(lines: string[], requested: Tick[]): Tick[] {
    const target = new Map<number, boolean>();
    for (const r of requested) target.set(r.line, r.checked);

    for (const r of requested) {
        if (r.checked) {
            const rootWidth = width(lines[r.line]);
            for (let i = r.line + 1; i < lines.length; i++) {
                if (endsGroup(lines[i]) || width(lines[i]) <= rootWidth) break;
                if (isChecked(lines[i]) !== null && !target.has(i)) target.set(i, true);
            }
        } else {
            let childWidth = width(lines[r.line]);
            for (let i = r.line - 1; i >= 0 && childWidth > 0; i--) {
                if (endsGroup(lines[i])) break;
                if (!ITEM.test(lines[i]) || width(lines[i]) >= childWidth) continue;
                childWidth = width(lines[i]);
                if (isChecked(lines[i]) === true) target.set(i, false);
            }
        }
    }

    return [...target]
        .filter(([line, checked]) => isChecked(lines[line]) !== null && isChecked(lines[line]) !== checked)
        .map(([line, checked]) => ({ line, checked }))
        .sort((a, b) => a.line - b.line);
}

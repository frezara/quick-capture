import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const result = await build({ entryPoints: ['src/source-marker.ts'], bundle: true, write: false, format: 'esm', platform: 'node' });
const { strip, serialise, sourceIDs, mapIdentities, recoverIdentities, hasDuplicateIdentity } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

const ID = '4457a173-9f6c-4efe-97ce-d9e0701e29df';
const M = ` <!--qc-source:${ID}-->`;
const M2 = M.replace('4457', '9999');

// ---- Strip and serialise -------------------------------------------------

test('stripping takes trailing markers out of the text and remembers their lines', () => {
    const file = `# Inbox\n- [ ] lunch${M}\n- [ ] plain !!\n- [ ] plan !!!${M2}`;
    const { text, marks } = strip(file);
    assert.equal(text, '# Inbox\n- [ ] lunch\n- [ ] plain !!\n- [ ] plan !!!');
    assert.deepEqual(marks, [{ line: 1, run: M }, { line: 3, run: M2 }]);
});
test('serialising puts every marker back byte for byte, legacy tokens included', () => {
    const file = `# Inbox\n- [ ] old ➕ 2026-10-15 09:00 <!--qc:abc-->${M}  \n- [ ] note <!-- ordinary comment -->\n`;
    const { text, marks } = strip(file);
    assert.equal(text, '# Inbox\n- [ ] old ➕ 2026-10-15 09:00\n- [ ] note <!-- ordinary comment -->\n');
    assert.equal(serialise(text, marks), file);
});
test('markers in the middle of a line are left as text', () => {
    const file = `- [ ] a${M} b`;
    assert.deepEqual(strip(file), { text: file, marks: [] });
});
test('the source identities of a mark list are read from their runs', () => {
    assert.deepEqual(sourceIDs([{ line: 0, run: ` <!--qc:abc-->${M}` }, { line: 2, run: ' <!--qc:old-->' }]), [ID, null]);
});

// ---- Identity through a change --------------------------------------------

function doc(text) {
    const lines = []; let from = 0;
    text.split('\n').forEach((t, i) => { lines.push({ from, to: from + t.length, text: t, number: i + 1 }); from += t.length + 1; });
    return { lineAt: pos => lines.find(l => pos >= l.from && pos <= l.to), line: n => lines[n - 1] };
}
/** One change, then recovery over the lines it touched, as a paste or move would get. */
function edit(text, ids, change, { typing = false } = {}) {
    const next = text.slice(0, change.from) + change.insert + text.slice(change.to);
    let mapped = mapIdentities(doc(text), ids, change);
    if (!typing) mapped = recoverIdentities(doc(next), mapped, touched(next, change.from, change.from + change.insert.length));
    return { text: next, ids: mapped };
}
function touched(text, from, to) {
    const first = text.slice(0, from).split('\n').length - 1, last = text.slice(0, to).split('\n').length - 1;
    return Array.from({ length: last - first + 1 }, (_, i) => first + i);
}
const start = (file) => { const { text, marks } = strip(file); return { text, ids: { marks, graveyard: [] } }; };
const at = (s, i) => s.ids.marks.find(m => m.line === i)?.run ?? null;

test('typing on a line keeps its identity, and lines below shift with an inserted line', () => {
    let s = start(`- [ ] lunch${M}\n- [ ] plan${M2}`);
    s = edit(s.text, s.ids, { from: 11, to: 11, insert: ' now' });
    assert.equal(at(s, 0), M);
    s = edit(s.text, s.ids, { from: 0, to: 0, insert: '- [ ] new\n' });
    assert.equal(at(s, 1), M); assert.equal(at(s, 2), M2); assert.equal(at(s, 0), null);
});
test('Enter mid-line keeps the identity on the first half', () => {
    let s = start(`- [ ] lunch at 3pm${M}`);
    s = edit(s.text, s.ids, { from: 11, to: 11, insert: '\n- [ ] ' });
    assert.equal(s.text, '- [ ] lunch\n- [ ]  at 3pm');
    assert.equal(at(s, 0), M); assert.equal(at(s, 1), null);
});
test('a line opened above with O pushes the identity down with its text', () => {
    let s = start(`- [ ] lunch${M}`);
    s = edit(s.text, s.ids, { from: 0, to: 0, insert: '- [ ] above\n' });
    assert.equal(at(s, 1), M); assert.equal(at(s, 0), null);
});
test('J keeps the first line identity and drops the second', () => {
    let s = start(`- [ ] lunch${M}\n  other${M2}`);
    s = edit(s.text, s.ids, { from: 11, to: 14, insert: ' ' });
    assert.equal(s.text, '- [ ] lunch other');
    assert.deepEqual(s.ids.marks, [{ line: 0, run: M }]);
});
test('dd drops the identity of the deleted line and moves the next one up', () => {
    let s = start(`- [ ] lunch${M}\n- [ ] plan${M2}`);
    s = edit(s.text, s.ids, { from: 0, to: 12, insert: '' });
    assert.deepEqual(s.ids.marks, [{ line: 0, run: M2 }]);
});
test('dd on the last line drops only that line identity', () => {
    let s = start(`- [ ] lunch${M}\n- [ ] plan${M2}`);
    s = edit(s.text, s.ids, { from: 11, to: 22, insert: '' });
    assert.deepEqual(s.ids.marks, [{ line: 0, run: M }]);
});
test('dd then p moves an item and it keeps its identity', () => {
    let s = start(`- [ ] lunch${M}\n- [ ] plan`);
    s = edit(s.text, s.ids, { from: 0, to: 12, insert: '' });          // dd
    s = edit(s.text, s.ids, { from: 10, to: 10, insert: '\n- [ ] lunch' }); // p
    assert.equal(s.text, '- [ ] plan\n- [ ] lunch');
    assert.deepEqual(s.ids.marks, [{ line: 1, run: M }]);
});
test('undo of J restores the second line identity', () => {
    let s = start(`- [ ] lunch${M}\n  other${M2}`);
    s = edit(s.text, s.ids, { from: 11, to: 14, insert: ' ' });
    s = edit(s.text, s.ids, { from: 11, to: 12, insert: '\n  ' });
    assert.deepEqual(s.ids.marks, [{ line: 0, run: M }, { line: 1, run: M2 }]);
});
test('a copied line never takes an identity that is still in use', () => {
    let s = start(`- [ ] lunch${M}`);
    s = edit(s.text, s.ids, { from: 11, to: 11, insert: '\n- [ ] lunch' }); // yy p
    assert.deepEqual(s.ids.marks, [{ line: 0, run: M }]);
});
test('replacing everything and undoing it brings every identity back', () => {
    const file = `- [ ] lunch${M}\n- [ ] plain\n- [ ] plan${M2}`;
    let s = start(file);
    const original = s.text;
    s = edit(s.text, s.ids, { from: 0, to: original.length, insert: 'x' });
    assert.deepEqual(s.ids.marks, []);
    s = edit(s.text, s.ids, { from: 0, to: 1, insert: original });
    assert.equal(serialise(s.text, s.ids.marks), file);
});

test('a freshly typed line never takes a deleted item identity', () => {
    let s = start(`- [ ] call${M}\n- [ ] plan`);
    s = edit(s.text, s.ids, { from: 0, to: 11, insert: '' });
    for (const ch of '\n- [ ] call') s = edit(s.text, s.ids, { from: s.text.length, to: s.text.length, insert: ch }, { typing: true });
    assert.deepEqual(s.ids.marks, []);
});
test('moving a line down in one transaction keeps both identities', () => {
    // Alt-Down on line 0: CodeMirror inserts "b\n" above, then deletes the old "b" line.
    const file = `- [ ] a${M}\n- [ ] b${M2}\n- [ ] c`;
    let { text, marks } = strip(file);
    let ids = { marks, graveyard: [] };
    const c1 = { from: 0, to: 0, insert: '- [ ] b\n' };
    const t1 = text.slice(0, c1.from) + c1.insert + text.slice(c1.to);
    ids = mapIdentities(doc(text), ids, c1);
    const c2 = { from: t1.indexOf('\n- [ ] b', 8), to: t1.indexOf('\n- [ ] c'), insert: '' };
    const t2 = t1.slice(0, c2.from) + c2.insert + t1.slice(c2.to);
    ids = mapIdentities(doc(t1), ids, c2);
    ids = recoverIdentities(doc(t2), ids, [0, 1]);
    assert.equal(t2, '- [ ] b\n- [ ] a\n- [ ] c');
    assert.deepEqual(ids.marks, [{ line: 0, run: M2 }, { line: 1, run: M }]);
});
test('two identities on one line count as a duplicate', () => {
    assert.equal(hasDuplicateIdentity([{ line: 0, run: `${M}${M2}` }], 0), true);
    assert.equal(hasDuplicateIdentity([{ line: 0, run: M }, { line: 3, run: M }], 0), true);
    assert.equal(hasDuplicateIdentity([{ line: 0, run: M }, { line: 3, run: M2 }], 0), false);
});

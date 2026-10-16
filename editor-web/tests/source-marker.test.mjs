import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const result = await build({ entryPoints: ['src/source-marker.ts'], bundle: true, write: false, format: 'esm', platform: 'node' });
const { trailingMarkerSpan } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

const ID = '4457a173-9f6c-4efe-97ce-d9e0701e29df';

test('a delivered task ends in a source marker span that includes the space before it', () => {
    const line = `- [ ] lunch at 3pm <!--qc-source:${ID}-->`;
    assert.deepEqual(trailingMarkerSpan(line), { from: '- [ ] lunch at 3pm'.length, to: line.length });
});
test('legacy creation tokens and stacked markers form one trailing span', () => {
    const line = `- [ ] task ➕ 2026-10-15 09:00 <!--qc:abc--> <!--qc-source:${ID}-->`;
    assert.deepEqual(trailingMarkerSpan(line), { from: '- [ ] task ➕ 2026-10-15 09:00'.length, to: line.length });
});
test('lines without a trailing marker have no span', () => {
    assert.equal(trailingMarkerSpan('- [ ] plain task !!'), null);
    assert.equal(trailingMarkerSpan(`- [ ] a <!--qc-source:${ID}--> b`), null);
    assert.equal(trailingMarkerSpan('<!-- an ordinary html comment -->'), null);
});

const { confineChange } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

/** A minimal stand-in for CodeMirror's Text: lineAt(pos) and length. */
function doc(text) {
    const lines = []; let from = 0;
    for (const t of text.split('\n')) { lines.push({ from, to: from + t.length, text: t }); from += t.length + 1; }
    return { length: text.length, lineAt: pos => lines.find(l => pos >= l.from && pos <= l.to) ?? lines[lines.length - 1] };
}
function apply(text, changes) {
    let out = text, shift = 0;
    for (const c of [...changes].sort((a, b) => a.from - b.from)) {
        out = out.slice(0, c.from + shift) + c.insert + out.slice(c.to + shift);
        shift += c.insert.length - (c.to - c.from);
    }
    return out;
}
const M = `<!--qc-source:${ID}-->`;

test('typing at the end of a delivered line lands before its marker', () => {
    const text = `- [ ] lunch ${M}\n- [ ] other`;
    const changes = confineChange(doc(text), { from: `- [ ] lunch ${M}`.length, to: `- [ ] lunch ${M}`.length, insert: ' now' });
    assert.equal(apply(text, changes), `- [ ] lunch now ${M}\n- [ ] other`);
});

test('Enter at the end of a delivered line opens the new line after the marker', () => {
    const text = `- [ ] lunch ${M}`;
    const changes = confineChange(doc(text), { from: text.length, to: text.length, insert: '\n- [ ] ' });
    assert.equal(apply(text, changes), `- [ ] lunch ${M}\n- [ ] `);
});
test('deleting to the end of the line stops at the marker', () => {
    const text = `- [ ] lunch at 3pm ${M}`;
    const changes = confineChange(doc(text), { from: '- [ ] lunch'.length, to: text.length, insert: '' });
    assert.equal(apply(text, changes), `- [ ] lunch ${M}`);
});
test('deleting the whole line takes the marker with it', () => {
    const text = `- [ ] lunch ${M}\n- [ ] other ${M}`;
    const changes = confineChange(doc(text), { from: 0, to: `- [ ] lunch ${M}\n`.length, insert: '' });
    assert.equal(apply(text, changes), `- [ ] other ${M}`);
});
test('joining the next line pulls its text in front of the marker and drops its own identity', () => {
    const text = `- [ ] lunch ${M}\n  other ${M.replace('4457', '9999')}`;
    const lineEnd = `- [ ] lunch ${M}`.length;
    const changes = confineChange(doc(text), { from: lineEnd, to: lineEnd + '\n  '.length, insert: ' ' });
    assert.equal(apply(text, changes), `- [ ] lunch other ${M}`);
});
test('a replacement reaching into the next line keeps the first identity at the end', () => {
    const text = `- [ ] lunch ${M}\n- [ ] other`;
    const from = '- [ ] lun'.length, to = `- [ ] lunch ${M}\n- [ ] ot`.length;
    const changes = confineChange(doc(text), { from, to, insert: 'x' });
    assert.equal(apply(text, changes), `- [ ] lunxher ${M}`);
});
test('edits on lines without a marker pass through untouched', () => {
    const text = `- [ ] plain\n- [ ] other ${M}`;
    const change = { from: 5, to: 11, insert: 'edited' };
    assert.deepEqual(confineChange(doc(text), change), [change]);
});
test('typing just before the marker is already in place', () => {
    const text = `- [ ] lunch ${M}`;
    const change = { from: '- [ ] lunch'.length, to: '- [ ] lunch'.length, insert: '!' };
    assert.deepEqual(confineChange(doc(text), change), [change]);
});
test('a selection ending inside a later marked line keeps that line identity', () => {
    const text = `- [ ] plain\n- [ ] other ${M}`;
    const from = '- [ ] pl'.length, to = `- [ ] plain\n- [ ] ot`.length;
    assert.equal(apply(text, confineChange(doc(text), { from, to, insert: '' })), `- [ ] plher ${M}`);
});

const { confineEdit } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

test('confineEdit places the caret after typed text, before the marker', () => {
    const text = `- [ ] lunch ${M}`;
    const { changes, cursor } = confineEdit(doc(text), { from: text.length, to: text.length, insert: ' now' });
    assert.equal(apply(text, changes), `- [ ] lunch now ${M}`);
    assert.equal(cursor, '- [ ] lunch now'.length);
});
test('confineEdit leaves Enter at the end of a marked line to the editor', () => {
    const text = `- [ ] lunch ${M}`;
    const enter = { from: text.length, to: text.length, insert: '\n- [ ] ' };
    assert.deepEqual(confineEdit(doc(text), enter), { changes: [enter], cursor: null });
});
test('confineEdit places the caret at the join point when lines merge', () => {
    const text = `- [ ] lunch ${M}\n  other`;
    const lineEnd = `- [ ] lunch ${M}`.length;
    const { changes, cursor } = confineEdit(doc(text), { from: lineEnd, to: lineEnd + 3, insert: ' ' });
    assert.equal(apply(text, changes), `- [ ] lunch other ${M}`);
    assert.equal(cursor, '- [ ] lunch '.length);
});
test('confineEdit places the caret at the deletion point when deleting to end of line', () => {
    const text = `- [ ] lunch at 3pm ${M}`;
    const { cursor } = confineEdit(doc(text), { from: '- [ ] lunch'.length, to: text.length, insert: '' });
    assert.equal(cursor, '- [ ] lunch'.length);
});
test('confineEdit reports no caret for untouched edits', () => {
    const text = `- [ ] plain`;
    const { changes, cursor } = confineEdit(doc(text), { from: 5, to: 5, insert: 'x' });
    assert.deepEqual(changes, [{ from: 5, to: 5, insert: 'x' }]);
    assert.equal(cursor, null);
});

test('confineEdit reports no caret when a change on a marked line needed no confining', () => {
    const text = `- [ ] lunch ${M}`;
    const toggle = { from: 3, to: 4, insert: 'x' };
    assert.deepEqual(confineEdit(doc(text), toggle), { changes: [toggle], cursor: null });
    const indent = { from: 0, to: 0, insert: '    ' };
    assert.deepEqual(confineEdit(doc(text), indent), { changes: [indent], cursor: null });
    const lineAbove = `- [ ] plain\n${text}`;
    const dd = { from: 0, to: '- [ ] plain\n'.length, insert: '' };
    assert.deepEqual(confineEdit(doc(lineAbove), dd), { changes: [dd], cursor: null });
});

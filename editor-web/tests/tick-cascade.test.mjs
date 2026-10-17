import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const result = await build({ entryPoints: ['src/tick-cascade.ts'], bundle: true, write: false, format: 'esm', platform: 'node' });
const { cascadeTicks } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

const doc = [
    '## Tasks',             // 0
    '- [ ] Ship release',   // 1
    '  - [ ] write notes',  // 2
    '    - [x] draft',      // 3
    '    - [ ] proofread',  // 4
    '  - plain bullet',     // 5
    '  - [ ] tag build',    // 6
    '- [ ] Next item',      // 7
    '  - [ ] its child',    // 8
];

test('ticking a parent ticks every unticked descendant, not siblings', () => {
    assert.deepEqual(cascadeTicks(doc, [{ line: 1, checked: true }]), [
        { line: 1, checked: true }, { line: 2, checked: true }, { line: 4, checked: true }, { line: 6, checked: true },
    ]);
});
test('ticking a middle item stops at its own subtree', () => {
    assert.deepEqual(cascadeTicks(doc, [{ line: 2, checked: true }]), [
        { line: 2, checked: true }, { line: 4, checked: true },
    ]);
});
test('unticking a child unticks every ticked ancestor', () => {
    const ticked = doc.map(l => l.replace('[ ]', '[x]'));
    assert.deepEqual(cascadeTicks(ticked, [{ line: 4, checked: false }]), [
        { line: 1, checked: false }, { line: 2, checked: false }, { line: 4, checked: false },
    ]);
});
test('unticking a parent leaves its children ticked', () => {
    const ticked = doc.map(l => l.replace('[ ]', '[x]'));
    assert.deepEqual(cascadeTicks(ticked, [{ line: 1, checked: false }]), [{ line: 1, checked: false }]);
});
test('ticking the last unticked child does not tick the parent', () => {
    const lines = ['- [ ] parent', '  - [x] a', '  - [ ] b'];
    assert.deepEqual(cascadeTicks(lines, [{ line: 2, checked: true }]), [{ line: 2, checked: true }]);
});
test('blank lines and headings end the group', () => {
    const lines = ['- [x] parent', '', '  - [x] not a child', '## Next', '  - [ ] nor this'];
    assert.deepEqual(cascadeTicks(lines, [{ line: 2, checked: false }]), [{ line: 2, checked: false }]);
    const open = ['- [ ] parent', '', '  - [ ] not a child'];
    assert.deepEqual(cascadeTicks(open, [{ line: 0, checked: true }]), [{ line: 0, checked: true }]);
});
test('batches merge without duplicates', () => {
    assert.deepEqual(cascadeTicks(doc, [{ line: 1, checked: true }, { line: 2, checked: true }, { line: 7, checked: true }]), [
        { line: 1, checked: true }, { line: 2, checked: true }, { line: 4, checked: true },
        { line: 6, checked: true }, { line: 7, checked: true }, { line: 8, checked: true },
    ]);
});
test('tabs count as four spaces of indent', () => {
    const lines = ['- [x] parent', '\t- [x] child'];
    assert.deepEqual(cascadeTicks(lines, [{ line: 1, checked: false }]), [
        { line: 0, checked: false }, { line: 1, checked: false },
    ]);
});

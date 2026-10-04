import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const result = await build({ entryPoints: ['src/document-session.ts'], bundle: true, write: false, format: 'esm', platform: 'node' });
const { DocumentSession } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

function setup() {
    let content = 'original';
    const requests = [], errors = [];
    let saved = 0;
    const session = new DocumentSession(() => content, r => requests.push(r), (message, disk) => errors.push({message, disk}), () => saved++);
    session.savedContent = content;
    return { session, requests, errors, edit: text => { content = text; }, saved: () => saved };
}

test('external changes cannot replace edits during the autosave delay', () => {
    const h = setup(); h.edit('my edits');
    assert.equal(h.session.acceptDisk('external edits'), false);
    assert.equal(h.session.savedContent, 'original');
    assert.equal(h.errors[0].disk, 'external edits');
});
test('clean buffers accept external updates', () => {
    const h = setup();
    assert.equal(h.session.acceptDisk('external edits'), true);
    assert.equal(h.session.savedContent, 'external edits');
});
test('save only completes and marks saved after native acknowledgement', async () => {
    const h = setup(); h.edit('my edits');
    let complete = false;
    const flush = h.session.save().then(ok => { complete = true; return ok; });
    await Promise.resolve();
    assert.equal(complete, false); assert.equal(h.saved(), 0);
    assert.equal(h.requests[0].expected, 'original');
    h.session.acknowledge(h.requests[0].id, null, null);
    assert.equal(await flush, true); assert.equal(h.saved(), 1);
});
test('failed saves retain the original baseline and can be retried', async () => {
    const h = setup(); h.edit('my edits');
    const flush = h.session.save();
    h.session.acknowledge(h.requests[0].id, 'Disk full', null);
    assert.equal(await flush, false); assert.equal(h.saved(), 0);
    assert.equal(h.session.savedContent, 'original');
    const retry = h.session.save();
    assert.equal(h.requests[1].content, 'my edits');
    h.session.acknowledge(h.requests[1].id, null, null);
    assert.equal(await retry, true);
});
test('flush includes edits typed while an earlier write is in flight', async () => {
    const h = setup(); h.edit('first edit');
    const flush = h.session.save();
    h.edit('second edit');
    h.session.acknowledge(h.requests[0].id, null, null);
    await Promise.resolve();
    assert.equal(h.requests.length, 2);
    assert.equal(h.requests[1].expected, 'first edit');
    h.session.acknowledge(h.requests[1].id, null, null);
    assert.equal(await flush, true);
    assert.equal(h.session.savedContent, 'second edit');
});
test('concurrent autosave and flush serialize writes', async () => {
    const h = setup(); h.edit('edits');
    const first = h.session.save(), second = h.session.save();
    assert.equal(h.requests.length, 1);
    h.session.acknowledge(h.requests[0].id, null, null);
    assert.deepEqual(await Promise.all([first, second]), [true, true]);
});
test('watcher echo of an in-flight save does not report a conflict', async () => {
    const h = setup(); h.edit('edits');
    const flush = h.session.save();
    assert.equal(h.session.acceptDisk('edits'), false);
    assert.equal(h.errors.length, 0);
    h.session.acknowledge(h.requests[0].id, null, null);
    await flush;
});
test('external edit arriving before a save acknowledgement stays a conflict', async () => {
    const h = setup(); h.edit('my edits');
    const flush = h.session.save();
    h.session.acceptDisk('new external version');
    h.session.acknowledge(h.requests[0].id, null, null);
    assert.equal(await flush, false);
    assert.equal(h.saved(), 0);
    assert.equal(h.errors.at(-1).disk, 'new external version');
    assert.equal(await h.session.save(), false);
    assert.equal(h.requests.length, 1);
});
test('explicit keep-mine resolution compares against the conflicting disk version', async () => {
    const h = setup(); h.edit('my edits');
    h.session.acceptDisk('external version');
    h.session.useDiskBaseline('external version');
    const retry = h.session.save();
    assert.equal(h.requests[0].expected, 'external version');
    assert.equal(h.requests[0].content, 'my edits');
    h.session.acknowledge(h.requests[0].id, null, null);
    assert.equal(await retry, true);
});

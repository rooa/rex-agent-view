import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PaneState } from './pane-state.mjs';

test('pane selection survives restart, isolates panes, and never duplicates transcripts', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rex-pane-state-'));
  try {
    const first = new PaneState('session:a/block:b', directory);
    assert.equal(first.read(), null);
    first.write({provider: 'claude', sessionId: 'native-session', cwd: '/tmp/project',
      model: 'opus', effort: 'high', messages: [{text: 'Do not duplicate my transcript'}]});
    assert.deepEqual(new PaneState('session:a/block:b', directory).read(), {
      provider: 'claude', sessionId: 'native-session', cwd: '/tmp/project', model: 'opus', effort: 'high',
    });
    assert.equal(new PaneState('session:a/block:c', directory).read(), null);
    assert.equal((await stat(first.file)).mode & 0o777, 0o600);
    assert.doesNotMatch(await readFile(first.file, 'utf8'), /transcript/);
    first.write({provider: 'codex', cwd: '/tmp/project'});
    assert.equal(first.read().sessionId, null);
  } finally { await rm(directory, {recursive: true, force: true}); }
});

test('invalid saved selections are reported, and a new conversation can replace them', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rex-pane-state-'));
  try {
    const store = new PaneState('../../pane', directory);
    assert.equal(join(directory, store.file.split('/').at(-1)), store.file);
    await writeFile(store.file, JSON.stringify({provider: 'unknown', cwd: '/tmp'}));
    assert.throws(() => store.read(), /configuration is invalid/);
    store.write({provider: 'codex', cwd: '/tmp'});
    assert.equal(store.read().provider, 'codex');
    const temporary = new PaneState(null, directory);
    temporary.write({provider: 'codex', cwd: '/tmp'});
    assert.equal(temporary.read(), null);
  } finally { await rm(directory, {recursive: true, force: true}); }
});

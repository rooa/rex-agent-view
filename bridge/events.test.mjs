import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TextStream, codexActivity, claudeActivity } from './events.mjs';
import { ClaudeSession } from './claude.mjs';

test('streamed text and authoritative final messages are not duplicated', () => {
  const events = [];
  const text = new TextStream(event => events.push(event));
  text.delta('one', 'Hello');
  text.delta('one', ' world');
  text.complete('one', 'Hello world!');
  text.complete('one', 'Hello world!');
  text.complete('two', 'A final answer.');
  assert.equal(events.map(event => event.text).join(''), 'Hello world!\n\nA final answer.');
});

test('text resets between turns and ignores empty assistant messages', () => {
  const events = [];
  const text = new TextStream(event => events.push(event));
  text.complete('empty', '');
  text.complete('one', 'First');
  text.reset();
  text.complete('two', 'Second');
  assert.deepEqual(events.map(event => event.text), ['First', 'Second']);
});

test('command activity contains executable command, output, and failure status', () => {
  assert.deepEqual(codexActivity({
    id: 'cmd', type: 'commandExecution', command: 'npm test',
    aggregatedOutput: 'Test failed', status: 'failed', exitCode: 1,
  }, true), {
    type: 'activity', id: 'cmd', title: 'npm test',
    detail: 'Test failed', status: 'failed',
  });
});

test('Claude tool inputs remain readable and preserve the tool identifier', () => {
  const result = claudeActivity({id: 'read', name: 'Read', input: {file_path: '/tmp/readme.md'}});
  assert.equal(result.id, 'read');
  assert.equal(result.title, 'Read · /tmp/readme.md');
  assert.match(result.detail, /\/tmp\/readme.md/);
  assert.equal(result.status, 'running');
});

test('Claude streams command arguments before completion and preserves the command title', () => {
  const events = [];
  const session = new ClaudeSession({cwd: '/tmp', emit: event => events.push(event)});
  const stream = event => session.receive({type: 'stream_event', event});
  stream({type: 'message_start', message: {id: 'message'}});
  stream({type: 'content_block_start', index: 1, content_block: {type: 'tool_use', id: 'command', name: 'Bash', input: {}}});
  stream({type: 'content_block_delta', index: 1, delta: {type: 'input_json_delta', partial_json: '{"command":"printf '}});
  assert.match(events.at(-1).detail, /printf/);
  stream({type: 'content_block_delta', index: 1, delta: {type: 'input_json_delta', partial_json: 'READY"}'}});
  assert.equal(events.at(-1).title, 'Bash · printf READY');
  assert.equal(events.at(-1).status, 'running');
  session.receive({type: 'user', message: {content: [{type: 'tool_result', tool_use_id: 'command', content: 'READY'}]}});
  assert.equal(events.at(-1).title, 'Bash · printf READY');
  assert.equal(events.at(-1).status, 'completed');
});

test('unstreamed Claude assistant blocks still emit text and tools in order', () => {
  const events = [];
  const session = new ClaudeSession({cwd: '/tmp', emit: event => events.push(event)});
  session.receive({type: 'assistant', message: {id: 'message', content: [
    {type: 'text', text: 'Before'},
    {type: 'tool_use', id: 'command', name: 'Bash', input: {command: 'pwd'}},
    {type: 'text', text: 'After'},
  ]}});
  assert.deepEqual(events.map(event => event.type), ['delta', 'activity', 'delta']);
  assert.deepEqual(events.filter(event => event.type === 'delta').map(event => event.text), ['Before', 'After']);
});

test('Claude auth retries show model-access context without hiding the final provider error', () => {
  const events = [];
  const session = new ClaudeSession({cwd: '/tmp', emit: event => events.push(event)});
  session.receive({type: 'system', subtype: 'api_retry', error: 'authentication_failed', error_status: 403});
  assert.match(events[0].detail, /authentication or model access/i);
  assert.match(events[0].detail, /403/);
  assert.match(events[0].detail, /executable.*model/i);
  session.receive({type: 'assistant', message: {id: 'error-message', content: [
    {type: 'text', text: 'HTTP 403: selected model is not allowed for this team'},
  ]}, error: 'authentication_failed'});
  assert.equal(events.filter(event => event.type === 'delta').map(event => event.text).join(''),
    'HTTP 403: selected model is not allowed for this team');
});

test('Claude executable resolves from adapter-local config, with a validated env override', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'rex-claude-config-'));
  const previous = process.env.REX_AGENT_CLAUDE;
  try {
    await mkdir(join(dir, 'bridge'));
    await mkdir(join(dir, '.rex-agent'));
    for (const file of ['claude.mjs', 'events.mjs', 'provider-data.mjs']) {
      await copyFile(new URL(file, import.meta.url), join(dir, 'bridge', file));
    }
    await symlink(new URL('../node_modules', import.meta.url).pathname, join(dir, 'node_modules'));
    await writeFile(join(dir, '.rex-agent/config.json'), JSON.stringify({claudeExecutable: process.execPath}));
    delete process.env.REX_AGENT_CLAUDE;
    const {ClaudeSession: LocalSession} = await import(join(dir, 'bridge/claude.mjs'));
    const configured = new LocalSession({cwd: '/tmp', emit: () => {}});
    await configured.start();
    assert.equal(configured.executable, process.execPath);
    process.env.REX_AGENT_CLAUDE = '/missing/rex-test-claude';
    await assert.rejects(new LocalSession({cwd: '/tmp', emit: () => {}}).start(), /executable.*not accessible/i);
    await writeFile(join(dir, '.rex-agent/config.json'), '{bad JSON');
    process.env.REX_AGENT_CLAUDE = process.execPath;
    await new LocalSession({cwd: '/tmp', emit: () => {}}).start();
    delete process.env.REX_AGENT_CLAUDE;
    await assert.rejects(new LocalSession({cwd: '/tmp', emit: () => {}}).start(), /JSON/);
    await writeFile(join(dir, '.rex-agent/config.json'), JSON.stringify({claudeExecutable: 42}));
    await assert.rejects(new LocalSession({cwd: '/tmp', emit: () => {}}).start(), /non-empty string/i);
  } finally {
    if (previous === undefined) delete process.env.REX_AGENT_CLAUDE;
    else process.env.REX_AGENT_CLAUDE = previous;
    await rm(dir, {recursive: true, force: true});
  }
});

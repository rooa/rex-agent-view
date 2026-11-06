import test from 'node:test';
import assert from 'node:assert/strict';
import { codexHistory, claudeHistory, codexSkillInputs, claudeSkillPrompt, resumeCommand, codexUsage, claudeUsage, historyQuery } from './provider-data.mjs';
import { CodexSession } from './codex.mjs';
import { ClaudeSession } from './claude.mjs';

test('native Codex history retains conversation order and completed tool details', () => {
  const messages = codexHistory([
    {item: {type: 'userMessage', content: [{type: 'text', text: 'Inspect the project'}]}},
    {item: {type: 'agentMessage', text: 'I will inspect it.'}},
    {item: {id: 'cmd', type: 'commandExecution', command: 'pwd', aggregatedOutput: '/project', status: 'completed'}},
    {item: {type: 'agentMessage', text: 'It is a Swift project.'}},
  ]);
  assert.equal(messages[0].role, 'user');
  assert.equal(messages[1].text, 'I will inspect it.');
  assert.equal(messages[1].activities[0].detail, '/project');
  assert.equal(messages[2].text, 'It is a Swift project.');
});

test('Claude native history joins tool results to assistant activity, not user bubbles', () => {
  const messages = claudeHistory([
    {type: 'user', uuid: 'u', message: {content: 'Read README'}},
    {type: 'assistant', uuid: 'a', message: {content: [
      {type: 'text', text: 'Reading it.'}, {type: 'tool_use', id: 'read', name: 'Read', input: {file_path: 'README.md'}},
    ]}},
    {type: 'user', uuid: 'result', message: {content: [{type: 'tool_result', tool_use_id: 'read', content: 'Project description'}]}},
    {type: 'assistant', uuid: 'b', message: {content: [{type: 'text', text: 'Here is the summary.'}]}},
  ]);
  assert.equal(messages.length, 3);
  assert.equal(messages[1].text, 'Reading it.');
  assert.equal(messages[2].text, 'Here is the summary.');
  assert.equal(messages[1].activities[0].status, 'completed');
  assert.equal(messages[1].activities[0].detail, 'Project description');
});

test('Claude history retains text/tool/text order within a single assistant message', () => {
  const messages = claudeHistory([{type: 'assistant', message: {content: [
    {type: 'text', text: 'Before'},
    {type: 'tool_use', id: 'command', name: 'Bash', input: {command: 'pwd'}},
    {type: 'text', text: 'After'},
  ]}}]);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].text, 'Before');
  assert.equal(messages[0].activities[0].id, 'command');
  assert.equal(messages[1].text, 'After');
});

test('Claude local commands join adjacent stdout and keep their place in history', () => {
  const command = '<command-message>effort</command-message>\n<command-name>/effort</command-name>\n<command-args>xhigh</command-args>';
  const output = 'Set effort level to xhigh (saved as your default for new sessions): Deeper reasoning than high, just below maximum (on supported models)';
  const records = [
    {type: 'user', message: {content: 'Before'}},
    {type: 'user', uuid: 'command', message: {content: command}},
    {type: 'user', uuid: 'output', message: {content: `<local-command-stdout>${output}</local-command-stdout>`}},
    {type: 'user', uuid: 'output', message: {content: `<local-command-stdout>${output}</local-command-stdout>`}},
    {type: 'user', message: {content: 'After'}},
  ];
  const original = structuredClone(records);
  assert.deepEqual(claudeHistory(records), [
    {role: 'user', text: 'Before'},
    {role: 'command', text: `/effort xhigh\n\n${output}`, command: {name: '/effort', args: 'xhigh', output}},
    {role: 'user', text: 'After'},
  ]);
  assert.deepEqual(records, original, 'Reading history must not rewrite native records');
});

test('Claude local commands support combined wrappers and standalone output', () => {
  const messages = claudeHistory([
    {type: 'user', message: {content: [
      {type: 'text', text: '<command-name>/effort</command-name><command-message>effort</command-message><command-args>xhigh</command-args>'},
      {type: 'text', text: '<local-command-stdout>First line\nSecond line</local-command-stdout>'},
    ]}},
    {type: 'assistant', message: {content: 'An answer between commands.'}},
    {type: 'user', message: {content: '<local-command-stdout>Standalone output</local-command-stdout>'}},
    {type: 'user', message: {content: '<command-name>/clear</command-name><command-message>clear</command-message><command-args></command-args>'}},
  ]);
  assert.deepEqual(messages[0], {role: 'command', text: '/effort xhigh\n\nFirst line\nSecond line',
    command: {name: '/effort', args: 'xhigh', output: 'First line\nSecond line'}});
  assert.equal(messages[1].text, 'An answer between commands.');
  assert.deepEqual(messages[2], {role: 'command', text: 'Standalone output',
    command: {name: '', args: '', output: 'Standalone output'}});
  assert.deepEqual(messages[3], {role: 'command', text: '/clear', command: {name: '/clear', args: '', output: ''}});
});

test('Claude command styling preserves quoted, incomplete, unknown, and assistant markup', () => {
  const command = '<command-name>/effort</command-name><command-args>xhigh</command-args>';
  const samples = [
    `Explain ${command}`,
    `\`\`\`xml\n${command}\n\`\`\``,
    '> ' + command,
    '<command-name>/effort',
    command + '<unknown-tag>keep this</unknown-tag>',
    '<command-name>/effort</command-name><command-name>/clear</command-name>',
  ];
  for (const text of samples) assert.deepEqual(claudeHistory([{type: 'user', message: {content: text}}]), [{role: 'user', text}]);
  assert.deepEqual(claudeHistory([{type: 'assistant', message: {content: command}}]), [{role: 'assistant', text: command, activities: []}]);
  const separated = claudeHistory([
    {type: 'user', message: {content: command}},
    {type: 'user', message: {content: 'An ordinary message'}},
    {type: 'user', message: {content: '<local-command-stdout>Later output</local-command-stdout>'}},
  ]);
  assert.equal(separated.length, 3);
  assert.equal(separated[0].command.output, '');
  assert.equal(separated[2].command.name, '');
});

test('Codex skill references use only catalog paths and reject injected paths', () => {
  const skills = [{name: 'rex', path: '/skills/rex/SKILL.md'}];
  assert.deepEqual(codexSkillInputs('Use $rex and inspect $PATH', [], skills), [{type: 'skill', name: 'rex', path: '/skills/rex/SKILL.md'}]);
  assert.throws(() => codexSkillInputs('hello', [{name: 'rex', path: '/secret'}], skills), /Unknown skill/);
  assert.equal(claudeSkillPrompt('inspect panes', [{name: 'rex'}], skills), '/rex inspect panes');
  assert.equal(claudeSkillPrompt('/rex inspect panes', [{name: 'rex'}], skills), '/rex inspect panes');
});

test('resume command safely quotes paths and native session identifiers', () => {
  assert.equal(resumeCommand('claude', 'thread-1', "/tmp/a'b", '/opt/bin/claude'), "cd '/tmp/a'\\''b' && '/opt/bin/claude' --resume 'thread-1'");
});

test('usage normalizes cached input and keeps session and turn scope distinct', () => {
  assert.deepEqual(codexUsage({total: {inputTokens: 100, outputTokens: 12, cachedInputTokens: 40}, last: {totalTokens: 80}, modelContextWindow: 200}), {
    type: 'usage', inputTokens: 100, outputTokens: 12, cachedInputTokens: 40, contextTokens: 80, contextWindow: 200, scope: 'session',
  });
  const usage = claudeUsage({usage: {input_tokens: 3, output_tokens: 5, cache_read_input_tokens: 20, cache_creation_input_tokens: 2}, total_cost_usd: 0.01}, {input_tokens: 3, output_tokens: 5, cache_read_input_tokens: 20});
  assert.equal(usage.inputTokens, 25);
  assert.equal(usage.contextTokens, 28);
  assert.equal(usage.scope, 'turn');
});

test('Codex reads all native history pages and resumes without starting a turn', async () => {
  const calls = [];
  const session = new CodexSession({cwd: '/old', emit: () => {}});
  session.call = async (method, params) => {
    calls.push({method, params});
    if (method === 'thread/read') return {thread: {id: 'native', cwd: '/actual', model: 'model-a', reasoningEffort: 'high', historyMode: 'paginated'}};
    if (method === 'thread/items/list') return params.cursor
      ? {data: [{item: {type: 'agentMessage', text: 'Answer'}}], nextCursor: null}
      : {data: [{item: {type: 'userMessage', content: [{type: 'text', text: 'Question'}]}}], nextCursor: 'page-2'};
    if (method === 'thread/resume') return {thread: {id: 'native', cwd: '/actual'}, model: 'model-a', reasoningEffort: 'high'};
    throw new Error(`Unexpected method ${method}`);
  };
  const restored = await session.resumeSession('native');
  assert.equal(session.threadId, 'native');
  assert.equal(session.cwd, '/actual');
  assert.equal(restored.messages.length, 2);
  assert.equal(calls.filter(call => call.method === 'thread/items/list').length, 2);
  assert.equal(calls.some(call => call.method === 'turn/start'), false);
  const resume = calls.find(call => call.method === 'thread/resume').params;
  assert.equal(resume.approvalPolicy, 'on-request');
  assert.equal(resume.approvalsReviewer, 'user');
  assert.equal(resume.sandbox, 'workspace-write');
});

test('Claude resumes SDK-native session metadata and forwards selected model/effort', async () => {
  const events = [];
  const session = new ClaudeSession({cwd: '/old', emit: event => events.push(event)});
  session.sdk = {
    getSessionInfo: async () => ({sessionId: 'native', cwd: '/actual'}),
    getSessionMessages: async () => [{type: 'user', uuid: 'u', message: {content: 'Question'}}],
  };
  session.executable = '/opt/bin/claude';
  const restored = await session.resumeSession('native');
  assert.equal(session.cwd, '/actual');
  assert.equal(restored.sessionId, 'native');
  let options;
  session.query = request => {
    options = request.options;
    return {async *[Symbol.asyncIterator]() { yield {type: 'result', subtype: 'success', result: 'Done', is_error: false}; }, close() {}};
  };
  await session.prompt('Next', {model: 'opus', effort: 'medium'});
  assert.equal(options.resume, 'native');
  assert.equal(options.cwd, '/actual');
  assert.equal(options.model, 'opus');
  assert.equal(options.effort, 'medium');
});

test('Codex Default resets prior overrides to the native session baseline', async () => {
  const calls = [];
  const session = new CodexSession({cwd: '/project', emit: () => {}});
  session.call = async (method, params) => {
    calls.push({method, params});
    if (method === 'thread/start') return {thread: {id: 'native'}, model: 'native-default', reasoningEffort: 'medium'};
    return {turn: {id: 'turn'}};
  };
  await session.prompt('First', {model: 'chosen', effort: 'high'});
  await session.prompt('Keep selection');
  await session.prompt('Reset', {model: null, effort: null});
  const starts = calls.filter(call => call.method === 'turn/start');
  assert.equal(calls[0].params.model, undefined);
  assert.equal(starts[1].params.model, 'chosen');
  assert.equal(starts[1].params.effort, 'high');
  assert.equal(starts[2].params.model, 'native-default');
  assert.equal(starts[2].params.effort, 'medium');
});

test('Claude null clears overrides, while omitted selections preserve them', async () => {
  const calls = [], events = [];
  const session = new ClaudeSession({cwd: '/project', emit: event => events.push(event)});
  session.query = request => {
    calls.push(request.options);
    return {async *[Symbol.asyncIterator]() { yield {type: 'result', is_error: false}; }, close() {}};
  };
  await session.prompt('First', {model: 'chosen', effort: 'high'});
  await session.prompt('Keep selection');
  await session.prompt('Reset', {model: null, effort: null});
  assert.equal(calls[1].model, 'chosen');
  assert.equal(calls[1].effort, 'high');
  assert.equal(calls[2].model, undefined);
  assert.equal(calls[2].effort, undefined);
  assert.equal(events.filter(event => event.type === 'status').at(-1).model, undefined);
});

test('a rejected Codex turn does not leave the adapter busy', async () => {
  const session = new CodexSession({cwd: '/project', emit: () => {}});
  session.threadId = 'native';
  session.call = async () => { throw new Error('Model unavailable'); };
  await assert.rejects(session.prompt('Hello'), /Model unavailable/);
  assert.equal(session.inTurn, false);
});

test('Codex uses its native index and scans older rollouts only for explicit recovery', async () => {
  const session = new CodexSession({cwd: '/project', emit: () => {}});
  const calls = [];
  session.call = async (method, input) => {
    assert.equal(method, 'thread/list');
    calls.push(input);
    return {data: [], nextCursor: null};
  };
  await session.listSessions({scope: 'project'});
  await session.listSessions({scope: 'project', repair: true});
  await session.listSessions({scope: 'project', repair: true, cursor: 'next-page'});
  assert.equal(calls[0].useStateDbOnly, true);
  assert.equal(calls[0].cwd, '/project');
  assert.equal(calls[1].useStateDbOnly, false);
  assert.equal(calls[2].useStateDbOnly, false, 'Explicit recovery pages must keep discovering unindexed rollouts');
  assert.equal(calls[2].cursor, 'next-page');
});

test('history cursors preserve source and scope while ordinary refresh returns to the index', () => {
  assert.equal(historyQuery({scope: 'project'}, '/project').source, 'native-index');
  assert.equal(historyQuery({scope: 'project', repair: true}, '/project').repair, true);
  const cursor = Buffer.from(JSON.stringify({scope: 'project', cwd: '/project', source: 'native-repair', codex: 'page-2', claude: false})).toString('base64url');
  const next = historyQuery({scope: 'project', cursor}, '/project');
  assert.equal(next.source, 'native-repair');
  assert.equal(next.repair, true);
  assert.equal(next.cursors.codex, 'page-2');
  assert.throws(() => historyQuery({scope: 'all', cursor}, '/project'), /scope changed/);
  assert.throws(() => historyQuery({scope: 'project', cursor}, '/different'), /project changed/);
  assert.throws(() => historyQuery({cursor: 'not-a-cursor'}, '/project'), /Invalid history cursor/);
  assert.equal(historyQuery({scope: 'project'}, '/project').repair, false);
});

test('Claude refuses to resume without the native working directory', async () => {
  const session = new ClaudeSession({cwd: '/current-project', emit: () => {}});
  let readMessages = false;
  session.sdk = {
    getSessionInfo: async () => ({sessionId: 'other-project'}),
    getSessionMessages: async () => { readMessages = true; return []; },
  };
  await assert.rejects(session.resumeSession('other-project'), /working directory/);
  assert.equal(session.cwd, '/current-project');
  assert.equal(session.sessionId, undefined);
  assert.equal(readMessages, false);
});

test('Pi history follows the active branch and pairs tool results', async () => {
  const {piHistory, piSessionTitle, piUsage} = await import('./provider-data.mjs');
  const entries = [
    {type: 'session', id: 's', cwd: '/tmp'},
    {type: 'model_change', id: 'a', parentId: null, provider: 'anthropic', modelId: 'm1'},
    {type: 'message', id: 'b', parentId: 'a', message: {role: 'user', content: 'abandoned'}},
    {type: 'message', id: 'c', parentId: 'a', message: {role: 'user', content: [{type: 'text', text: 'hello'}]}},
    {type: 'message', id: 'd', parentId: 'c', message: {role: 'assistant', content: [
      {type: 'thinking', thinking: 'x'}, {type: 'text', text: 'Looking'}, {type: 'toolCall', id: 't1', name: 'bash', arguments: {command: 'ls'}}]}},
    {type: 'message', id: 'e', parentId: 'd', message: {role: 'toolResult', toolCallId: 't1', content: [{type: 'text', text: 'out'}], isError: true}},
    {type: 'message', id: 'f', parentId: 'e', message: {role: 'assistant', content: [{type: 'text', text: 'Done'}]}},
  ];
  const history = piHistory(entries);
  assert.equal(history.model, 'anthropic/m1');
  assert.deepEqual(history.messages, [
    {role: 'user', text: 'hello', editId: 'c'},
    {role: 'assistant', text: 'Looking', activities: [{type: 'activity', id: 't1', title: 'bash · ls', detail: 'out', status: 'failed'}]},
    {role: 'assistant', text: 'Done', activities: []},
  ]);
  assert.equal(piSessionTitle(entries), 'abandoned');
  assert.equal(piSessionTitle([...entries, {type: 'session_info', id: 'g', parentId: 'f', name: 'Named'}]), 'Named');
  assert.equal(resumeCommand('pi', 'id-1', '/tmp', '/bin/pi'), "cd '/tmp' && '/bin/pi' --session 'id-1'");
  assert.deepEqual(piUsage([{input: 10, output: 2, cacheRead: 5, cacheWrite: 1, totalTokens: 18, cost: {total: 0.5}}], 1000),
    {type: 'usage', inputTokens: 16, outputTokens: 2, cachedInputTokens: 5, contextTokens: 18, contextWindow: 1000, costUSD: 0.5, scope: 'turn'});
});

test('readImages encodes supported image files and rejects others', async () => {
  const {readImages} = await import('./provider-data.mjs');
  const {mkdtemp, writeFile} = await import('node:fs/promises');
  const {tmpdir} = await import('node:os');
  const {join} = await import('node:path');
  const dir = await mkdtemp(join(tmpdir(), 'rex-images-'));
  await writeFile(join(dir, 'a.PNG'), 'png-bytes');
  assert.deepEqual(readImages([join(dir, 'a.PNG')]), [{data: Buffer.from('png-bytes').toString('base64'), mimeType: 'image/png'}]);
  assert.throws(() => readImages([join(dir, 'a.txt')]), /Unsupported image type/);
});

test('history marks user messages with edit points and editIndex locates them', async () => {
  const {editIndex} = await import('./provider-data.mjs');
  assert.equal(codexHistory([{turnId: 't1', item: {type: 'userMessage', content: [{type: 'text', text: 'hi'}]}}])[0].editId, 't1');
  assert.equal(claudeHistory([{type: 'user', uuid: 'u1', message: {content: 'hi'}}])[0].editId, 'u1');
  const users = [{text: 'first'}, {text: 'same'}, {text: 'look\n[Image attachment]'}];
  assert.equal(editIndex(users, 2, 'look\n[Image: pasted.png]'), 2);
  assert.equal(editIndex(users, 5, 'first'), 0);
  assert.throws(() => editIndex([{text: 'same'}, {text: 'same'}], 3, 'same'), /Could not find/);
  assert.throws(() => editIndex(users, 0, 'missing'), /Could not find/);
});

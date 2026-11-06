import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { PaneState } from './pane-state.mjs';

test('JSONL bridge restores native sessions, applies settings, handles approval, and interrupts', {timeout: 10000}, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'rex-bridge-test-'));
  const paneKey = `test/${dir}`;
  const saved = new PaneState(paneKey);
  let restored;
  const executable = join(dir, 'codex');
  const starts = join(dir, 'provider-starts');
  await writeFile(executable, `#!/usr/bin/env node
const readline = require('node:readline');
require('node:fs').appendFileSync(${JSON.stringify(starts)}, 'started\\n');
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
let turn = 0;
const finish = text => {
  if (text) {
    send({method:'item/agentMessage/delta',params:{itemId:'message-'+turn,delta:text}});
    send({method:'item/completed',params:{item:{type:'agentMessage',id:'message-'+turn,text}}});
  }
  send({method:'turn/completed',params:{turn:{id:String(turn),status:'completed'}}});
};
readline.createInterface({input:process.stdin}).on('line', line => {
  const m = JSON.parse(line);
  if (m.method === 'initialize') send({id:m.id,result:{}});
  if (m.method === 'model/list' || m.method === 'skills/list') send({id:m.id,result:{data:[]}});
  if (m.method === 'thread/start') send({id:m.id,result:{thread:{id:'conversation-1'},model:'default-model',reasoningEffort:'medium'}});
  if (m.method === 'thread/read') {
    if (m.params.threadId === 'gone-session') send({id:m.id,error:{message:'Session unavailable'}});
    else send({id:m.id,result:{thread:{id:m.params.threadId,cwd:process.cwd(),turns:[{items:[{id:'old-user',type:'userMessage',content:[{type:'text',text:'Saved CLI prompt'}]},{id:'old-answer',type:'agentMessage',text:'Saved CLI answer'}]}]}}});
  }
  if (m.method === 'thread/resume') send({id:m.id,result:{thread:{id:m.params.threadId,cwd:process.cwd()},model:'saved-model',reasoningEffort:'medium'}});
  if (m.method === 'turn/start') {
    turn++;
    send({id:m.id,result:{turn:{id:String(turn)}}});
    const text = m.params.input[0].text;
    if (text === 'approval') send({id:'approval-1',method:'item/commandExecution/requestApproval',params:{command:'echo test',itemId:'tool-1'}});
    else if (text === 'settings') finish(m.params.model + ':' + m.params.effort);
    else if (text !== 'wait') finish('Reply '+turn);
  }
  if (m.id === 'approval-1' && m.result) finish(m.result.decision);
  if (m.method === 'turn/interrupt') {
    send({id:m.id,result:{}});
    send({method:'turn/completed',params:{turn:{id:String(turn),status:'interrupted'}}});
  }
});
`);
  await chmod(executable, 0o755);
  const args = ['bridge/main.mjs', '--provider', 'codex', '--cwd', dir, '--pane', paneKey];
  const options = {
    cwd: new URL('..', import.meta.url),
    env: {...process.env, PATH: `${dir}:${process.env.PATH}`},
  };
  const proc = spawn(process.execPath, args, options);
  const events = [];
  let stderr = '';
  proc.stderr.on('data', data => { stderr += data; });
  const lines = createInterface({input: proc.stdout});
  lines.on('line', line => events.push(JSON.parse(line)));
  const send = message => proc.stdin.write(JSON.stringify(message) + '\n');
  const wait = async (predicate, child = proc, received = events) => {
    const deadline = Date.now() + 3000;
    while (!predicate()) {
      if (child.exitCode !== null || Date.now() > deadline) {
        throw new Error(`Bridge stopped or timed out: ${stderr}\n${JSON.stringify(received)}`);
      }
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  };
  try {
    await wait(() => events.some(e => e.type === 'ready'));
    send({type:'prompt',text:'hello'});
    await wait(() => events.filter(e => e.type === 'done').length === 1);
    send({type:'prompt',text:'followup'});
    await wait(() => events.filter(e => e.type === 'done').length === 2);
    assert.equal(events.filter(e => e.type === 'session').length, 1);
    assert.deepEqual(events.filter(e => e.type === 'delta').map(e => e.text), ['Reply 1','Reply 2']);
    send({type:'prompt',text:'approval'});
    await wait(() => events.some(e => e.type === 'approval'));
    send({type:'approval',requestId:'approval-1',decision:'decline'});
    await wait(() => events.filter(e => e.type === 'done').length === 3);
    assert.equal(events.filter(e => e.type === 'delta').at(-1).text, 'decline');
    send({type:'prompt',text:'wait'});
    send({type:'new',provider:'codex'});
    await wait(() => events.some(e => e.type === 'error' && e.operation === 'new'));
    send({type:'stop'});
    await wait(() => events.filter(e => e.type === 'done').length === 4);
    assert.equal(events.filter(e => e.type === 'done').at(-1).status, 'interrupted');
    send({type:'resume',provider:'codex',sessionId:'native-cli-session'});
    await wait(() => events.filter(e => e.type === 'ready').length === 2);
    const loaded = events.filter(e => e.type === 'conversation').at(-1);
    assert.equal(loaded.sessionId, 'native-cli-session');
    assert.deepEqual(loaded.messages.map(m => m.text), ['Saved CLI prompt', 'Saved CLI answer']);
    send({type:'configure',model:'chosen-model',effort:'high'});
    await wait(() => events.some(e => e.type === 'configured'));
    send({type:'prompt',text:'settings'});
    await wait(() => events.filter(e => e.type === 'done').length === 5);
    assert.equal(events.filter(e => e.type === 'delta').at(-1).text, 'chosen-model:high');
    const exited = once(proc, 'exit');
    send({type:'close'});
    await exited;
    assert.equal(proc.exitCode, 0);
    restored = spawn(process.execPath, args, options);
    const restoredEvents = [];
    createInterface({input: restored.stdout}).on('line', line => restoredEvents.push(JSON.parse(line)));
    restored.stderr.on('data', data => { stderr += data; });
    await wait(() => restoredEvents.some(e => e.type === 'ready'), restored, restoredEvents);
    const reopened = restoredEvents.find(e => e.type === 'conversation');
    assert.equal(reopened.sessionId, 'native-cli-session');
    assert.equal(reopened.model, 'chosen-model');
    assert.equal(reopened.effort, 'high');
    assert.equal(reopened.messages[1].text, 'Saved CLI answer');
    const startsBeforeReselect = await readFile(starts, 'utf8');
    restored.stdin.write(JSON.stringify({type:'resume',provider:'codex',sessionId:'native-cli-session'}) + '\n');
    await wait(() => restoredEvents.filter(e => e.type === 'ready').length === 2, restored, restoredEvents);
    assert.equal(await readFile(starts, 'utf8'), startsBeforeReselect, 'Reselecting the restored session must keep its existing provider/writer');
    assert.equal(restoredEvents.filter(e => e.type === 'conversation').length, 1, 'Reselecting must preserve the current transcript');
    assert.equal(saved.read().model, 'chosen-model');
    assert.equal(saved.read().effort, 'high');
    const restoredExit = once(restored, 'exit');
    restored.stdin.write(JSON.stringify({type:'close'}) + '\n');
    await restoredExit;
    assert.equal(restored.exitCode, 0);
    saved.write({provider:'codex',sessionId:'gone-session',cwd:dir});
    restored = spawn(process.execPath, args, options);
    const recoveryEvents = [];
    createInterface({input:restored.stdout}).on('line', line => recoveryEvents.push(JSON.parse(line)));
    await wait(() => recoveryEvents.some(e => e.type === 'ready'), restored, recoveryEvents);
    assert(recoveryEvents.some(e => e.type === 'error' && e.operation === 'restore'));
    assert.equal(saved.read().sessionId, 'gone-session', 'A failed restore must not erase the saved association');
    restored.stdin.write(JSON.stringify({type:'new',provider:'codex'}) + '\n');
    await wait(() => recoveryEvents.filter(e => e.type === 'ready').length === 2, restored, recoveryEvents);
    assert.equal(saved.read().sessionId, null, 'Explicit New replaces the saved association');
    const recoveryExit = once(restored, 'exit');
    restored.stdin.write(JSON.stringify({type:'close'}) + '\n');
    await recoveryExit;
  } finally {
    proc.kill('SIGTERM');
    restored?.kill('SIGTERM');
    lines.close();
    await rm(saved.file, {force: true});
    await rm(dir, {recursive:true, force:true});
  }
});

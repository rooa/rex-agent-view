import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, statSync, existsSync, symlinkSync, lstatSync, utimesSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const installer = join(repo, 'scripts/install-actions.mjs');
const original = '-- Personal settings\nrex.bind("cmd+d", "pane.split")\n';

function fixture(t, extra = {}) {
  const base = mkdtempSync(join(tmpdir(), 'rex-agent-actions-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, 'project with ]] and "quotes"');
  mkdirSync(join(root, 'rex'), { recursive: true });
  writeFileSync(join(root, 'rex/agent-view.lua'), 'rex.action{name="rex_agent_new_pane",title="New Agent Pane",run=function() end}\n');
  const config = join(base, 'config/init.lua');
  mkdirSync(dirname(config));
  writeFileSync(config, original, { mode: 0o640 });
  const state = join(base, 'state.json');
  writeFileSync(state, JSON.stringify({ config, reloads: [], checks: [], ...extra }));
  const rex = join(base, 'rex');
  writeFileSync(rex, `#!${process.execPath}
const fs = require('node:fs'), path = require('node:path');
const statePath = path.join(__dirname, 'state.json');
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const args = process.argv.slice(2);
const save = () => fs.writeFileSync(statePath, JSON.stringify(state));
const print = value => process.stdout.write(JSON.stringify(value));
if (args[0] === 'server' && args[1] === 'status') print({ endpoint: state.endpoint || 'unix:///fake.sock' });
else if (args[0] === 'api' && args[2] === 'client.keymap') print({ config: { path: state.config } });
else if (args[0] === 'config' && args[1] === 'check') {
  if (path.dirname(args[2]) !== path.dirname(state.config)) throw Error('Candidate must preserve relative require paths');
  state.checks.push(fs.readFileSync(args[2], 'utf8')); save();
  print({ actions: [{name:'rex_agent_new_pane'}], diagnostics: state.failCheck ? [{severity:'error',message:'invalid candidate'}] : [] });
} else if (args[0] === 'config' && args[1] === 'reload') {
  state.reloads.push(fs.existsSync(state.config) ? fs.readFileSync(state.config, 'utf8') : null); save();
  print({ diagnostics: state.failReload && state.reloads.length === 1 ? [{severity:'error',message:'reload rejected'}] : [] });
} else throw Error('Unexpected command: ' + JSON.stringify(args));
`, { mode: 0o700 });
  return { root, config, rex, state: () => JSON.parse(readFileSync(state, 'utf8')) };
}

async function install(options) {
  assert.ok(existsSync(installer), 'The palette-action installer has not been implemented');
  return (await import(pathToFileURL(installer))).installActions(options);
}

test('installs one managed action loader and preserves personal config and mode', async t => {
  const f = fixture(t);
  const result = await install(f);
  const text = readFileSync(f.config, 'utf8');
  assert.ok(text.startsWith(original));
  assert.match(text, /-- BEGIN rex-agent-view\n/);
  assert.match(text, /dofile\(\[=\[/);
  assert.ok(text.includes(join(f.root, 'rex/agent-view.lua')));
  assert.equal(statSync(f.config).mode & 0o777, 0o640);
  assert.equal(result.configPath, f.config);
  assert.equal(result.changed, true);
  assert.equal(f.state().checks.length, 1);
  assert.deepEqual(f.state().reloads, [text]);
  utimesSync(f.config, 1, 1);
  const repeated = await install(f);
  assert.equal(readFileSync(f.config, 'utf8'), text);
  assert.equal(statSync(f.config).mtimeMs, 1000);
  assert.equal(repeated.changed, false);
});

test('updates only its existing managed block after a checkout moves', async t => {
  const f = fixture(t);
  const suffix = '\n-- User content after the integration\nrex.bind("cmd+t", "client.tab.new")\n';
  writeFileSync(f.config, original + '-- BEGIN rex-agent-view\ndofile([[old/path.lua]])\n-- END rex-agent-view\n' + suffix);
  await install(f);
  const text = readFileSync(f.config, 'utf8');
  assert.ok(text.startsWith(original));
  assert.ok(text.endsWith(suffix));
  assert.equal(text.match(/-- BEGIN rex-agent-view/g).length, 1);
  assert.ok(!text.includes('old/path.lua'));
});

test('validation failure leaves the original file and running config alone', async t => {
  const f = fixture(t, { failCheck: true });
  await assert.rejects(install(f), /invalid candidate/);
  assert.equal(readFileSync(f.config, 'utf8'), original);
  assert.deepEqual(f.state().reloads, []);
});

test('reload failure restores both original bytes and running config', async t => {
  const f = fixture(t, { failReload: true });
  await assert.rejects(install(f), /reload rejected/);
  assert.equal(readFileSync(f.config, 'utf8'), original);
  assert.equal(f.state().reloads.length, 2);
  assert.equal(f.state().reloads[1], original);
});

test('rollback removes a newly created config and preserves symlinked configs', async t => {
  const f = fixture(t, { failReload: true });
  rmSync(f.config);
  await assert.rejects(install(f), /reload rejected/);
  assert.equal(existsSync(f.config), false);
  assert.equal(f.state().reloads[1], null);
  const g = fixture(t);
  const target = join(dirname(g.config), 'real-init.lua');
  writeFileSync(target, original);
  rmSync(g.config);
  symlinkSync(target, g.config);
  await install(g);
  assert.ok(lstatSync(g.config).isSymbolicLink());
  assert.match(readFileSync(target, 'utf8'), /-- BEGIN rex-agent-view/);
});

test('refuses malformed markers and a remote server before changing config', async t => {
  const f = fixture(t);
  writeFileSync(f.config, original + '-- BEGIN rex-agent-view\n');
  await assert.rejects(install(f), /managed block/);
  assert.equal(readFileSync(f.config, 'utf8'), original + '-- BEGIN rex-agent-view\n');
  const g = fixture(t, { endpoint: 'tcp://example.test:7777' });
  await assert.rejects(install(g), /local Rex server/);
  assert.equal(readFileSync(g.config, 'utf8'), original);
});

test('Lua action is app-scoped and uses current session, block, and directory', () => {
  const source = join(repo, 'rex/agent-view.lua');
  assert.ok(existsSync(source), 'The New Agent Pane action has not been implemented');
  const result = spawnSync(process.env.REX_AGENT_CLI || 'rex', ['do', join(repo, 'scripts/check-actions.lua'), `source=${source}`, '--json'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(JSON.parse(result.stdout).passed, true);
});

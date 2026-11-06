#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export REX_AGENT_ROOT="$project_dir"
export REX_AGENT_CLI="$(command -v rex)"
export REX_AGENT_NODE="$(command -v node)"
node scripts/install-actions.mjs >/dev/null
defaults write com.superlogical.rex.agent.experimental rex.client.remoteControl -bool true
node --input-type=module - "$@" <<'JS'
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { setTimeout } from 'node:timers/promises';
const root = process.env.REX_AGENT_ROOT;
const rex = process.env.REX_AGENT_CLI;
const run = args => {
  const result = spawnSync(rex, args, { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || 'Rex command failed');
  return result.stdout ? JSON.parse(result.stdout) : {};
};
const list = run(['ls', '--json']);
const sessions = list.sessions || [];
let session = sessions.find(x => x.label === 'rex-agent');
if (!session) {
  const made = run(['new', 'rex-agent', '-c', root, '--json']);
  session = { session_id: made.session_id };
}
const view = run(['session', 'inspect', session.session_id, '--json']);
let window = view.windows.find(w => w.label === 'Agent Workspace');
if (!window) {
  const made = run(['window', 'new', '-s', session.session_id, 'Agent Workspace', '-c', root, '--keep-open', '--json', '--', '/usr/bin/tail', '-f', '/dev/null']);
  window = { window_id: made.window_id, focused_block_id: made.block_ids[0] };
  run(['block', 'rename', '-s', session.session_id, made.block_ids[0], 'rex-agent:Agent']);
}
const env = { ...process.env, REX_AGENT_SESSION: session.session_id, REX_AGENT_WINDOW: window.window_id };
writeFileSync(root + '/build/launch-context.json', JSON.stringify({ sessionID: session.session_id, windowID: window.window_id }, null, 2));
const previous = new Set(run(['client', 'ls', '--json']).clients.map(x => x.client_id));
// LaunchServices creates the app's native window and passes only this copy's
// integration environment. Direct executable launches do not open a Rex window.
const variables = ['REX_AGENT_ROOT', 'REX_AGENT_CLI', 'REX_AGENT_NODE', 'REX_AGENT_SESSION', 'REX_AGENT_WINDOW', 'PATH'];
if (env.REX_AGENT_CLAUDE) variables.push('REX_AGENT_CLAUDE');
if (env.REX_AGENT_PI) variables.push('REX_AGENT_PI');
const opened = spawnSync('/usr/bin/open', ['-n', '-a', root + '/build/Rex Agent View.app', ...variables.flatMap(key => ['--env', `${key}=${env[key]}`])], { encoding: 'utf8' });
if (opened.status !== 0) throw new Error(opened.stderr || 'Could not open the experimental Rex window');
let selectedClient;
let pid;
let lastError;
for (let attempt = 0; attempt < 30; attempt++) {
  await setTimeout(300);
  const client = run(['client', 'ls', '--json']).clients.find(x => !previous.has(x.client_id) && x.info?.name === 'Rex Agent View' && x.connection_state === 'connected');
  if (client) {
    try {
      run(['-C', client.client_id, 'do', 'session.select', `session_id=${session.session_id}`, `window_id=${window.window_id}`]);
      selectedClient = client.client_id;
      pid = client.principal.pid;
      break;
    } catch (error) { lastError = error; }
  }
}
if (!selectedClient) throw new Error(`Experimental Rex did not select its workspace: ${lastError?.message || 'no connected app client after 9 seconds'}`);
console.log(JSON.stringify({ pid, clientID: selectedClient, sessionID: session.session_id, windowID: window.window_id }));
JS

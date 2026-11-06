import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync, realpathSync, renameSync, rmSync } from 'node:fs';
import { dirname, resolve, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function installActions({ root = projectRoot, rex = process.env.REX_AGENT_CLI || 'rex' } = {}) {
  const run = args => {
    const result = spawnSync(rex, args, { encoding: 'utf8', timeout: 15000 });
    if (result.error || result.status !== 0) throw new Error((result.stderr || result.stdout || result.error?.message || 'Rex command failed').trim());
    const value = JSON.parse(result.stdout);
    const errors = (value.diagnostics || []).filter(item => item.severity === 'error');
    if (errors.length) throw new Error(errors.map(item => item.message).join('\n'));
    return value;
  };
  const status = run(['server', 'status', '--json']);
  if (!status.endpoint?.startsWith('unix://')) throw new Error('Install the Agent action through a local Rex server.');
  const keymap = run(['api', 'call', 'client.keymap', '{"server_actions":"configured"}']);
  const configPath = keymap.config?.path;
  if (!configPath || !isAbsolute(configPath)) throw new Error('Rex did not report an absolute configuration path.');
  const source = resolve(root, 'rex/agent-view.lua');
  if (!existsSync(source)) throw new Error(`Missing Agent action: ${source}`);
  const original = existsSync(configPath) ? readFileSync(configPath, 'utf8') : null;
  const target = original === null ? configPath : realpathSync(configPath);
  const mode = original === null ? 0o600 : statSync(target).mode & 0o777;
  const text = original ?? '';
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  let equals = '';
  while (source.includes(']' + equals + ']')) equals += '=';
  const block = ['-- BEGIN rex-agent-view', `dofile([${equals}[${source}]${equals}])`, '-- END rex-agent-view', ''].join(newline);
  const markers = text.match(/^-- (?:BEGIN|END) rex-agent-view\r?$/gm) || [];
  const pattern = /^-- BEGIN rex-agent-view\r?\n[\s\S]*?^-- END rex-agent-view(?:\r?\n|$)/gm;
  const managed = [...text.matchAll(pattern)];
  if (markers.length && (markers.length !== 2 || managed.length !== 1)) throw new Error('The rex-agent-view managed block is incomplete or duplicated; the config was not changed.');
  const next = managed.length
    ? text.slice(0, managed[0].index) + block + text.slice(managed[0].index + managed[0][0].length)
    : text + (text ? (text.endsWith('\n') ? '' : newline) + newline : '') + block;
  const changed = next !== text;
  mkdirSync(dirname(configPath), { recursive: true, mode: 0o700 });
  const candidate = resolve(dirname(configPath), `.rex-agent-view-check-${randomUUID()}.lua`);
  const replace = content => {
    if (content === null) { rmSync(target, { force: true }); return; }
    const temporary = target + `.rex-agent-view-${randomUUID()}.tmp`;
    try {
      writeFileSync(temporary, content, { flag: 'wx', mode });
      renameSync(temporary, target);
    } finally { rmSync(temporary, { force: true }); }
  };
  let installed = false;
  try {
    writeFileSync(candidate, next, { flag: 'wx', mode: 0o600 });
    const checked = run(['config', 'check', candidate, '--json']);
    if (!(checked.actions || []).some(action => action.name === 'rex_agent_new_pane')) throw new Error('The checked config did not register New Agent Pane.');
    const current = existsSync(configPath) ? readFileSync(configPath, 'utf8') : null;
    if (current !== original) throw new Error('Rex configuration changed during installation; retry after saving your edits.');
    if (changed) { replace(next); installed = true; }
    run(['config', 'reload', '--json']);
    return { configPath, changed };
  } catch (error) {
    if (installed) {
      replace(original);
      try { run(['config', 'reload', '--json']); }
      catch (restoreError) { throw new Error(`${error.message}\nThe original config file was restored, but reloading it failed: ${restoreError.message}`); }
    }
    throw error;
  } finally { rmSync(candidate, { force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = installActions();
    console.log(`New Agent Pane is available in the Rex command palette (${result.configPath}).`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Native provider files own transcripts. This file only remembers what a Rex pane shows.
export class PaneState {
  constructor(key, directory = fileURLToPath(new URL('../.rex-agent/panes/', import.meta.url))) {
    this.file = key ? join(directory, createHash('sha256').update(key).digest('hex') + '.json') : null;
  }

  read() {
    if (!this.file) return null;
    let state;
    try { state = JSON.parse(readFileSync(this.file, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    if (!state || !['codex', 'claude', 'pi'].includes(state.provider) || typeof state.cwd !== 'string'
      || (state.sessionId != null && typeof state.sessionId !== 'string')
      || (state.model != null && typeof state.model !== 'string')
      || (state.effort != null && typeof state.effort !== 'string')) {
      throw new Error('Saved pane configuration is invalid. Start a new conversation to replace it.');
    }
    return state;
  }

  write({provider, sessionId, cwd, model, effort}) {
    if (!this.file) return;
    mkdirSync(dirname(this.file), {recursive: true, mode: 0o700});
    const temporary = `${this.file}.${process.pid}.tmp`;
    writeFileSync(temporary, JSON.stringify({provider, sessionId: sessionId ?? null, cwd,
      model: model ?? null, effort: effort ?? null}, null, 2) + '\n', {mode: 0o600});
    renameSync(temporary, this.file);
  }
}

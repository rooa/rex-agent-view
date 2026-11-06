import { spawn } from 'node:child_process';
import { accessSync, constants, readFileSync } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { TextStream, piActivity, readable } from './events.mjs';
import { claudeSkillPrompt, piHistory, readImages, piSessionTitle, piUsage, resumeCommand, sessionTitle } from './provider-data.mjs';

const levels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
const sessionRoot = () => process.env.PI_CODING_AGENT_SESSION_DIR || join(homedir(), '.pi', 'agent', 'sessions');
const projectDirectory = cwd => `--${cwd.replace(/^[/\\]/, '').replace(/[/\\:]/g, '-')}--`;

export function piEfforts(model) {
  if (!model.reasoning) return [];
  const map = model.thinkingLevelMap || {};
  return levels.filter(level => map[level] !== null && (level in map || !['xhigh', 'max'].includes(level)));
}

export class PiSession {
  constructor({cwd, emit}) {
    this.cwd = cwd;
    this.emit = emit;
    this.text = new TextStream(emit);
    this.pending = new Map();
    this.approvals = new Map();
    this.tools = new Map();
    this.nextId = 1;
  }

  async start(sessionFile) {
    if (!this.executable) {
      let configured = process.env.REX_AGENT_PI;
      if (configured === undefined) {
        try {
          const config = JSON.parse(readFileSync(new URL('../.rex-agent/config.json', import.meta.url), 'utf8'));
          if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('.rex-agent/config.json must contain a JSON object.');
          configured = config.piExecutable;
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
      if (configured !== undefined) {
        if (typeof configured !== 'string' || !configured.trim()) throw new Error('Pi executable must be a non-empty string.');
        try { accessSync(configured, constants.X_OK); }
        catch { throw new Error(`Pi executable is not accessible: ${configured}`); }
        this.executable = configured;
      } else {
        for (const directory of (process.env.PATH || '').split(':')) {
          const candidate = join(directory, 'pi');
          try { accessSync(candidate, constants.X_OK); this.executable = candidate; break; } catch {}
        }
      }
      if (!this.executable) throw new Error('Pi CLI was not found on PATH. Install pi and sign in first.');
    }
    const args = ['--mode', 'rpc', ...(sessionFile ? ['--session', sessionFile] : [])];
    const child = spawn(this.executable, args, {cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe']});
    this.process = child;
    let stderr = '';
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-4000); });
    child.stdin.on('error', () => {});
    child.on('error', error => this.failed(error));
    child.on('exit', (code, signal) => {
      if (!this.closing && this.process === child) this.failed(new Error(`Pi exited (${signal || code}). ${stderr.trim()}`));
    });
    // Pi's protocol splits only on LF; readline would also split on U+2028/U+2029.
    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index).replace(/\r$/, '');
        buffer = buffer.slice(index + 1);
        if (!line.trim()) continue;
        try { this.receive(JSON.parse(line)); }
        catch (error) { this.emit({type: 'error', message: `Invalid Pi event: ${error.message}`}); }
      }
    });
    const state = await this.call('get_state');
    this.applyState(state);
    this.started = true;
  }

  applyState(state) {
    if (state.model) {
      this.model = `${state.model.provider}/${state.model.id}`;
      this.contextWindow = state.model.contextWindow ?? null;
    }
    this.effort = state.thinkingLevel;
  }

  async getCatalog() {
    if (this.catalog) return this.catalog;
    const [{models}, {commands}] = await Promise.all([this.call('get_available_models'), this.call('get_commands')]);
    this.catalog = {
      models: models.map(model => ({id: `${model.provider}/${model.id}`, label: model.name || model.id,
        efforts: piEfforts(model)})),
      // Skills and prompt templates work in any client; many extension commands assume Pi's TUI.
      skills: commands.map((command, index) => ({command, index}))
        .sort((a, b) => (a.command.source === 'extension') - (b.command.source === 'extension') || a.index - b.index)
        .map(({command}) => ({name: command.name, description: command.description, insertText: `/${command.name} `})),
    };
    return this.catalog;
  }

  async sessionFiles(scope) {
    const root = sessionRoot();
    const directories = scope === 'project' ? [projectDirectory(this.cwd)]
      : (await readdir(root, {withFileTypes: true}).catch(() => [])).filter(entry => entry.isDirectory()).map(entry => entry.name);
    const files = [];
    for (const directory of directories) {
      const names = await readdir(join(root, directory)).catch(() => []);
      for (const name of names.filter(name => name.endsWith('.jsonl'))) {
        const path = join(root, directory, name);
        try { files.push({path, updatedAt: (await stat(path)).mtimeMs}); } catch {}
      }
    }
    return files.sort((a, b) => b.updatedAt - a.updatedAt);
  }

  async readEntries(path) {
    return (await readFile(path, 'utf8')).split('\n').filter(line => line.trim()).flatMap(line => {
      try { return [JSON.parse(line)]; } catch { return []; }
    });
  }

  async listSessions({scope = 'project', limit = 50, cursor} = {}) {
    const offset = Number(cursor || 0);
    if (!Number.isInteger(offset) || offset < 0) throw new Error('Invalid Pi history cursor.');
    const files = await this.sessionFiles(scope);
    const sessions = [];
    for (const file of files.slice(offset, offset + limit)) {
      const entries = await this.readEntries(file.path);
      const header = entries[0];
      if (header?.type !== 'session') continue;
      sessions.push({id: header.id, provider: 'pi', title: sessionTitle(piSessionTitle(entries)),
        cwd: header.cwd || '', updatedAt: file.updatedAt});
    }
    return {sessions, nextCursor: files.length > offset + limit ? String(offset + limit) : null};
  }

  async findSession(id) {
    for (const file of await this.sessionFiles('all')) {
      if (file.path.endsWith(`_${id}.jsonl`)) return file.path;
    }
    throw new Error('Pi session was not found.');
  }

  async readSession(id) {
    const path = await this.findSession(id);
    const entries = await this.readEntries(path);
    const cwd = entries[0]?.cwd;
    if (!cwd) throw new Error('Pi could not recover this session’s original working directory.');
    return {sessionId: id, cwd, path, ...piHistory(entries), resumeCommand: resumeCommand('pi', id, cwd, this.executable)};
  }

  async resumeSession(id) {
    if (this.inTurn) throw new Error('Stop the current turn before resuming another session.');
    const {path, ...history} = await this.readSession(id);
    // Pi runs a session in its recorded directory, so restart the RPC process there.
    await this.stopProcess();
    this.closing = false;
    this.cwd = history.cwd;
    this.sessionId = id;
    this.catalog = null;
    await this.start(path);
    this.modelOverride = undefined;
    this.effortOverride = undefined;
    return {...history, model: this.model, effort: this.effort};
  }

  // Pi's own fork: a new session holding the active branch before this user entry.
  async forkBefore(users, index) {
    if (index === 0) return null;
    const result = await this.call('fork', {entryId: users[index].editId});
    if (result.cancelled) throw new Error('A Pi extension cancelled the fork.');
    const state = await this.call('get_state');
    return state.sessionId;
  }

  send(message) {
    if (!this.process?.stdin.writable) throw new Error('Pi connection is closed. Start a new session.');
    this.process.stdin.write(JSON.stringify(message) + '\n');
  }

  call(type, params = {}) {
    const id = `rex-${this.nextId++}`;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Pi did not answer ${type} within 60 seconds.`));
      }, 60000);
      this.pending.set(id, {resolve, reject, timeout});
      try { this.send({id, type, ...params}); }
      catch (error) { clearTimeout(timeout); this.pending.delete(id); reject(error); }
    });
  }

  receive(event) {
    if (event.type === 'response') {
      const pending = this.pending.get(event.id);
      if (!pending) return;
      clearTimeout(pending.timeout);
      this.pending.delete(event.id);
      if (event.success) pending.resolve(event.data ?? {});
      else pending.reject(new Error(event.error || `Pi rejected ${event.command}.`));
      return;
    }
    if (event.type === 'extension_ui_request') {
      if (event.method === 'confirm') {
        this.approvals.set(event.id, null);
        this.emit({type: 'approval', requestId: event.id, title: event.title || 'Confirm?', detail: event.message || ''});
        this.emit({type: 'status', state: 'waiting'});
      } else if (event.method === 'select' && Array.isArray(event.options) && event.options.length) {
        this.approvals.set(event.id, event.options);
        this.emit({type: 'approval', requestId: event.id, title: event.title || 'Choose an option', detail: '', options: event.options});
        this.emit({type: 'status', state: 'waiting'});
      } else if (['select', 'input', 'editor'].includes(event.method)) {
        this.send({type: 'extension_ui_response', id: event.id, cancelled: true});
        this.emit({type: 'error', message: `Pi requested an unsupported interaction: ${event.method}`});
      } else if (event.method === 'notify' && event.message) {
        this.emit(event.notifyType === 'error' ? {type: 'error', message: event.message} : {type: 'notice', text: event.message});
      }
      return;
    }
    if (!this.inTurn) return;
    switch (event.type) {
      case 'agent_start': this.emit({type: 'status', state: 'running', model: this.model, effort: this.effort}); break;
      case 'message_start':
        if (event.message?.role === 'assistant') this.messageId = `message-${this.nextId++}`;
        break;
      case 'message_update': {
        const update = event.assistantMessageEvent;
        if (update?.type === 'text_delta') this.text.delta(this.messageId, update.delta);
        break;
      }
      case 'message_end': {
        const message = event.message;
        if (message?.role !== 'assistant') break;
        const text = (message.content || []).filter(block => block.type === 'text').map(block => block.text).join('');
        if (text) this.text.complete(this.messageId, text);
        if (message.model) this.model = `${message.provider}/${message.model}`;
        if (message.usage) this.turnUsage.push(message.usage);
        if (message.stopReason === 'error' && message.errorMessage) this.lastError = message.errorMessage;
        break;
      }
      case 'tool_execution_start': {
        const activity = piActivity({id: event.toolCallId, name: event.toolName, arguments: event.args});
        this.tools.set(activity.id, activity);
        this.emit(activity);
        break;
      }
      case 'tool_execution_update':
      case 'tool_execution_end': {
        const result = event.type === 'tool_execution_end' ? event.result : event.partialResult;
        const tool = this.tools.get(event.toolCallId) || piActivity({id: event.toolCallId, name: event.toolName, arguments: event.args});
        const output = (result?.content || []).map(block => block.text || '').join('\n');
        this.emit({...tool, detail: readable(output || tool.detail),
          status: event.type === 'tool_execution_update' ? 'running' : event.isError ? 'failed' : 'completed'});
        break;
      }
      case 'compaction_start': this.emit({type: 'status', state: 'compacting'}); break;
      case 'compaction_end': this.emit({type: 'status', state: 'running'}); break;
      case 'auto_retry_start':
        this.emit({type: 'activity', id: 'pi-connection', title: 'Retrying Pi request',
          detail: `${event.errorMessage || 'Connection error'} · attempt ${event.attempt || 1}`, status: 'running'});
        break;
      case 'auto_retry_end':
        this.emit({type: 'activity', id: 'pi-connection', title: 'Retrying Pi request',
          detail: event.success ? 'Recovered' : event.finalError || 'Retry failed', status: event.success ? 'completed' : 'failed'});
        break;
      case 'agent_settled': this.finish(event.aborted || this.stopped ? 'interrupted' : this.lastError ? 'failed' : 'completed'); break;
    }
  }

  finish(status) {
    if (!this.inTurn) return;
    this.inTurn = false;
    this.clearApprovals();
    if (this.lastError && status === 'failed') this.emit({type: 'error', message: this.lastError});
    if (this.turnUsage.length) this.emit(piUsage(this.turnUsage, this.contextWindow));
    this.emit({type: 'done', status});
  }

  async prompt(prompt, options = {}) {
    this.stopped = false;
    if (options.skills?.length && !this.catalog) await this.getCatalog();
    prompt = claudeSkillPrompt(prompt, options.skills, this.catalog?.skills, 'Pi');
    if (this.stopped) { this.emit({type: 'done', status: 'interrupted'}); return; }
    const images = readImages(options.images).map(image => ({type: 'image', ...image}));
    this.text.reset();
    this.tools.clear();
    this.turnUsage = [];
    this.lastError = null;
    if (options.model !== undefined) this.modelOverride = options.model || undefined;
    if (options.effort !== undefined) this.effortOverride = options.effort || undefined;
    if (this.modelOverride && this.modelOverride !== this.model) {
      const slash = this.modelOverride.indexOf('/');
      const model = await this.call('set_model', {provider: this.modelOverride.slice(0, slash), modelId: this.modelOverride.slice(slash + 1)});
      this.model = this.modelOverride;
      this.contextWindow = model.contextWindow ?? this.contextWindow;
    }
    if (this.effortOverride && this.effortOverride !== this.effort) {
      await this.call('set_thinking_level', {level: this.effortOverride});
      this.effort = this.effortOverride;
    }
    this.emit({type: 'status', state: 'requesting', model: this.model, effort: this.effort});
    if (this.stopped) { this.emit({type: 'done', status: 'interrupted'}); return; }
    this.inTurn = true;
    try {
      const result = await this.call('prompt', {message: prompt, ...(images.length ? {images} : {})});
      if (!this.sessionId) {
        const state = await this.call('get_state');
        if (state.sessionId) {
          this.sessionId = state.sessionId;
          this.emit({type: 'session', sessionId: this.sessionId, cwd: this.cwd});
        }
      }
      if (result.disposition === 'handled') this.finish('completed');
    } catch (error) {
      this.inTurn = false;
      throw error;
    }
  }

  approve(requestId, decision, value) {
    if (!this.approvals.has(requestId)) throw new Error('That approval is no longer pending.');
    const options = this.approvals.get(requestId);
    if (options && decision === 'select' && !options.includes(value)) throw new Error('Choose one of the offered options.');
    this.approvals.delete(requestId);
    this.send(options ? {type: 'extension_ui_response', id: requestId, ...(decision === 'select' ? {value} : {cancelled: true})}
      : {type: 'extension_ui_response', id: requestId, confirmed: decision === 'accept'});
  }

  clearApprovals() {
    for (const id of this.approvals.keys()) {
      try { this.send({type: 'extension_ui_response', id, cancelled: true}); } catch {}
    }
    this.approvals.clear();
  }

  async stop() {
    this.stopped = true;
    this.clearApprovals();
    if (this.inTurn) await this.call('abort');
  }

  failed(error) {
    for (const pending of this.pending.values()) { clearTimeout(pending.timeout); pending.reject(error); }
    this.pending.clear();
    if (this.started && !this.failureReported) {
      this.failureReported = true;
      this.emit({type: 'error', message: error.message});
    }
    if (this.inTurn) {
      this.inTurn = false;
      this.emit({type: 'done', status: 'failed'});
    }
  }

  async stopProcess() {
    this.closing = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timeout); pending.reject(new Error('Session closed.')); }
    this.pending.clear();
    const child = this.process;
    if (!child?.pid || child.exitCode != null || child.signalCode) return;
    await new Promise(resolve => {
      const timeout = setTimeout(() => child.kill('SIGKILL'), 2000);
      child.once('exit', () => { clearTimeout(timeout); resolve(); });
      child.stdin.end();
      child.kill('SIGTERM');
    });
  }

  async close() {
    this.clearApprovals();
    await this.stopProcess();
  }
}

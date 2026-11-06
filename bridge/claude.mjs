import { accessSync, constants, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { TextStream, claudeActivity, readable } from './events.mjs';
import { claudeHistory, claudeSkillPrompt, readImages, claudeUsage, resumeCommand, sessionTitle } from './provider-data.mjs';

export class ClaudeSession {
  constructor({cwd, emit}) {
    this.cwd = cwd;
    this.emit = emit;
    this.text = new TextStream(emit);
    this.approvals = new Map();
    this.tools = new Map();
    this.toolInputs = new Map();
  }

  async start() {
    let configured = process.env.REX_AGENT_CLAUDE;
    if (configured === undefined) {
      try {
        const config = JSON.parse(readFileSync(new URL('../.rex-agent/config.json', import.meta.url), 'utf8'));
        if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('.rex-agent/config.json must contain a JSON object.');
        configured = config.claudeExecutable;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    if (configured !== undefined) {
      if (typeof configured !== 'string' || !configured.trim()) throw new Error('Claude executable must be a non-empty string.');
      try { accessSync(configured, constants.X_OK); }
      catch { throw new Error(`Claude executable is not accessible: ${configured}`); }
      this.executable = configured;
    } else {
      for (const directory of (process.env.PATH || '').split(':')) {
        const candidate = join(directory, 'claude');
        try { accessSync(candidate, constants.X_OK); this.executable = candidate; break; } catch {}
      }
    }
    if (!this.executable) throw new Error('Claude CLI was not found on PATH. Install Claude Code and sign in first.');
    this.sdk = await import('@anthropic-ai/claude-agent-sdk');
    this.query = this.sdk.query;
  }

  queryOptions(extra = {}) {
    const env = {...process.env};
    delete env.CLAUDECODE;
    delete env.CLAUDE_CODE_CHILD_SESSION;
    return {
      cwd: this.cwd, env, pathToClaudeCodeExecutable: this.executable,
      settingSources: ['user', 'project', 'local'],
      permissionMode: 'default', includePartialMessages: true, enableFileCheckpointing: true,
      systemPrompt: {type: 'preset', preset: 'claude_code',
        append: 'When you need clarification, ask in your chat response. This client supports ordinary followup messages but no structured question dialog.'},
      canUseTool: (name, input, options) => this.requestApproval(name, input, options),
      ...extra,
    };
  }

  async getCatalog() {
    if (this.catalog) return this.catalog;
    let release;
    const prompt = {async *[Symbol.asyncIterator]() { await new Promise(resolve => { release = resolve; }); }};
    const discovery = this.query({prompt, options: this.queryOptions({persistSession: false})});
    this.catalogQuery = discovery;
    let timeout;
    try {
      const [commands, models] = await Promise.race([
        Promise.all([discovery.supportedCommands(), discovery.supportedModels()]),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Claude capability discovery timed out.')), 30000); }),
      ]);
      this.catalog = {
        models: models.map(model => ({id: model.value, label: model.displayName,
          resolvedModel: model.resolvedModel, efforts: model.supportedEffortLevels || []})),
        skills: commands.map(command => ({name: command.name, description: command.description,
          argumentHint: command.argumentHint, insertText: `/${command.name} `})),
      };
      return this.catalog;
    } finally {
      clearTimeout(timeout);
      release?.();
      discovery.close();
      if (this.catalogQuery === discovery) this.catalogQuery = null;
    }
  }

  async listSessions({scope = 'project', limit = 50, cursor} = {}) {
    const offset = Number(cursor || 0);
    if (!Number.isInteger(offset) || offset < 0) throw new Error('Invalid Claude history cursor.');
    const page = await this.sdk.listSessions({limit, offset, includeProgrammatic: true,
      ...(scope === 'project' ? {dir: this.cwd} : {})});
    return {sessions: page.map(session => ({id: session.sessionId, provider: 'claude',
      title: sessionTitle(session.customTitle || session.summary), cwd: session.cwd || '', updatedAt: session.lastModified})),
      nextCursor: page.length === limit ? String(offset + limit) : null};
  }

  async readSession(id) {
    const info = await this.sdk.getSessionInfo(id);
    if (!info) throw new Error('Claude session was not found.');
    if (!info.cwd) throw new Error('Claude could not recover this session’s original working directory. Resume it in the CLI from its original project.');
    const cwd = info.cwd;
    const records = await this.sdk.getSessionMessages(id, {dir: cwd});
    return {sessionId: id, cwd, messages: claudeHistory(records), resumeCommand: resumeCommand('claude', id, cwd, this.executable)};
  }

  async resumeSession(id) {
    if (this.currentQuery) throw new Error('Stop the current turn before resuming another session.');
    const history = await this.readSession(id);
    this.sessionId = history.sessionId;
    this.cwd = history.cwd;
    this.model = undefined;
    this.effort = undefined;
    this.modelOverride = undefined;
    this.effortOverride = undefined;
    this.catalog = null;
    return history;
  }

  // Restores (or previews) files to their state before a user message, using the original session's checkpoints.
  async rewindFiles(messageId, dryRun) {
    let release, timeout;
    const prompt = {async *[Symbol.asyncIterator]() { await new Promise(resolve => { release = resolve; }); }};
    const query = this.query({prompt, options: this.queryOptions({resume: this.sessionId})});
    try {
      return await Promise.race([query.rewindFiles(messageId, {dryRun}),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Claude file restore timed out.')), 30000); })]);
    } finally { clearTimeout(timeout); release?.(); query.close(); }
  }

  async previewEdit(message) {
    const result = await this.rewindFiles(message.editId, true);
    return result.canRewind ? result.filesChanged || [] : [];
  }

  async forkBefore(users, index, {restoreFiles} = {}) {
    const target = users[index].editId;
    if (!target) throw new Error('This Claude message cannot be edited.');
    if (restoreFiles) {
      const result = await this.rewindFiles(target, false);
      if (!result.canRewind) throw new Error(result.error || 'Claude could not restore files for this message.');
    }
    const records = await this.sdk.getSessionMessages(this.sessionId, {dir: this.cwd});
    const position = records.findIndex(record => record.uuid === target);
    if (position < 0) throw new Error('Claude could not find this message in the saved session.');
    if (position === 0) return null;
    const {sessionId} = await this.sdk.forkSession(this.sessionId, {dir: this.cwd, upToMessageId: records[position - 1].uuid});
    return sessionId;
  }

  async prompt(prompt, options = {}) {
    this.stopped = false;
    if (options.skills?.length && !this.catalog) await this.getCatalog();
    prompt = claudeSkillPrompt(prompt, options.skills, this.catalog?.skills);
    if (this.stopped) { this.emit({type: 'done', status: 'interrupted'}); return; }
    const images = readImages(options.images);
    this.text.reset();
    this.tools.clear();
    this.toolInputs.clear();
    this.lastUsage = {};
    this.controller = new AbortController();
    if (options.model !== undefined) this.model = this.modelOverride = options.model || undefined;
    if (options.effort !== undefined) this.effort = this.effortOverride = options.effort || undefined;
    this.emit({type: 'status', state: 'requesting', model: this.model, effort: this.effort});
    // Images require the SDK's streaming input form; text-only prompts stay plain strings.
    const content = [...(prompt ? [{type: 'text', text: prompt}] : []),
      ...images.map(image => ({type: 'image', source: {type: 'base64', media_type: image.mimeType, data: image.data}}))];
    const input = images.length
      ? (async function* () { yield {type: 'user', message: {role: 'user', content}, parent_tool_use_id: null}; })() : prompt;
    const query = this.query({prompt: input, options: this.queryOptions({
      resume: this.sessionId, abortController: this.controller,
      ...(this.modelOverride ? {model: this.modelOverride} : {}), ...(this.effortOverride ? {effort: this.effortOverride} : {}),
    })});
    this.currentQuery = query;
    let result;
    try {
      for await (const event of query) {
        this.receive(event);
        if (event.type === 'result') { result = event; break; }
      }
      if (result?.is_error && !this.stopped) {
        this.emit({type: 'error', message: result.errors?.join('\n') || result.result || 'Claude could not complete this turn.'});
      }
      this.emit({type: 'done', status: this.stopped ? 'interrupted' : result && !result.is_error ? 'completed' : 'failed'});
    } catch (error) {
      if (!this.stopped && !this.closing) this.emit({type: 'error', message: error.message});
      if (!this.closing) this.emit({type: 'done', status: this.stopped ? 'interrupted' : 'failed'});
    } finally {
      this.clearApprovals();
      query.close();
      this.currentQuery = null;
    }
  }

  receive(event) {
    if (event.type === 'system' && event.subtype === 'api_retry') {
      const reason = event.error === 'authentication_failed'
        ? 'Authentication or model access was rejected. Check the selected Claude executable and model in the terminal, and verify provider access.'
        : event.error || 'Connection error';
      this.emit({type: 'activity', id: 'claude-connection', title: 'Retrying Claude request',
        detail: `${reason}${event.error_status ? ` (HTTP ${event.error_status})` : ''} · attempt ${event.attempt || 1}`,
        status: 'running'});
    }
    if (event.session_id && !this.sessionId) {
      this.sessionId = event.session_id;
      this.emit({type: 'session', sessionId: this.sessionId, cwd: this.cwd});
    }
    // Subagent output belongs in its tool activity, not in the main answer.
    if (event.parent_tool_use_id) return;
    if (event.type === 'system' && event.subtype === 'init') {
      this.model = event.model;
      this.emit({type: 'status', state: 'running', model: this.model, effort: this.effort});
    }
    if (event.type === 'system' && event.subtype === 'status') {
      this.emit({type: 'status', state: event.status || 'running', model: this.model, effort: this.effort});
    }
    if (event.type === 'system' && event.subtype === 'session_state_changed') {
      this.emit({type: 'status', state: event.state === 'requires_action' ? 'waiting' : event.state});
    }
    if (event.type === 'stream_event') {
      const e = event.event;
      if (e.type === 'message_start') {
        this.messageId = e.message.id;
        this.lastUsage = e.message.usage || this.lastUsage;
        this.toolInputs.clear();
      }
      if (e.type === 'content_block_delta' && e.delta.type === 'text_delta') {
        this.text.delta(this.messageId, e.delta.text);
      }
      if (e.type === 'content_block_start' && e.content_block.type === 'tool_use') {
        const activity = claudeActivity(e.content_block);
        this.toolInputs.set(e.index, {block: e.content_block, json: ''});
        this.tools.set(activity.id, activity);
        this.emit(activity);
      }
      if (e.type === 'content_block_delta' && e.delta.type === 'input_json_delta') {
        const input = this.toolInputs.get(e.index);
        if (input) {
          input.json += e.delta.partial_json;
          let activity;
          try { activity = claudeActivity({...input.block, input: JSON.parse(input.json)}); }
          catch { activity = {...this.tools.get(input.block.id), detail: readable(input.json)}; }
          this.tools.set(activity.id, activity);
          this.emit(activity);
        }
      }
      if (e.type === 'content_block_stop') this.toolInputs.delete(e.index);
    }
    if (event.type === 'assistant') {
      this.lastUsage = event.message.usage || this.lastUsage;
      const blocks = event.message.content || [];
      let text = '';
      for (const block of blocks) {
        if (block.type === 'text') {
          text += block.text;
          this.text.complete(event.message.id, text);
        } else if (block.type === 'tool_use') {
          const activity = claudeActivity(block);
          this.tools.set(activity.id, activity);
          this.emit(activity);
        }
      }
      if (event.error) this.emit({type: 'error', message: event.error});
    }
    if (event.type === 'user' && Array.isArray(event.message.content)) {
      for (const block of event.message.content.filter(b => b.type === 'tool_result')) {
        const tool = this.tools.get(block.tool_use_id);
        this.emit({type: 'activity', id: block.tool_use_id, title: tool?.title || 'Tool result',
          detail: readable(typeof block.content === 'string' ? block.content : block.content?.map(b => b.text || '').join('\n')),
          status: block.is_error ? 'failed' : 'completed'});
      }
    }
    if (event.type === 'result') {
      if (!this.text.hasText && event.result) this.text.complete('result', event.result);
      this.emit(claudeUsage(event, this.lastUsage));
    }
  }

  requestApproval(name, input, options) {
    if (name === 'AskUserQuestion') return Promise.resolve({behavior: 'deny', message: 'Ask your question in ordinary chat text; the user can send a followup.'});
    if (options.signal.aborted) return Promise.resolve({behavior: 'deny', message: 'Turn interrupted.'});
    const requestId = options.toolUseID || randomUUID();
    return new Promise(resolve => {
      const cancel = () => {
        this.approvals.delete(requestId);
        resolve({behavior: 'deny', message: 'Turn interrupted.'});
      };
      options.signal.addEventListener('abort', cancel, {once: true});
      this.approvals.set(requestId, {input, resolve, cleanup: () => options.signal.removeEventListener('abort', cancel)});
      this.emit({type: 'approval', requestId, title: options.title || `Allow ${name}?`,
        detail: [options.description, options.decisionReason, readable(input)].filter(Boolean).join('\n')});
      this.emit({type: 'status', state: 'waiting'});
    });
  }

  approve(requestId, decision) {
    const approval = this.approvals.get(requestId);
    if (!approval) throw new Error('That approval is no longer pending.');
    this.approvals.delete(requestId);
    approval.cleanup();
    approval.resolve(decision === 'accept' ? {behavior: 'allow', updatedInput: approval.input}
      : {behavior: 'deny', message: 'The user declined this tool call.'});
  }

  clearApprovals() {
    for (const approval of this.approvals.values()) {
      approval.cleanup();
      approval.resolve({behavior: 'deny', message: 'Turn interrupted.'});
    }
    this.approvals.clear();
  }

  async stop() {
    this.stopped = true;
    this.clearApprovals();
    if (this.currentQuery) {
      try { await this.currentQuery.interrupt(); } finally { this.controller.abort(); }
    }
  }

  async close() {
    this.closing = true;
    this.clearApprovals();
    this.controller?.abort();
    this.currentQuery?.close();
    this.catalogQuery?.close();
  }
}

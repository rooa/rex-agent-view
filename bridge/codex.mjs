import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { TextStream, codexActivity, readable } from './events.mjs';
import { codexHistory, codexSkillInputs, codexUsage, resumeCommand, sessionTitle } from './provider-data.mjs';

export class CodexSession {
  constructor({cwd, emit}) {
    this.cwd = cwd;
    this.emit = emit;
    this.text = new TextStream(emit);
    this.pending = new Map();
    this.approvals = new Map();
    this.activities = new Map();
    this.nextId = 1;
  }

  async start() {
    this.process = spawn('codex', ['app-server'], {cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe']});
    let stderr = '';
    this.process.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-4000); });
    this.process.stdin.on('error', () => {});
    this.process.on('error', error => this.failed(error));
    this.process.on('exit', (code, signal) => {
      if (!this.closing) this.failed(new Error(`Codex exited (${signal || code}). ${stderr.trim()}`));
    });
    this.lines = createInterface({input: this.process.stdout});
    this.lines.on('line', line => {
      try { this.receive(JSON.parse(line)); }
      catch (error) { this.emit({type: 'error', message: `Invalid Codex event: ${error.message}`}); }
    });
    await this.call('initialize', {
      clientInfo: {name: 'rex_agent', title: 'Rex Agent View', version: '0.1.0'},
      capabilities: {experimentalApi: true},
    });
    this.send({method: 'initialized', params: {}});
    this.started = true;
  }

  async getCatalog() {
    if (this.catalog) return this.catalog;
    const [modelPage, skillPage] = await Promise.all([
      this.call('model/list', {limit: 100}), this.call('skills/list', {cwds: [this.cwd]}),
    ]);
    const models = [...modelPage.data];
    let cursor = modelPage.nextCursor;
    while (cursor) {
      const page = await this.call('model/list', {limit: 100, cursor});
      models.push(...page.data); cursor = page.nextCursor;
    }
    this.catalog = {
      models: models.map(model => ({id: model.model, label: model.displayName, isDefault: model.isDefault,
        efforts: model.supportedReasoningEfforts.map(item => item.reasoningEffort), defaultEffort: model.defaultReasoningEffort})),
      skills: skillPage.data.flatMap(entry => entry.skills).filter(skill => skill.enabled).map(skill => ({
        name: skill.name, description: skill.description, path: skill.path, insertText: `$${skill.name} `,
      })),
    };
    return this.catalog;
  }

  async listSessions({scope = 'project', limit = 50, cursor, repair = false} = {}) {
    const page = await this.call('thread/list', {limit, cursor, sortKey: 'updated_at',
      useStateDbOnly: !repair,
      sourceKinds: ['cli', 'appServer', 'exec', 'vscode'], modelProviders: [], ...(scope === 'project' ? {cwd: this.cwd} : {})});
    return {sessions: page.data.map(thread => ({id: thread.id, provider: 'codex',
      title: sessionTitle(thread.name || thread.preview), cwd: thread.cwd, updatedAt: thread.updatedAt * 1000})), nextCursor: page.nextCursor};
  }

  async readSession(id) {
    const {thread} = await this.call('thread/read', {threadId: id, includeTurns: false});
    let entries = [];
    if (thread.historyMode === 'paginated') {
      let cursor;
      do {
        const page = await this.call('thread/items/list', {threadId: id, limit: 200, sortDirection: 'asc', cursor});
        entries.push(...page.data); cursor = page.nextCursor;
      } while (cursor);
    } else {
      const result = await this.call('thread/read', {threadId: id, includeTurns: true});
      entries = result.thread.turns.flatMap(turn => turn.items.map(item => ({item, turnId: turn.id})));
    }
    return {sessionId: id, cwd: thread.cwd, model: thread.model, effort: thread.reasoningEffort,
      messages: codexHistory(entries), resumeCommand: resumeCommand('codex', id, thread.cwd)};
  }

  async resumeSession(id) {
    if (this.inTurn) throw new Error('Stop the current turn before resuming another session.');
    const history = await this.readSession(id);
    const result = await this.call('thread/resume', {threadId: id, excludeTurns: true,
      approvalPolicy: 'on-request', approvalsReviewer: 'user', sandbox: 'workspace-write'});
    this.threadId = result.thread.id;
    this.cwd = result.thread.cwd;
    this.model = result.model ?? history.model;
    this.effort = result.reasoningEffort ?? history.effort;
    this.baselineModel = this.model;
    this.baselineEffort = this.effort;
    this.catalog = null;
    return {...history, cwd: this.cwd, model: this.model, effort: this.effort};
  }

  // Forks through the turn before the edited message, keeping the original thread intact.
  async forkBefore(users, index) {
    if (index === 0) return null;
    const lastTurnId = users[index - 1].editId;
    if (!lastTurnId) throw new Error('This Codex message cannot be edited.');
    // Fork in a short-lived app-server: the process that forks becomes the fork's writer,
    // and the pane's next provider process must be able to resume it.
    const helper = new CodexSession({cwd: this.cwd, emit: () => {}});
    try {
      await helper.start();
      const {thread} = await helper.call('thread/fork', {threadId: this.threadId, lastTurnId, excludeTurns: true});
      return thread.id;
    } finally { await helper.close(); }
  }

  send(message) {
    if (!this.process?.stdin.writable) throw new Error('Codex connection is closed. Start a new session.');
    this.process.stdin.write(JSON.stringify(message) + '\n');
  }

  call(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex did not answer ${method} within 60 seconds.`));
      }, 60000);
      this.pending.set(id, {resolve, reject, timeout});
      try { this.send({id, method, params}); }
      catch (error) { clearTimeout(timeout); this.pending.delete(id); reject(error); }
    });
  }

  receive(message) {
    if (message.id != null && !message.method) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timeout);
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
      return;
    }
    if (message.id != null) {
      if (['item/commandExecution/requestApproval', 'item/fileChange/requestApproval'].includes(message.method)) {
        this.approvals.set(String(message.id), message.id);
        const p = message.params;
        this.emit({type: 'approval', requestId: String(message.id),
          title: p.command || (message.method.includes('fileChange') ? 'Approve file changes' : 'Approve command'),
          detail: [p.reason, p.cwd, p.grantRoot].filter(Boolean).join('\n')});
      } else {
        this.send({id: message.id, error: {code: -32601,
          message: 'This pane supports command/file approvals. Ask other questions in chat text.'}});
        this.emit({type: 'error', message: `Codex requested an unsupported interaction: ${message.method}`});
      }
      return;
    }
    const p = message.params || {};
    switch (message.method) {
      case 'item/agentMessage/delta': this.text.delta(p.itemId, p.delta); break;
      case 'item/started':
      case 'item/completed': {
        const item = p.item;
        if (!item) break;
        const completed = message.method === 'item/completed';
        if (item.type === 'contextCompaction') this.emit({type: 'status', state: completed ? 'running' : 'compacting'});
        if (item.type === 'agentMessage' && completed) this.text.complete(item.id, item.text);
        const activity = codexActivity(item, completed);
        if (activity) { this.activities.set(item.id, activity); this.emit(activity); }
        break;
      }
      case 'item/commandExecution/outputDelta': {
        const activity = this.activities.get(p.itemId);
        if (activity) {
          activity.detail = readable((activity.output || '') + p.delta);
          activity.output = activity.detail;
          const {output, ...event} = activity;
          this.emit(event);
        }
        break;
      }
      case 'thread/tokenUsage/updated': this.emit(codexUsage(p.tokenUsage)); break;
      case 'turn/started': this.emit({type: 'status', state: 'running', model: this.model, effort: this.effort}); break;
      case 'thread/status/changed':
        if (p.threadId === this.threadId && p.status?.type === 'active') {
          this.emit({type: 'status', state: p.status.activeFlags?.length ? 'waiting' : 'running'});
        }
        break;
      case 'error': this.emit({type: 'error', message: p.error?.message || 'Codex reported an error.'}); break;
      case 'turn/completed':
        this.inTurn = false;
        this.turnId = null;
        this.approvals.clear();
        if (p.turn.error) this.emit({type: 'error', message: p.turn.error.message});
        this.emit({type: 'done', status: p.turn.status});
        break;
    }
  }

  async prompt(prompt, options = {}) {
    this.stopped = false;
    if ((options.skills?.length || /(?:^|\s)\$[\w]/.test(prompt)) && !this.catalog) await this.getCatalog();
    const skillInputs = codexSkillInputs(prompt, options.skills, this.catalog?.skills);
    if (this.stopped) { this.emit({type: 'done', status: 'interrupted'}); return; }
    this.inTurn = true;
    this.text.reset();
    this.activities.clear();
    try {
      if (!this.threadId) {
        const result = await this.call('thread/start', {
          cwd: this.cwd, approvalPolicy: 'on-request', approvalsReviewer: 'user', sandbox: 'workspace-write',
          developerInstructions: 'When you need clarification, ask in your chat response. This client supports ordinary followup messages but no structured question dialog.',
        });
        this.threadId = result.thread.id;
        this.baselineModel = result.model;
        this.baselineEffort = result.reasoningEffort;
        this.model = result.model;
        this.effort = result.reasoningEffort;
        this.emit({type: 'session', sessionId: this.threadId, cwd: this.cwd, model: this.model, effort: this.effort});
      }
      this.model = options.model === null ? this.baselineModel : options.model ?? this.model;
      this.effort = options.effort === null
        ? (this.model === this.baselineModel ? this.baselineEffort : null)
          ?? this.catalog?.models.find(model => model.id === this.model)?.defaultEffort
        : options.effort ?? this.effort;
      this.emit({type: 'status', state: 'requesting', model: this.model, effort: this.effort});
      if (this.stopped) {
        this.inTurn = false;
        this.emit({type: 'done', status: 'interrupted'});
        return;
      }
      const result = await this.call('turn/start', {
        threadId: this.threadId, input: [...(prompt ? [{type: 'text', text: prompt, text_elements: []}] : []),
          ...(options.images || []).map(path => ({type: 'localImage', path})), ...skillInputs],
        ...(this.model ? {model: this.model} : {}), ...(this.effort ? {effort: this.effort} : {}),
      });
      if (this.inTurn) {
        this.turnId = result.turn.id;
        if (this.stopped) await this.stop();
      }
    } catch (error) {
      this.inTurn = false;
      this.turnId = null;
      throw error;
    }
  }

  async stop() {
    this.stopped = true;
    if (this.turnId) await this.call('turn/interrupt', {threadId: this.threadId, turnId: this.turnId});
  }

  approve(requestId, decision) {
    const id = this.approvals.get(String(requestId));
    if (id == null) throw new Error('That approval is no longer pending.');
    this.approvals.delete(String(requestId));
    this.send({id, result: {decision}});
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

  async close() {
    this.closing = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timeout); pending.reject(new Error('Session closed.')); }
    this.pending.clear();
    if (!this.process?.pid || this.process.exitCode != null || this.process.signalCode) return;
    await new Promise(resolve => {
      const timeout = setTimeout(() => this.process.kill('SIGKILL'), 2000);
      this.process.once('exit', () => { clearTimeout(timeout); resolve(); });
      this.process.stdin.end();
      this.process.kill('SIGTERM');
    });
    this.lines?.close();
  }
}

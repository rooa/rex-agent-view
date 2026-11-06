// Both providers send partial text followed by the same complete message.
export class TextStream {
  constructor(emit) { this.emit = emit; this.reset(); }
  reset() { this.messages = new Map(); this.hasText = false; }
  delta(id, text) {
    if (!text) return;
    if (!this.messages.has(id) && this.hasText) this.emit({type: 'delta', text: '\n\n'});
    this.messages.set(id, (this.messages.get(id) || '') + text);
    this.hasText = true;
    this.emit({type: 'delta', text});
  }
  complete(id, text) {
    const previous = this.messages.get(id) || '';
    if (text?.startsWith(previous)) this.delta(id, text.slice(previous.length));
  }
}

export function readable(value) {
  return (typeof value === 'string' ? value : JSON.stringify(value, null, 2) || '').slice(0, 32000);
}

export function codexActivity(item, completed = false) {
  let title, detail;
  switch (item.type) {
    case 'commandExecution': title = item.command; detail = item.aggregatedOutput || item.command; break;
    case 'fileChange': title = 'File changes'; detail = item.changes?.map(c => `${c.path}\n${c.diff || ''}`).join('\n\n'); break;
    case 'mcpToolCall': title = `${item.server} · ${item.tool}`; detail = item.error || item.result || item.arguments; break;
    case 'dynamicToolCall': title = item.tool; detail = item.contentItems || item.arguments; break;
    case 'webSearch': title = 'Web search'; detail = item.query || item.action; break;
    case 'collabAgentToolCall': title = `Agent · ${item.tool}`; detail = item.prompt || item.agentsStates; break;
    case 'plan': title = 'Plan'; detail = item.text; break;
    default: return null;
  }
  const failed = ['failed', 'declined'].includes(item.status) || (item.exitCode != null && item.exitCode !== 0);
  return {type: 'activity', id: item.id, title: title || item.type, detail: readable(detail),
    status: failed ? 'failed' : completed ? 'completed' : 'running'};
}

export function claudeActivity(block) {
  const subject = block.input?.command || block.input?.file_path || block.input?.path || block.input?.pattern;
  const title = subject ? `${block.name} · ${String(subject).replace(/\s+/g, ' ').slice(0, 200)}` : block.name;
  return {type: 'activity', id: block.id, title, detail: readable(block.input), status: 'running'};
}

export function piActivity(call) {
  const input = call.arguments || {};
  const subject = input.command || input.path || input.file_path || input.pattern;
  const title = subject ? `${call.name} · ${String(subject).replace(/\s+/g, ' ').slice(0, 200)}` : call.name;
  return {type: 'activity', id: call.id, title, detail: readable(input), status: 'running'};
}

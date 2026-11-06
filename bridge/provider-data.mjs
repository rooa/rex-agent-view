import { readFileSync } from 'node:fs';
import { extname } from 'node:path';
import { codexActivity, claudeActivity, piActivity, readable } from './events.mjs';

const quote = value => `'${String(value).replaceAll("'", "'\\''")}'`;
export const resumeCommand = (provider, id, cwd, executable = provider) =>
  `cd ${quote(cwd)} && ${quote(executable)} ${{claude: '--resume', pi: '--session'}[provider] || 'resume'} ${quote(id)}`;
export const sessionTitle = value => (value || 'Untitled conversation').replace(/\s+/g, ' ').trim().slice(0, 160);

export function historyQuery(message, cwd) {
  const scope = message.scope === 'project' ? 'project' : 'all';
  let cursors = {};
  if (message.cursor) {
    try { cursors = JSON.parse(Buffer.from(message.cursor, 'base64url').toString()); }
    catch { throw new Error('Invalid history cursor. Refresh the history list.'); }
    if (!cursors || typeof cursors !== 'object' || Array.isArray(cursors)) throw new Error('Invalid history cursor. Refresh the history list.');
    if (cursors.scope !== scope) throw new Error('History scope changed. Refresh the history list.');
    if (scope === 'project' && cursors.cwd !== cwd) throw new Error('The project changed. Refresh the history list.');
    if (cursors.source != null && !['native-index', 'native-repair'].includes(cursors.source)) {
      throw new Error('Invalid history cursor source. Refresh the history list.');
    }
  }
  const source = message.cursor ? cursors.source || 'native-index' : message.repair === true ? 'native-repair' : 'native-index';
  return {scope, cursors, source, repair: source === 'native-repair'};
}

function contentText(content) {
  if (typeof content === 'string') return content;
  return (content || []).map(block => {
    if (block.type === 'text') return block.text;
    if (block.type === 'image' || block.type === 'localImage') return '[Image attachment]';
    if (block.type === 'audio' || block.type === 'localAudio') return '[Audio attachment]';
    return '';
  }).filter(Boolean).join('\n');
}

function assistant(messages, text = false) {
  if (messages.at(-1)?.role !== 'assistant' || (text && messages.at(-1).activities.length)) {
    messages.push({role: 'assistant', text: '', activities: []});
  }
  return messages.at(-1);
}

function localCommand(text) {
  const source = text.trim(), fields = new Map();
  let end = 0;
  for (const match of source.matchAll(/<(command-name|command-message|command-args|local-command-stdout)>([\s\S]*?)<\/\1>/g)) {
    if (source.slice(end, match.index).trim() || fields.has(match[1])) return null;
    fields.set(match[1], match[2]);
    end = match.index + match[0].length;
  }
  if (!fields.size || source.slice(end).trim()) return null;
  const name = fields.get('command-name')?.trim() || '';
  if (name ? !/^\/[^\s<>]+$/.test(name) : fields.size !== 1 || !fields.has('local-command-stdout')) return null;
  return {name, args: fields.get('command-args')?.trim() || '', output: fields.get('local-command-stdout') || ''};
}

const commandText = command => [[command.name, command.args].filter(Boolean).join(' '), command.output].filter(Boolean).join('\n\n');

export function codexHistory(entries) {
  const messages = [];
  for (const entry of entries) {
    const item = entry.item || entry;
    if (item.type === 'userMessage') {
      const text = contentText(item.content);
      if (text) messages.push({role: 'user', text, ...(entry.turnId ? {editId: entry.turnId} : {})});
    } else if (item.type === 'agentMessage' && item.text) {
      const message = assistant(messages, true);
      message.text += (message.text ? '\n\n' : '') + item.text;
    } else {
      const activity = codexActivity(item, !['inProgress', 'running'].includes(item.status));
      if (activity) assistant(messages).activities.push(activity);
    }
  }
  return messages;
}

export function claudeHistory(records) {
  const messages = [], tools = new Map(), seen = new Set();
  let pendingCommand;
  for (const record of records) {
    if (record.parent_tool_use_id || record.type === 'system' || (record.uuid && seen.has(record.uuid))) continue;
    if (record.uuid) seen.add(record.uuid);
    const content = record.message?.content;
    const text = contentText(content);
    if (record.type === 'user') {
      const command = (!Array.isArray(content) || content.every(block => block.type === 'text')) ? localCommand(text) : null;
      if (command) {
        if (!command.name && pendingCommand) {
          pendingCommand.command.output = [pendingCommand.command.output, command.output].filter(Boolean).join('\n');
          pendingCommand.text = commandText(pendingCommand.command);
        } else {
          const message = {role: 'command', text: commandText(command), command};
          messages.push(message);
          pendingCommand = command.name ? message : null;
        }
      } else {
        pendingCommand = null;
        if (text) messages.push({role: 'user', text, ...(record.uuid ? {editId: record.uuid} : {})});
      }
      for (const block of Array.isArray(content) ? content : []) {
        if (block.type !== 'tool_result') continue;
        const activity = tools.get(block.tool_use_id);
        if (activity) {
          activity.detail = readable(contentText(block.content));
          activity.status = block.is_error ? 'failed' : 'completed';
        }
      }
    } else if (record.type === 'assistant') {
      pendingCommand = null;
      const blocks = typeof content === 'string' ? [{type: 'text', text: content}] : content || [];
      for (const block of blocks) {
        const text = contentText([block]);
        if (text) {
          const message = assistant(messages, true);
          message.text += (message.text ? '\n\n' : '') + text;
        } else if (block.type === 'tool_use' && !tools.has(block.id)) {
          const activity = claudeActivity(block);
          tools.set(block.id, activity);
          assistant(messages).activities.push(activity);
        }
      }
    }
  }
  return messages.filter(message => message.text || message.activities?.length);
}

export function codexSkillInputs(text, selected = [], catalog = []) {
  const skills = new Map();
  for (const choice of selected) {
    const skill = catalog.find(item => item.name === choice.name && (!choice.path || item.path === choice.path));
    if (!skill) throw new Error(`Unknown skill: ${choice.name || '(missing name)'}`);
    skills.set(skill.path, skill);
  }
  for (const match of text.matchAll(/(?:^|\s)\$([\w:./-]+)/g)) {
    const skill = catalog.find(item => item.name === match[1]);
    if (skill) skills.set(skill.path, skill);
  }
  return [...skills.values()].map(({name, path}) => ({type: 'skill', name, path}));
}

export function claudeSkillPrompt(text, selected = [], catalog = [], agent = 'Claude') {
  if (!selected.length) return text;
  if (selected.length > 1) throw new Error(`${agent} invokes one slash skill per prompt.`);
  const skill = catalog.find(item => item.name === selected[0].name);
  if (!skill) throw new Error(`Unknown ${agent} skill: ${selected[0].name || '(missing name)'}`);
  const prefix = `/${skill.name}`;
  return text === prefix || text.startsWith(prefix + ' ') || text.startsWith(prefix + '\n') ? text : `${prefix} ${text}`;
}

// Pi stores a tree; the active branch is the chain of parents from the last entry.
function piBranch(entries) {
  const byId = new Map(entries.filter(entry => entry.id).map(entry => [entry.id, entry]));
  const branch = [];
  for (let entry = entries.findLast(entry => entry.id); entry; entry = byId.get(entry.parentId)) branch.unshift(entry);
  return branch;
}

export function piSessionTitle(entries) {
  const named = entries.findLast(entry => entry.type === 'session_info');
  if (named?.name) return named.name;
  const first = entries.find(entry => entry.type === 'message' && entry.message?.role === 'user');
  return first ? contentText(first.message.content) : '';
}

export function piHistory(entries) {
  const messages = [], tools = new Map();
  let model, effort;
  for (const entry of piBranch(entries)) {
    if (entry.type === 'model_change') model = `${entry.provider}/${entry.modelId}`;
    if (entry.type === 'thinking_level_change') effort = entry.thinkingLevel;
    if (entry.type !== 'message') continue;
    const message = entry.message;
    if (message.role === 'user') {
      const text = contentText(message.content);
      if (text) messages.push({role: 'user', text, editId: entry.id});
    } else if (message.role === 'assistant') {
      for (const block of message.content || []) {
        if (block.type === 'text' && block.text) {
          const current = assistant(messages, true);
          current.text += (current.text ? '\n\n' : '') + block.text;
        } else if (block.type === 'toolCall') {
          const activity = piActivity(block);
          tools.set(block.id, activity);
          assistant(messages).activities.push(activity);
        }
      }
    } else if (message.role === 'toolResult') {
      const activity = tools.get(message.toolCallId);
      if (activity) {
        activity.detail = readable(contentText(message.content) || activity.detail);
        activity.status = message.isError ? 'failed' : 'completed';
      }
    }
  }
  for (const message of messages) for (const activity of message.activities || []) {
    if (activity.status === 'running') activity.status = 'completed';
  }
  return {messages: messages.filter(message => message.text || message.activities?.length), model, effort};
}

export function piUsage(turns, contextWindow = null) {
  const total = key => turns.reduce((sum, usage) => sum + (usage[key] || 0), 0);
  const last = turns.at(-1) || {};
  return {type: 'usage', inputTokens: total('input') + total('cacheRead') + total('cacheWrite'), outputTokens: total('output'),
    cachedInputTokens: total('cacheRead'), contextTokens: last.totalTokens ?? null, contextWindow,
    costUSD: turns.reduce((sum, usage) => sum + (usage.cost?.total || 0), 0), scope: 'turn'};
}

const imageTypes = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp'};
export function readImages(paths = []) {
  return paths.map(path => {
    const mimeType = imageTypes[extname(path).toLowerCase()];
    if (!mimeType) throw new Error(`Unsupported image type: ${path}`);
    return {data: readFileSync(path).toString('base64'), mimeType};
  });
}

// The pane identifies an edited message by its position among user messages; the text guards against drift.
const comparable = text => String(text || '').split('\n').filter(line => !/^\[Image(: .*| attachment)\]$/.test(line.trim())).join('\n').trim();
export function editIndex(users, index, text) {
  const wanted = comparable(text);
  if (users[index] && comparable(users[index].text) === wanted) return index;
  const matches = users.flatMap((message, i) => comparable(message.text) === wanted ? [i] : []);
  if (matches.length === 1) return matches[0];
  throw new Error('Could not find this message in the saved conversation. Resume it from History and try again.');
}

export function codexUsage(usage) {
  return {type: 'usage', inputTokens: usage.total?.inputTokens || 0, outputTokens: usage.total?.outputTokens || 0,
    cachedInputTokens: usage.total?.cachedInputTokens || 0, contextTokens: usage.last?.totalTokens ?? null,
    contextWindow: usage.modelContextWindow ?? null, scope: 'session'};
}

export function claudeUsage(result, latest = {}) {
  const perModel = Object.values(result.modelUsage || {});
  const raw = result.usage || {};
  const total = key => perModel.reduce((sum, item) => sum + (item[key] || 0), 0);
  return {type: 'usage',
    inputTokens: perModel.length ? total('inputTokens') + total('cacheReadInputTokens') + total('cacheCreationInputTokens')
      : (raw.input_tokens || 0) + (raw.cache_read_input_tokens || 0) + (raw.cache_creation_input_tokens || 0),
    outputTokens: perModel.length ? total('outputTokens') : raw.output_tokens || 0,
    cachedInputTokens: perModel.length ? total('cacheReadInputTokens') : raw.cache_read_input_tokens || 0,
    contextTokens: latest.input_tokens == null ? null : (latest.input_tokens || 0) + (latest.output_tokens || 0)
      + (latest.cache_read_input_tokens || 0) + (latest.cache_creation_input_tokens || 0),
    contextWindow: perModel.length ? Math.max(...perModel.map(item => item.contextWindow || 0)) || null : null,
    costUSD: result.total_cost_usd ?? null, scope: 'turn'};
}

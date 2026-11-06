#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { PaneState } from './pane-state.mjs';
import { CodexSession } from './codex.mjs';
import { ClaudeSession } from './claude.mjs';
import { PiSession } from './pi.mjs';
import { editIndex, historyQuery, resumeCommand as cliResumeCommand } from './provider-data.mjs';

let busy = false;
let changing = false;
let closing = false;
let provider;
let providerName;
let cwd;
let sessionId = null;
let selection = {model: null, effort: null};
let store;
let preserveSavedAssociation = false;
let conversationVersion = 0;
const classes = {codex: CodexSession, claude: ClaudeSession, pi: PiSession};
const output = event => {
  if (!closing) process.stdout.write(JSON.stringify(event) + '\n');
};
const resumeCommand = () => sessionId
  ? cliResumeCommand(providerName, sessionId, cwd, providerName === 'codex' ? 'codex' : provider.executable) : null;
const save = () => {
  if (preserveSavedAssociation) return;
  try { store?.write({provider: providerName, sessionId, cwd, ...selection}); }
  catch (error) { output({type: 'error', operation: 'persistence', message: `Could not save pane selection: ${error.message}`}); }
};
const emit = event => {
  if (event.type === 'done') busy = false;
  if (event.type === 'session') {
    sessionId = event.sessionId;
    preserveSavedAssociation = false;
    save();
    event = {...event, provider: providerName, cwd, resumeCommand: resumeCommand()};
  }
  output(event);
};
const close = async () => {
  if (closing) return;
  closing = true;
  const timeout = setTimeout(() => process.exit(0), 4000);
  await provider?.close();
  clearTimeout(timeout);
  process.exit(0);
};
process.on('SIGINT', close);
process.on('SIGTERM', close);
process.stdout.on('error', close);

async function makeProvider(name, directory) {
  if (!Object.hasOwn(classes, name)) throw new Error('Provider must be codex, claude, or pi.');
  const instance = new classes[name]({cwd: directory, emit: event => {
    if (provider === instance) emit(event);
  }});
  try { await instance.start(); }
  catch (error) { await instance.close(); throw error; }
  return instance;
}

async function catalog(requestId) {
  const current = provider;
  try {
    const data = await current.getCatalog();
    if (current === provider) output({type: 'catalog', requestId, ...data, provider: providerName});
  } catch (error) {
    if (current === provider) output({type: 'error', operation: 'catalog', requestId,
      message: `Could not load models and skills: ${error.message}`});
  }
}

async function activate(name, id, options, directory = cwd, persist = true) {
  if (busy || changing) throw new Error('Stop the current turn before switching conversations.');
  if (id && name === providerName && id === sessionId) {
    output({type: 'ready', provider: providerName, cwd});
    return;
  }
  changing = true;
  let candidate;
  try {
    candidate = await makeProvider(name, directory);
    const conversation = id ? await candidate.resumeSession(id) : {cwd: directory, messages: []};
    const nextCwd = conversation.cwd || directory;
    if (!(await stat(nextCwd)).isDirectory()) throw new Error('This conversation’s working directory is unavailable.');
    candidate.cwd = nextCwd;
    const previous = provider;
    provider = candidate;
    providerName = name;
    cwd = nextCwd;
    sessionId = conversation.sessionId || id || null;
    selection = options || {model: conversation.model ?? null, effort: conversation.effort ?? null};
    preserveSavedAssociation = !persist;
    conversationVersion++;
    try { await previous?.close(); }
    catch (error) { output({type: 'error', operation: 'cleanup', message: `The previous agent could not close cleanly: ${error.message}`}); }
    save();
    output({type: 'conversation', ...conversation, provider: name, sessionId, cwd,
      resolvedModel: conversation.model, ...selection, resumeCommand: resumeCommand()});
    await catalog();
    output({type: 'ready', provider: name, cwd});
    if (conversation.model) output({type: 'status', state: 'ready', model: conversation.model, effort: conversation.effort});
  } catch (error) {
    if (candidate && candidate !== provider) await candidate.close();
    throw error;
  } finally { changing = false; }
}

async function sessions(message) {
  const requestCwd = cwd;
  const version = conversationVersion;
  const {scope, cursors, source, repair} = historyQuery(message, requestCwd);
  const next = {scope, cwd: requestCwd, source};
  const rows = [];
  const warnings = [];
  for (const name of Object.keys(classes)) {
    if (cursors[name] === false) { next[name] = false; continue; }
    let instance;
    try {
      // A conversation may change while this read-only request is in flight.
      instance = await makeProvider(name, requestCwd);
      const page = await instance.listSessions({scope, limit: 50, cursor: cursors[name], repair});
      rows.push(...page.sessions);
      next[name] = page.nextCursor ?? false;
    } catch (error) {
      next[name] = false;
      warnings.push(`${{codex: 'Codex', claude: 'Claude', pi: 'Pi'}[name]}: ${error.message}`);
    } finally { await instance?.close(); }
  }
  if (version !== conversationVersion) throw new Error('The conversation changed. Refresh the history list.');
  rows.sort((a, b) => b.updatedAt - a.updatedAt);
  const nextCursor = Object.keys(classes).some(name => next[name] !== false)
    ? Buffer.from(JSON.stringify(next)).toString('base64url') : null;
  output({type: 'sessions', requestId: message.requestId, sessions: rows, nextCursor, warnings, source});
}

try {
  const {values} = parseArgs({options: {
    provider: {type: 'string', default: 'codex'}, cwd: {type: 'string', default: process.cwd()},
    pane: {type: 'string'},
  }});
  if (!Object.hasOwn(classes, values.provider)) throw new Error('Provider must be codex, claude, or pi.');
  cwd = resolve(values.cwd);
  if (!(await stat(cwd)).isDirectory()) throw new Error('Working directory must be a directory.');
  store = new PaneState(values.pane);
  let saved;
  try { saved = store.read(); }
  catch (error) { output({type: 'error', operation: 'persistence', message: error.message}); }
  if (saved) {
    try { await activate(saved.provider, saved.sessionId, {model: saved.model, effort: saved.effort}, saved.cwd); }
    catch (error) {
      output({type: 'error', operation: 'restore', message: `Could not restore the saved conversation: ${error.message}`});
      await activate(values.provider, null, {model: null, effort: null}, cwd, false);
    }
  } else await activate(values.provider, null, {model: null, effort: null});

  const lines = createInterface({input: process.stdin});
  lines.on('close', close);
  lines.on('line', line => {
    if (closing || !line.trim()) return;
    let message;
    try { message = JSON.parse(line); }
    catch { output({type: 'error', message: 'Input must be one JSON object per line.'}); return; }
    const run = async () => {
      switch (message.type) {
        case 'prompt':
          if (busy || changing) throw new Error('A turn is still running. Stop it or wait before sending another prompt.');
          if (typeof message.text !== 'string') throw new Error('Prompt text must be a string.');
          if (message.images != null && (!Array.isArray(message.images) || message.images.some(path => typeof path !== 'string'))) throw new Error('Images must be file paths.');
          if (!message.text.trim() && !message.images?.length) throw new Error('Prompt text cannot be empty.');
          busy = true;
          provider.prompt(message.text, {...selection, skills: message.skills, images: message.images || []}).catch(error => {
            output({type: 'error', message: error.message});
            if (busy) emit({type: 'done', status: 'failed'});
          });
          break;
        case 'new':
          await activate(message.provider || providerName, null,
            !message.provider || message.provider === providerName ? selection : {model: null, effort: null});
          break;
        case 'resume':
          if (typeof message.sessionId !== 'string' || !message.sessionId) throw new Error('Choose a session to resume.');
          await activate(message.provider || providerName, message.sessionId);
          break;
        case 'configure':
          if (busy || changing) throw new Error('Wait for the current turn before changing its model or effort.');
          for (const key of ['model', 'effort']) {
            if (message[key] != null && typeof message[key] !== 'string') throw new Error(`${key} must be a string.`);
          }
          selection = {model: message.model || null, effort: message.effort || null};
          save();
          output({type: 'configured', ...selection});
          break;
        case 'editPreview':
        case 'edit': {
          if (busy || changing) throw new Error('Stop the current turn before editing a message.');
          if (!provider.forkBefore) throw new Error(`Editing messages is not supported for ${providerName} yet.`);
          if (!sessionId) throw new Error('Send a message before editing.');
          const users = (await provider.readSession(sessionId)).messages.filter(item => item.role === 'user');
          const index = editIndex(users, message.index, message.original);
          if (message.type === 'editPreview') {
            output({type: 'editPreview', requestId: message.requestId, files: await provider.previewEdit?.(users[index]) ?? []});
            break;
          }
          const forked = await provider.forkBefore(users, index, {restoreFiles: message.restoreFiles === true});
          await activate(providerName, forked, selection);
          break;
        }
        case 'catalog': await catalog(message.requestId); break;
        case 'sessions': await sessions(message); break;
        case 'stop': if (busy) await provider.stop(); break;
        case 'approval':
          if (!['accept', 'decline', 'select'].includes(message.decision)) throw new Error('Approval decision must be accept, decline, or select.');
          if (message.decision === 'select' && (providerName !== 'pi' || typeof message.value !== 'string')) throw new Error('Only Pi choices accept a selected value.');
          await provider.approve(message.requestId, message.decision, message.value);
          break;
        case 'close': await close(); break;
        default: throw new Error(`Unknown input type: ${message.type}`);
      }
    };
    run().catch(error => output({type: 'error', operation: message.type, requestId: message.requestId, message: error.message}));
  });
} catch (error) {
  output({type: 'error', message: error.message});
  await provider?.close();
  process.exitCode = 1;
}

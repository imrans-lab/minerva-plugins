// Record the replies the REAL Council backend gives, so the page's tests replay
// something the engine actually said.
//
//   node council/ui/tests/record-envelopes.mjs
//
// Writes ui/tests/recorded.js. Nothing here writes an envelope by hand: every
// snapshot is what `minerva_council_export_snapshot` returned after the engine
// loaded a fixture, and every refusal is one the engine produced. The wrapper's
// own reply frame (`{schema_version, envelope:"reply", ok, snapshot_revision,
// payload}`) is added around each body exactly as council_panel.gd does, because
// that is the wrapper's shape and not content.
//
// A STAND-IN HOST, and what it is allowed to be. The backend reaches Minerva by
// writing `minerva/capability` requests to its own stdout. This script answers
// them, which is what makes a real round runnable with no Minerva: it serves a
// small provider/model catalogue and answers `host.providers.chat` with a reply
// in the shape replyContract asks for, citing an anchor id it reads back out of
// the prompt it was actually sent. The engine then does everything else — it
// plans the round, enforces the citation eligibility, mints the ids, derives the
// statuses and writes the synthesis. So the recorded contributions are the
// engine's work over a model's words, which is exactly the material the page has
// to render; only the words are this file's.
//
// Rebuild whenever the fixtures or the engine change:
//   go build -o council-plugin ./     (from council/)
//   node council/ui/tests/record-envelopes.mjs

import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const here = dirname(fileURLToPath(import.meta.url));
const plugin = join(here, '..', '..');
const fixtures = join(plugin, 'fixtures');
const binary = join(plugin, 'council-plugin');

if (!existsSync(binary)) {
  console.error(`${binary} is not built. From council/: go build -o council-plugin ./`);
  process.exit(1);
}

// --------------------------------------------------------------- the host

// The turnrock entry is what a Core-backed model looks like on the wire: no
// static model list, one entry per live service action, and a model_spec the
// caller must send back to reach it (singleton_object.gd list_enabled_models
// for API_PROVIDER.TURNROCK). It is here so the page is recorded against a
// catalogue that HAS one, which is the only way its chooser can be checked
// against a Core action at all.
const CATALOGUE = [
  { key: 'anthropic', display: 'Anthropic', models: [
    { model_name: 'claude-sonnet-4-6', display: 'Claude Sonnet 4.6', model_spec: {kind: 'dynamic', model_id: 10003} },
    { model_name: 'claude-opus-4-6', display: 'Claude Opus 4.6' }
  ] },
  { key: 'openai', display: 'OpenAI', models: [
    { model_name: 'gpt-5-mini', display: 'GPT-5 mini' }
  ] },
  { key: 'turnrock', display: 'TurnRock', models: [
    {
      model_name: 'qwen3-8b',
      display: 'model-chat (qwen3-8b)',
      model_spec: {
        kind: 'core_action',
        service_client_id: 'model-chat',
        service_name: 'model-chat',
        action_name: 'qwen3-8b'
      }
    }
  ] }
];

// Long enough that a run.start with wait_seconds:1 answers while the round is
// still pending, which is the only way to record the running state honestly.
let modelDelayMs = 2600;

function modelAnswer(prompt) {
  // Cite an anchor the prompt actually offered. A citation to anything else is
  // dropped by the engine and the claim recorded as unestablished — correct
  // behaviour, but it would leave the fixture with no source-labelled claim.
  const anchors = [...String(prompt).matchAll(/\banc-[A-Za-z0-9._:-]+/g)].map((m) => m[0]);
  const sources = [...String(prompt).matchAll(/\bsrc-[A-Za-z0-9._:-]+/g)].map((m) => m[0]);
  const revisions = [...String(prompt).matchAll(/revision (\d+)/g)].map((m) => Number(m[1]));
  const claims = [
    { support: 'inference', text: 'Taken together the numbers and the captured writing point the same way: the order is priced against a bench the shop does not reliably have.' },
    { support: 'unknown', text: 'What premium would compensate for the lost freedom is not established by anything I was given.' }
  ];
  if (anchors.length && sources.length) {
    claims.unshift({
      support: 'source',
      text: 'The captured writing holds that a recurring order removes the freedom to decline, and that this is what is being sold.',
      citations: [{ source_id: sources[0], source_revision: revisions[0] || 1, anchor_id: anchors[0] }]
    });
  }
  return JSON.stringify({
    answer: 'Quote the order against the worst week the bench has actually cleared, and price the standing commitment separately from the units.',
    claims
  });
}

// The host's own name for a Core action, or '' for anything else.
function coreActionName(spec) {
  if (!spec || spec.kind !== 'core_action') { return ''; }
  return `${spec.service_name || 'Core'} (${spec.action_name})`;
}

// ------------------------------------------------------------ the process

const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 1;

lines.on('line', (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.method === 'minerva/capability') {
    answerCapability(message);
    return;
  }
  const waiting = pending.get(String(message.id));
  if (waiting) { pending.delete(String(message.id)); waiting(message); }
});

function write(message) { child.stdin.write(JSON.stringify(message) + '\n'); }

function rpc(method, params) {
  const id = String(nextId++);
  return new Promise((resolve) => {
    pending.set(id, resolve);
    write({ jsonrpc: '2.0', id, method, params });
  });
}

function capabilityOk(id, result) {
  write({ jsonrpc: '2.0', id, result: { success: true, result } });
}

function answerCapability(message) {
  const capability = message.params && message.params.capability;
  const args = (message.params && message.params.args) || {};
  if (capability === 'host.models.list_providers') {
    capabilityOk(message.id, { providers: CATALOGUE.map((p) => ({ key: p.key, display: p.display })) });
    return;
  }
  if (capability === 'host.models.list_models') {
    const provider = CATALOGUE.find((p) => p.key === args.provider);
    capabilityOk(message.id, { provider: args.provider, models: provider ? provider.models : [] });
    return;
  }
  if (capability === 'host.providers.chat') {
    const prompt = JSON.stringify(args);
    setTimeout(() => {
      capabilityOk(message.id, {
        // What ANSWERED, which for a Core action is the provider's own name for
        // it rather than the name that was asked for (CapabilityBroker.gd
        // reports actual_model_name, and CoreProvider.model_name is
        // "<service> (<action>)").
        model: coreActionName(args.model_spec) || args.model || 'claude-sonnet-4-6',
        choices: [{ message: { content: modelAnswer(prompt) } }],
        usage: { prompt_tokens: 1180, completion_tokens: 240 }
      });
    }, modelDelayMs);
    return;
  }
  // Everything else — the chat-provider registration among it — is refused the
  // way a host with no such grant would refuse it.
  write({ jsonrpc: '2.0', id: message.id, result: {
    success: false, error_code: 'permission_denied',
    error_message: `${capability} is not available to this recorder`
  } });
}

// --------------------------------------------------------- tool shortcuts

async function tool(name, args) {
  const reply = await rpc('tools/call', { name, arguments: args || {} });
  const body = reply.result && reply.result.content && reply.result.content[0];
  const text = body ? body.text : '{}';
  return { parsed: JSON.parse(text), isError: !!(reply.result && reply.result.isError) };
}

let requestSeq = 0;

// One protocol command, exactly as the wrapper relays one.
async function command(name, payload, baseRevision, waitSeconds) {
  const args = { request_id: `rec-${++requestSeq}`, command: name, payload: payload || {} };
  if (baseRevision !== undefined) { args.base_revision = baseRevision; }
  // wait_seconds is an ENVELOPE field, not a payload one: it bounds how long the
  // backend may hold this reply, which is a property of the hop rather than of
  // the command's arguments.
  if (waitSeconds !== undefined) { args.wait_seconds = waitSeconds; }
  const { parsed } = await tool('minerva_council_command', args);
  return parsed;
}

async function load(snapshot, mode) {
  const { parsed, isError } = await tool('minerva_council_load_snapshot', { snapshot, mode: mode || 'replace' });
  if (isError || parsed.ok === false) {
    throw new Error('the backend refused a document: ' + JSON.stringify(parsed));
  }
  return parsed;
}

async function exported() {
  const { parsed } = await tool('minerva_council_export_snapshot', {});
  return parsed.snapshot;
}

// The wrapper's reply frame around a snapshot, which is what the page's
// snapshot.get resolves with (council_panel.gd answers that command locally).
function snapshotReply(snapshot) {
  return {
    schema_version: 1,
    envelope: 'reply',
    request_id: '',
    ok: true,
    snapshot_revision: snapshot.snapshot_revision,
    payload: { snapshot }
  };
}

function fixture(name) { return JSON.parse(readFileSync(join(fixtures, name), 'utf8')); }

// A document that carries hostile text in every field a view renders. It is
// pushed through the real engine, so what the page replays is a snapshot the
// backend validated and stored — the injection is content, exactly as a model's
// answer or an imported council would be.
const HOSTILE = '</script><img src=x onerror="window.__councilInjected=1"><script>window.__councilInjected=1</script>';

function poison(snapshot) {
  const copy = JSON.parse(JSON.stringify(snapshot));
  const definition = copy.definitions[0];
  definition.name = 'Injected council ' + HOSTILE;
  definition.purpose = HOSTILE;
  definition.members.forEach((member) => {
    member.display_name = 'Member ' + HOSTILE;
    if (member.scope) { member.scope = HOSTILE; }
  });
  definition.seats.forEach((seat) => { seat.responsibility = HOSTILE; });
  // Only the title. A payload's bytes, its length and its anchor offsets are
  // checked against each other by the contract, so hostile material has to be
  // captured through source.capture — which derives all three — rather than
  // edited into a record.
  definition.sources.forEach((source) => { source.title = 'Source ' + HOSTILE; });
  copy.sessions.forEach((session) => {
    session.question = 'Question ' + HOSTILE;
    session.definition_snapshot = JSON.parse(JSON.stringify(definition));
    session.definition_snapshot.definition_revision = session.definition_snapshot.definition_revision;
    (session.runs || []).forEach((run) => {
      (run.contributions || []).forEach((c) => { poisonContribution(c); });
      if (run.synthesis) { poisonContribution(run.synthesis); }
    });
  });
  return copy;
}

function poisonContribution(contribution) {
  if (contribution.text) { contribution.text = HOSTILE + ' ' + contribution.text; }
  (contribution.claims || []).forEach((claim) => { claim.text = HOSTILE; });
  if (contribution.failure) { contribution.failure.message = HOSTILE; }
}

// ------------------------------------------------------------------- run

const recorded = {};

async function main() {
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'recorder', version: '1' } });
  write({ jsonrpc: '2.0', method: 'notifications/initialized' });

  // 1. A partial round, as the fixture holds it.
  const partial = fixture('project_snapshot.json');
  await load(partial);
  const partialSnapshot = await exported();
  recorded.partial = snapshotReply(partialSnapshot);

  // Reads against that document, and the two refusals a reader can provoke.
  const definitionId = partialSnapshot.definitions[0].definition_id;
  const source = partialSnapshot.definitions[0].sources[0];
  recorded.source_fetch = await command('source.fetch', {
    definition_id: definitionId,
    source_id: source.source_id,
    source_revision: source.source_revision
  });
  recorded.source_missing = await command('source.fetch', {
    definition_id: definitionId, source_id: 'src-not-in-this-council'
  });
  recorded.stale = await command('run.cancel',
    { session_id: partialSnapshot.sessions[0].session_id, run_id: 'run-1' },
    partialSnapshot.snapshot_revision + 7);

  // 2. A real retry: the engine plans the round, calls the stand-in host, reads
  //    the claims back under its own citation rules and writes the synthesis.
  const sessionId = partialSnapshot.sessions[0].session_id;
  const failedRun = partialSnapshot.sessions[0].runs.filter((r) => r.status !== 'complete').pop();
  const started = await command('run.retry',
    { session_id: sessionId, run_id: failedRun.run_id },
    partialSnapshot.snapshot_revision, 1);
  recorded.run_started = started;
  recorded.running = snapshotReply(await exported());

  let settled = null;
  for (let i = 0; i < 40 && !settled; i++) {
    const reply = await command('run.await', {
      session_id: sessionId,
      run_id: started.payload ? started.payload.run_id : ''
    }, undefined, 2);
    const status = reply.payload && reply.payload.status;
    if (status && status !== 'pending' && status !== 'running') { settled = reply; }
  }
  recorded.run_settled = settled;
  recorded.retried = snapshotReply(await exported());

  // 3. The finished consultation, with its disagreement and its outcome.
  modelDelayMs = 0;
  await load(fixture('workshop_complete.mcouncil'));
  const complete = await exported();
  recorded.complete = snapshotReply(complete);
  recorded.complete_sources = {};
  for (const src of complete.definitions[0].sources) {
    recorded.complete_sources[src.source_id + '@' + src.source_revision] = await command('source.fetch', {
      definition_id: complete.definitions[0].definition_id,
      source_id: src.source_id,
      source_revision: src.source_revision
    });
  }

  // 3b. A capture whose anchor sits AFTER non-ASCII text, in a council with no
  //     session — the Sources pane reads the SESSION's embedded definition when
  //     one is open, which is a historical copy a later capture never joins.
  //
  //     Anchor offsets are byte offsets into the UTF-8 capture and the page
  //     indexes UTF-16 code units, so an all-ASCII fixture cannot tell a correct
  //     conversion from no conversion at all. Here the curly apostrophe, the two
  //     em-dashes and the emoji put 9 bytes of drift before the quote begins.
  const unasked = fixture('project_snapshot.json');
  unasked.definitions = [complete.definitions[0]];
  unasked.sessions = [];
  delete unasked.view;
  await load(unasked);
  const unaskedSnapshot = await exported();
  recorded.punctuation_capture = await command('source.capture', {
    definition_id: unaskedSnapshot.definitions[0].definition_id,
    source_id: 'src-margin-note',
    title: 'A margin note — with the punctuation intact',
    author: 'R. Okonkwo',
    locator: 'note: margin note',
    text: 'The bench’s ceiling — measured, not guessed — is what a quote rests on. 🪚\n'
      + 'The number to quote against is the worst week, not the average one.',
    excerpts: [{ anchor_id: 'anc-worst-week', quote: 'the worst week, not the average one' }]
  }, unaskedSnapshot.snapshot_revision);
  const punctuation = await exported();
  recorded.punctuation = snapshotReply(punctuation);
  recorded.punctuation_source = await command('source.fetch', {
    definition_id: punctuation.definitions[0].definition_id,
    source_id: 'src-margin-note',
    source_revision: 1
  });

  // 4. A council whose material did not travel: every source is an inventory
  //    entry with its hash and no payload.
  const inventory = fixture('project_snapshot.json');
  inventory.definitions = [fixture('definition_imported_inventory.json')];
  inventory.sessions = [];
  delete inventory.view;
  await load(inventory);
  recorded.inventory = snapshotReply(await exported());

  // 5. A cancelled round.
  const cancelled = fixture('project_snapshot.json');
  const cancelledSession = fixture('session_cancelled.json');
  cancelled.definitions = [cancelledSession.definition_snapshot];
  cancelled.sessions = [cancelledSession];
  delete cancelled.view;
  await load(cancelled);
  recorded.cancelled = snapshotReply(await exported());

  // 6. The injection fixture, stored by the engine like any other document.
  //    Its captured material is fetched too, so the harness exercises the page's
  //    fetched path rather than falling back to a refusal.
  const poisoned = poison(fixture('workshop_complete.mcouncil'));
  await load(poisoned);
  const hostileBase = await exported();
  // Hostile MATERIAL, captured the way real material is: the engine hashes the
  // text, places the quote and mints the anchor, so the excerpt the page renders
  // is a capture the contract accepted rather than a record edited past it.
  recorded.hostile_capture = await command('source.capture', {
    definition_id: hostileBase.definitions[0].definition_id,
    source_id: 'src-injected',
    title: 'Captured ' + HOSTILE,
    text: 'Before the payload.\n' + HOSTILE + '\nAfter the payload.',
    excerpts: [{ anchor_id: "anc-injected", quote: HOSTILE }]
  }, hostileBase.snapshot_revision);
  const hostile = await exported();
  recorded.hostile = snapshotReply(hostile);
  recorded.hostile_source = await command('source.fetch', {
    definition_id: hostile.definitions[0].definition_id,
    source_id: 'src-injected',
    source_revision: 1
  });

  // 7. The catalogue, as the wrapper's models command carries it.
  const { parsed: models } = await tool('minerva_council_models', {});
  recorded.models = {
    schema_version: 1, envelope: 'reply', request_id: '', ok: true,
    snapshot_revision: 0,
    payload: { models: models.models, known: models.known, refresh_error: models.refresh_error || '' }
  };

  await rpc('shutdown', {});
  child.stdin.end();

  const header = `// GENERATED by ui/tests/record-envelopes.mjs — do not edit.
//
// Every snapshot here came back from the real Council backend after it loaded a
// fixture from council/fixtures, and every refusal is one the engine produced.
// Regenerate with:  node council/ui/tests/record-envelopes.mjs
window.CouncilRecorded = `;
  writeFileSync(join(here, 'recorded.js'), header + JSON.stringify(recorded, null, 1) + ';\n');
  console.log('wrote ui/tests/recorded.js');
  for (const key of Object.keys(recorded)) {
    const entry = recorded[key];
    const revision = entry && entry.snapshot_revision;
    console.log(`  ${key}${revision !== undefined ? ' @ revision ' + revision : ''}`);
  }
}

main().then(() => process.exit(0)).catch((error) => {
  console.error(error);
  child.kill();
  process.exit(1);
});

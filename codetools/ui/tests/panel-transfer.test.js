// Run with: node codetools/ui/tests/panel-transfer.test.js
//
// Drives the REAL panel script out of ui/code_graph.html in a vm context.
// The oracle is the host's own bound: a webview bridge message is capped at
// 65,536 UTF-8 bytes in both directions with no bulk route, so the test serves
// the graph the way the worker does — as `paged_envelope` parts, each measured
// against the cap — and fails unless the page reassembles every node and edge.
// It also fails if a broken transfer leaves the page with a silent empty graph
// instead of an error.
//
// Not covered here (no browser): d3, layout, and the real IPC transport.

const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');

const CONTROL_BYTES = 65536;
const NODE_COUNT = 400;
const EDGE_COUNT = 399;

// ---- the page's own script, extracted verbatim -----------------------------
const html = fs.readFileSync(path.join(__dirname, '..', 'code_graph.html'), 'utf8');
const marker = html.lastIndexOf('<!-- Panel logic. -->');
assert.ok(marker > 0, 'panel logic script island not found');
const open = html.indexOf('<script>', marker) + '<script>'.length;
const close = html.indexOf('</script>', open);
let source = html.slice(open, close);

// Both oversized calls must go through the paged route.
assert.match(source, /callPaged\('minerva_codetools_get_graph'/,
  'the graph must be fetched through the paged route');
assert.match(source, /callPaged\('minerva_codetools_get_diff'/,
  'the diff must be fetched through the paged route');
// A failed diff must be reported, not swallowed into missing change markers.
assert.match(source, /catch \(e\) \{ setStatus\('Change markers unavailable/,
  'boot must surface a diff failure');

// Load the script without booting the panel: boot() needs a browser.
const booted = source.replace(/\bboot\(\);\s*$/, '');
assert.notEqual(booted, source, 'expected a trailing boot() call to strip');
source = booted;

// ---- DOM stub --------------------------------------------------------------
function element(id) {
  return {
    id,
    value: '',
    textContent: '',
    innerHTML: '',
    style: {},
    dataset: {},
    classList: {
      classes: new Set(),
      add(c) { this.classes.add(c); },
      remove(c) { this.classes.delete(c); },
      toggle(c, on) { if (on) this.classes.add(c); else this.classes.delete(c); },
      contains(c) { return this.classes.has(c); },
    },
    addEventListener() {},
    appendChild(child) { (this.children = this.children || []).push(child); },
  };
}

const nodes = new Map();
const document = {
  getElementById(id) {
    if (!nodes.has(id)) nodes.set(id, element(id));
    return nodes.get(id);
  },
  createElement(tag) { return element(tag); },
  querySelectorAll() { return []; },
};

// ---- the graph the worker holds --------------------------------------------
const graph = {
  type: 'code_graph',
  nodes: Array.from({ length: NODE_COUNT }, (_, i) => ({
    id: 'sym_' + i, name: 'sym_' + i, file: 'src/file_' + (i % 20) + '.gd',
    kind: 'function', fan_in: i % 5, fan_out: i % 3, x: i * 1.5, y: i * 2.5,
    signature: 'func sym_' + i + '(x: int) -> void',
    signature_hash: 'hash_' + i, line_start: i, line_end: i + 6,
    description: 'a symbol description long enough to matter. '.repeat(6),
  })),
  edges: Array.from({ length: EDGE_COUNT }, (_, i) => ({
    source: 'sym_' + i, target: 'sym_' + (i + 1), type: 'calls', confidence: 1,
  })),
  files: Array.from({ length: 20 }, (_, i) => ({ path: 'src/file_' + i + '.gd', description: '' })),
  analysis: { dead_code_ids: [], dry_signature_groups: {} },
  stats: { symbols: NODE_COUNT, edges: EDGE_COUNT, project_name: 'fixture' },
};
const envelopeText = JSON.stringify({
  status: 'ok', summary: 'code graph', artifacts: [graph],
  evidence_handles: [], follow_ups: [],
});
assert.ok(Buffer.byteLength(envelopeText, 'utf8') > CONTROL_BYTES,
  'the fixture graph must be over the cap or it proves nothing');

// ---- bridge stub: the worker's paged transfer, measured against the cap ----
// `drop` names a part the "worker" loses, so the test can check that a broken
// transfer reaches the page as an error.
function makeBridge(options = {}) {
  const state = { chunks: null, token: 'tok-' + Math.random().toString(16).slice(2), requests: [] };
  return {
    state,
    call(tool, args) {
      const request = { tool, args };
      const requestBytes = Buffer.byteLength(JSON.stringify(request), 'utf8');
      assert.ok(requestBytes <= CONTROL_BYTES,
        `request to ${tool} is ${requestBytes} bytes, over the cap`);
      state.requests.push(request);
      if (!args.page) return Promise.reject(new Error('panel must ask for a paged transfer'));

      if (args.page.token === undefined) {
        const budget = args.page.max_bytes;
        assert.ok(budget > 0 && budget <= CONTROL_BYTES, 'budget must sit under the cap');
        // Slice like the worker does. A part is escaped twice on the way out
        // (envelope -> MCP text content -> the host's reply), so a chunk is
        // sized well under the budget it is measured against below.
        const room = Math.floor(budget / 3);
        state.chunks = [];
        for (let i = 0; i < envelopeText.length; i += room) {
          state.chunks.push(envelopeText.slice(i, i + room));
        }
        return Promise.resolve(reply(0));
      }
      assert.equal(args.page.token, state.token, 'part request must carry the token');
      return Promise.resolve(reply(args.page.part));
    },
  };

  function reply(part) {
    if (options.drop === part) {
      // The worker lost this part: answer with the wrong one rather than
      // failing outright — the page must not accept it as a valid slice.
      part = part === 0 ? 1 : 0;
    }
    const envelope = {
      status: 'ok', summary: 'paged reply', evidence_handles: [], follow_ups: [],
      artifacts: [{
        type: 'paged_envelope', token: state.token, part,
        parts: state.chunks.length, total_bytes: Buffer.byteLength(envelopeText, 'utf8'),
        encoding: 'json', chunk: state.chunks[part],
      }],
    };
    // What the page really receives: the backend's {ok, result} wrapper as MCP
    // text content, re-serialized by the host — the shape window.minerva.call
    // resolves with.
    const payload = {
      content: [{ type: 'text', text: JSON.stringify({ ok: true, result: envelope }) }],
    };
    const size = Buffer.byteLength(JSON.stringify({ success: true, result: payload, id: 'x'.repeat(36) }), 'utf8');
    assert.ok(size <= CONTROL_BYTES, `part ${part} reply is ${size} bytes, over the cap`);
    return payload;
  }
}

function load(bridge) {
  const context = {
    window: { minerva: bridge, __MINERVA_PANEL: { data_directory: '/tmp/ct' } },
    document,
    console,
    ResizeObserver: function ResizeObserver() { return { observe() {} }; },
    setTimeout,
    clearTimeout,
    Math,
    Object,
    JSON,
    String,
    Number,
    Array,
    Set,
    Error,
    Promise,
    parseFloat,
    parseInt,
    d3: new Proxy(function () {}, { get: () => context.d3, apply: () => context.d3 }),
  };
  // The panel script is strict-mode global code; hand its helpers out
  // explicitly rather than relying on how declarations bind in a vm context.
  vm.runInNewContext(source + '\nglobalThis.__panel = { callPaged, callTool };\n', context);
  assert.equal(typeof context.__panel.callPaged, 'function', 'callPaged must load');
  return context.__panel;
}

(async () => {
  // A graph over the cap arrives whole.
  const good = makeBridge();
  const page = load(good);
  const artifact = await page.callPaged('minerva_codetools_get_graph', { db_path: '/tmp/ct/code_visualizer.db' });
  assert.equal(artifact.type, 'code_graph', 'reassembled artifact type');
  assert.equal(artifact.nodes.length, NODE_COUNT, 'every symbol survived the transfer');
  assert.equal(artifact.edges.length, EDGE_COUNT, 'every edge survived the transfer');
  assert.equal(artifact.stats.symbols, NODE_COUNT, "the worker's symbol count is intact");
  assert.deepEqual(artifact.nodes[NODE_COUNT - 1], graph.nodes[NODE_COUNT - 1],
    'the last node must match the one the worker built');

  const parts = good.state.chunks.length;
  assert.ok(parts > 1, 'the fixture must really need more than one part');
  assert.equal(good.state.requests.length, parts, 'one request per part, no re-runs');
  assert.ok(good.state.requests.slice(1).every((r) => r.args.db_path),
    'every part request carries the tool arguments the schema requires');

  // A transfer that breaks fails structurally — never a silently empty graph.
  const broken = makeBridge({ drop: 1 });
  const brokenPage = load(broken);
  await assert.rejects(
    brokenPage.callPaged('minerva_codetools_get_graph', { db_path: '/tmp/ct/code_visualizer.db' }),
    /did not arrive/,
    'a missing part must reach the page as an error');

  console.log('PASS: panel reassembles a ' + Buffer.byteLength(envelopeText, 'utf8')
    + '-byte graph from ' + parts + ' in-cap parts');
})().catch((error) => { console.error(error); process.exitCode = 1; });

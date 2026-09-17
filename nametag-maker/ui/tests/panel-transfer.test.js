// Run with: node nametag-maker/ui/tests/panel-transfer.test.js
//
// Drives the REAL panel script out of ui/nametag_panel.html in a vm context.
// The oracle is the host's own bound: every message on the webview bridge is
// capped at 65,536 UTF-8 bytes in both directions, so the test fails if any
// request or reply the page relies on crosses it, and it fails if the bytes the
// page hands PDF.js are not byte-for-byte the PDF the backend generated.
//
// Not covered here (no browser): PDF.js itself, canvas rasterization, the host
// dialog, and the real IPC transport — those are stubbed.

const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');

const CONTROL_BYTES = 65536;

// ---- the page's own script, extracted verbatim -----------------------------
const html = fs.readFileSync(path.join(__dirname, '..', 'nametag_panel.html'), 'utf8');
const marker = html.lastIndexOf('<!-- Panel logic. -->');
assert.ok(marker > 0, 'panel logic script island not found');
const open = html.indexOf('<script>', marker) + '<script>'.length;
const close = html.indexOf('</script>', open);
const source = html.slice(open, close);
assert.ok(source.includes('nametag_read_chunk'), 'panel script does not use the chunk route');
assert.ok(source.includes('deliver_by_token'), 'panel script does not use the token route');

// ---- a PDF the backend holds: bigger than one bridge message ---------------
const pdf = Buffer.alloc(200_000);
Buffer.from('%PDF-1.7\n').copy(pdf);
for (let i = 9; i < pdf.length; i++) pdf[i] = (i * 7 + Math.floor(i / 251)) & 0xff;
const ICON_PATH = '/home/me/logo.png';
const PAGE_COUNT = 3;
// The first transfer is dropped mid-pull, the way an expired or evicted one is:
// the page must start over exactly once and still show the preview.
let tokenSeq = 0;
let liveToken = null;
let dropNextChunk = true;

// ---- DOM stub --------------------------------------------------------------
function element(id) {
  return {
    id,
    value: '',
    checked: false,
    textContent: '',
    innerHTML: '',
    disabled: false,
    className: '',
    width: 0,
    height: 0,
    handlers: {},
    classList: {
      classes: new Set(),
      add(c) { this.classes.add(c); },
      remove(c) { this.classes.delete(c); },
      contains(c) { return this.classes.has(c); },
    },
    addEventListener(type, fn) { this.handlers[type] = fn; },
    appendChild(child) { (this.children = this.children || []).push(child); },
    focus() {},
    getContext() { return {}; },
  };
}

const nodes = new Map();
const document = {
  getElementById(id) {
    if (!nodes.has(id)) nodes.set(id, element(id));
    return nodes.get(id);
  },
  createElement(tag) { return element(tag); },
};
document.getElementById('pdfWorkerSource').textContent = '/* worker */';
document.getElementById('csv').value = 'Name,Class,Group #,Room Assignment\nAda,Algorithms,1,A-101\n';
document.getElementById('backMode').value = 'same';
document.getElementById('iconWidth').value = '0.40';
document.getElementById('offX').value = '0';
document.getElementById('offY').value = '0';

// ---- bridge stub: the backend's answers, measured against the real cap -----
const calls = [];
function bounded(label, value) {
  const size = Buffer.byteLength(JSON.stringify(value), 'utf8');
  assert.ok(size <= CONTROL_BYTES,
    `${label} is ${size} bytes, over the ${CONTROL_BYTES}-byte bridge cap`);
  return value;
}

const minerva = {
  call(tool, args) {
    bounded(`request to ${tool}`, { tool, arguments: args });
    calls.push({ tool, args });
    if (tool.endsWith('nametag_pick_icon')) {
      return Promise.resolve(bounded('pick_icon reply', { success: true, cancelled: false, path: ICON_PATH }));
    }
    if (tool.endsWith('nametag_generate')) {
      assert.equal(args.deliver_by_token, true, 'generate must ask for the token route');
      assert.equal(args.icon_path, ICON_PATH, 'generate must pass the icon by path');
      assert.ok(!('icon_png_base64' in args), 'the icon must not travel inline');
      liveToken = 'token-' + (++tokenSeq);
      return Promise.resolve(bounded('generate reply', {
        success: true, token: liveToken, byte_size: pdf.length,
        page_count: PAGE_COUNT, content_type: 'application/pdf',
      }));
    }
    if (tool.endsWith('nametag_read_chunk')) {
      const offset = args.offset;
      assert.equal(typeof offset, 'number', 'chunk request must carry a numeric offset');
      assert.ok(!('path' in args), 'a chunk is fetched by token, not by path');
      if (dropNextChunk) {
        dropNextChunk = false;
        return Promise.resolve(bounded('read_chunk refusal', {
          success: false, error_code: 'transfer_not_found',
          error_message: 'no transfer for this token',
        }));
      }
      if (args.token !== liveToken) {
        return Promise.resolve(bounded('read_chunk refusal', {
          success: false, error_code: 'transfer_not_found',
          error_message: 'stale token ' + args.token,
        }));
      }
      const end = Math.min(offset + 32 * 1024, pdf.length);
      return Promise.resolve(bounded('read_chunk reply', {
        success: true, offset, length: end - offset,
        total_bytes: pdf.length, eof: end >= pdf.length,
        bytes_b64: pdf.subarray(offset, end).toString('base64'),
      }));
    }
    if (tool.endsWith('nametag_save')) {
      return Promise.resolve(bounded('save reply', {
        success: true, saved: true, path: '/home/me/tags.pdf',
        bytes_written: pdf.length, page_count: PAGE_COUNT,
      }));
    }
    return Promise.reject(new Error('unexpected tool ' + tool));
  },
};

// ---- PDF.js stub: records exactly what the page handed it ------------------
let rendered = null;
const pdfjsLib = {
  GlobalWorkerOptions: {},
  getDocument(opts) {
    rendered = opts.data;
    return {
      promise: Promise.resolve({
        numPages: PAGE_COUNT,
        getPage() {
          return Promise.resolve({
            getViewport: () => ({ width: 612, height: 792 }),
            render: () => ({ promise: Promise.resolve() }),
          });
        },
      }),
    };
  },
};

const context = {
  window: { minerva },
  document,
  pdfjsLib,
  console,
  atob,
  Blob: function Blob() {},
  URL: { createObjectURL: () => 'blob:worker' },
  setTimeout,
  clearTimeout,
  Uint8Array,
  Math,
  Object,
  JSON,
  String,
  Number,
  Error,
  parseFloat,
};
vm.runInNewContext(source, context);

(async () => {
  // The page must be able to take an icon of any size: it picks a path.
  await document.getElementById('iconBtn').handlers.click();
  assert.match(document.getElementById('iconStatus').textContent, /logo\.png/);

  await document.getElementById('genBtn').handlers.click();

  const err = document.getElementById('genErr').textContent;
  assert.equal(err, '', 'generate reported an error: ' + err);

  // The bytes PDF.js rendered are the PDF the backend wrote — every chunk, in
  // order, nothing dropped or repeated.
  assert.ok(rendered instanceof context.Uint8Array || rendered instanceof Uint8Array,
    'the page must hand PDF.js raw bytes');
  assert.equal(rendered.length, pdf.length, 'reassembled length');
  assert.ok(Buffer.compare(Buffer.from(rendered), pdf) === 0, 'reassembled bytes differ from the generated PDF');

  // One page canvas per reported page.
  const pagesEl = document.getElementById('pages');
  const canvases = (pagesEl.children || []).filter((c) => c.id === 'canvas');
  assert.equal(canvases.length, PAGE_COUNT, 'every page is previewed');
  assert.match(document.getElementById('genInfo').textContent, new RegExp('^' + PAGE_COUNT + ' page'));

  // The transfer really was chunked, and a dropped transfer was restarted
  // exactly once — never a retry loop.
  const chunkCalls = calls.filter((c) => c.tool.endsWith('nametag_read_chunk'));
  assert.ok(chunkCalls.length >= Math.ceil(pdf.length / (32 * 1024)),
    'the page must walk the transfer in bridge-sized slices');
  const generateCalls = calls.filter((c) => c.tool.endsWith('nametag_generate'));
  assert.equal(generateCalls.length, 2, 'a lost transfer is restarted once, and only once');

  // Save still works, and still carries no bytes.
  await document.getElementById('saveBtn').handlers.click();
  assert.equal(document.getElementById('saveErr').textContent, '');
  assert.match(document.getElementById('saveOk').textContent, /Saved to: \/home\/me\/tags\.pdf/);
  const save = calls.find((c) => c.tool.endsWith('nametag_save'));
  assert.ok(save && save.args.icon_path === ICON_PATH && !('icon_png_base64' in save.args),
    'save reuses the path-based args');

  console.log('PASS: panel transfers a ' + pdf.length + '-byte PDF by token + chunks, all messages under the cap');
})().catch((error) => { console.error(error); process.exitCode = 1; });

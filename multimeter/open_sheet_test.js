// Actual panel and injected bridge code, with DOM/native transport edges only.
// Native capability/provider behavior is exercised by the Sheets runtime fixture.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const {webcrypto} = require('node:crypto');
const host = process.argv[2];
assert.ok(host, 'usage: node open_sheet_test.js PATH_TO_MINERVA');
const bridge = fs.readFileSync(path.join(host, 'src/Scripts/UI/Controls/WebViewEditor/minerva_bridge.gd'), 'utf8')
  .split('"""')[1].replace('<script>', '').replace('</script>', '');
const html = fs.readFileSync(path.join(__dirname, 'ui/multimeter_panel.html'), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]).find(text => text.includes('var openingSheet'));
assert.ok(script, 'actual recording panel script is present');
assert.ok(!html.includes('user-select: none'), 'error span keeps native text selection for copying');
const settle = () => new Promise(resolve => setImmediate(resolve));
function panel(file) {
  const elements = new Map();
  for (const match of html.matchAll(/id="([^"]+)"/g)) {
    const handlers = {};
    elements.set(match[1], {isConnected: true, disabled: false, value: '60', clientWidth: 400, clientHeight: 200,
      textContent: '', addEventListener: (event, callback) => {handlers[event] = callback;},
      getContext: () => ({setTransform() {}, clearRect() {}}), handlers});
  }
  const native = [], waiting = [], errors = [];
  let recording = false;
  const window = {addEventListener() {}, sendIpcMessage(raw) {
    const message = JSON.parse(raw), tool = message.payload.tool;
    native.push(message);
    if (tool === 'minerva_sheets_create_editor') {waiting.push(message); return;}
    let result = {};
    if (tool.endsWith('_record_start')) {recording = true; result = {path: file};}
    if (tool.endsWith('_record_stop')) {recording = false; result = {path: file, rows: 3};}
    if (tool.endsWith('_status')) result = {connected: false, recording: {recording, path: file, rows: 3}};
    if (tool.endsWith('_read')) result = {history: []};
    queueMicrotask(() => window.minerva._ipcReply({id: message.id, success: true, result}));
  }};
  const context = {window, document: {getElementById: id => elements.get(id), querySelectorAll: () => []},
    crypto: webcrypto, TextEncoder, console: {...console, error: message => errors.push(message)}, setTimeout, clearTimeout, setInterval() {}};
  vm.runInNewContext(bridge, context);
  vm.runInNewContext(script, context);
  return {elements, native, waiting, errors, window, click: id => elements.get(id).handlers.click(),
    reply(result) {const message = waiting.shift(); window.minerva._ipcReply({id: message.id, ...result});},
    poll() {window.minerva._dispatchPluginState({connected: false, recording: {recording: false}});}};
}
(async () => {
  const first = panel('/tmp/recording-one.csv'); await settle();
  await first.click('rec'); await settle();
  await first.click('rec'); await settle();
  const recordings = first.native.filter(x => /_record_(start|stop)$/.test(x.payload.tool)).length;
  assert.equal(recordings, 2);
  for (const code of ['tool_not_found', 'plugin_not_running', 'plugin_crashed']) {
    const pending = first.click('openSheet');
    first.click('openSheet'); first.poll();
    assert.equal(first.waiting.length, 1, 'double click sends once');
    assert.equal(first.elements.get('openSheet').disabled, true, 'poll cannot re-enable pending call');
    assert.deepEqual(first.waiting[0].payload.arguments, {name: 'Recording', file_path: '/tmp/recording-one.csv'});
    first.reply({success: false, error_code: code, error_message: 'native refusal'});
    await pending; first.poll();
    assert.equal(first.elements.get('err').textContent, '[' + code + '] native refusal');
    assert.equal(first.errors.at(-1), 'Open Recording: [' + code + '] native refusal');
    assert.equal(first.elements.get('openSheet').disabled, false, 'retry stays available');
  }
  const second = panel('/tmp/recording-two.csv'); await settle();
  await second.click('rec'); await settle();
  const one = first.click('openSheet'), two = second.click('openSheet');
  assert.equal(first.waiting.length, 1); assert.equal(second.waiting.length, 1);
  assert.equal(second.waiting[0].payload.arguments.file_path, '/tmp/recording-two.csv');
  first.reply({success: true, result: {editor_name: 'recording-one'}});
  second.elements.get('openSheet').isConnected = false;
  second.elements.get('err').isConnected = false;
  second.reply({success: false, error_code: 'provider_stopped', error_message: 'closed view'});
  await Promise.all([one, two]);
  assert.equal(second.elements.get('err').textContent, '', 'late failure does not write into retired panel');
  assert.equal(first.native.filter(x => /_record_(start|stop)$/.test(x.payload.tool)).length, recordings,
    'open, failure, retry and provider restart never repeat recording mutations');
  console.log('PASS: actual MultiMeter panel/native bridge pending, typed errors, retry, lifetime and two views');
})().catch(error => {console.error(error); process.exitCode = 1;});

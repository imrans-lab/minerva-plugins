// A stand-in for the wrapper that answers out of ui/tests/recorded.js.
//
// It is injected into a copy of the production page at the same point
// council_bridge.gd injects the real bridge, and it offers the same two
// functions — `call` and `onEvent` — so the page under test is byte-for-byte the
// page that ships. Nothing here shapes a reply: every envelope comes from
// recorded.js, which the real backend produced (ui/tests/record-envelopes.mjs).
//
// What it adds, for the harness only, is `window.__councilReplay`: which
// recorded document is being served, a way to swap it and fire the event that
// says the record moved, and the log of every call the page made — which is how
// a test can assert that rendering a hostile document fired no host action at
// all.

(function (global) {
  'use strict';

  var recorded = global.CouncilRecorded || {};
  var params = {};
  String(global.location.search || '').replace(/^\?/, '').split('&').forEach(function (pair) {
    if (!pair) { return; }
    var bits = pair.split('=');
    params[decodeURIComponent(bits[0])] = decodeURIComponent((bits[1] || '').replace(/\+/g, ' '));
  });

  var handlers = [];
  var log = [];
  var preferences = {};
  // A project with nothing in it — the state a first-time reader opens Council
  // in, and the only one the onboarding is reachable from.
  //
  // It is DERIVED from a recorded document rather than written here: the
  // recorder produces documents that hold something, and a snapshot with no
  // councils is that same record with its councils and sessions removed. Every
  // other field — schema version, project identity, revision — is still the
  // backend's own, so the page is reading a shape the engine really emits.
  var EMPTY = 'no_council';

  var current = (recorded[params.case] || params.case === EMPTY) ? params.case : 'complete';
  var forceStale = false;

  function emptied() {
    var base = snapshotFor('inventory');
    // A silent null would serve the page an empty reply and the failure would
    // read as a page bug rather than a missing recording.
    if (!base) { throw new Error('no recorded document named inventory to empty'); }
    var copy = JSON.parse(JSON.stringify(base));
    copy.definitions = [];
    copy.sessions = [];
    return copy;
  }

  function snapshotFor(key) {
    if (key === EMPTY) { return emptied(); }
    var entry = recorded[key];
    return entry && entry.payload ? entry.payload.snapshot : null;
  }

  function reply(body) {
    var snapshot = snapshotFor(current) || {};
    var out = {
      schema_version: 1,
      envelope: 'reply',
      request_id: '',
      ok: true,
      snapshot_revision: snapshot.snapshot_revision,
      payload: body || {}
    };
    return out;
  }

  function refusal(code, message, retryable) {
    var snapshot = snapshotFor(current) || {};
    return {
      schema_version: 1, envelope: 'reply', request_id: '', ok: false,
      snapshot_revision: snapshot.snapshot_revision,
      error: { code: code, message: message, retryable: !!retryable }
    };
  }

  // Every recorded fetch, by source and revision. A source the recorder did not
  // fetch answers with the engine's real missing_source refusal — which is the
  // right answer, but only for a source that really is absent, so anything the
  // page can open is recorded.
  function fetchTable() {
    var table = {};
    Object.keys(recorded.complete_sources || {}).forEach(function (key) {
      table[key] = recorded.complete_sources[key];
    });
    [recorded.source_fetch, recorded.hostile_source, recorded.punctuation_source].forEach(function (reply) {
      if (!reply || !reply.ok || !reply.payload || !reply.payload.source) { return; }
      var source = reply.payload.source;
      table[source.source_id + '@' + source.source_revision] = reply;
    });
    return table;
  }

  var fetches = fetchTable();

  function sourceReply(payload) {
    return fetches[payload.source_id + '@' + payload.source_revision]
      || recorded.source_missing;
  }

  function answer(command, payload, baseRevision) {
    if (command === 'wrapper.describe') {
      return reply({
        panel_key: 'replay#1',
        plugin_id: 'council',
        file_path: '',
        unreadable: params.unreadable === '1',
        unreadable_reason: params.unreadable === '1'
          ? 'This file is not a Council document, so Council will not change it.'
          : '',
        theme: { dark: params.theme === 'dark', font_size: 16 },
        max_message_code_units: 32768,
        // Mirrors council_panel.gd TEXT_SCALES, which is the authority.
        text_scales: [0.85, 1.0, 1.12, 1.28, 1.45, 1.7]
      });
    }
    if (command === 'snapshot.get') { return reply({ snapshot: snapshotFor(current) || {} }); }
    if (command === 'wrapper.get_preferences') { return reply(preferences); }
    if (command === 'wrapper.set_preference') {
      preferences.text_scale = payload.text_scale;
      return reply({ stored: true, text_scale: payload.text_scale });
    }
    // Re-framed against the document being served: the recorded catalogue was
    // read with no document loaded, and handing its revision back would tell the
    // page the record had moved to 0.
    if (command === 'wrapper.models') { return reply(recorded.models.payload); }
    if (command === 'wrapper.set_view') { return reply({ view: payload.view }); }
    if (command === 'wrapper.chat_handoff') {
      return reply({ chat_id: 'chat-0192ab', characters: 1234 });
    }
    if (command === 'source.fetch') { return sourceReply(payload); }
    // Every mutation replays a refusal the engine really produced, unless the
    // harness has asked for the stale one: the page's job on a write is to show
    // what came back, and a fabricated success would test nothing.
    if (forceStale) { forceStale = false; return recorded.stale; }
    if (command === 'run.retry' || command === 'run.start') { return recorded.run_started; }
    if (command === 'source.capture') { return recorded.hostile_capture; }
    return refusal('internal', 'The replay harness has no recorded reply for ' + command + '.', false);
  }

  global.council = {
    call: function (command, payload, baseRevision) {
      log.push({ command: command, payload: payload, base_revision: baseRevision });
      var body = answer(command, payload || {}, baseRevision);
      // Asynchronous, like the real hop: a page that only works when replies
      // arrive synchronously does not work at all.
      return new Promise(function (resolve) { setTimeout(function () { resolve(body); }, 0); });
    },
    onEvent: function (cb) { handlers.push(cb); }
  };

  function fire(event) {
    handlers.forEach(function (handler) {
      try { handler(event); } catch (e) { /* one bad handler must not stop the rest */ }
    });
  }

  global.__councilReplay = {
    calls: log,
    current: function () { return current; },
    // Swap the served document and tell the page the record moved — which is
    // exactly what the wrapper does, and all it does.
    advance: function (key) {
      if (!recorded[key] && key !== EMPTY) { throw new Error('no recorded document named ' + key); }
      current = key;
      fire({ schema_version: 1, envelope: 'event', event: 'council.snapshot_changed', payload: {} });
    },
    theme: function (dark) {
      fire({ schema_version: 1, envelope: 'event', event: 'council.theme_changed', payload: { dark: !!dark } });
    },
    staleNext: function () { forceStale = true; },
    preferences: function () { return preferences; }
  };

  // Deep links, for the screenshot run only. The shipped page has no query
  // string — the wrapper stages it at a path it mints — so opening a state
  // directly is done by driving the page's own navigation once it has booted,
  // exactly as a click would.
  function parseDetail(spec) {
    var bits = String(spec).split(':');
    if (bits[0] === 'source') {
      return { kind: 'source', source_id: bits[1], revision: Number(bits[2]), anchor_id: bits[3] || '' };
    }
    if (bits[0] === 'member') { return { kind: 'member', member_id: bits[1] }; }
    if (bits[0] === 'compare') { return { kind: 'compare', ids: (bits[1] || '').split(',') }; }
    if (bits[0] === 'add_member' || bits[0] === 'create_council') { return { kind: bits[0] }; }
    return null;
  }

  function applyDeepLink() {
    var app = global.CouncilApp;
    if (!app) { return setTimeout(applyDeepLink, 40); }
    var revision = document.getElementById('revision');
    if (!revision || revision.textContent.indexOf('revision ') !== 0) {
      return setTimeout(applyDeepLink, 40);
    }
    if (params.pane) { app.state.pane = params.pane; }
    if (params.detail) { app.state.detail = parseDetail(params.detail); }
    app.render();
  }

  if (params.pane || params.detail) {
    document.addEventListener('DOMContentLoaded', applyDeepLink);
  }

  if (params.theme === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
  }
  if (params.motion === 'reduce') {
    document.documentElement.setAttribute('data-motion', 'reduce');
  }
  if (params.w) {
    document.addEventListener('DOMContentLoaded', function () {
      var panel = document.getElementById('panel');
      if (panel) { panel.style.maxWidth = String(Number(params.w)) + 'px'; }
      document.documentElement.setAttribute('data-framed', '');
    });
  }
})(window);

// The prototype's behaviour: what it reads, what it shows, and what it does
// when an answer arrives while you are reading something else.
//
// Three rules this file exists to prove out for the production panel:
//
//  1. The page is a view. Every render comes from a fresh snapshot.get; nothing
//     is patched in place from an event payload, because an event carries no
//     authority.
//  2. Reading position is protected. Before a re-render the topmost visible
//     block is remembered by key, and afterwards the scroller is nudged so that
//     block sits where it was. Late answers never shove the paragraph you are
//     reading up the screen.
//  3. Detail is a push, not a jump. Opening a member, a source or a comparison
//     records where you were and which control you used; Back restores both,
//     and Escape is Back.

(function (global) {
  'use strict';

  var V = global.CouncilViews;

  var state = {
    snapshot: null,
    revision: null,
    pane: 'session',
    detail: null,
    scenario: null,
    demoNote: '',
    seen: {},
    returnTo: null,
    message: ''
  };

  var el = {};

  // ------------------------------------------------------------------ query

  function query() {
    var out = {};
    global.location.search.replace(/^\?/, '').split('&').forEach(function (pair) {
      if (!pair) { return; }
      var bits = pair.split('=');
      out[decodeURIComponent(bits[0])] = decodeURIComponent((bits[1] || '').replace(/\+/g, ' '));
    });
    return out;
  }

  // Deep-linked detail, so a state can be opened directly for a screenshot or
  // pointed at during a walkthrough: detail=source:src.narrow-shop:2:a.year-test
  function parseDetail(spec) {
    if (!spec) { return null; }
    var bits = spec.split(':');
    if (bits[0] === 'source') {
      return { kind: 'source', source_id: bits[1], revision: Number(bits[2]), anchor_id: bits[3] || '' };
    }
    if (bits[0] === 'member') { return { kind: 'member', member_id: bits[1] }; }
    if (bits[0] === 'compare') { return { kind: 'compare', ids: (bits[1] || '').split(',') }; }
    if (bits[0] === 'ask') { return { kind: 'ask' }; }
    return null;
  }

  // --------------------------------------------------------------- plumbing

  function session() {
    var sessions = (state.snapshot && state.snapshot.sessions) || [];
    var wanted = (state.snapshot.view || {}).selected_session_id;
    var picked = null;
    sessions.forEach(function (s) { if (s.session_id === wanted) { picked = s; } });
    return picked || sessions[sessions.length - 1] || null;
  }

  function say(text) {
    state.message = text || '';
    el.message.textContent = state.message;
  }

  function announce(text) { el.announcer.textContent = text; }

  function accept(reply) {
    if (reply && reply.snapshot_revision !== undefined) { state.revision = reply.snapshot_revision; }
    if (reply && reply.ok === false) { say(reply.error ? reply.error.message : 'Refused.'); }
    return reply;
  }

  function read() {
    return global.council.call('snapshot.get', {}).then(accept).then(function (reply) {
      if (!reply.ok) { return; }
      state.snapshot = reply.payload.snapshot;
      render();
    });
  }

  // Mutations go one at a time. Two in flight together race for the same
  // revision: the second is written against a number the first has already
  // moved, so it comes back stale through no fault of the reader - and its
  // refusal is then overwritten by the first one's success message. Serialising
  // them costs nothing at human speed and removes the whole class.
  var inFlight = Promise.resolve();

  function mutate(command, payload) {
    var run = inFlight.then(function () {
      return global.council.call(command, payload, state.revision).then(accept).then(function (reply) {
        return read().then(function () { return reply; });
      });
    });
    inFlight = run.catch(function () { /* one failure must not wedge the queue */ });
    return run;
  }

  // ------------------------------------------------- reading-position anchor

  function captureAnchor(scroller) {
    var frame = scroller.getBoundingClientRect();
    var nodes = scroller.querySelectorAll('[data-anchor]');
    for (var i = 0; i < nodes.length; i++) {
      var offset = nodes[i].getBoundingClientRect().top - frame.top;
      if (offset >= -8) { return { key: nodes[i].getAttribute('data-anchor'), offset: offset }; }
    }
    return null;
  }

  function restoreAnchor(scroller, anchor) {
    if (!anchor) { return; }
    var node = scroller.querySelector('[data-anchor="' + anchor.key + '"]');
    if (!node) { return; }
    var offset = node.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
    scroller.scrollTop += (offset - anchor.offset);
  }

  function inView(node, scroller) {
    var frame = scroller.getBoundingClientRect();
    var box = node.getBoundingClientRect();
    return box.top < frame.bottom && box.bottom > frame.top;
  }

  // ----------------------------------------------------------------- render

  function render() {
    var snap = state.snapshot;
    var current = session();
    var definition = V.definitionOf(current, snap);

    // Masthead: the question is the largest thing on the page when there is one.
    var name = definition ? definition.name : 'Council';
    el.councilName.innerHTML = '<span>' + V.esc(name) + '</span>'
      + (definition ? '<span>rev ' + V.esc(definition.definition_revision) + '</span>' : '');
    el.question.textContent = current ? current.question : 'No question yet';
    el.questionMeta.innerHTML = current
      ? '<span class="status" data-status="' + V.esc(current.status) + '">' + V.esc(current.status) + '</span>'
        + '<span>' + V.esc((current.runs || []).length) + ' round(s)</span>'
        + '<span>chat ' + V.esc((current.chat_binding || {}).chat_id || 'not bound') + '</span>'
      : '<span>' + V.esc(((snap.definitions || [])[0] ? 'Ready to be asked' : 'Nothing assembled yet')) + '</span>';

    Array.prototype.forEach.call(el.panes.querySelectorAll('button'), function (b) {
      b.setAttribute('aria-selected', String(b.getAttribute('data-pane') === state.pane));
    });

    var anchor = captureAnchor(el.reading);

    var html;
    if (state.pane === 'members') { html = V.membersPane(snap, current); }
    else if (state.pane === 'sources') { html = V.sourcesPane(snap, current); }
    else { html = V.sessionPane(snap, current, { demoNote: state.demoNote }); }
    el.reading.innerHTML = html;

    restoreAnchor(el.reading, anchor);
    renderDetail(current);
    el.revision.textContent = 'revision ' + state.revision;
    noteArrivals(current);
  }

  function renderDetail(current) {
    var detail = state.detail;
    el.stage.setAttribute('data-detail', detail ? 'open' : 'closed');

    if (!detail) {
      el.detail.innerHTML = V.glance(state.snapshot, current);
      return;
    }

    var definition = V.definitionOf(current, state.snapshot);
    var body = '';
    if (detail.kind === 'member') { body = V.memberDetail(definition, detail.member_id); }
    else if (detail.kind === 'source') { body = V.sourceDetail(definition, detail.source_id, detail.revision, detail.anchor_id, detail.fetched); }
    else if (detail.kind === 'compare') { body = V.compareDetail(current, detail.ids); }
    else if (detail.kind === 'follow_up') { body = V.followUpDetail(current, detail.seat_id, detail.from); }
    else if (detail.kind === 'ask') { body = V.askDetail(state.snapshot); }

    el.detail.innerHTML = '<p class="back-row"><button class="action quiet" data-back>&larr; Back</button></p>' + body;

    if (detail.focusOnOpen) {
      detail.focusOnOpen = false;
      var head = el.detail.querySelector('#detail-title');
      if (head) { head.focus(); }
      // Deliberately no scroll to the marked span: the quote is already shown
      // above the capture, and a view that jumps on open is a view that has
      // taken the reading position away from the reader.
      el.detail.scrollTop = 0;
    }
  }

  // A contribution that completes while you are reading gets announced and
  // offered, never scrolled to: the reader decides when to move.
  function noteArrivals(current) {
    var fresh = [];
    if (current) {
      (current.runs || []).forEach(function (run) {
        (run.contributions || []).forEach(function (c) {
          if (c.status !== 'complete') { return; }
          if (state.seen[c.contribution_id]) { return; }
          state.seen[c.contribution_id] = true;
          fresh.push(c);
        });
      });
    }
    if (!fresh.length || !state.started) { state.started = true; el.arrival.hidden = true; return; }

    var definition = V.definitionOf(current, state.snapshot);
    var last = fresh[fresh.length - 1];
    var who = (V.memberOf(definition, last.member_id) || {}).display_name || last.seat_id;
    announce(who + ' answered.');

    var node = el.reading.querySelector('#contrib-' + cssId(last.contribution_id));
    if (state.pane !== 'session' || !node || inView(node, el.reading)) { el.arrival.hidden = true; return; }
    el.arrival.hidden = false;
    el.arrival.textContent = who + ' answered ↓';
    el.arrival.onclick = function () {
      var target = el.reading.querySelector('#contrib-' + cssId(last.contribution_id));
      if (target) { target.scrollIntoView({ block: 'start' }); target.focus(); }
      el.arrival.hidden = true;
    };
  }

  function cssId(value) { return String(value).replace(/[^A-Za-z0-9_-]/g, '\\$&'); }

  // -------------------------------------------------------------- navigation

  // A re-render replaces every node in the reading column, so a remembered DOM
  // node is dead by the time Back runs. What survives a render is the control's
  // data attributes, so the return trip is recorded as a selector.
  function selectorFor(node) {
    if (!node || !node.attributes) { return ''; }
    var parts = [node.tagName.toLowerCase()];
    Array.prototype.forEach.call(node.attributes, function (a) {
      if (a.name.indexOf('data-') === 0) { parts.push('[' + a.name + '="' + a.value + '"]'); }
    });
    return parts.length > 1 ? parts.join('') : '';
  }

  function openDetail(detail, trigger) {
    if (!state.detail) {
      // No pane is recorded: a detail can only be opened from the pane you are
      // on, and switching pane closes the detail, so there is never one to
      // return to.
      state.returnTo = {
        scrollTop: el.reading.scrollTop,
        trigger: selectorFor(trigger)
      };
    }
    detail.focusOnOpen = true;
    state.detail = detail;
    render();
  }

  function back() {
    var to = state.returnTo;
    state.detail = null;
    state.returnTo = null;
    render();
    if (!to) { return; }
    el.reading.scrollTop = to.scrollTop;
    var trigger = to.trigger ? el.reading.querySelector(to.trigger) : null;
    if (trigger) {
      // preventScroll: focus must not undo the scroll position just restored.
      trigger.focus({ preventScroll: true });
    } else {
      el.reading.focus({ preventScroll: true });
    }
  }

  function goPane(pane) {
    state.pane = pane;
    state.detail = null;
    state.returnTo = null;
    el.reading.scrollTop = 0;
    render();
    global.council.call('wrapper.set_view', { view: { pane: pane, selected_session_id: (session() || {}).session_id } }).then(accept);
  }

  // ----------------------------------------------------------------- actions

  function onClick(event) {
    var target = event.target.closest('[data-back], [data-pane], [data-goto-pane], [data-open-member],'
      + '[data-open-source], [data-compare], [data-compare-add], [data-follow-up], [data-send-follow-up],'
      + '[data-retain], [data-retry-run], [data-retry-seat], [data-cancel-run], [data-ask], [data-send-question],'
      + '[data-create-council], [data-seat-member]');
    if (!target) { return; }
    var d = target.dataset;

    if (d.back !== undefined) { back(); return; }
    if (d.pane) { goPane(d.pane); return; }
    if (d.gotoPane) { goPane(d.gotoPane); return; }

    if (d.openMember) { openDetail({ kind: 'member', member_id: d.openMember }, target); return; }

    if (d.openSource) {
      var wanted = { kind: 'source', source_id: d.openSource, revision: Number(d.revision), anchor_id: d.anchor || '' };
      openDetail(wanted, target);
      // The material itself is fetched, not read out of the roster: in
      // production it can exceed the inline limit and live in a blob.
      global.council.call('source.fetch', { source_id: wanted.source_id, source_revision: wanted.revision })
        .then(accept).then(function (reply) {
          if (!reply.ok || state.detail !== wanted) { return; }
          wanted.fetched = reply.payload.source;
          render();
        });
      return;
    }

    if (d.compare) { openDetail({ kind: 'compare', ids: [d.compare] }, target); return; }
    if (d.compareAdd) {
      state.detail.ids = state.detail.ids.slice(0, 1).concat([d.compareAdd]);
      state.detail.focusOnOpen = true;
      render();
      return;
    }

    if (d.followUp) { openDetail({ kind: 'follow_up', seat_id: d.followUp, from: d.from }, target); return; }

    if (d.sendFollowUp) {
      var text = (el.detail.querySelector('#follow-up-text') || {}).value || '';
      if (!text.trim()) { say('Write the follow-up first.'); return; }
      mutate('run.start', { session_id: (session() || {}).session_id, seat_id: d.sendFollowUp, prompt: text })
        .then(function (reply) {
          if (!reply.ok) { return; }
          say('Asked. The rest of the council is not re-run.');
          state.detail = null;
          state.returnTo = null;
          state.pane = 'session';
          render();
        });
      return;
    }

    // Valueless data attributes read back as '', which is falsy: these have to
    // be tested for presence, not for truth.
    if (d.ask !== undefined) { openDetail({ kind: 'ask' }, target); return; }

    if (d.sendQuestion !== undefined) {
      var question = (el.detail.querySelector('#question-text') || {}).value || '';
      if (!question.trim()) { say('Write the question first.'); return; }
      // Move to the session before the round exists: the reader asked a
      // question and should be looking at where the answer will appear, not at
      // the roster they asked it from.
      state.detail = null; state.returnTo = null; state.pane = 'session';
      mutate('session.create', { question: question }).then(function (reply) {
        if (!reply.ok) { return; }
        return mutate('run.start', { session_id: reply.payload.session_id }).then(function () {
          say('The round is open. Every seat has the same context.');
        });
      });
      return;
    }

    if (d.createCouncil !== undefined) {
      mutate('definition.upsert', {
        name: 'Bindery decisions',
        purpose: 'Decide the awkward calls for a two-person hand bindery: what to take on, what to refuse, and what to stop doing.'
      }).then(function (reply) { if (reply.ok) { say('Council created with a chair. Give it seats.'); } });
      return;
    }

    if (d.seatMember) {
      var definition = V.definitionOf(session(), state.snapshot);
      var member = V.memberOf(definition, d.seatMember);
      var template = null;
      global.CouncilSample.seats.forEach(function (s) { if (s.member_id === d.seatMember) { template = s; } });
      if (!template) { return; }
      mutate('definition.upsert', { seat: template }).then(function (reply) {
        if (reply.ok) { say(member.display_name + ' now holds a seat.'); }
      });
      return;
    }

    if (d.retain) {
      var run = null;
      ((session() || {}).runs || []).forEach(function (r) {
        (r.contributions || []).concat(r.synthesis ? [r.synthesis] : []).forEach(function (c) {
          if (c.contribution_id === d.retain) { run = r; }
        });
      });
      // The record moved between render and click if this is null. Say so;
      // crashing would leave the panel looking dead with no explanation.
      if (!run) { say('That answer is no longer in the session. The panel has re-read it.'); read(); return; }
      mutate('outcome.retain', {
        session_id: (session() || {}).session_id, run_id: run.run_id, contribution_id: d.retain
      }).then(function (reply) { if (reply.ok) { say('Kept as a note.'); } });
      return;
    }

    if (d.retryRun) { mutate('run.retry', { run_id: d.retryRun }).then(function (r) { if (r.ok) { say('Retrying.'); } }); return; }

    if (d.retrySeat) {
      var lastRun = ((session() || {}).runs || []).slice(-1)[0];
      if (!lastRun) { say('There is no round to retry. The panel has re-read the session.'); read(); return; }
      mutate('run.retry', { run_id: lastRun.run_id, seat_id: d.retrySeat })
        .then(function (r) { if (r.ok) { say('Asking that seat again.'); } });
      return;
    }

    if (d.cancelRun) {
      mutate('run.cancel', { run_id: d.cancelRun })
        .then(function (r) { if (r.ok) { say('Cancelled. Answers already in are kept.'); } });
    }
  }

  function onKeydown(event) {
    if (event.key === 'Escape' && state.detail) {
      event.preventDefault();
      back();
    }
  }

  // ------------------------------------------------------------ scaffolding

  function scaffold(scenarioKey, params) {
    var options = Object.keys(global.CouncilScenarios.scenarios).map(function (key) {
      return '<option value="' + key + '"' + (key === scenarioKey ? ' selected' : '') + '>'
        + V.esc(global.CouncilScenarios.scenarios[key].label) + '</option>';
    }).join('');

    el.scaffold.innerHTML = 'Prototype scaffolding, not part of the panel: '
      + '<label class="visually-hidden" for="scenario">State</label>'
      + '<select id="scenario">' + options + '</select>'
      + '<button id="toggle-theme">' + (params.theme === 'dark' ? 'Light' : 'Dark') + '</button>'
      + '<button id="toggle-motion">' + (params.motion === 'reduce' ? 'Motion on' : 'Reduce motion') + '</button>'
      + '<button id="fake-stale" title="Make the next change carry the wrong revision">Simulate a stale view</button>';

    document.getElementById('scenario').onchange = function (e) {
      go({ scenario: e.target.value, theme: params.theme, motion: params.motion });
    };
    document.getElementById('toggle-theme').onclick = function () {
      go({ scenario: scenarioKey, theme: params.theme === 'dark' ? 'light' : 'dark', motion: params.motion });
    };
    document.getElementById('toggle-motion').onclick = function () {
      go({ scenario: scenarioKey, theme: params.theme, motion: params.motion === 'reduce' ? '' : 'reduce' });
    };
    document.getElementById('fake-stale').onclick = function () {
      global.councilMockControl.staleNext = true;
      say('The next change will be written against an old revision.');
    };
  }

  function go(params) {
    var bits = ['scenario=' + params.scenario];
    if (params.theme) { bits.push('theme=' + params.theme); }
    if (params.motion) { bits.push('motion=' + params.motion); }
    global.location.search = '?' + bits.join('&');
  }

  // ------------------------------------------------------------------ start

  function boot() {
    el = {
      councilName: document.getElementById('council-name'),
      question: document.getElementById('question'),
      questionMeta: document.getElementById('question-meta'),
      panes: document.getElementById('panes'),
      stage: document.getElementById('stage'),
      reading: document.getElementById('reading'),
      detail: document.getElementById('detail'),
      message: document.getElementById('message'),
      revision: document.getElementById('revision'),
      announcer: document.getElementById('announcer'),
      arrival: document.getElementById('arrival'),
      scaffold: document.getElementById('scaffold')
    };

    var params = query();
    var key = global.CouncilScenarios.scenarios[params.scenario] ? params.scenario : 'ordinary';
    var scenario = global.CouncilScenarios.scenarios[key];
    state.scenario = key;
    state.demoNote = scenario.demo_note || '';
    state.pane = ['session', 'members', 'sources'].indexOf(params.pane) >= 0 ? params.pane : null;
    state.detail = parseDetail(params.detail);
    if (state.detail) { state.detail.focusOnOpen = true; }

    document.documentElement.setAttribute('data-theme', params.theme === 'dark' ? 'dark' : 'light');
    // ?w= frames the panel at an exact width. Headless Chrome will not take a
    // window narrower than 500px, and the layout answers to the panel's width
    // rather than the window's, so this captures 400px honestly.
    if (params.w) {
      document.getElementById('panel').style.maxWidth = String(Number(params.w)) + 'px';
      document.documentElement.setAttribute('data-framed', '');
    }
    if (params.motion === 'reduce') { document.documentElement.setAttribute('data-motion', 'reduce'); }

    global.CouncilMock.install(scenario, { dark: params.theme === 'dark' });
    scaffold(key, { theme: params.theme || 'light', motion: params.motion || '' });

    document.addEventListener('click', onClick);
    document.addEventListener('keydown', onKeydown);

    global.council.onEvent(function (event) {
      if (event.event === 'council.theme_changed') {
        document.documentElement.setAttribute('data-theme', event.payload.dark ? 'dark' : 'light');
        return;
      }
      read(); // an event says the record moved; it never says what it now is
    });

    global.council.call('wrapper.describe', {}).then(accept).then(function (reply) {
      if (reply.ok && reply.payload.unreadable) { say(reply.payload.unreadable_reason); }
      return read();
    }).then(function () {
      if (!state.pane) { state.pane = (state.snapshot.view || {}).pane || 'session'; render(); }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})(window);

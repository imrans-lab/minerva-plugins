// What the panel does: what it reads, what it shows, and what it does when an
// answer arrives while you are reading something else.
//
// Four rules this file exists to hold:
//
//  1. The page is a view. Every render comes from a fresh snapshot.get. Nothing
//     is patched in place from an event payload, because an event carries no
//     authority — it says the record moved and never says what it now is.
//  2. Reading position is protected. Before a re-render the topmost visible
//     block is remembered by key; afterwards the scroller is nudged so that
//     block sits where it was. Saving scrollTop alone does not work, because
//     content inserted above the viewport changes what that number means.
//  3. Detail is a push, not a jump. Opening a member, a source or a comparison
//     records where you were and which control you used; Back restores both, and
//     Escape is Back. The control is remembered as a SELECTOR, not as a node: a
//     render replaces every node in the column, so a remembered node is detached
//     by the time Back runs and focusing it does nothing at all.
//  4. A refusal is not a status message. It stays until it is acknowledged or
//     acted on, where an ordinary note fades with the next thing that happens.

(function (global) {
  'use strict';

  var D = global.CouncilDom;
  var R = global.CouncilRecord;
  var el = D.el;

  var state = {
    snapshot: {},
    pane: 'session',
    detail: null,
    returnTo: null,
    picked: {},
    seen: {},
    started: false,
    models: [],
    modelsKnown: false,
    unreadable: '',
    refusal: null
  };

  var ui = {};
  var bridge = null;
  // Whether the refusal currently up is the wrapper's "this council is behind"
  // one. The wrapper says when that stops being true, and only that refusal is
  // taken down then — one the reader is looking at for another reason stays.
  var syncRefusal = false;
  var textSize = null;

  // ------------------------------------------------------------- messages

  function say(text) {
    state.refusal = null;
    D.replace(ui.message, text ? el('span', { text: text }) : null);
  }

  // A refusal stays put. One status line shared with successes loses the reason
  // a change was rejected to whatever happened next, which is the one message a
  // reader actually needs.
  function refuse(error) {
    state.refusal = error;
    D.replace(ui.message, el('span', { class: 'refusal' }, [
      error.message || 'Refused.',
      ' ',
      el('button', {
        class: 'action quiet',
        type: 'button',
        data: { 'dismiss-refusal': '1' },
        text: 'Dismiss'
      })
    ]));
  }

  function announce(text) { ui.announcer.textContent = text; }

  // -------------------------------------------------- reading-position anchor

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

  // ---------------------------------------------------------------- render

  function currentSession() { return R.selectedSession(state.snapshot); }

  function renderMasthead(session, definition) {
    D.replace(ui.councilName, [
      el('span', { text: definition ? definition.name : 'Council' }),
      definition && el('span', { text: 'rev ' + R.text(definition.definition_revision) })
    ]);
    ui.question.textContent = session ? R.text(session.question) : 'No question yet';

    var binding = (session && session.chat_binding) || {};
    D.replace(ui.questionMeta, session
      ? [
          el('span', { class: 'status', data: { status: session.status }, text: session.status }),
          el('span', { text: R.runsOf(session).length + ' round(s)' }),
          el('span', {
            text: binding.chat_id
              ? (binding.missing ? 'chat ' + binding.chat_id + ' (missing)' : 'chat ' + binding.chat_id)
              : 'not bound to a chat'
          })
        ]
      : [el('span', {
          text: R.list(state.snapshot.definitions).length
            ? 'Ready to be asked' : 'Nothing assembled yet'
        })]);
  }

  function renderFootrail() {
    D.replace(ui.sizer, [
      el('span', { class: 'visually-hidden', id: 'text-size-label', text: 'Council text size' }),
      el('button', {
        type: 'button',
        data: { 'text-smaller': '1' },
        title: 'Smaller text (Ctrl and minus)',
        aria: { label: 'Smaller text' },
        disabled: textSize.canShrink() ? null : true,
        text: 'A−'
      }),
      el('button', {
        type: 'button',
        data: { 'text-reset': '1' },
        title: 'Reset the text size (Ctrl and 0)',
        aria: { label: 'Reset text size' },
        text: textSize.label()
      }),
      el('button', {
        type: 'button',
        data: { 'text-larger': '1' },
        title: 'Larger text (Ctrl and plus)',
        aria: { label: 'Larger text' },
        disabled: textSize.canGrow() ? null : true,
        text: 'A+'
      })
    ]);
    ui.revision.textContent = 'revision ' + R.text(bridge.revision);
  }

  function readingContent(session) {
    if (state.unreadable) {
      return el('div', { class: 'notice' }, [
        el('h3', { text: 'This document is not one Council can edit' }),
        state.unreadable,
        el('p', {
          class: 'superseded flush group-tight',
          text: 'It is kept exactly as it was found and is handed back unchanged when the tab is saved.'
        })
      ]);
    }
    if (state.pane === 'members') {
      return global.CouncilMembersPane.membersPane(state.snapshot, session);
    }
    if (state.pane === 'sources') {
      return global.CouncilSourcesPane.sourcesPane(state.snapshot, session);
    }
    return global.CouncilSessionPane.sessionPane(state.snapshot, session, { picked: state.picked });
  }

  function detailContent(session) {
    var detail = state.detail;
    var definition = R.definitionOf(session, state.snapshot);
    var editable = R.editableDefinition(state.snapshot, session);
    var context = {
      models: state.models,
      modelsKnown: state.modelsKnown,
      editable: !!editable
    };
    var V = global.CouncilDetail;

    if (detail.kind === 'member') {
      return V.memberDetail(editable || definition, detail.member_id, context);
    }
    if (detail.kind === 'source') {
      return V.sourceDetail(definition, detail.source_id, detail.revision, detail.anchor_id, detail.fetched);
    }
    if (detail.kind === 'compare') { return V.compareDetail(session, detail.ids); }
    if (detail.kind === 'follow_up') { return V.followUpDetail(session, detail, context); }
    if (detail.kind === 'help') { return V.helpDetail(); }
    if (detail.kind === 'create_council') { return V.createCouncilDetail(); }
    if (detail.kind === 'add_member') { return V.addMemberDetail(context); }
    if (detail.kind === 'seat_member') { return V.seatMemberDetail(editable, detail.member_id); }
    return null;
  }

  // What the reader has typed but not sent.
  //
  // A composer is the one place in the panel holding something that exists
  // nowhere else, and the panel re-renders on every event — an answer landing
  // mid-round, the model catalogue arriving after a chooser was opened. Both
  // replace the detail column under a half-written follow-up. So the values are
  // lifted out before the replace and put back after it, along with the cursor,
  // whenever the SAME detail is being redrawn. A different detail is a different
  // form and gets none of this.
  function captureDraft(root) {
    var draft = { values: {}, focus: '', start: 0, end: 0 };
    var fields = root.querySelectorAll('input[id], textarea[id], select[id]');
    for (var i = 0; i < fields.length; i++) {
      var field = fields[i];
      if (field.type === 'checkbox' || field.type === 'radio') { continue; }
      draft.values[field.id] = field.value;
      if (field === document.activeElement) {
        draft.focus = field.id;
        // A select has no selection range, and reading one throws in some
        // browsers, so it is only asked of the fields that have it.
        if (field.selectionStart !== undefined && field.selectionStart !== null) {
          draft.start = field.selectionStart;
          draft.end = field.selectionEnd;
        }
      }
    }
    return draft;
  }

  function restoreDraft(root, draft) {
    Object.keys(draft.values).forEach(function (id) {
      var field = root.querySelector('#' + cssEscape(id));
      // Only a field that is still there and still empty: a form the render
      // filled in from the record has newer values than the ones lifted out.
      if (field && !field.value) { field.value = draft.values[id]; }
    });
    if (!draft.focus) { return; }
    var focused = root.querySelector('#' + cssEscape(draft.focus));
    if (!focused) { return; }
    focused.focus({ preventScroll: true });
    if (focused.setSelectionRange && focused.type !== 'checkbox') {
      try { focused.setSelectionRange(draft.start, draft.end); } catch (e) { /* not a text field */ }
    }
  }

  var lastDetail = null;

  function renderDetail(session) {
    ui.stage.setAttribute('data-detail', state.detail ? 'open' : 'closed');
    if (!state.detail) {
      lastDetail = null;
      D.replace(ui.detail, global.CouncilDetail.glance(state.snapshot, session));
      return;
    }
    var redrawing = state.detail === lastDetail;
    var draft = redrawing ? captureDraft(ui.detail) : null;
    lastDetail = state.detail;

    D.replace(ui.detail, [
      el('p', { class: 'back-row' }, [
        el('button', { class: 'action quiet', type: 'button', data: { back: '1' }, text: '← Back' })
      ]),
      detailContent(session)
    ]);
    if (draft) { restoreDraft(ui.detail, draft); }
    if (state.detail.focusOnOpen) {
      state.detail.focusOnOpen = false;
      var head = ui.detail.querySelector('#detail-title');
      if (head) { head.focus(); }
      // Deliberately no scroll to the marked span: the quote is already shown
      // above the capture, and a view that jumps on open has taken the reading
      // position away from the reader.
      ui.detail.scrollTop = 0;
    }
  }

  function render() {
    var session = currentSession();
    var definition = R.definitionOf(session, state.snapshot);
    renderMasthead(session, definition);

    Array.prototype.forEach.call(ui.panes.querySelectorAll('button'), function (button) {
      var mine = button.getAttribute('data-pane') === state.pane;
      // aria-current, not aria-selected: these are plain buttons, and
      // aria-selected is not mapped without a tab role.
      if (mine) { button.setAttribute('aria-current', 'page'); }
      else { button.removeAttribute('aria-current'); }
    });

    var anchor = captureAnchor(ui.reading);
    D.replace(ui.reading, readingContent(session));
    restoreAnchor(ui.reading, anchor);
    renderDetail(session);
    renderFootrail();
    noteArrivals(session);
  }

  // A contribution that completes while you are reading is announced and
  // offered, never scrolled to: the reader decides when to move.
  function noteArrivals(session) {
    var fresh = [];
    R.runsOf(session).forEach(function (run) {
      R.list(run.contributions).concat(run.synthesis ? [run.synthesis] : []).forEach(function (c) {
        if (!c || c.status !== 'complete' || state.seen[c.contribution_id]) { return; }
        state.seen[c.contribution_id] = true;
        fresh.push(c);
      });
    });
    if (!state.started) { state.started = true; ui.arrival.hidden = true; return; }
    if (!fresh.length) { return; }

    var definition = R.definitionOf(session, state.snapshot);
    var last = fresh[fresh.length - 1];
    var member = R.memberOf(definition, last.member_id);
    var who = (member && member.display_name) || last.seat_id;
    announce(who + ' answered.');

    var node = ui.reading.querySelector('#contrib-' + cssEscape(last.contribution_id));
    if (state.pane !== 'session' || !node || inView(node, ui.reading)) {
      ui.arrival.hidden = true;
      return;
    }
    ui.arrival.hidden = false;
    ui.arrival.textContent = who + ' answered ↓';
    ui.arrival.onclick = function () {
      var target = ui.reading.querySelector('#contrib-' + cssEscape(last.contribution_id));
      if (target) { target.scrollIntoView({ block: 'start' }); target.focus(); }
      ui.arrival.hidden = true;
    };
  }

  function cssEscape(value) { return String(value).replace(/[^A-Za-z0-9_-]/g, '\\$&'); }

  // ------------------------------------------------------------ navigation

  // A re-render replaces every node in the reading column, so a remembered DOM
  // node is dead by the time Back runs. What survives is a control's data
  // attributes, so the return trip is recorded as a selector.
  function selectorFor(node) {
    if (!node || !node.attributes) { return ''; }
    var parts = [node.tagName.toLowerCase()];
    Array.prototype.forEach.call(node.attributes, function (a) {
      if (a.name.indexOf('data-') === 0) { parts.push('[' + a.name + '="' + a.value + '"]'); }
    });
    return parts.length > 1 ? parts.join('') : '';
  }

  // The details that offer a model choice. Opening one re-reads the host's
  // catalogue, because a model enabled in Minerva since the panel opened must
  // appear without reopening the tab.
  var OFFERS_MODELS = { member: true, add_member: true, follow_up: true };

  function openDetail(detail, trigger) {
    if (!state.detail) {
      state.returnTo = { scrollTop: ui.reading.scrollTop, trigger: selectorFor(trigger) };
    }
    detail.focusOnOpen = true;
    state.detail = detail;
    render();
    if (OFFERS_MODELS[detail.kind]) {
      readModels().then(function () { if (state.detail === detail) { render(); } });
    }
  }

  // The catalogue is never held for longer than the control that shows it. A
  // failure leaves the last list in place: an empty select would be a worse
  // answer than a slightly old one.
  function readModels() {
    return bridge.models().then(function (catalogue) {
      if (catalogue.known || catalogue.models.length) {
        state.models = catalogue.models;
        state.modelsKnown = catalogue.known;
      }
      return catalogue;
    });
  }

  function back() {
    var to = state.returnTo;
    state.detail = null;
    state.returnTo = null;
    render();
    if (!to) { return; }
    ui.reading.scrollTop = to.scrollTop;
    var trigger = to.trigger ? ui.reading.querySelector(to.trigger) : null;
    // preventScroll: focusing must not undo the scroll position just restored.
    if (trigger) { trigger.focus({ preventScroll: true }); }
    else { ui.reading.focus({ preventScroll: true }); }
  }

  function goPane(pane) {
    state.pane = pane;
    state.detail = null;
    state.returnTo = null;
    ui.reading.scrollTop = 0;
    render();
    // set_view advances no revision, so nothing here may treat the reply as
    // evidence that anything was saved. It is user intent, sent and forgotten.
    bridge.send('wrapper.set_view', {
      view: {
        pane: pane,
        selected_session_id: (currentSession() || {}).session_id,
        selected_definition_id: (R.editableDefinition(state.snapshot, currentSession()) || {}).definition_id
      }
    });
  }

  // --------------------------------------------------------------- writing

  function value(id) {
    var node = ui.detail.querySelector('#' + id);
    return node ? String(node.value || '').trim() : '';
  }

  function mintId(prefix) {
    return prefix + '-' + Date.now().toString(36) + '-'
      + Math.floor(Math.random() * 1e6).toString(36);
  }

  function afterWrite(reply, message) {
    if (!reply || !reply.ok) { return false; }
    state.detail = null;
    state.returnTo = null;
    say(message);
    render();
    return true;
  }

  // Starting one of the councils Council ships with.
  //
  // It is an ordinary definition.import of an ordinary record — the presets are
  // inlined into this page by ui/build.mjs from council/presets, the same files
  // the backend embeds for minerva_council_presets. The one thing changed on the
  // way in is the definition_id: the shipped id NAMES the preset rather than
  // claiming a slot in this project, and import refuses an id the project
  // already holds, so minting a fresh one is what lets the same preset be
  // started twice and edited apart.
  function usePreset(id) {
    var preset = null;
    (global.CouncilPresets || []).forEach(function (candidate) {
      if (candidate.definition_id === id) { preset = candidate; }
    });
    if (!preset) { say('That council is not one this build ships.'); return; }
    var definition = JSON.parse(JSON.stringify(preset));
    definition.definition_id = mintId('def');
    definition.definition_revision = 1;
    bridge.mutate('definition.import', { definition: definition }).then(function (reply) {
      afterWrite(reply, 'Started ' + definition.name + '. Read its members before you ask anything: '
        + 'a preset is a starting point, not a fact about your situation.');
    });
  }

  function createCouncil() {
    var name = value('council-name');
    if (!name) { say('Give the council a name first.'); return; }
    var chairId = mintId('mem');
    bridge.mutate('definition.upsert', {
      definition: {
        schema_version: 1,
        record_kind: 'council_definition',
        definition_id: mintId('def'),
        definition_revision: 1,
        name: name,
        purpose: value('council-purpose'),
        members: [{
          member_id: chairId,
          member_revision: 1,
          kind: 'assistant',
          display_name: 'Chair',
          scope: 'Runs the round, reports where members disagree, and never adds a position of its own.',
          limitations: 'Has no grounding of its own; everything it reports must trace to a member contribution.',
          grounding: []
        }],
        seats: [{
          seat_id: mintId('seat'),
          member_id: chairId,
          responsibility: 'Synthesise the round and preserve disagreement.',
          role: 'chair'
        }],
        sources: [],
        // The council's own limits. They are data because a round is planned
        // from the record: a limit that lived only in a request would be gone by
        // the time it mattered.
        deliberation: {
          max_members_per_round: 4,
          max_concurrent_members: 2,
          max_prompt_bytes: 16384,
          run_budget_seconds: 300,
          max_rounds_per_session: 12,
          independent_initial_round: true,
          preserve_disagreement: true,
          per_member_timeout_seconds: 120
        }
      }
    }).then(function (reply) {
      afterWrite(reply, 'Council created with a chair. Add the members you want beside it.');
    });
  }

  function addMember() {
    var definition = R.editableDefinition(state.snapshot, currentSession());
    if (!definition) { say('There is no council in this project to add a member to.'); return; }
    var name = value('member-name');
    if (!name) { say('Give the member a display name first.'); return; }
    var kind = value('member-kind') || 'assistant';
    var member = {
      member_id: mintId('mem'),
      kind: kind,
      display_name: name,
      grounding: []
    };
    if (kind === 'simulant' && value('member-represents')) {
      member.represents = value('member-represents');
    }
    if (value('member-scope')) { member.scope = value('member-scope'); }
    if (value('member-limitations')) { member.limitations = value('member-limitations'); }
    // A human is never consulted by a round, so a model hint on one would be a
    // provenance nobody can honour.
    if (kind !== 'human' && value('member-model')) { member.model_hint = value('member-model'); }

    bridge.mutate('member.upsert', {
      definition_id: definition.definition_id,
      member: member
    }).then(function (reply) {
      afterWrite(reply, name + ' is in the council. Give them a seat to have them consulted.');
    });
  }

  function saveModel(memberId) {
    var definition = R.editableDefinition(state.snapshot, currentSession());
    var member = R.memberOf(definition, memberId);
    if (!member) { say('That member is no longer in this council.'); bridge.read(); return; }
    var next = {};
    Object.keys(member).forEach(function (key) {
      // member_revision is minted by the engine when the identity changes;
      // sending one back is refused.
      if (key !== 'member_revision') { next[key] = member[key]; }
    });
    var chosen = value('member-model');
    if (chosen) { next.model_hint = chosen; } else { delete next.model_hint; }

    bridge.mutate('member.upsert', {
      definition_id: definition.definition_id,
      member: next
    }).then(function (reply) {
      if (!reply || !reply.ok) { return; }
      say(chosen
        ? member.display_name + ' will be asked with ' + chosen + '.'
        : member.display_name + ' will be asked with whichever model Minerva lists first.');
      render();
    });
  }

  function seatMember(memberId) {
    var definition = R.editableDefinition(state.snapshot, currentSession());
    if (!definition) { say('There is no council in this project to seat into.'); return; }
    var responsibility = value('seat-responsibility');
    if (!responsibility) { say('Say what this seat is responsible for first.'); return; }
    var next = JSON.parse(JSON.stringify(definition));
    next.seats = R.list(next.seats).concat([{
      seat_id: mintId('seat'),
      member_id: memberId,
      responsibility: responsibility,
      role: 'advisor'
    }]);
    // An edit advances the revision it was written against; the engine refuses
    // one that is not ahead of what it holds.
    next.definition_revision = Number(next.definition_revision) + 1;
    bridge.mutate('definition.upsert', { definition: next }).then(function (reply) {
      afterWrite(reply, 'Seated. The next round will consult them.');
    });
  }

  function sendFollowUp(seatId, claimId) {
    var session = currentSession();
    if (!session) { say('There is no session to follow up on.'); return; }
    var prompt = value('follow-up-text');
    if (!prompt) { say('Write the follow-up first.'); return; }
    var payload = { session_id: session.session_id, kind: 'follow_up', prompt: prompt };
    // A follow-up about an argument is routed by the engine to whoever made it,
    // so the claim travels alone; naming a seat as well is refused when they
    // disagree.
    if (claimId) { payload.addressed_claim_id = claimId; }
    else { payload.addressed_seat_id = seatId; payload.seat_ids = [seatId]; }
    var model = value('follow-up-model');
    if (model && seatId) { payload.model_overrides = {}; payload.model_overrides[seatId] = model; }

    bridge.mutate('run.start', payload).then(function (reply) {
      if (!reply || !reply.ok) { return; }
      state.detail = null;
      state.returnTo = null;
      state.pane = 'session';
      say('Asked. Only that seat was consulted.');
      render();
    });
  }

  function handoff() {
    var session = currentSession();
    if (!session) { say('There is no session to send.'); return; }
    var ids = Object.keys(state.picked);
    bridge.send('wrapper.chat_handoff', {
      session_id: session.session_id,
      contribution_ids: ids
    }).then(function (reply) {
      if (!reply || !reply.ok) { return; }
      say('Sent ' + reply.payload.characters + ' characters to chat ' + reply.payload.chat_id + '.');
    });
  }

  // ---------------------------------------------------------------- events

  var TRIGGERS = ['[data-back]', '[data-pane]', '[data-goto-pane]', '[data-open-member]',
    '[data-open-source]', '[data-compare]', '[data-compare-add]', '[data-follow-up]',
    '[data-follow-claim]', '[data-send-follow-up]', '[data-retry-run]', '[data-retry-seat]',
    '[data-cancel-run]', '[data-create-council]', '[data-create-council-send]',
    '[data-use-preset]', '[data-help]',
    '[data-add-member]', '[data-add-member-send]', '[data-seat-member]', '[data-seat-member-send]',
    '[data-save-model]', '[data-dismiss-refusal]', '[data-text-larger]',
    '[data-text-smaller]', '[data-text-reset]'].join(',');

  function onClick(event) {
    var target = event.target.closest(TRIGGERS);
    if (!target) { return; }
    var d = target.dataset;

    // A valueless data- attribute reads back as '', which is falsy. Presence,
    // not truth, is what these tests have to ask for.
    if (d.back !== undefined) { back(); return; }
    if (d.dismissRefusal !== undefined) { say(''); return; }
    if (d.textLarger !== undefined) { textSize.step(1); renderFootrail(); return; }
    if (d.textSmaller !== undefined) { textSize.step(-1); renderFootrail(); return; }
    if (d.textReset !== undefined) { textSize.reset(); renderFootrail(); return; }
    if (d.pane) { goPane(d.pane); return; }
    if (d.gotoPane) { goPane(d.gotoPane); return; }

    if (d.openMember) { openDetail({ kind: 'member', member_id: d.openMember }, target); return; }

    if (d.openSource) {
      var wanted = {
        kind: 'source',
        source_id: d.openSource,
        revision: Number(d.revision),
        anchor_id: d.anchor || ''
      };
      openDetail(wanted, target);
      // The material is fetched rather than read out of the roster the page
      // already has: in production it may exceed the inline limit and live in a
      // blob.
      bridge.send('source.fetch', {
        definition_id: (R.definitionOf(currentSession(), state.snapshot) || {}).definition_id,
        source_id: wanted.source_id,
        source_revision: wanted.revision
      }).then(function (reply) {
        if (!reply || !reply.ok || state.detail !== wanted) { return; }
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

    if (d.followUp) {
      openDetail({ kind: 'follow_up', seat_id: d.followUp, from: d.from }, target);
      return;
    }
    if (d.followClaim) {
      var contribution = null;
      R.runsOf(currentSession()).forEach(function (run) {
        R.partsOf(run).forEach(function (c) {
          R.list(c.claims).forEach(function (claim) {
            if (claim.claim_id === d.followClaim) { contribution = c; }
          });
        });
      });
      if (!contribution) { say('That argument is no longer in the session.'); bridge.read(); return; }
      openDetail({
        kind: 'follow_up',
        seat_id: contribution.seat_id,
        from: contribution.contribution_id,
        claim_id: d.followClaim
      }, target);
      return;
    }
    if (d.sendFollowUp) { sendFollowUp(d.sendFollowUp, d.claim || ''); return; }

    if (d.help !== undefined) { openDetail({ kind: 'help' }, target); return; }
    if (d.usePreset) { usePreset(d.usePreset); return; }
    if (d.createCouncil !== undefined) { openDetail({ kind: 'create_council' }, target); return; }
    if (d.createCouncilSend !== undefined) { createCouncil(); return; }
    if (d.addMember !== undefined) { openDetail({ kind: 'add_member' }, target); return; }
    if (d.addMemberSend !== undefined) { addMember(); return; }
    if (d.seatMember) { openDetail({ kind: 'seat_member', member_id: d.seatMember }, target); return; }
    if (d.seatMemberSend) { seatMember(d.seatMemberSend); return; }
    if (d.saveModel) { saveModel(d.saveModel); return; }

    if (d.retryRun) {
      bridge.mutate('run.retry', {
        session_id: (currentSession() || {}).session_id,
        run_id: d.retryRun
      }).then(function (reply) { if (reply && reply.ok) { say('Retrying.'); render(); } });
      return;
    }

    if (d.retrySeat) {
      var session = currentSession();
      var last = R.lastRun(session);
      if (!last) { say('There is no round to retry. The panel has re-read the session.'); bridge.read(); return; }
      bridge.mutate('run.retry', {
        session_id: session.session_id,
        run_id: last.run_id,
        seat_ids: [d.retrySeat]
      }).then(function (reply) { if (reply && reply.ok) { say('Asking that seat again.'); render(); } });
      return;
    }

    if (d.cancelRun) {
      bridge.mutate('run.cancel', {
        session_id: (currentSession() || {}).session_id,
        run_id: d.cancelRun
      }).then(function (reply) {
        if (reply && reply.ok) { say('Cancelled. Answers already in are kept.'); render(); }
      });
    }
  }

  function onChange(event) {
    var node = event.target.closest('[data-pick]');
    if (!node) { return; }
    var id = node.getAttribute('data-pick');
    if (node.checked) { state.picked[id] = true; } else { delete state.picked[id]; }
    ui.handoff.disabled = Object.keys(state.picked).length === 0;
  }

  function onKeydown(event) {
    if (event.key === 'Escape' && state.detail) {
      event.preventDefault();
      back();
      return;
    }
    // Minerva's own scale shortcuts do not reach inside the embedded browser, so
    // a reader pressing them here gets Council's text size instead of nothing.
    if (!event.ctrlKey && !event.metaKey) { return; }
    if (event.key === '+' || event.key === '=') { event.preventDefault(); textSize.step(1); renderFootrail(); }
    else if (event.key === '-' || event.key === '_') { event.preventDefault(); textSize.step(-1); renderFootrail(); }
    else if (event.key === '0') { event.preventDefault(); textSize.reset(); renderFootrail(); }
  }

  // ------------------------------------------------------------------ boot

  function applyTheme(payload) {
    document.documentElement.setAttribute('data-theme', payload && payload.dark ? 'dark' : 'light');
  }

  function boot() {
    ui = {
      councilName: document.getElementById('council-name'),
      question: document.getElementById('question'),
      questionMeta: document.getElementById('question-meta'),
      panes: document.getElementById('panes'),
      stage: document.getElementById('stage'),
      reading: document.getElementById('reading'),
      detail: document.getElementById('detail'),
      message: document.getElementById('message'),
      revision: document.getElementById('revision'),
      sizer: document.getElementById('sizer'),
      handoff: document.getElementById('handoff'),
      announcer: document.getElementById('announcer'),
      arrival: document.getElementById('arrival')
    };

    bridge = new global.CouncilBridgeClient.Bridge(global.council);
    textSize = new global.CouncilPrefs.TextSize(bridge);
    bridge.onRefusal = refuse;
    bridge.onSnapshot = function (snapshot) { state.snapshot = snapshot || {}; };

    document.addEventListener('click', onClick);
    document.addEventListener('change', onChange);
    document.addEventListener('keydown', onKeydown);
    ui.handoff.addEventListener('click', handoff);
    ui.handoff.disabled = true;

    global.council.onEvent(function (event) {
      if (event.event === 'council.theme_changed') { applyTheme(event.payload); return; }
      if (event.event === 'council.focus_changed') {
        document.documentElement.setAttribute('data-focused', String(!!(event.payload || {}).focused));
        return;
      }
      // The wrapper could not read back a council the engine has carried
      // further. It is a refusal, not a status line: it stays until it is
      // acknowledged, because what it says is that what was saved is missing
      // something.
      if (event.event === 'council.sync_warning') {
        syncRefusal = true;
        refuse({ message: (event.payload || {}).message || 'This council is behind the Council backend.' });
        return;
      }
      // And the wrapper caught up. A refusal that outlives what it was about
      // sends a reader looking for a problem that is not there.
      if (event.event === 'council.sync_cleared') {
        if (syncRefusal && state.refusal) { say(''); }
        syncRefusal = false;
        return;
      }
      // Everything else says the record moved. The page re-reads rather than
      // trusting the payload it was handed.
      bridge.read().then(render);
    });

    bridge.describe().then(function (reply) {
      if (reply && reply.ok && reply.payload) {
        applyTheme(reply.payload.theme);
        // The wrapper decides which sizes it will store; the page offers only
        // the ones both know.
        textSize.adopt(reply.payload.text_scales);
        if (reply.payload.unreadable) {
          state.unreadable = R.text(reply.payload.unreadable_reason);
        }
      }
      return textSize.load();
    }).then(function () {
      return bridge.read();
    }).then(function () {
      var view = state.snapshot.view || {};
      if (['session', 'members', 'sources'].indexOf(view.pane) >= 0) { state.pane = view.pane; }
      render();
      // The catalogue is NOT read here. Nothing on the first screen needs it —
      // the Members pane names each member's own model_hint out of the record —
      // and reading it costs a host round trip per enabled provider. It is read
      // when a chooser is opened, which is also the only moment it can be stale.
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // Exposed for the harness in ui/tests: it drives the page the way a reader
  // does, and needs to be able to ask what the page currently believes.
  global.CouncilApp = {
    state: state,
    render: render,
    back: back,
    bridge: function () { return bridge; },
    textSize: function () { return textSize; }
  };
})(window);

// A stand-in for the wrapper Council actually talks to.
//
// It mimics the surface in council/ui/council_bridge.gd - council.call(command,
// payload, baseRevision) returning a reply envelope, and council.onEvent(cb) -
// and it obeys the rules from architecture.md 5.2 that the page has to be built
// against: a mutating command carries base_revision or is refused, a read
// command must not, a reply always arrives (a refusal is a reply), every reply
// carries the revision it was produced against, and an event never carries
// authority - it says the record moved and the page re-reads.
//
// It is not wired to anything. Nothing here talks to Minerva, and the real
// wrapper relays most of these commands to a Go engine that this file only
// imitates well enough to design against.

(function (global) {
  'use strict';

  var INLINE_LIMIT = 32768; // UTF-16 code units, as the wrapper counts them.

  var READ_COMMANDS = { 'snapshot.get': 1, 'source.fetch': 1, 'definition.export': 1 };
  var WRAPPER_COMMANDS = { 'wrapper.describe': 1, 'wrapper.set_view': 1, 'wrapper.chat_handoff': 1 };

  function clone(value) { return JSON.parse(JSON.stringify(value)); }

  function reply(requestId, revision, ok, extra) {
    var envelope = {
      schema_version: 1, envelope: 'reply', request_id: requestId,
      ok: ok, snapshot_revision: revision
    };
    Object.keys(extra || {}).forEach(function (k) { envelope[k] = extra[k]; });
    return envelope;
  }

  function failure(code, message, retryable) {
    return { code: code, message: message, retryable: !!retryable };
  }

  // architecture.md 4.1: a session's status is a function of its runs and of
  // nothing else. The mock derives it for the same reason the engine does -
  // so that no code path here can set a status the runs contradict.
  function deriveSessionStatus(session) {
    var runs = session.runs || [];
    if (!runs.length) { return 'draft'; }
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].status === 'pending' || runs[i].status === 'running') { return 'running'; }
    }
    var last = runs[runs.length - 1];
    if (last.status === 'complete') { return 'complete'; }
    if (last.status === 'cancelled') { return 'cancelled'; }
    if (last.status === 'partial') { return 'partial'; }
    var answered = (last.contributions || []).some(function (c) { return c.status === 'complete'; });
    return answered ? 'partial' : 'failed';
  }

  function Bridge(scenario, options) {
    this.scenario = scenario;
    this.snapshot = scenario.snapshot();
    this.revision = this.snapshot.snapshot_revision;
    this.handlers = [];
    this.timers = [];
    this.unreadable = scenario.unreadable || '';
    this.dark = !!(options && options.dark);
    this.staleNext = false; // set by the prototype control that fakes a stale view
    this.seq = 0;
  }

  Bridge.prototype.emit = function (event, payload) {
    var envelope = {
      schema_version: 1, envelope: 'event', event: event,
      snapshot_revision: this.revision, payload: payload || {}
    };
    this.handlers.forEach(function (h) {
      try { h(envelope); } catch (e) { /* one bad handler must not stop the rest */ }
    });
  };

  Bridge.prototype.bump = function () {
    this.revision += 1;
    this.snapshot.snapshot_revision = this.revision;
  };

  Bridge.prototype.session = function (id) {
    var found = null;
    (this.snapshot.sessions || []).forEach(function (s) {
      if (!id || s.session_id === id) { found = found || s; }
    });
    return found;
  };

  Bridge.prototype.findRun = function (runId) {
    var found = null;
    (this.snapshot.sessions || []).forEach(function (s) {
      (s.runs || []).forEach(function (r) { if (r.run_id === runId) { found = r; } });
    });
    return found;
  };

  // ------------------------------------------------------------- the timeline

  Bridge.prototype.start = function () {
    var self = this;
    (this.scenario.timeline || []).forEach(function (step) {
      self.timers.push(global.setTimeout(function () { self.step(step); }, step.after));
    });
  };

  Bridge.prototype.stop = function () {
    this.timers.forEach(function (t) { global.clearTimeout(t); });
    this.timers = [];
  };

  Bridge.prototype.step = function (step) {
    var arrivals = global.CouncilScenarios.arrivals;
    if (step.contribution && arrivals[step.contribution]) {
      var body = arrivals[step.contribution]();
      var replaced = false;
      (this.snapshot.sessions || []).forEach(function (s) {
        (s.runs || []).forEach(function (r) {
          r.contributions = (r.contributions || []).map(function (c) {
            if (c.contribution_id !== body.contribution_id) { return c; }
            replaced = true;
            return body;
          });
        });
      });
      if (!replaced) { return; }
      this.bump();
      this.rederive();
      this.emit('council.contribution_ready', { contribution_id: body.contribution_id });
      return;
    }
    if (step.finish) {
      var run = this.findRun(step.finish);
      if (!run) { return; }
      var makeSynthesis = global.CouncilScenarios.revisedSynthesis[step.finish];
      if (makeSynthesis) { run.synthesis = makeSynthesis(); }
      var anyFailed = (run.contributions || []).some(function (c) { return c.status === 'failed'; });
      run.status = anyFailed ? 'partial' : 'complete';
      run.ended_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
      this.bump();
      this.rederive();
      this.emit('council.run_finished', { run_id: run.run_id, status: run.status });
    }
  };

  Bridge.prototype.rederive = function () {
    (this.snapshot.sessions || []).forEach(function (s) {
      s.status = deriveSessionStatus(s);
    });
  };

  // -------------------------------------------------------------- the surface

  Bridge.prototype.handle = function (command, payload, baseRevision, requestId) {
    var text = JSON.stringify(payload || {});
    if (text.length > INLINE_LIMIT) {
      // Refused, never dropped: a dropped message leaves the page's promise
      // pending forever, which looks exactly like a hung panel.
      return reply(requestId, this.revision, false, {
        error: failure('payload_too_large',
          'That message is ' + text.length + ' units; the panel accepts ' + INLINE_LIMIT + '.', false)
      });
    }

    var isRead = !!READ_COMMANDS[command];
    var isWrapper = !!WRAPPER_COMMANDS[command];
    if (!isRead && !isWrapper) {
      if (baseRevision === undefined || baseRevision === null) {
        return reply(requestId, this.revision, false, {
          error: failure('internal', 'A mutating command must carry the revision it was written against.', false)
        });
      }
      if (baseRevision !== this.revision) {
        return reply(requestId, this.revision, false, {
          error: failure('stale_revision',
            'The council moved while you were reading it. Nothing was changed; the panel has re-read it.', true)
        });
      }
      if (this.unreadable) {
        return reply(requestId, this.revision, false, {
          error: failure('internal', 'Council will not change this document: ' + this.unreadable, false)
        });
      }
    } else if (isRead && baseRevision !== undefined && baseRevision !== null) {
      return reply(requestId, this.revision, false, {
        error: failure('internal', 'A read command does not carry a revision.', false)
      });
    }

    return this.dispatch(command, payload || {}, requestId);
  };

  Bridge.prototype.dispatch = function (command, payload, requestId) {
    var self = this;
    var ok = function (body) { return reply(requestId, self.revision, true, { payload: body || {} }); };
    var no = function (code, message, retryable) {
      return reply(requestId, self.revision, false, { error: failure(code, message, retryable) });
    };

    switch (command) {

      case 'snapshot.get':
        return ok({ snapshot: clone(this.snapshot) });

      case 'source.fetch': {
        var source = null;
        (this.snapshot.definitions || []).forEach(function (d) {
          (d.sources || []).forEach(function (s) {
            if (s.source_id === payload.source_id && s.source_revision === payload.source_revision) { source = s; }
          });
        });
        if (!source) { return no('missing_source', 'That source revision is not in this project.', false); }
        if (!source.payload) {
          return no('missing_source',
            'This source was captured as a reference only. Its material was never brought into the project, so it cannot be shown.', false);
        }
        return ok({ source: clone(source) });
      }

      case 'definition.export': {
        var def = (this.snapshot.definitions || [])[0];
        if (!def) { return no('internal', 'There is no council to export.', false); }
        return ok({ definition: clone(def), included_source_material: true });
      }

      case 'run.start': {
        var session = this.session(payload.session_id);
        if (!session) { return no('internal', 'There is no session to run.', false); }
        return ok({ run: this.beginRun(session, payload) });
      }

      case 'run.cancel': {
        var running = this.findRun(payload.run_id);
        if (!running) { return no('internal', 'That run is not in this project.', false); }
        this.stop();
        (running.contributions || []).forEach(function (c) {
          if (c.status === 'pending' || c.status === 'running') {
            c.status = 'cancelled';
            c.failure = failure('cancelled', 'Cancelled before this seat answered.', true);
          }
        });
        running.status = 'cancelled';
        running.failure = failure('cancelled', 'You cancelled this round. Answers already in are kept.', true);
        this.bump();
        this.rederive();
        this.emit('council.run_finished', { run_id: running.run_id, status: 'cancelled' });
        return ok({ run_id: running.run_id });
      }

      case 'run.retry': {
        var target = this.findRun(payload.run_id);
        if (!target) { return no('internal', 'That run is not in this project.', false); }
        this.retryRun(target, payload.seat_id);
        return ok({ run_id: target.run_id });
      }

      case 'outcome.retain': {
        var host = this.session(payload.session_id);
        if (!host) { return no('internal', 'There is no session to retain from.', false); }
        var outcome = {
          outcome_id: 'out.' + (++this.seq),
          run_id: payload.run_id,
          contribution_id: payload.contribution_id,
          note: { kind: 'note', ref: 'note:council-outcome-' + this.seq, label: 'Council outcome' },
          retained_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z')
        };
        host.outcomes = (host.outcomes || []).concat([outcome]);
        this.bump();
        this.emit('council.snapshot_changed', {});
        return ok({ outcome: outcome });
      }

      case 'definition.upsert': {
        var current = (this.snapshot.definitions || [])[0];
        if (!current) {
          // Assembling from nothing: the council starts as a chair and the
          // member library, with every other seat an explicit choice.
          current = global.CouncilSample.definition(1);
          current.name = payload.name || 'Untitled council';
          current.purpose = payload.purpose || '';
          current.seats = global.CouncilSample.seats.slice(0, 1);
          this.snapshot.definitions = [current];
          this.snapshot.view = this.snapshot.view || {};
          this.snapshot.view.selected_definition_id = current.definition_id;
        }
        if (payload.seat) { this.upsertSeat(current, payload.seat); }
        if (payload.name) { current.name = payload.name; }
        if (payload.purpose !== undefined) { current.purpose = payload.purpose; }
        current.definition_revision += 1;
        this.bump();
        this.emit('council.snapshot_changed', {});
        return ok({ definition_revision: current.definition_revision });
      }

      case 'session.create': {
        var base = (this.snapshot.definitions || [])[0];
        if (!base) { return no('internal', 'There is no council to consult.', false); }
        var made = {
          schema_version: 1, record_kind: 'council_session',
          session_id: 'ses.' + (++this.seq), session_revision: 1,
          definition_snapshot: clone(base),
          chat_binding: { chat_id: 'chat.bindery-planning', bound_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z') },
          question: String(payload.question || '').slice(0, 8000),
          status: 'draft', runs: [], outcomes: []
        };
        this.snapshot.sessions = (this.snapshot.sessions || []).concat([made]);
        this.snapshot.view = this.snapshot.view || {};
        this.snapshot.view.selected_session_id = made.session_id;
        this.bump();
        this.emit('council.snapshot_changed', {});
        return ok({ session_id: made.session_id });
      }

      case 'source.upsert':
      case 'session.bind_chat':
      case 'definition.import':
        return no('internal', 'The prototype does not stand in for ' + command + '.', false);

      case 'wrapper.describe':
        return ok({
          panel_key: 'council:prototype', plugin_id: 'council', file_path: '',
          unreadable: !!this.unreadable, unreadable_reason: this.unreadable,
          theme: { dark: this.dark }, max_message_code_units: INLINE_LIMIT
        });

      case 'wrapper.set_view': {
        if (this.unreadable) { return no('internal', 'Council will not change this document.', false); }
        // Merged, not replaced: the page sends only the fields it is changing,
        // and a wrapper that drops the rest would quietly lose which council
        // the user had selected.
        var view = this.snapshot.view || {};
        var incoming = payload.view || {};
        Object.keys(incoming).forEach(function (k) { view[k] = incoming[k]; });
        this.snapshot.view = view;
        return ok({ view: view }); // view advances no revision
      }

      case 'wrapper.chat_handoff': {
        var from = this.session(payload.session_id);
        if (!from) { return no('internal', 'There is no session to send.', false); }
        var chatId = (from.chat_binding || {}).chat_id;
        if (!chatId) { return no('missing_chat', 'This session is not bound to a chat.', false); }
        var picked = (payload.contribution_ids || []).length;
        if (!picked) { return no('internal', 'Nothing is selected to send.', false); }
        return ok({ chat_id: chatId, characters: picked * 640 });
      }
    }
    return no('internal', '"' + command + '" is not an operation this panel performs.', false);
  };

  // ----------------------------------------------------------- run mechanics

  // One bounded round of the advisor seats, answers landing on staggered
  // timers so the page has to survive results arriving one at a time.
  Bridge.prototype.beginRun = function (session, payload) {
    if (payload.seat_id) { return this.beginFollowUp(session, payload); }

    var self = this;
    var def = session.definition_snapshot;
    var advisors = (def.seats || []).filter(function (s) { return s.role !== 'chair'; })
      .slice(0, def.deliberation.max_members_per_round);
    var run = {
      run_id: 'run.' + (++this.seq), request_id: 'req.round.' + this.seq,
      kind: 'initial_round', status: 'running',
      started_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), prompt: '',
      contributions: advisors.map(function (seat) {
        var member = (def.members || []).filter(function (m) { return m.member_id === seat.member_id; })[0];
        return {
          contribution_id: 'c.' + seat.seat_id + '.' + self.seq, seat_id: seat.seat_id,
          member_id: member.member_id, member_revision: member.member_revision,
          status: 'pending', claims: []
        };
      })
    };
    session.runs = (session.runs || []).concat([run]);
    this.bump();
    this.rederive();
    this.emit('council.run_progress', { run_id: run.run_id });

    var known = { 'seat.demand': 'c.signal.1', 'seat.money': 'c.capital.1', 'seat.focus': 'c.narrow.1' };
    advisors.forEach(function (seat, i) {
      self.timers.push(global.setTimeout(function () {
        var member = (def.members || []).filter(function (m) { return m.member_id === seat.member_id; })[0];
        var slot = run.contributions[i];
        var arrival = known[seat.seat_id] && global.CouncilScenarios.arrivals[known[seat.seat_id]];
        var body = arrival ? arrival() : global.CouncilScenarios.followUpReply(seat, member, slot.contribution_id);
        body.contribution_id = slot.contribution_id;
        body.seat_id = seat.seat_id;
        body.member_id = member.member_id;
        body.member_revision = member.member_revision;
        run.contributions[i] = body;
        self.bump();
        self.rederive();
        self.emit('council.contribution_ready', { contribution_id: body.contribution_id });
      }, 1600 + i * 1500));
    });

    self.timers.push(global.setTimeout(function () {
      run.synthesis = global.CouncilScenarios.revisedSynthesis['run.1']();
      run.status = 'complete';
      run.ended_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
      self.bump();
      self.rederive();
      self.emit('council.run_finished', { run_id: run.run_id, status: 'complete' });
    }, 1600 + advisors.length * 1500));

    return { run_id: run.run_id };
  };

  Bridge.prototype.beginFollowUp = function (session, payload) {
    var self = this;
    var def = session.definition_snapshot;
    var seat = (def.seats || []).filter(function (s) { return s.seat_id === payload.seat_id; })[0];
    if (!seat) { seat = (def.seats || [])[1]; }
    var member = (def.members || []).filter(function (m) { return m.member_id === seat.member_id; })[0];

    var contributionId = 'c.followup.' + (++this.seq);
    var run = {
      run_id: 'run.followup.' + this.seq,
      request_id: 'req.followup.' + this.seq,
      kind: 'follow_up', status: 'running',
      started_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
      prompt: String(payload.prompt || '').slice(0, 8000),
      addressed_seat_id: seat.seat_id,
      contributions: [{
        contribution_id: contributionId, seat_id: seat.seat_id, member_id: member.member_id,
        member_revision: member.member_revision, status: 'running', claims: []
      }]
    };
    session.runs = (session.runs || []).concat([run]);
    this.bump();
    this.rederive();
    this.emit('council.run_progress', { run_id: run.run_id });

    // The answer lands on a timer, so the page has to cope with a result
    // arriving while the reader is somewhere else on the page.
    this.timers.push(global.setTimeout(function () {
      var body = seat.seat_id === 'seat.focus'
        ? global.CouncilScenarios.arrivals['c.narrow.2']()
        : global.CouncilScenarios.followUpReply(seat, member, contributionId);
      body.contribution_id = contributionId;
      body.seat_id = seat.seat_id;
      run.contributions = [body];
      run.synthesis = global.CouncilScenarios.revisedSynthesis['run.2']();
      run.synthesis.contribution_id = 'c.chair.' + self.seq;
      run.status = 'complete';
      run.ended_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
      self.bump();
      self.rederive();
      self.emit('council.run_finished', { run_id: run.run_id, status: 'complete' });
    }, 2800));

    return { run_id: run.run_id, addressed_seat_id: seat.seat_id };
  };

  Bridge.prototype.retryRun = function (run, seatId) {
    var self = this;
    (run.contributions || []).forEach(function (c) {
      if (seatId && c.seat_id !== seatId) { return; }
      if (c.status !== 'failed' && c.status !== 'cancelled') { return; }
      c.status = 'running';
      delete c.failure;
    });
    delete run.failure;
    run.status = 'running';
    this.bump();
    this.rederive();
    this.emit('council.run_progress', { run_id: run.run_id });

    this.timers.push(global.setTimeout(function () {
      (run.contributions || []).forEach(function (c, i) {
        if (c.status !== 'running') { return; }
        var arrival = global.CouncilScenarios.arrivals['c.capital.1'];
        var body = arrival ? arrival() : null;
        if (body) {
          body.contribution_id = c.contribution_id;
          body.seat_id = c.seat_id;
          run.contributions[i] = body;
        }
      });
      run.status = 'complete';
      run.ended_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
      self.bump();
      self.rederive();
      self.emit('council.run_finished', { run_id: run.run_id, status: 'complete' });
    }, 2400));
  };

  Bridge.prototype.upsertSeat = function (definition, seat) {
    var replaced = false;
    definition.seats = (definition.seats || []).map(function (s) {
      if (s.seat_id !== seat.seat_id) { return s; }
      replaced = true;
      return seat;
    });
    if (!replaced) { definition.seats = definition.seats.concat([seat]); }
  };

  // ---------------------------------------------------------------- install

  global.CouncilMock = {
    install: function (scenario, options) {
      var bridge = new Bridge(scenario, options);
      var seq = 0;

      global.council = {
        call: function (command, payload, baseRevision) {
          var requestId = 'p' + (++seq) + '-' + Date.now();
          if (bridge.staleNext && baseRevision !== undefined && baseRevision !== null) {
            baseRevision = baseRevision + 1; // pretend the page read an older record
            bridge.staleNext = false;
          }
          // A reply always arrives, and never synchronously: the real hop is
          // IPC, and a page that renders inside the same tick would hide every
          // in-flight state the design has to show.
          return new Promise(function (resolve) {
            global.setTimeout(function () {
              resolve(bridge.handle(command, payload, baseRevision, requestId));
            }, 40);
          });
        },
        onEvent: function (cb) { bridge.handlers.push(cb); }
      };

      global.councilMockControl = bridge;
      bridge.start();
      return bridge;
    },
    deriveSessionStatus: deriveSessionStatus
  };
})(window);

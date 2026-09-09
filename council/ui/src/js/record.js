// Reading a Council snapshot: the lookups every view needs, and nothing else.
//
// These functions are pure and total. A record can be missing a field, an id can
// name something that is no longer there, and an array the schema requires can
// arrive empty from a document written by an older Council — so every lookup
// answers with null or an empty array rather than throwing. A view that crashed
// on a half-built record would leave the panel looking dead, with the record
// itself perfectly intact underneath.

(function (global) {
  'use strict';

  var KIND_WORD = { human: 'Human', assistant: 'Assistant', simulant: 'Simulant' };

  var MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
                'August', 'September', 'October', 'November', 'December'];

  function list(value) { return Array.isArray(value) ? value : []; }

  function text(value) {
    return value === undefined || value === null ? '' : String(value);
  }

  // Timestamps are stored as RFC 3339 UTC; how they read is a view concern. An
  // unparseable stamp is shown as it was stored rather than as "Invalid Date".
  function when(stamp) {
    var m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(text(stamp));
    if (!m) { return text(stamp); }
    return Number(m[3]) + ' ' + MONTHS[Number(m[2]) - 1] + ' ' + m[1] + ', ' + m[4] + ':' + m[5] + ' UTC';
  }

  function kindWord(kind) { return KIND_WORD[kind] || text(kind); }

  // ------------------------------------------------------------ selection

  function sessionsOf(snapshot) { return list(snapshot && snapshot.sessions); }

  // Which session the panel is showing. The wrapper persists the choice in
  // `view`; with none recorded the newest session is the one a reader means.
  function selectedSession(snapshot) {
    var sessions = sessionsOf(snapshot);
    var wanted = ((snapshot && snapshot.view) || {}).selected_session_id;
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i] && sessions[i].session_id === wanted) { return sessions[i]; }
    }
    return sessions.length ? sessions[sessions.length - 1] : null;
  }

  // The council a view should read. A session carries its own definition
  // snapshot — later edits to the council must never rewrite what was actually
  // asked of whom — so that is the authority whenever a session is open.
  function definitionOf(session, snapshot) {
    if (session && session.definition_snapshot) { return session.definition_snapshot; }
    var wanted = ((snapshot && snapshot.view) || {}).selected_definition_id;
    var definitions = list(snapshot && snapshot.definitions);
    for (var i = 0; i < definitions.length; i++) {
      if (definitions[i] && definitions[i].definition_id === wanted) { return definitions[i]; }
    }
    return definitions.length ? definitions[0] : null;
  }

  // The council a MUTATION must be written against. definitionOf may answer with
  // a session's embedded copy, which is a historical record and not a member of
  // snapshot.definitions; editing that would write a council the project does
  // not hold.
  function editableDefinition(snapshot, session) {
    var definitions = list(snapshot && snapshot.definitions);
    var wanted = session && session.definition_snapshot
      ? session.definition_snapshot.definition_id
      : ((snapshot && snapshot.view) || {}).selected_definition_id;
    for (var i = 0; i < definitions.length; i++) {
      if (definitions[i] && definitions[i].definition_id === wanted) { return definitions[i]; }
    }
    return definitions.length ? definitions[0] : null;
  }

  // ------------------------------------------------------------- lookups

  function memberOf(definition, memberId) {
    var members = list(definition && definition.members);
    for (var i = 0; i < members.length; i++) {
      if (members[i] && members[i].member_id === memberId) { return members[i]; }
    }
    return null;
  }

  function seatOf(definition, seatId) {
    var seats = list(definition && definition.seats);
    for (var i = 0; i < seats.length; i++) {
      if (seats[i] && seats[i].seat_id === seatId) { return seats[i]; }
    }
    return null;
  }

  function seatForMember(definition, memberId) {
    var seats = list(definition && definition.seats);
    for (var i = 0; i < seats.length; i++) {
      if (seats[i] && seats[i].member_id === memberId) { return seats[i]; }
    }
    return null;
  }

  // A source id names a capture history, not one record. With no revision the
  // newest capture is meant; array order is not a version order.
  function sourceOf(definition, sourceId, revision) {
    var sources = list(definition && definition.sources);
    var found = null;
    for (var i = 0; i < sources.length; i++) {
      var source = sources[i];
      if (!source || source.source_id !== sourceId) { continue; }
      if (revision === undefined || revision === null || revision === '') {
        if (!found || Number(source.source_revision) > Number(found.source_revision)) { found = source; }
        continue;
      }
      if (Number(source.source_revision) === Number(revision)) { return source; }
    }
    return found;
  }

  function anchorOf(source, anchorId) {
    var anchors = list(source && source.anchors);
    for (var i = 0; i < anchors.length; i++) {
      if (anchors[i] && anchors[i].anchor_id === anchorId) { return anchors[i]; }
    }
    return null;
  }

  // Whether a source's material travelled with the inventory entry. A reference
  // captured without its payload still carries the hash it stood for, which is
  // why the hash is read from the SOURCE and never from the payload that may not
  // be there.
  function hasMaterial(source) {
    return !!(source && source.payload && typeof source.payload.inline === 'string');
  }

  function contentHash(source) { return text(source && source.content_hash); }

  // An anchor's start and end are BYTE offsets into the UTF-8 capture: the
  // engine slices Go strings (internal/session/grounding.go buildAnchors,
  // internal/contract/invariants.go), where an index is a byte. JavaScript
  // indexes UTF-16 code units, so one em-dash or curly quote before a span
  // shifts the mark by two characters and a four-byte emoji by two more — a
  // fault that is invisible in any all-ASCII fixture.
  //
  // This walks the capture a code point at a time, summing the UTF-8 width of
  // each, and answers with the code-unit span the byte span names. An offset
  // that lands inside a character, or past the end, is not repaired here: it
  // answers null, and the caller marks nothing rather than the wrong words.
  function byteSpanToUnits(capture, start, end) {
    if (typeof start !== 'number' || typeof end !== 'number' || start > end || start < 0) {
      return null;
    }
    var body = text(capture);
    var units = { start: -1, end: -1 };
    var bytes = 0;
    var i = 0;
    while (true) {
      if (bytes === start && units.start < 0) { units.start = i; }
      if (bytes === end) { units.end = i; break; }
      if (bytes > end || i >= body.length) { break; }
      var point = body.codePointAt(i);
      bytes += point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
      i += point > 0xffff ? 2 : 1;
    }
    if (units.start < 0 || units.end < 0) { return null; }
    return units;
  }

  // Where an anchor's quote sits in a capture, as code units.
  //
  // The byte span is tried first because it is what the record says. When the
  // text it names is not the quote — an anchor from a build that measured
  // differently, or a capture edited outside the engine — the quote is located
  // by search, which is exactly what the engine itself does when an offered
  // span does not match (grounding.go). A quote that appears more than once is
  // left unmarked: marking the first of several would assert evidence the
  // record does not carry.
  function anchorSpan(capture, anchor) {
    if (!anchor) { return null; }
    var body = text(capture);
    var quote = text(anchor.quote);
    var span = byteSpanToUnits(body, anchor.start, anchor.end);
    if (span && body.slice(span.start, span.end) === quote) { return span; }
    if (!quote) { return null; }
    var at = body.indexOf(quote);
    if (at < 0 || body.indexOf(quote, at + 1) >= 0) { return null; }
    return { start: at, end: at + quote.length };
  }

  // --------------------------------------------------------------- runs

  function runsOf(session) { return list(session && session.runs); }

  function partsOf(run) {
    var parts = list(run && run.contributions).slice();
    if (run && run.synthesis) { parts.push(run.synthesis); }
    return parts;
  }

  function findContribution(session, contributionId) {
    var runs = runsOf(session);
    for (var i = 0; i < runs.length; i++) {
      var parts = partsOf(runs[i]);
      for (var j = 0; j < parts.length; j++) {
        if (parts[j] && parts[j].contribution_id === contributionId) { return parts[j]; }
      }
    }
    return null;
  }

  function runOfContribution(session, contributionId) {
    var runs = runsOf(session);
    for (var i = 0; i < runs.length; i++) {
      var parts = partsOf(runs[i]);
      for (var j = 0; j < parts.length; j++) {
        if (parts[j] && parts[j].contribution_id === contributionId) { return runs[i]; }
      }
    }
    return null;
  }

  function lastRun(session) {
    var runs = runsOf(session);
    return runs.length ? runs[runs.length - 1] : null;
  }

  function isLive(run) {
    return !!run && (run.status === 'running' || run.status === 'pending');
  }

  // The synthesis a reader means by "what did the council conclude": the newest
  // one. Earlier syntheses are kept under their own rounds, never overwritten.
  function currentSynthesis(session) {
    var runs = runsOf(session);
    for (var i = runs.length - 1; i >= 0; i--) {
      if (runs[i] && runs[i].synthesis) {
        return { synthesis: runs[i].synthesis, run: runs[i], index: i };
      }
    }
    return null;
  }

  // Completed answers, newest last. Comparison and the follow-up router read
  // this rather than walking runs again.
  function completedContributions(session) {
    var out = [];
    runsOf(session).forEach(function (run) {
      list(run.contributions).forEach(function (c) {
        if (c && c.status === 'complete') { out.push(c); }
      });
    });
    return out;
  }

  function runTitle(session, run, index) {
    var definition = session && session.definition_snapshot;
    if (run && run.kind === 'follow_up') {
      var seat = seatOf(definition, run.addressed_seat_id);
      return 'Follow-up to ' + (seat ? seat.responsibility : 'one seat');
    }
    if (run && run.kind === 'retry') { return 'Retry, round ' + (index + 1); }
    return 'Round ' + (index + 1);
  }

  global.CouncilRecord = {
    list: list,
    text: text,
    when: when,
    kindWord: kindWord,
    sessionsOf: sessionsOf,
    selectedSession: selectedSession,
    definitionOf: definitionOf,
    editableDefinition: editableDefinition,
    memberOf: memberOf,
    seatOf: seatOf,
    seatForMember: seatForMember,
    sourceOf: sourceOf,
    anchorOf: anchorOf,
    hasMaterial: hasMaterial,
    contentHash: contentHash,
    byteSpanToUnits: byteSpanToUnits,
    anchorSpan: anchorSpan,
    runsOf: runsOf,
    partsOf: partsOf,
    findContribution: findContribution,
    runOfContribution: runOfContribution,
    lastRun: lastRun,
    isLive: isLive,
    currentSynthesis: currentSynthesis,
    completedContributions: completedContributions,
    runTitle: runTitle
  };
})(window);

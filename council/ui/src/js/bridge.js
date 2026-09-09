// The page's half of the wrapper protocol.
//
// Everything the panel knows comes through here, and three rules hold:
//
//  1. A read is a read and a mutation is a mutation. A mutating command carries
//     the revision it was written against; a read must not carry one. Which is
//     which is not a judgement the views make — the set is stated once, below.
//  2. Mutations are single-flight. Two in flight at once race for the same
//     revision: the second is written against a number the first has already
//     moved, comes back `stale_revision` through no fault of the reader, and its
//     refusal is then overwritten by the first one's success message. Serialising
//     costs nothing at human speed and removes the class.
//  3. The size that matters is the size of the message that actually travels.
//     The wrapper measures the whole serialised envelope, framing included, so
//     that is what is measured here — before sending, so an oversized request is
//     refused with something a reader can act on instead of being cut off at the
//     hop.

(function (global) {
  'use strict';

  // Commands that change the record, and therefore carry base_revision. The
  // wrapper's own `wrapper.*` commands are not in it: none of them changes a
  // council, and `wrapper.set_view` advances no revision at all, so nothing may
  // treat its reply as evidence that anything was saved.
  var MUTATIONS = {
    'definition.upsert': true,
    'definition.import': true,
    'source.upsert': true,
    'source.capture': true,
    'member.upsert': true,
    'member.adopt_source': true,
    'session.create': true,
    'session.bind_chat': true,
    'run.start': true,
    'run.cancel': true,
    'run.retry': true,
    'outcome.retain': true,
    'outcome.mark_missing': true
  };

  // The wrapper's ceiling, in UTF-16 code units. Replaced by the real one from
  // wrapper.describe as soon as the panel answers; the literal is the floor to
  // measure against until then.
  var DEFAULT_LIMIT = 32768;

  function Bridge(transport) {
    this.transport = transport;
    this.revision = null;
    this.limit = DEFAULT_LIMIT;
    this.describeReply = null;
    this.queue = Promise.resolve();
    this.onRefusal = function () {};
    this.onSnapshot = function () {};
  }

  // What the wrapper will measure this request as. The envelope is rebuilt in
  // the same shape council_bridge.gd sends, because a check against the payload
  // alone passes messages the hop then refuses.
  Bridge.prototype.measure = function (command, payload, baseRevision) {
    var envelope = {
      schema_version: 1,
      envelope: 'request',
      request_id: 'p0000-0000000000000',
      command: command,
      payload: payload || {}
    };
    if (baseRevision !== undefined && baseRevision !== null) {
      envelope.base_revision = baseRevision;
    }
    try {
      return JSON.stringify(envelope).length;
    } catch (e) {
      return Infinity;
    }
  };

  Bridge.prototype.tooLarge = function (size) {
    return {
      ok: false,
      snapshot_revision: this.revision,
      error: {
        code: 'payload_too_large',
        message: 'That request needs ' + size + ' units and the panel carries '
          + this.limit + ' in one message. Nothing was changed. Shorten the text and try again.',
        retryable: false
      }
    };
  };

  // One call, with no queueing and no revision stamping. Reads and wrapper
  // commands go through here directly.
  Bridge.prototype.send = function (command, payload, baseRevision) {
    var self = this;
    var size = this.measure(command, payload, baseRevision);
    if (size > this.limit) {
      // Through accept(), not around it: a refusal the page produced itself has
      // to reach the reader the same way one the wrapper produced does.
      return Promise.resolve(this.accept(this.tooLarge(size)));
    }
    return this.transport.call(command, payload || {}, baseRevision).then(function (reply) {
      return self.accept(reply);
    });
  };

  // Every reply carries the revision it was produced against. The page keeps it
  // only to stamp the next mutation, never as a source of truth.
  Bridge.prototype.accept = function (reply) {
    if (reply && reply.snapshot_revision !== undefined && reply.snapshot_revision !== null) {
      this.revision = reply.snapshot_revision;
    }
    if (reply && reply.ok === false) {
      this.onRefusal(reply.error || { code: 'internal', message: 'Refused.', retryable: false });
    }
    return reply;
  };

  Bridge.prototype.describe = function () {
    var self = this;
    return this.send('wrapper.describe', {}).then(function (reply) {
      if (reply && reply.ok && reply.payload) {
        self.describeReply = reply.payload;
        var limit = Number(reply.payload.max_message_code_units);
        if (limit > 0) { self.limit = limit; }
      }
      return reply;
    });
  };

  // Re-read the record. Every event causes one of these: an event says the
  // record moved and never says what it now is, so nothing is patched in place.
  Bridge.prototype.read = function () {
    var self = this;
    return this.send('snapshot.get', {}).then(function (reply) {
      if (reply && reply.ok && reply.payload) {
        self.onSnapshot(reply.payload.snapshot || {});
      }
      return reply;
    });
  };

  // A change, queued behind every other change, followed by a fresh read. The
  // reply is returned to the caller so it can say what happened; the record it
  // describes has already been re-read by the time that runs.
  Bridge.prototype.mutate = function (command, payload) {
    var self = this;
    var run = this.queue.then(function () {
      if (!MUTATIONS[command]) {
        throw new Error('mutate() was given the read command ' + command);
      }
      return self.send(command, payload, self.revision).then(function (reply) {
        return self.read().then(function () { return reply; });
      });
    });
    // One failure must not wedge the queue for everything behind it.
    this.queue = run.catch(function () {});
    return run;
  };

  // The host's enabled models, as the wrapper reads them from the backend.
  //
  // Deliberately NOT cached. Every call re-reads Minerva's enabled providers
  // (council_backend.gd: "each call re-reads them from the host, which is what
  // makes it the answer after a user enables a model"), and a page that cached
  // the first answer would show a stale catalogue until the tab was reopened —
  // which is exactly the case the re-read exists for. The cost is a host round
  // trip per provider, paid only when a control that offers models is opened.
  Bridge.prototype.models = function () {
    return this.send('wrapper.models', {}).then(function (reply) {
      if (!reply || !reply.ok || !reply.payload) {
        return { models: [], known: false, error: reply && reply.error ? reply.error.message : '' };
      }
      return {
        models: Array.isArray(reply.payload.models) ? reply.payload.models : [],
        known: !!reply.payload.known,
        error: global.CouncilRecord.text(reply.payload.refresh_error)
      };
    });
  };

  global.CouncilBridgeClient = { Bridge: Bridge, MUTATIONS: MUTATIONS };
})(window);

// The states the prototype can be opened in, each a whole council_project_snapshot.
//
// A scenario is data, not a code path: the page renders whatever snapshot it is
// handed, so "partial" and "ordinary" go through exactly the same renderer. That
// is the point — a state that only exists because a flag was set somewhere is a
// state the production UI will get wrong.

(function (global) {
  'use strict';

  var S = global.CouncilSample;

  var QUESTION = 'A pilot customer will pay up front for a slipcase variant we do not make. Do we take it?';

  function claim(id, support, text, citations) {
    return { claim_id: id, support: support, text: text, citations: citations || [] };
  }

  function cite(source_id, source_revision, anchor_id) {
    return { source_id: source_id, source_revision: source_revision, anchor_id: anchor_id };
  }

  // ---------------------------------------------------------------- members

  function signalContribution(id) {
    return {
      contribution_id: id, seat_id: 'seat.demand', member_id: 'm.signal', member_revision: 3,
      status: 'complete', model_id: 'sonnet-4.6',
      text: 'The call gives us one order, not a pattern. Forty units, once, for an anniversary; '
        + 'the buyer did not expect to reorder and would not introduce us to the two peers they '
        + 'named. Nothing in this material says a second slipcase buyer exists. The question that '
        + 'would have told us something durable - what they would pay for the standard binding at '
        + 'this volume - was never asked.',
      claims: [
        claim('cl.s1', 'source',
          'The buyer named a single run of forty units for an anniversary and did not expect to reorder.',
          [cite('src.pilot-call', 1, 'a.one-off'), cite('src.pilot-call', 1, 'a.no-reorder')]),
        claim('cl.s2', 'inference',
          'One order from a buyer who names no successor is demand for a favour that pays, not demand for a product line.'),
        claim('cl.s3', 'unknown',
          'Whether this buyer would take the standard binding at the same volume was never asked, so the material establishes nothing about it.')
      ]
    };
  }

  function capitalContribution(id) {
    return {
      contribution_id: id, seat_id: 'seat.money', member_id: 'm.capital', member_revision: 2,
      status: 'complete', model_id: 'sonnet-4.6',
      text: 'Take the cash, and cap it. The payment lands before the work does, which is the only '
        + 'shape of order that improves the runway instead of consuming it. The exposure is a '
        + 'fortnight of the ordinary work and a cloth we would have to buy in. I would want to set '
        + 'against that what the press costs us each month, and that figure is referenced in this '
        + 'project but was never captured into it, so I am arguing without it.',
      claims: [
        claim('cl.c1', 'source', 'The buyer offered to pay the whole amount before the work begins.',
          [cite('src.pilot-call', 1, 'a.upfront')]),
        claim('cl.c2', 'inference',
          'Money paid up front is worth more than the same money invoiced later, because it does not have to be financed.'),
        claim('cl.c3', 'unknown',
          'What a fortnight of diverted work costs against the monthly press payment cannot be stated from the material this council holds.')
      ]
    };
  }

  function narrowContribution(id) {
    return {
      contribution_id: id, seat_id: 'seat.focus', member_id: 'm.okonkwo', member_revision: 2,
      status: 'complete', model_id: 'sonnet-4.6',
      text: 'The essay I am grounded in offers one test for a paid detour: does the variant become '
        + 'the ordinary work within a year. A run of forty that the buyer expects never to repeat '
        + 'does not become the ordinary work, so on that test this is a detour and the price of it '
        + 'is the repetition given up. I should be plain that the essay is arguing about attention, '
        + 'not about equipment finance, which is the argument being made against me.',
      claims: [
        claim('cl.n1', 'source',
          'The essay proposes one test for a paid detour: whether the variant becomes the ordinary work within a year.',
          [cite('src.narrow-shop', 2, 'a.year-test')]),
        claim('cl.n2', 'source', 'It holds that a narrow shop earns its margin from repetition.',
          [cite('src.narrow-shop', 2, 'a.repetition')]),
        claim('cl.n3', 'inference',
          'A one-off run that the buyer expects never to repeat fails that test, so the cost of taking it is the repetition displaced.'),
        claim('cl.n4', 'unknown',
          'The essay takes no position on accepting a detour in order to fund equipment, which is the case being argued against this seat.')
      ]
    };
  }

  function synthesis(id, text, claims) {
    return {
      contribution_id: id, seat_id: 'seat.chair', member_id: 'm.chair', member_revision: 1,
      status: 'complete', model_id: 'opus-4.6', text: text, claims: claims || []
    };
  }

  var ROUND_ONE_SYNTHESIS = synthesis('c.chair.1',
    'The council does not agree, and the disagreement is not about the facts. Customer Signal and '
    + 'the Narrow Shop seat read the same call the same way: one order, no successor named, no '
    + 'introduction offered. Capital Discipline disputes none of that and argues the cash is worth '
    + 'the fortnight anyway. So the split is about what a fortnight of the ordinary work is worth, '
    + 'and that is the one number this council does not have.',
    [
      claim('cl.h1', 'inference',
        'Two seats treat the order as a detour to be priced; one treats it as cash to be banked. Neither reading contradicts the call log.'),
      claim('cl.h2', 'unknown',
        'The council cannot price the fortnight: the ledger it would need is referenced but its material was never captured.')
    ]);

  function baseRun(overrides) {
    var run = {
      run_id: 'run.1', request_id: 'req.round-one', kind: 'initial_round', status: 'complete',
      started_at: '2026-09-03T10:02:11Z', ended_at: '2026-09-03T10:03:48Z', prompt: '',
      contributions: [signalContribution('c.signal.1'), capitalContribution('c.capital.1'), narrowContribution('c.narrow.1')],
      synthesis: ROUND_ONE_SYNTHESIS
    };
    Object.keys(overrides || {}).forEach(function (k) {
      if (overrides[k] === undefined) { delete run[k]; } else { run[k] = overrides[k]; }
    });
    return run;
  }

  // ---------------------------------------------------------------- sessions

  function session(overrides) {
    var s = {
      schema_version: 1,
      record_kind: 'council_session',
      session_id: 'ses.slipcase',
      session_revision: 6,
      definition_snapshot: S.definition(4),
      chat_binding: { chat_id: 'chat.bindery-planning', origin_message_id: 'msg.4471', bound_at: '2026-09-03T10:01:55Z' },
      question: QUESTION,
      status: 'complete',
      runs: [baseRun()],
      outcomes: []
    };
    Object.keys(overrides || {}).forEach(function (k) { s[k] = overrides[k]; });
    return s;
  }

  function snapshot(overrides) {
    var snap = {
      schema_version: 1,
      record_kind: 'council_project_snapshot',
      snapshot_revision: 14,
      definitions: [S.definition(4)],
      sessions: [session()],
      view: { selected_session_id: 'ses.slipcase', selected_definition_id: 'def.bindery', pane: 'session' }
    };
    Object.keys(overrides || {}).forEach(function (k) { snap[k] = overrides[k]; });
    return snap;
  }

  // ---------------------------------------------------------------- scenarios

  var SCENARIOS = {

    ordinary: {
      label: 'Ordinary - a finished round with a live disagreement',
      snapshot: snapshot
    },

    empty: {
      label: 'Empty - a project with no council yet',
      snapshot: function () {
        return snapshot({ snapshot_revision: 1, definitions: [], sessions: [], view: { pane: 'session' } });
      }
    },

    assembling: {
      label: 'Assembling - a council being put together, nothing asked yet',
      snapshot: function () {
        var def = S.definition(2);
        def.seats = S.seats.slice(0, 3);
        return snapshot({
          snapshot_revision: 5,
          definitions: [def],
          sessions: [],
          view: { selected_definition_id: 'def.bindery', pane: 'members' }
        });
      }
    },

    running: {
      label: 'Running - one seat answered, two still out',
      snapshot: function () {
        var pendingCapital = capitalContribution('c.capital.1');
        pendingCapital.status = 'running';
        pendingCapital.text = '';
        pendingCapital.claims = [];
        delete pendingCapital.model_id;
        var pendingNarrow = narrowContribution('c.narrow.1');
        pendingNarrow.status = 'pending';
        pendingNarrow.text = '';
        pendingNarrow.claims = [];
        delete pendingNarrow.model_id;
        return snapshot({
          snapshot_revision: 11,
          sessions: [session({
            session_revision: 3, status: 'running',
            runs: [baseRun({
              status: 'running', ended_at: undefined, synthesis: undefined,
              contributions: [signalContribution('c.signal.1'), pendingCapital, pendingNarrow]
            })]
          })]
        });
      },
      // The round is genuinely in flight: these land on timers, through events.
      timeline: [
        { after: 2600, contribution: 'c.capital.1' },
        { after: 5200, contribution: 'c.narrow.1' },
        { after: 6400, finish: 'run.1' }
      ]
    },

    partial: {
      label: 'Partial - one seat timed out and can be retried',
      snapshot: function () {
        var failed = capitalContribution('c.capital.1');
        failed.status = 'failed';
        failed.text = '';
        failed.claims = [];
        delete failed.model_id;
        failed.failure = {
          code: 'timeout', retryable: true,
          message: 'Capital Discipline did not answer within 120 seconds. Nothing was spent past the timeout.'
        };
        return snapshot({
          snapshot_revision: 12,
          sessions: [session({
            status: 'partial',
            runs: [baseRun({
              status: 'partial',
              contributions: [signalContribution('c.signal.1'), failed, narrowContribution('c.narrow.1')],
              synthesis: synthesis('c.chair.1',
                'Two of three seats answered. Customer Signal and the Narrow Shop seat agree the order '
                + 'is a one-off and read it as a detour to be priced. The seat that would have argued '
                + 'the cash case timed out, so the argument against them is not in front of you and '
                + 'this synthesis should not be read as the council settling anything.',
                [claim('cl.h1', 'inference',
                  'With the cash argument missing, the round is one-sided by absence rather than by agreement.')]),
              failure: {
                code: 'timeout', retryable: true,
                message: 'One of three seats did not answer in time.'
              }
            })]
          })]
        });
      }
    },

    error: {
      label: 'Error - the round never started',
      snapshot: function () {
        return snapshot({
          snapshot_revision: 9,
          sessions: [session({
            session_revision: 2, status: 'failed',
            runs: [baseRun({
              status: 'failed', ended_at: '2026-09-03T10:02:14Z', contributions: [], synthesis: undefined,
              failure: {
                code: 'model_unavailable', retryable: true,
                message: 'No enabled model accepted the round. Nothing was sent and nothing was spent.'
              }
            })]
          })]
        });
      }
    },

    late: {
      label: 'Late contribution - a follow-up answer arrives after the round closed',
      demo_note: 'Demo data. This walkthrough also shows what a contribution entered by a second '
        + 'person would look like arriving late. Council v0.1 sends no invitations and seats no '
        + 'human but you; there is deliberately no invite control anywhere in this prototype.',
      snapshot: function () {
        var owner = {
          contribution_id: 'c.owner.late', seat_id: 'seat.owner', member_id: 'm.owner',
          member_revision: 1, status: 'pending', claims: []
        };
        var followUp = narrowContribution('c.narrow.2');
        followUp.status = 'running';
        followUp.text = '';
        followUp.claims = [];
        delete followUp.model_id;
        return snapshot({
          snapshot_revision: 18,
          sessions: [session({
            session_revision: 9, status: 'running',
            runs: [baseRun(), {
              run_id: 'run.2', request_id: 'req.follow-up-focus', kind: 'follow_up', status: 'running',
              started_at: '2026-09-03T10:11:02Z',
              addressed_seat_id: 'seat.focus',
              prompt: 'Capital Discipline argues the cash is worth a fortnight of the ordinary work. '
                + 'On your own test, is there a shape of this order that passes?',
              contributions: [followUp, owner]
            }]
          })]
        });
      },
      timeline: [
        { after: 3200, contribution: 'c.narrow.2' },
        { after: 7000, contribution: 'c.owner.late' },
        { after: 8200, finish: 'run.2' }
      ]
    },

    unreadable: {
      label: 'Unreadable - the open document is not a council',
      unreadable: 'This file is not a Council record, so Council will not edit it. Saving hands the '
        + 'original bytes back unchanged.',
      snapshot: function () {
        return snapshot({ snapshot_revision: 1, definitions: [], sessions: [], view: {} });
      }
    }
  };

  // Bodies for contributions that arrive while the prototype is open. Kept out
  // of the snapshot so that "not answered yet" is a real absence, not text the
  // renderer is hiding.
  var ARRIVALS = {
    'c.signal.1': function () { return signalContribution('c.signal.1'); },
    'c.capital.1': function () { return capitalContribution('c.capital.1'); },
    'c.narrow.1': function () { return narrowContribution('c.narrow.1'); },
    'c.narrow.2': function () {
      var c = narrowContribution('c.narrow.2');
      c.text = 'There is one, and it is narrower than what is on the table. If the slipcase is made '
        + 'in a cloth we already stock, to the case size we already cut, then it is a variation of '
        + 'the ordinary work rather than a detour from it, and the year test stops being the right '
        + 'question. As offered - a cloth we do not stock, a size we do not cut - my answer does '
        + 'not change.';
      c.claims = [
        claim('cl.n5', 'source', 'The test is whether the variant becomes the ordinary work within a year.',
          [cite('src.narrow-shop', 2, 'a.year-test')]),
        claim('cl.n6', 'inference',
          'A slipcase in stocked cloth at the case size already cut is a variation of the ordinary work, so the test does not bite.'),
        claim('cl.n7', 'unknown',
          'Whether the buyer would accept a stocked cloth is not established anywhere in this material.')
      ];
      return c;
    },
    'c.owner.late': function () {
      return {
        contribution_id: 'c.owner.late', seat_id: 'seat.owner', member_id: 'm.owner',
        member_revision: 1, status: 'complete',
        text: 'Entered by hand after the round closed: we have four metres of the grey cloth left '
          + 'from the spring run, which is enough for forty slipcases if the case size holds.',
        claims: [claim('cl.o1', 'unknown',
          'Entered by a person from their own knowledge. No source in this council supports or contradicts it.')]
      };
    }
  };

  var REVISED_SYNTHESIS = {
    'run.1': function () { return ROUND_ONE_SYNTHESIS; },
    'run.2': function () {
      return synthesis('c.chair.2',
        'The follow-up narrows the disagreement rather than settling it. The Narrow Shop seat now '
        + 'accepts a slipcase in stocked cloth at the existing case size as ordinary work, which is '
        + 'not the order as offered. A late contribution entered by hand says the stocked cloth '
        + 'exists in sufficient quantity. That makes a counter-offer the live question, and it is '
        + 'one nobody in this council can answer: whether the buyer would take it.',
        [
          claim('cl.h3', 'inference',
            'The council now agrees on a version of the order it has not been offered, which turns the decision into a counter-offer.'),
          claim('cl.h4', 'unknown',
            'Whether the buyer accepts a stocked cloth is unknown to every seat here; only the buyer can answer it.')
        ]);
    }
  };

  // A follow-up the prototype starts itself, for a seat with no scripted reply.
  function followUpReply(seat, member, contributionId) {
    return {
      contribution_id: contributionId, seat_id: seat.seat_id, member_id: member.member_id,
      member_revision: member.member_revision, status: 'complete', model_id: 'sonnet-4.6',
      text: 'Taking the question on its own: this seat can speak to ' + seat.responsibility.charAt(0).toLowerCase()
        + seat.responsibility.slice(1).replace(/\.$/, '') + ', and on that ground the answer turns on '
        + 'what the material actually establishes rather than on what the round assumed.',
      claims: [
        claim('cl.f1.' + contributionId, 'inference',
          'Answered from this seat\'s responsibility alone; the follow-up was not put to the rest of the council.'),
        claim('cl.f2.' + contributionId, 'unknown',
          'Nothing in this council\'s sources speaks to the question directly.')
      ]
    };
  }

  global.CouncilScenarios = {
    followUpReply: followUpReply,
    scenarios: SCENARIOS,
    arrivals: ARRIVALS,
    revisedSynthesis: REVISED_SYNTHESIS,
    question: QUESTION
  };
})(window);

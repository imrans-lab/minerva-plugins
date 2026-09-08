// Original sample material for the Council prototype.
//
// Everything here is invented for this prototype: the bindery, its pilot
// customer, and the essayist whose simulant sits on the council. No real person
// is quoted or represented. The shapes follow council/schemas/*.json exactly, so
// the prototype cannot show a field the backend has no way to produce.
//
// Anchor offsets are derived from the payload text at load time (see anchor())
// rather than written by hand, so a quote and its span can never disagree.
// Content hashes were computed once from these exact strings; they are here
// because the schema requires them, not because the prototype checks them.

(function (global) {
  'use strict';

  // Paragraphs, not hard-wrapped lines: the panel wraps captured text itself,
  // and a citation that has to survive a line break is a citation waiting to
  // break.
  var ESSAY = [
    'On the Narrow Shop (excerpt)',
    'A shop that does one thing well is not a small version of a shop that does many things. It is a different animal. Its margin comes from repetition: the third hundred of a run costs a fraction of the first ten, and that difference is the whole business.',
    'The temptation is always the paid detour. Someone offers real money for a variant you do not make. The money is real and the variant is not free. You pay for it in the repetition you give up while you build it.',
    'I have no general rule for when to take the detour. I have one test I trust: if the variant becomes the ordinary work within a year it was never a detour. If it does not, you have sold a year of your attention at a price you never quoted.'
  ].join('\n\n');

  var CALL_LOG = [
    'Call log - pilot customer, 14 minutes',
    'They asked for a slipcase variant in a cloth we do not stock. Volume named: forty units, once, for an anniversary run. They offered to pay the whole amount up front.',
    'Asked whether they would reorder. Answer: probably not, a one-time thing for them. Asked who else buys slipcases. They named two peers and would not introduce us to either.',
    'We never asked what they would pay for the standard binding at the same volume. That question is still open.'
  ].join('\n\n');

  // Find a quote inside its payload and return the anchor the schema wants.
  // A quote that is not present is a bug in this file, and saying so loudly
  // here is cheaper than rendering a citation that points at nothing.
  function anchor(id, text, quote) {
    var start = text.indexOf(quote);
    if (start < 0) {
      throw new Error('sample-data: anchor ' + id + ' quotes text that is not in its source');
    }
    return { anchor_id: id, quote: quote, start: start, end: start + quote.length };
  }

  function payload(text, hash) {
    return {
      content_type: 'text/plain',
      byte_length: new global.TextEncoder().encode(text).length,
      content_hash: hash,
      inline: text
    };
  }

  var SOURCES = [
    {
      source_id: 'src.narrow-shop',
      source_revision: 2,
      title: 'On the Narrow Shop',
      author: 'R. V. Okonkwo (invented for this prototype)',
      locator: 'pasted excerpt',
      captured_at: '2026-08-19T09:12:00Z',
      artifact: { kind: 'note', ref: 'note:narrow-shop-excerpt', label: 'On the Narrow Shop - excerpt' },
      payload: payload(ESSAY, 'sha256:7e9469c83cde3faa1ee814af33f647c93b8007f9ae6f913bb17ee64f3f6148ee'),
      anchors: [
        anchor('a.repetition', ESSAY, 'Its margin comes from repetition'),
        anchor('a.detour', ESSAY, 'The money is real and the variant is not free'),
        anchor('a.year-test', ESSAY, 'if the variant becomes the ordinary work within a year it was never a detour')
      ]
    },
    {
      source_id: 'src.pilot-call',
      source_revision: 1,
      title: 'Pilot customer call log',
      author: '',
      locator: 'Minerva note: Bindery / pilot calls',
      captured_at: '2026-09-02T16:40:00Z',
      artifact: { kind: 'note', ref: 'note:pilot-call-log', label: 'Bindery / pilot calls' },
      payload: payload(CALL_LOG, 'sha256:5625d75425712ad90629b3ab087b0ab426b5255c3d4b4787034af96392707f1a'),
      anchors: [
        anchor('a.one-off', CALL_LOG, 'forty units, once, for an anniversary run'),
        anchor('a.no-reorder', CALL_LOG, 'Answer: probably not, a one-time thing for them'),
        anchor('a.upfront', CALL_LOG, 'They offered to pay the whole amount up front'),
        anchor('a.unasked', CALL_LOG, 'We never asked what they would pay for the standard binding at the same volume')
      ]
    },
    {
      // Inventory only: captured as a reference, material never embedded. Any
      // citation into it has to render as "material not available" rather than
      // as a quote nobody can check.
      source_id: 'src.ledger',
      source_revision: 1,
      title: 'Bindery ledger, spring quarter',
      author: '',
      locator: 'Spreadsheet outside the project',
      captured_at: '2026-09-02T16:44:00Z',
      artifact: { kind: 'file', ref: 'file:ledger-spring.ods', label: 'ledger-spring.ods', missing: true },
      anchors: [{ anchor_id: 'a.press-payment', quote: 'press payment, monthly' }]
    }
  ];

  var MEMBERS = [
    {
      member_id: 'm.chair', member_revision: 1, kind: 'assistant',
      display_name: 'The Chair',
      scope: 'Reads every contribution in a round and reports what the council actually said, including where it disagrees.',
      limitations: 'Holds no grounding of its own. Anything it asserts that no member supported is its own inference.',
      grounding: []
    },
    {
      member_id: 'm.signal', member_revision: 3, kind: 'assistant',
      display_name: 'Customer Signal',
      scope: 'What the evidence from real conversations does and does not establish about demand.',
      limitations: 'Sees only the call material in this project. Says nothing about price, capacity or craft.',
      grounding: [{ source_id: 'src.pilot-call', source_revision: 1 }]
    },
    {
      member_id: 'm.capital', member_revision: 2, kind: 'assistant',
      display_name: 'Capital Discipline',
      scope: 'Cash timing, committed cost, and what a decision does to the runway.',
      limitations: 'Has the call log and a reference to the ledger, whose figures were never captured into the project.',
      grounding: [
        { source_id: 'src.pilot-call', source_revision: 1 },
        { source_id: 'src.ledger', source_revision: 1 }
      ]
    },
    {
      member_id: 'm.okonkwo', member_revision: 2, kind: 'simulant',
      display_name: 'Narrow Shop simulant',
      represents: 'R. V. Okonkwo, an essayist invented for this prototype',
      scope: 'One essay on why single-product shops earn their margin from repetition, and the test it proposes for paid detours.',
      limitations: 'Two thousand words on one subject. It establishes no view on pricing, hiring, or this bindery in particular, and the simulant is not the author.',
      grounding: [{ source_id: 'src.narrow-shop', source_revision: 2 }]
    },
    {
      member_id: 'm.owner', member_revision: 1, kind: 'human',
      display_name: 'You',
      scope: 'The person running this project. Contributions are entered here by hand.',
      limitations: 'The only human this version of Council can seat.',
      grounding: []
    }
  ];

  var SEATS = [
    { seat_id: 'seat.chair', member_id: 'm.chair', role: 'chair',
      responsibility: 'Synthesise the round and name the disagreement rather than resolving it.',
      relevance_tags: ['always'] },
    { seat_id: 'seat.demand', member_id: 'm.signal', role: 'advisor',
      responsibility: 'Say what the customer evidence supports.', relevance_tags: ['demand', 'customers'] },
    { seat_id: 'seat.money', member_id: 'm.capital', role: 'advisor',
      responsibility: 'Say what the decision costs and when.', relevance_tags: ['cash', 'runway'] },
    { seat_id: 'seat.focus', member_id: 'm.okonkwo', role: 'advisor',
      responsibility: 'Argue the case for staying narrow.', relevance_tags: ['focus', 'strategy'] },
    { seat_id: 'seat.owner', member_id: 'm.owner', role: 'advisor',
      responsibility: 'Add what only the owner knows.', relevance_tags: ['owner'] }
  ];

  function definition(revision) {
    return {
      schema_version: 1,
      record_kind: 'council_definition',
      definition_id: 'def.bindery',
      definition_revision: revision || 4,
      name: 'Bindery decisions',
      purpose: 'Decide the awkward calls for a two-person hand bindery: what to take on, what to refuse, and what to stop doing.',
      members: MEMBERS,
      seats: SEATS,
      sources: SOURCES,
      deliberation: {
        max_members_per_round: 4,
        independent_initial_round: true,
        preserve_disagreement: true,
        per_member_timeout_seconds: 120
      }
    };
  }

  global.CouncilSample = {
    ESSAY: ESSAY,
    CALL_LOG: CALL_LOG,
    sources: SOURCES,
    members: MEMBERS,
    seats: SEATS,
    definition: definition
  };
})(window);

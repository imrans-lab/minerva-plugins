// Fragments more than one pane needs: an identity, a status pill, a claim list,
// and a whole contribution.
//
// Views are functions from record to nodes. They hold no state, reach for
// nothing outside their arguments, and attach no listeners: a control says what
// it is with `data-*` attributes and one delegated handler in app.js decides
// what that means. That is what makes Back work — a re-render replaces every
// node, so the only thing that can survive it is a control's attributes.

(function (global) {
  'use strict';

  var D = global.CouncilDom;
  var R = global.CouncilRecord;
  var el = D.el;

  // The name, then a chip that always spells the word — Human, Assistant,
  // Simulant — because a colour or an icon alone is not readable in monochrome
  // or at a glance. The seat's responsibility sits beside it when there is one:
  // identity and responsibility are separate records, and reading them as one
  // line makes it obvious when the same member is seated differently.
  function identity(definition, memberId, seatId) {
    var member = R.memberOf(definition, memberId) || { display_name: memberId, kind: 'assistant' };
    var seat = seatId ? R.seatOf(definition, seatId) : null;
    return el('div', { class: 'who' }, [
      el('span', { class: 'name', text: member.display_name || memberId }),
      el('span', { class: 'kind', data: { kind: member.kind }, text: R.kindWord(member.kind) }),
      seat && el('span', { class: 'seat', text: seat.responsibility })
    ]);
  }

  // A status pill is rendered only when the status is worth reading. A finished
  // contribution shows none: labelling the ordinary case is noise that costs a
  // line in a 400px pane.
  function statusPill(status) {
    return el('span', { class: 'status', data: { status: status }, text: status });
  }

  function citation(definition, cite) {
    var source = R.sourceOf(definition, cite.source_id, cite.source_revision);
    var anchor = R.anchorOf(source, cite.anchor_id);
    var quote = R.text(anchor && anchor.quote);
    var short = quote.length > 46 ? quote.slice(0, 44).replace(/\s+\S*$/, '') + '…' : quote;
    return [
      el('button', {
        class: 'link',
        type: 'button',
        data: {
          'open-source': cite.source_id,
          revision: cite.source_revision,
          anchor: cite.anchor_id || ''
        },
        text: short ? '“' + short + '”' : (source ? source.title : cite.source_id)
      }),
      el('span', {
        class: 'cite-source',
        text: (source ? source.title : cite.source_id) + ' · rev ' + R.text(cite.source_revision)
      })
    ];
  }

  // A claim carries the support it claimed and, when that support is `source`,
  // the words it points at. `inference` and `unknown` claims carry no citations
  // — that is the schema's rule, and it reads here as an absence you can see.
  function claimList(definition, claims, options) {
    var opts = options || {};
    var rows = R.list(claims);
    if (!rows.length) { return null; }
    return el('ul', { class: 'claims' }, rows.map(function (claim) {
      var cites = R.list(claim.citations);
      return el('li', { class: 'claim' }, [
        el('span', { class: 'support', data: { support: claim.support }, text: claim.support }),
        el('span', {}, [
          el('span', { class: 'text', text: claim.text }),
          cites.length && el('span', { class: 'citations' }, cites.map(function (cite) {
            return citation(definition, cite);
          })),
          opts.followUpOnClaims && claim.claim_id && el('span', { class: 'claim-actions' }, [
            el('button', {
              class: 'action quiet',
              type: 'button',
              data: { 'follow-claim': claim.claim_id },
              text: 'Ask about this argument'
            })
          ])
        ])
      ]);
    }));
  }

  // Which model produced an answer, and what it cost. The record has carried
  // model_id since the first schema so a result is never attributed to a model
  // that did not produce it; a field no view renders cannot do that job, so it
  // is rendered. A contribution with no model_id shows no line at all, which is
  // how a hand-entered answer reads as one.
  function provenance(contribution) {
    var usage = contribution.usage || {};
    var bits = [];
    if (contribution.model_id) { bits.push('Answered by ' + contribution.model_id); }
    if (usage.prompt_tokens !== undefined || usage.completion_tokens !== undefined) {
      bits.push(R.text(usage.prompt_tokens || 0) + ' prompt / '
        + R.text(usage.completion_tokens || 0) + ' completion tokens');
    }
    if (!bits.length) { return null; }
    return el('p', { class: 'provenance' }, bits.map(function (bit) {
      return el('span', { text: bit });
    }));
  }

  function contributionBody(definition, contribution) {
    if (contribution.status === 'pending' || contribution.status === 'running') {
      return el('p', { class: 'waiting' }, [
        el('span', { class: 'pulse', aria: { hidden: 'true' } }),
        contribution.status === 'running' ? 'Answering…' : 'Waiting to start'
      ]);
    }
    if (contribution.failure) {
      return el('p', { class: 'notice' }, [
        contribution.failure.message,
        contribution.failure.retryable && ' ',
        contribution.failure.retryable && el('button', {
          class: 'action',
          type: 'button',
          data: { 'retry-seat': contribution.seat_id },
          text: 'Ask this seat again'
        })
      ]);
    }
    return D.frag([
      el('p', { class: 'say', text: contribution.text }),
      claimList(definition, contribution.claims, { followUpOnClaims: contribution.status === 'complete' })
    ]);
  }

  // One contribution as a whole block. `data-anchor` is what keeps the reading
  // position still across a re-render, and the id is what the arrival button
  // scrolls to.
  function contributionBlock(definition, contribution, options) {
    var opts = options || {};
    var id = contribution.contribution_id;
    var complete = contribution.status === 'complete';
    return el('article', {
      class: 'contribution',
      id: 'contrib-' + id,
      tabindex: '-1',
      data: { anchor: 'c:' + id }
    }, [
      el('header', { class: 'row head' }, [
        identity(definition, contribution.member_id, contribution.seat_id),
        !complete && statusPill(contribution.status)
      ]),
      contribution.status === 'stale' && el('p', {
        class: 'superseded',
        text: 'This answer arrived after its round had stopped. It is kept for the record and changed nothing.'
      }),
      contributionBody(definition, contribution),
      provenance(contribution),
      complete && !opts.hideActions && el('div', { class: 'row' }, [
        el('button', {
          class: 'action',
          type: 'button',
          data: { 'follow-up': contribution.seat_id, from: id },
          text: 'Ask this seat a follow-up'
        }),
        el('button', {
          class: 'action quiet',
          type: 'button',
          data: { compare: id },
          text: 'Compare'
        }),
        el('label', { class: 'action quiet' }, [
          el('input', {
            type: 'checkbox',
            data: { pick: id },
            checked: opts.picked ? true : null
          }),
          ' Send to chat'
        ])
      ])
    ]);
  }

  global.CouncilParts = {
    identity: identity,
    statusPill: statusPill,
    claimList: claimList,
    provenance: provenance,
    contributionBlock: contributionBlock
  };
})(window);

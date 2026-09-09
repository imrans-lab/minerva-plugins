// The detail column: one thing at a time, opened from the reading column.
//
// Below a 900px panel a detail covers the reading column and Back returns to it;
// at or above 900px the two sit side by side and Back is hidden, because the
// detail column is simply where details appear. That is a container query in the
// stylesheet, not a measurement here — the page never asks how wide it is.
//
// Nothing in this file scrolls anything. A source opens with its metadata and
// the quoted span above the whole capture, so a reader in a 400px pane sees what
// was actually cited without being thrown into the middle of a document they
// have not been introduced to.

(function (global) {
  'use strict';

  var D = global.CouncilDom;
  var R = global.CouncilRecord;
  var P = global.CouncilParts;
  var el = D.el;

  function title(text) {
    return el('h3', { id: 'detail-title', tabindex: '-1', text: text });
  }

  function field(label, value) {
    if (value === null || value === undefined || value === '') { return null; }
    return el('dl', { class: 'field' }, [
      el('dt', { text: label }),
      typeof value === 'string' || typeof value === 'number'
        ? el('dd', { text: String(value) })
        : el('dd', {}, value)
    ]);
  }

  // A select over the host's enabled models. The empty option is not "no model":
  // it is "let the engine take the catalogue's first", which is what the engine
  // does and what the label says, so nobody discovers it by being billed for it.
  function modelSelect(id, models, chosen, emptyLabel) {
    var options = [el('option', { value: '', text: emptyLabel })];
    R.list(models).forEach(function (model) {
      options.push(el('option', {
        value: model.model_name,
        selected: model.model_name === chosen ? true : null,
        text: model.display
          ? model.display + ' (' + model.provider_display + ')'
          : model.model_name
      }));
    });
    // A hint the host no longer offers must still be visible and selected, or
    // saving the form would silently change which model answers.
    if (chosen && !R.list(models).some(function (m) { return m.model_name === chosen; })) {
      options.push(el('option', {
        value: chosen,
        selected: true,
        text: chosen + ' — not enabled in this Minerva'
      }));
    }
    return el('select', { id: id }, options);
  }

  // --------------------------------------------------------------- member

  function memberDetail(definition, memberId, context) {
    var member = R.memberOf(definition, memberId);
    if (!member) { return el('p', { class: 'empty', text: 'That member is not in this council.' }); }
    var seat = R.seatForMember(definition, memberId);

    var grounding = R.list(member.grounding);
    var groundingBody = grounding.length
      ? el('ul', { class: 'roster' }, grounding.map(function (ref) {
          var source = R.sourceOf(definition, ref.source_id, ref.source_revision);
          return el('li', {}, [
            el('button', {
              class: 'entry',
              type: 'button',
              data: { 'open-source': ref.source_id, revision: ref.source_revision }
            }, [
              (source ? source.title : ref.source_id) + ' · rev ' + R.text(ref.source_revision),
              source && !R.hasMaterial(source)
                && el('div', { class: 'line2', text: 'Material not in this project' })
            ])
          ]);
        }))
      : 'Nothing. This member holds no source material of its own.';

    return D.frag([
      el('h2', { text: 'Member' }),
      title(member.display_name),
      el('div', { class: 'who' }, [
        el('span', { class: 'kind', data: { kind: member.kind }, text: R.kindWord(member.kind) }),
        el('span', { class: 'seat', text: 'member revision ' + R.text(member.member_revision) })
      ]),
      member.represents && field('Represents', member.represents
        + '. The simulant and that author are separate identities; nothing here is a statement by them.'),
      seat && field('Seat in this council', seat.responsibility),
      field('Speaks to', member.scope),
      field('Does not establish', member.limitations),
      field('Grounded in', groundingBody),
      member.kind !== 'human' && context.editable && el('div', { class: 'composer' }, [
        el('label', { class: 'visible', for: 'member-model', text: 'Which model answers for this member' }),
        modelSelect('member-model', context.models, member.model_hint,
          'The first model Minerva has enabled'),
        el('div', { class: 'row' }, [
          el('button', {
            class: 'action',
            type: 'button',
            data: { 'save-model': member.member_id },
            text: 'Save the model choice'
          })
        ])
      ])
    ]);
  }

  // --------------------------------------------------------------- source

  function sourceDetail(definition, sourceId, revision, anchorId, fetched) {
    var source = R.sourceOf(definition, sourceId, revision);
    if (!source) { return el('p', { class: 'empty', text: 'That source revision is not in this project.' }); }

    var head = [
      el('h2', { text: 'Source' }),
      title(source.title),
      field('Captured', 'revision ' + R.text(source.source_revision)
        + ' on ' + R.when(source.captured_at)),
      field('Author', source.author),
      field('Where it came from', source.locator)
    ];

    // The fetched capture is preferred over the inventory copy: in production
    // material may exceed the inline limit and be read separately.
    var live = fetched && R.hasMaterial(fetched) ? fetched : source;
    if (!R.hasMaterial(live)) {
      head.push(el('div', { class: 'notice' }, [
        el('h3', { text: 'Material not available' }),
        'This source was captured as a reference only, so nothing can be quoted from it here. '
          + 'A claim citing it is a claim you cannot check.'
      ]));
      // The hash is the whole value of an inventory entry: it says exactly which
      // bytes are missing, so the capture can be recognised if it comes back.
      head.push(field('Bytes it stood for', R.contentHash(source)));
      return D.frag(head);
    }

    var text = R.text(live.payload.inline);
    var anchor = R.anchorOf(source, anchorId);
    // The record's offsets are bytes; this string is indexed in code units.
    // R.anchorSpan does the conversion and answers null when it cannot place the
    // quote, in which case the capture is shown whole rather than with a mark
    // over words nobody cited.
    var span = R.anchorSpan(text, anchor);
    var excerpt = el('div', { class: 'excerpt' });
    if (span) {
      excerpt.appendChild(document.createTextNode(text.slice(0, span.start)));
      excerpt.appendChild(el('mark', { id: 'cited-span', text: text.slice(span.start, span.end) }));
      excerpt.appendChild(document.createTextNode(text.slice(span.end)));
    } else {
      excerpt.textContent = text;
    }

    // The cited words come first so a reader in a 400px pane sees what was
    // quoted without scrolling; the whole capture sits under it with the same
    // span marked, for reading it in context.
    return D.frag(head.concat([
      anchor && field('Cited span', 'bytes ' + R.text(anchor.start)
        + '–' + R.text(anchor.end) + ' of this capture'),
      anchor && el('blockquote', { class: 'quoted', text: anchor.quote }),
      field('Integrity', R.text(live.payload.byte_length) + ' bytes, '
        + R.text(live.payload.content_hash).slice(0, 18) + '…'),
      el('h2', { class: 'group', text: 'The capture' }),
      excerpt,
      el('h2', { class: 'group', text: 'Anchors in this capture' }),
      el('ul', { class: 'roster' }, R.list(source.anchors).map(function (a) {
        return el('li', {}, [
          el('button', {
            class: 'entry',
            type: 'button',
            data: {
              'open-source': source.source_id,
              revision: source.source_revision,
              anchor: a.anchor_id
            },
            text: a.quote
          })
        ]);
      }))
    ]));
  }

  // -------------------------------------------------------------- compare

  function compareDetail(session, ids) {
    var definition = session && session.definition_snapshot;
    var picked = R.list(ids).map(function (id) {
      return R.findContribution(session, id);
    }).filter(Boolean);

    var blocks = [
      el('h2', { text: 'Compare' }),
      title('Where these answers part company')
    ];
    if (picked.length < 2) {
      blocks.push(el('p', {
        class: 'empty',
        text: 'Pick a second answer to set beside this one. Everything either seat asserted '
          + 'is shown with the support it claimed.'
      }));
    }
    blocks.push(el('div', { class: 'compare' + (picked.length > 1 ? ' two' : '') },
      picked.map(function (c) {
        return el('div', { class: 'column' }, [
          P.identity(definition, c.member_id, c.seat_id),
          P.claimList(definition, c.claims, {})
        ]);
      })));

    if (picked.length > 1) {
      var counts = {};
      picked.forEach(function (c) {
        var seen = {};
        R.list(c.claims).forEach(function (claim) {
          R.list(claim.citations).forEach(function (cite) { seen[cite.source_id] = true; });
        });
        Object.keys(seen).forEach(function (id) { counts[id] = (counts[id] || 0) + 1; });
      });
      var common = Object.keys(counts).filter(function (id) { return counts[id] > 1; });
      blocks.push(el('p', { class: 'superseded group-tight',
        text: common.length
          ? 'Both cite ' + common.map(function (id) {
              var source = R.sourceOf(definition, id);
              return source ? source.title : id;
            }).join(' and ') + ', so the disagreement is over what it implies, not over what it says.'
          : 'These answers cite no source in common.'
      }));
    }

    var others = R.completedContributions(session).filter(function (c) {
      return R.list(ids).indexOf(c.contribution_id) < 0;
    });
    if (others.length) {
      blocks.push(el('h2', { class: 'group', text: 'Set another answer beside it' }));
      blocks.push(el('ul', { class: 'roster' }, others.map(function (c) {
        return el('li', {}, [
          el('button', {
            class: 'entry',
            type: 'button',
            data: { 'compare-add': c.contribution_id }
          }, [P.identity(definition, c.member_id, c.seat_id)])
        ]);
      })));
    }
    return D.frag(blocks);
  }

  // ------------------------------------------------------------ follow-up

  function followUpDetail(session, detail, context) {
    var definition = session && session.definition_snapshot;
    var seatId = detail.seat_id;
    var seat = R.seatOf(definition, seatId);
    var member = seat ? R.memberOf(definition, seat.member_id) : null;
    var from = detail.from ? R.findContribution(session, detail.from) : null;
    var claim = null;
    if (detail.claim_id) {
      R.runsOf(session).forEach(function (run) {
        R.partsOf(run).forEach(function (c) {
          R.list(c.claims).forEach(function (candidate) {
            if (candidate.claim_id === detail.claim_id) { claim = candidate; }
          });
        });
      });
    }

    return D.frag([
      el('h2', { text: 'Follow-up' }),
      title('Ask ' + R.text(member ? member.display_name : seatId) + ' one more thing'),
      el('p', {
        class: 'superseded',
        text: 'Only this seat is asked. The rest of the council is not re-run, and nothing '
          + 'already said is discarded.'
      }),
      claim && el('blockquote', { class: 'quoted', text: claim.text }),
      !claim && from && el('blockquote', { class: 'quoted', text: R.text(from.text).slice(0, 220) + '…' }),
      el('div', { class: 'composer' }, [
        el('label', { class: 'visually-hidden', for: 'follow-up-text', text: 'Your follow-up question' }),
        el('textarea', { id: 'follow-up-text', placeholder: 'What would you like this seat to answer?' }),
        el('label', { class: 'visible', for: 'follow-up-model', text: 'Model for this round' }),
        modelSelect('follow-up-model', context.models, '',
          'Whatever this member is normally asked with'),
        el('div', { class: 'row' }, [
          el('button', {
            class: 'action primary',
            type: 'button',
            data: { 'send-follow-up': seatId, claim: detail.claim_id || '' },
            text: 'Ask this seat'
          }),
          el('button', { class: 'action quiet', type: 'button', data: { back: '1' }, text: 'Cancel' })
        ])
      ])
    ]);
  }

  // ------------------------------------------------------- assembly forms

  function createCouncilDetail() {
    return D.frag([
      el('h2', { text: 'New council' }),
      title('Start a council'),
      el('p', {
        class: 'superseded',
        text: 'A council opens with a chair and nothing else. The chair runs each round and '
          + 'reports where members disagree; it never adds a position of its own. Seat the '
          + 'members you want beside it next.'
      }),
      el('div', { class: 'composer' }, [
        el('label', { class: 'visible', for: 'council-name', text: 'Name' }),
        el('input', { id: 'council-name', type: 'text', placeholder: 'What this council is for, in a few words' }),
        el('label', { class: 'visible', for: 'council-purpose', text: 'Purpose' }),
        el('textarea', { id: 'council-purpose', placeholder: 'What kinds of decisions is this council asked to weigh in on?' }),
        el('div', { class: 'row' }, [
          el('button', { class: 'action primary', type: 'button', data: { 'create-council-send': '1' }, text: 'Create the council' }),
          el('button', { class: 'action quiet', type: 'button', data: { back: '1' }, text: 'Cancel' })
        ])
      ])
    ]);
  }

  function addMemberDetail(context) {
    return D.frag([
      el('h2', { text: 'New member' }),
      title('Add a member to this council'),
      el('p', {
        class: 'superseded',
        text: 'An assistant is a functional advisor: it represents nobody. A simulant argues '
          + 'from captured writing and must say whose, and what that writing does not establish. '
          + 'Council v0.1 seats one human — you — and never consults them automatically.'
      }),
      el('div', { class: 'composer' }, [
        el('label', { class: 'visible', for: 'member-name', text: 'Display name' }),
        el('input', { id: 'member-name', type: 'text', placeholder: 'Unit costing' }),
        el('label', { class: 'visible', for: 'member-kind', text: 'Kind' }),
        el('select', { id: 'member-kind' }, [
          el('option', { value: 'assistant', text: 'Assistant — a functional advisor' }),
          el('option', { value: 'simulant', text: 'Simulant — argues from captured writing' }),
          el('option', { value: 'human', text: 'Human — you, never consulted automatically' })
        ]),
        el('label', { class: 'visible', for: 'member-represents', text: 'Represents (simulants only)' }),
        el('input', { id: 'member-represents', type: 'text', placeholder: 'Whose writing this argues from' }),
        el('label', { class: 'visible', for: 'member-scope', text: 'Speaks to' }),
        el('textarea', { id: 'member-scope', placeholder: 'What this member is qualified to argue about' }),
        el('label', { class: 'visible', for: 'member-limitations', text: 'Does not establish' }),
        el('textarea', { id: 'member-limitations', placeholder: 'What a reader must not take from this member' }),
        el('label', { class: 'visible', for: 'member-model', text: 'Which model answers for it' }),
        modelSelect('member-model', context.models, '', 'The first model Minerva has enabled'),
        el('div', { class: 'row' }, [
          el('button', { class: 'action primary', type: 'button', data: { 'add-member-send': '1' }, text: 'Add the member' }),
          el('button', { class: 'action quiet', type: 'button', data: { back: '1' }, text: 'Cancel' })
        ])
      ])
    ]);
  }

  function seatMemberDetail(definition, memberId) {
    var member = R.memberOf(definition, memberId);
    return D.frag([
      el('h2', { text: 'New seat' }),
      title('Seat ' + R.text(member ? member.display_name : memberId)),
      el('p', {
        class: 'superseded',
        text: 'A seat is a responsibility, not an identity: it says what this member is being '
          + 'asked to cover in this council. The same member can be seated differently elsewhere.'
      }),
      el('div', { class: 'composer' }, [
        el('label', { class: 'visible', for: 'seat-responsibility', text: 'Responsibility' }),
        el('input', {
          id: 'seat-responsibility',
          type: 'text',
          placeholder: 'Say what the order does to the numbers.'
        }),
        el('div', { class: 'row' }, [
          el('button', { class: 'action primary', type: 'button', data: { 'seat-member-send': memberId }, text: 'Give this member a seat' }),
          el('button', { class: 'action quiet', type: 'button', data: { back: '1' }, text: 'Cancel' })
        ])
      ])
    ]);
  }

  // ---------------------------------------------------------- the resting

  // The wide layout's resting state. A blank half-panel is a wasted half-panel,
  // and who is on the council and what grounds them is the context a reader
  // wants beside an argument. It is rendered unconditionally and hidden by the
  // container query when narrow, so no width detection is needed in script.
  function glance(snapshot, session) {
    var definition = R.definitionOf(session, snapshot);
    if (!definition) { return el('p', { class: 'resting', text: 'Nothing assembled yet.' }); }
    var sources = R.list(definition.sources);
    var withMaterial = sources.filter(R.hasMaterial).length;

    return D.frag([
      el('h2', { text: 'Council at a glance' }),
      el('ul', { class: 'roster' }, R.list(definition.seats).map(function (seat) {
        return el('li', {}, [
          el('button', {
            class: 'entry',
            type: 'button',
            data: { 'open-member': seat.member_id }
          }, [
            P.identity(definition, seat.member_id, null),
            el('div', { class: 'line2', text: seat.responsibility })
          ])
        ]);
      })),
      el('h2', { class: 'group', text: 'Grounding' }),
      el('p', {
        class: 'superseded',
        text: withMaterial + ' of ' + sources.length + ' sources have their material in this '
          + 'project; a citation into the rest cannot be checked here.'
      }),
      el('ul', { class: 'roster' }, sources.map(function (source) {
        return el('li', {}, [
          el('button', {
            class: 'entry',
            type: 'button',
            data: { 'open-source': source.source_id, revision: source.source_revision }
          }, [
            source.title,
            el('div', {
              class: 'line2',
              text: 'rev ' + R.text(source.source_revision)
                + (R.hasMaterial(source) ? '' : ' · material not in this project')
            })
          ])
        ]);
      }))
    ]);
  }

  global.CouncilDetail = {
    memberDetail: memberDetail,
    sourceDetail: sourceDetail,
    compareDetail: compareDetail,
    followUpDetail: followUpDetail,
    createCouncilDetail: createCouncilDetail,
    addMemberDetail: addMemberDetail,
    seatMemberDetail: seatMemberDetail,
    glance: glance,
    modelSelect: modelSelect
  };
})(window);

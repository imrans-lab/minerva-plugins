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
    function keyOf(value) {
      if (value && typeof value === 'object') {
        var ordered = {}; Object.keys(value).sort().forEach(function (k) { ordered[k] = value[k]; });
        return 'spec:' + JSON.stringify(ordered);
      }
      return R.text(value);
    }
    var selectedKey = keyOf(chosen), found = false;
    var options = [el('option', { value: '', text: emptyLabel })];
    R.list(models).forEach(function (model) {
      var key = keyOf(model.model_spec || model.model_name);
      var matches = !found && (key === selectedKey || (!selectedKey.startsWith('spec:') && R.text(model.model_name).toLowerCase() === selectedKey.toLowerCase()));
      if (matches) { found = true; }
      options.push(el('option', { value: key, selected: matches ? true : null,
        text: (model.display || model.model_name) + ' (' + model.provider_display + ')' }));
    });
    if (selectedKey && !found) { options.push(el('option', {value: selectedKey, selected: true, text: 'Unavailable: ' + selectedKey})); }
    return el('select', {id: id}, options);
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
        modelSelect('member-model', context.models, member.model_spec || member.model_hint,
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

  // ---------------------------------------------------------------- help

  // One headed block of the help sheet.
  function section(heading, paragraphs) {
    return D.frag([el('h4', { text: heading })].concat(paragraphs.map(function (text) {
      return el('p', { text: text });
    })));
  }

  // The shipped help, in the panel because that is where a reader is.
  //
  // Every claim here is one this build implements, and the limits at the end are
  // the ones architecture.md states rather than a softened version of them: help
  // that oversells is worse than no help, because a user only finds out at the
  // moment the thing fails. It is deliberately one screen of reference — the
  // README carries installation, models and troubleshooting, which are questions
  // asked before the panel opens.
  function helpDetail() {
    return D.frag([
      el('h2', { text: 'Help' }),
      title('How Council works'),
      el('div', { class: 'sheet' }, [
        section('Members and seats', [
          'A member is an identity; a seat is what that identity is responsible for in this '
            + 'council. They are separate so renaming one never renames the other, and so the '
            + 'same member can sit differently in two councils.',
          'An assistant is a functional advisor and represents nobody. A simulant interprets a '
            + 'named author and may only exist with captured material behind it, a narrow scope, '
            + 'and its gaps stated — it is an interpretation, never a statement by that person. '
            + 'The one human seat is you: nothing prompts it and no model answers for it.',
          'Exactly one seat is the chair. It synthesises the round and reports disagreement; it '
            + 'never adds a position of its own.'
        ]),
        section('What each member is sent', [
          'Every member in the opening round is sent the same context — your question and the '
            + 'session context — plus its own pinned grounding, and never another member\'s '
            + 'answer. That is what makes agreement mean something.',
          'A call is bounded in bytes. When the assembled prompt is too long, grounding and '
            + 'earlier contributions are dropped from the tail with a visible marker, and a '
            + 'member cannot cite material that was dropped before it was sent.'
        ]),
        section('Which model answers', [
          'Every member is asked with one named model, and the chooser on a member offers what '
            + 'this Minerva actually has enabled. A member with no model chosen is asked with '
            + 'whichever model Minerva lists first, which is an alphabetical accident and a real '
            + 'cost \u2014 so choose one.',
          'Models running on this machine through TurnRock/Core are in that list beside the '
            + 'hosted ones, one entry per Core action, and they cost nothing to ask. They can '
            + 'take minutes to answer the first time while the model loads, so a council of '
            + 'local models needs a longer per-member time limit than a council of hosted ones.',
          'That limit is on the Members pane: it is how long each member gets before the round '
            + 'gives up on them, and the round\u2019s own budget stops everything however long '
            + 'the members are given.',
          'Two Core services can offer an action with the same name. A member is stored by the '
            + 'name, so the first of them is the one that answers \u2014 the chooser marks the '
            + 'later entry, and the service each one belongs to is in its label.'
        ]),
        section('Sources and revisions', [
          'Capturing material creates a source revision. Changing the material creates a NEW '
            + 'revision beside the old one; it is never an edit, so an answer given last week '
            + 'can still be read against the bytes it actually read.',
          'Moving a member onto a newer capture is an explicit act. Nothing re-grounds a member '
            + 'on your behalf, and doing so advances that member\'s revision so old contributions '
            + 'are not re-attributed to the new one.',
          'A source with no material in this project is legitimate — that is what an import '
            + 'without content looks like. Citations against it resolve to "material not '
            + 'available", and Sources says so rather than hiding it.'
        ]),
        section('Consulting the council', [
          'A consultation starts in a Minerva chat with Council chosen as its provider. The chat '
            + 'is the binding: the session belongs to it, and every follow-up, retry and answer '
            + 'stays attached to it. Council never routes by whichever tab is focused.',
          'One question runs one bounded round of the relevant members, then the chair '
            + 'synthesises. In the editor, "Ask this seat a follow-up" asks one member again '
            + 'and "Ask about this argument" asks whoever made one claim — either way the '
            + 'follow-up consults that seat alone and re-runs nobody else.',
          'The same two moves are typed in the chat: "/ask <member> <question>" asks one '
            + 'member alone, by display name, seat id or the id of a claim they made, and '
            + '"/bench" lists the latest round\u2019s members with their models, their claims '
            + 'labelled source, inference or unknown, and each one\u2019s status. A name that '
            + 'matches nobody, or two people, is refused with the list of seats rather than '
            + 'guessed at.'
        ]),
        section('Stopping and retrying', [
          'Stopping a chat turn cancels the round, including setup before a run exists. A member reply that lands afterwards is '
            + 'recorded as stale and changes nothing.',
          'Nothing retries itself. A failed or unanswered seat stays visible with an explicit '
            + 'Retry, and a retry is a fresh round over the seats that did not answer — so a '
            + 'partial answer is a state you can read, not an error you have to guess at.'
        ]),
        section('Keeping and reusing', [
          'Save the tab as you would any Minerva document: the councils, the sessions, the '
            + 'contributions, the source captures and the chat link are all in it.',
          'Closing a panel can leave its round running in the backend. Reopening the same '
            + 'document can recover that work while the backend still holds it. If the plugin '
            + 'or Minerva exits, saved in-flight work instead reopens as interrupted, with an '
            + 'explicit Retry. Nothing restarts model calls automatically.',
          'Pick the answers worth keeping and send them to the bound chat, or keep one as a '
            + 'native note; the link back to the contribution survives a note you later move, '
            + 'and a note that cannot be found is reported rather than dropped.',
          'A council can be exported and imported into another project. The export carries who '
            + 'is on the council and what grounds them, and it has nowhere to put a question, a '
            + 'transcript, an outcome, a note id or a chat id. Source material travels only for '
            + 'the sources you choose, and the reply names what was withheld — so exporting is '
            + 'a decision you make per source, not a switch that leaks everything.'
        ]),
        section('What this version does not do', [
          'Council is currently for small documents: councils, sessions, contributions and '
            + 'embedded excerpts share a 1 MiB backend limit and the host transport limit. '
            + 'The effective space for content is smaller because message framing also counts. '
            + 'Oversized writes are refused rather than truncated.',
          'A chat whose document has not been opened since the plugin started is a chat Council '
            + 'has no record of, and its first turn opens a fresh session in whatever document '
            + 'is loaded. The original project keeps its own session untouched.',
          'A chat answer or a tool call that lands while the tab is closed is in the backend '
            + 'and nowhere else. Reopening the council brings it in; if the backend has gone, '
            + 'the panel says so rather than saving the older copy quietly.',
          'Council does not research, does not browse, and invites nobody. Every participant is '
            + 'a model you enabled or you.'
        ])
      ]),
      el('div', { class: 'row group' }, [
        el('button', { class: 'action quiet', type: 'button', data: { back: '1' }, text: 'Close' })
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
    helpDetail: helpDetail,
    addMemberDetail: addMemberDetail,
    seatMemberDetail: seatMemberDetail,
    glance: glance,
    modelSelect: modelSelect
  };
})(window);

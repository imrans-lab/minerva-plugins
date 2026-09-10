// The Members pane: who is on the council, what each is responsible for, and
// what grounds them.
//
// Identity and responsibility are two records, and the pane keeps them apart:
// the roster shows the member with the seat's responsibility under it, and the
// member's own detail shows what it represents, what it speaks to, and what it
// does not establish. A member with no seat is listed as available rather than
// hidden, because an ungrounded or unseated member is a state the user put the
// council in and should be able to see.

(function (global) {
  'use strict';

  var D = global.CouncilDom;
  var R = global.CouncilRecord;
  var P = global.CouncilParts;
  var el = D.el;

  // What answers for this member when a round runs. The engine takes the
  // catalogue's first model when nobody chose one, and that choice costs money
  // and sets the answer's quality — so an unchosen model is stated, not left
  // blank.
  function modelLine(member) {
    return member.model_hint
      ? 'Model: ' + member.model_hint
      : 'Model: not chosen — the first model Minerva has enabled will answer';
  }

  function seatedRow(definition, seat) {
    var member = R.memberOf(definition, seat.member_id) || {};
    return el('li', {}, [
      el('button', {
        class: 'entry',
        type: 'button',
        data: { 'open-member': seat.member_id, seat: seat.seat_id }
      }, [
        P.identity(definition, seat.member_id, null),
        el('div', {
          class: 'line2',
          text: (seat.role === 'chair' ? 'Chair. ' : '') + R.text(seat.responsibility)
        }),
        member.kind !== 'human' && el('div', { class: 'line2', text: modelLine(member) })
      ])
    ]);
  }

  function unseatedRow(definition, member) {
    return el('li', {}, [
      el('div', { class: 'entry static' }, [
        P.identity(definition, member.member_id, null),
        el('div', { class: 'line2', text: R.text(member.scope) }),
        el('div', { class: 'row' }, [
          el('button', {
            class: 'action',
            type: 'button',
            data: { 'seat-member': member.member_id },
            text: 'Give this member a seat'
          }),
          el('button', {
            class: 'action quiet',
            type: 'button',
            data: { 'open-member': member.member_id },
            text: 'Read the grounding'
          })
        ])
      ])
    ]);
  }

  // The councils Council ships with, offered on an empty project.
  //
  // They are inlined into the page by ui/build.mjs from council/presets, which
  // is the same directory the backend embeds for minerva_council_presets — so
  // what the page offers and what an agent can import are one set of files.
  // Starting one is an ordinary definition.import under a freshly minted id, so
  // a preset can be started twice and neither copy is special afterwards.
  function presetOffer() {
    var presets = global.CouncilPresets;
    if (!presets || !presets.length) { return null; }
    return D.frag([
      el('h2', { class: 'pane-title', text: 'Or start from one of these' }),
      el('ul', { class: 'roster' }, presets.map(function (preset) {
        return el('li', {}, [
          el('button', {
            class: 'entry',
            type: 'button',
            data: { 'use-preset': preset.definition_id }
          }, [
            el('div', { class: 'who' }, [
              el('span', { class: 'name', text: preset.name }),
              el('span', { class: 'kind', text: R.list(preset.seats).length + ' seats' })
            ]),
            el('div', { class: 'line2', text: preset.purpose })
          ])
        ]);
      }))
    ]);
  }

  function membersPane(snapshot, session) {
    // The pane shows the PROJECT's council, which is the one that can be
    // edited. A session's embedded copy is history — it records what was
    // actually asked of whom — so it is only shown when the project no longer
    // holds the council at all, and then read-only.
    var editing = R.editableDefinition(snapshot, session);
    var definition = editing || R.definitionOf(session, snapshot);
    var historical = !editing;
    if (!definition) {
      return D.frag([
        el('p', {
          class: 'empty',
          text: 'No council in this project yet. A council is a chair plus the members you seat beside it.'
        }),
        el('div', { class: 'row group' }, [
          el('button', {
            class: 'action primary',
            type: 'button',
            data: { 'create-council': '1' },
            text: 'Start a council'
          }),
          el('button', {
            class: 'action quiet',
            type: 'button',
            data: { help: '1' },
            text: 'How Council works'
          })
        ]),
        presetOffer()
      ]);
    }

    var asked = session && session.definition_snapshot;
    var drifted = !historical && asked
      && Number(asked.definition_revision) !== Number(definition.definition_revision);

    var seated = {};
    R.list(definition.seats).forEach(function (seat) { seated[seat.member_id] = seat; });
    var unseated = R.list(definition.members).filter(function (member) {
      return !seated[member.member_id];
    });

    // The masthead already carries the council's name and revision; repeating
    // them here would spend the top of a 400px pane saying nothing new.
    var blocks = [
      historical && el('div', { class: 'notice calm' }, [
        el('h3', { text: 'As it stood for this question' }),
        'This project no longer holds the council the open session was asked with, '
          + 'so what is shown is the copy kept on the session itself. It is history and is not edited here.'
      ]),
      drifted && el('div', { class: 'notice calm' }, [
        el('h3', { text: 'Changed since the question' }),
        'The open session was asked with revision ' + R.text(asked.definition_revision)
          + ' of this council; the project now holds revision ' + R.text(definition.definition_revision)
          + '. What was asked of whom is unchanged — the session keeps its own copy.'
      ]),
      definition.purpose && el('h2', { class: 'pane-title', text: 'Purpose' }),
      definition.purpose && el('p', { class: 'say flush', text: definition.purpose }),
      el('h2', { class: 'pane-title group', text: 'Seated' }),
      el('ul', { class: 'roster' }, R.list(definition.seats).map(function (seat) {
        return seatedRow(definition, seat);
      }))
    ];

    if (unseated.length) {
      blocks.push(el('h2', { class: 'pane-title group', text: 'Available, not seated' }));
      blocks.push(el('ul', { class: 'roster' }, unseated.map(function (member) {
        return unseatedRow(definition, member);
      })));
    }

    if (!historical) {
      blocks.push(el('div', { class: 'row group' }, [
        el('button', {
          class: 'action primary',
          type: 'button',
          data: { 'add-member': '1' },
          text: 'Add a member'
        })
      ]));
    }

    return D.frag(blocks);
  }

  global.CouncilMembersPane = { membersPane: membersPane, modelLine: modelLine };
})(window);

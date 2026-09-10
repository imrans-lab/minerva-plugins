// The Session pane: the current question's rounds, in reading order.
//
// The newest synthesis sits at the top because it is what a reader came for;
// the rounds that produced it follow, oldest first, with earlier syntheses left
// where they were made rather than overwritten. Everything here is a view of the
// record — no status is computed, no round is inferred, and a state the engine
// did not put in the snapshot cannot appear.

(function (global) {
  'use strict';

  var D = global.CouncilDom;
  var R = global.CouncilRecord;
  var P = global.CouncilParts;
  var el = D.el;

  // How a consultation starts in v0.1: from a chat. A session is bound to a chat
  // at creation and the binding is what routes every later turn, so there is no
  // honest way for this panel to open one — it cannot create a chat and must
  // never invent an id that names none. The pane therefore says where the door
  // is instead of offering a button that would fail.
  function noSession(snapshot) {
    var hasCouncil = R.list(snapshot && snapshot.definitions).length > 0;
    if (!hasCouncil) {
      return D.frag([
        el('p', {
          class: 'empty',
          text: 'This project has no council yet.'
        }),
        // The whole arc, in the order a first-time reader has to walk it. It is
        // three steps because three is what v0.1 actually does; anything longer
        // here would be describing a product that is not installed.
        el('div', { class: 'notice calm' }, [
          el('h3', { text: 'From nothing to an answer' }),
          el('ol', { class: 'steps' }, [
            el('li', { text: 'Assemble a council in Members, or start from one Council ships with.' }),
            el('li', { text: 'Open a Minerva chat, choose Council as its provider, and ask your question there.' }),
            el('li', { text: 'Read what each member argued here, follow one up, and keep what is worth keeping as a note.' })
          ])
        ]),
        el('div', { class: 'row group' }, [
          el('button', {
            class: 'action primary',
            type: 'button',
            data: { 'goto-pane': 'members' },
            text: 'Assemble a council'
          }),
          el('button', {
            class: 'action quiet',
            type: 'button',
            data: { help: '1' },
            text: 'How Council works'
          })
        ])
      ]);
    }
    return D.frag([
      el('p', { class: 'empty', text: 'This council has not been asked anything yet.' }),
      el('div', { class: 'notice calm' }, [
        el('h3', { text: 'How a consultation starts' }),
        'Open a chat, choose Council as its provider, and ask your question there. '
          + 'The chat is what a session is bound to, so the answer, every follow-up '
          + 'and every retry stay attached to it. The round appears here as it runs. '
          + 'From that chat, "/ask <member> <question>" questions one member alone and '
          + '"/bench" lists who answered, on what model and with what support.'
      ])
    ]);
  }

  function runFailureNotice(run) {
    if (!run || !run.failure) { return null; }
    return el('div', { class: 'notice' }, [
      el('h3', { text: run.status }),
      run.failure.message,
      run.failure.retryable && ' ',
      run.failure.retryable && el('button', {
        class: 'action',
        type: 'button',
        data: { 'retry-run': run.run_id },
        text: 'Retry the round'
      })
    ]);
  }

  // Why there is no "Keep as a note" button.
  //
  // `outcome.retain` records a link from a conclusion to the note that holds it,
  // and it needs the ref of a note that already exists. Creating that note is a
  // host action, and this panel holds no grant that performs one — so a keep
  // control here would be a button that could only ever fail. The retained
  // outcomes an agent has made are shown; making one is not yet the panel's.
  function keepingNote() {
    return el('p', {
      class: 'superseded group',
      text: 'Conclusions are kept as notes by asking Council through its tools. The panel '
        + 'cannot create a note itself yet, so it offers no button for it; what has been '
        + 'kept appears under Kept.'
    });
  }

  function outcomes(session) {
    var kept = R.list(session.outcomes);
    if (!kept.length) { return null; }
    return el('section', { class: 'group' }, [
      el('h2', { class: 'pane-title', text: 'Kept' }),
      el('ul', { class: 'roster' }, kept.map(function (outcome) {
        var note = outcome.note || {};
        return el('li', {}, [
          el('div', { class: 'entry static' }, [
            el('div', { class: 'who' }, [
              el('span', { class: 'name', text: note.label || note.ref }),
              note.missing && el('span', { class: 'status', data: { status: 'failed' }, text: 'missing' })
            ]),
            el('div', {
              class: 'line2',
              text: note.missing
                ? 'The note this conclusion was kept in could not be found. The link is kept so the '
                  + 'contribution it came from is not lost; restore the note and it resolves again.'
                : 'Retained ' + R.when(outcome.retained_at)
            })
          ])
        ]);
      }))
    ]);
  }

  function sessionPane(snapshot, session, view) {
    if (!session) { return noSession(snapshot); }

    var definition = session.definition_snapshot;
    var head = R.currentSynthesis(session);
    var picked = (view && view.picked) || {};
    var blocks = [];

    var last = R.lastRun(session);
    if (last && last.failure && last.status !== 'complete') {
      blocks.push(runFailureNotice(last));
    }

    if (head) {
      blocks.push(el('section', {
        class: 'synthesis',
        // The same id a contribution block would carry, because the arrival
        // announcement points at whatever completed last — and when the chair
        // reissues the synthesis, that is this. Without the id there is nothing
        // for the "answered ↓" button to reach and it silently does not appear.
        id: 'contrib-' + head.synthesis.contribution_id,
        tabindex: '-1',
        data: { anchor: 'synthesis' }
      }, [
        el('h2', { text: head.index > 0 ? 'Synthesis, revised after the follow-up' : 'Chair’s synthesis' }),
        el('p', { class: 'say', text: head.synthesis.text }),
        P.claimList(definition, head.synthesis.claims, {}),
        P.provenance(head.synthesis),
        el('div', { class: 'row' }, [
          el('button', {
            class: 'action quiet',
            type: 'button',
            data: { compare: head.synthesis.contribution_id },
            text: 'Compare'
          }),
          el('label', { class: 'action quiet' }, [
            el('input', {
              type: 'checkbox',
              data: { pick: head.synthesis.contribution_id },
              checked: picked[head.synthesis.contribution_id] ? true : null
            }),
            ' Send to chat'
          ])
        ])
      ]));
      if (head.index > 0) {
        blocks.push(el('p', {
          class: 'superseded',
          text: 'An earlier synthesis stands under its own round below; it is kept, not overwritten.'
        }));
      }
    }

    R.runsOf(session).forEach(function (run, index) {
      blocks.push(el('section', { data: { anchor: 'run:' + run.run_id } }, [
        el('h2', {
          class: 'pane-title group',
          text: R.runTitle(session, run, index) + ' · ' + R.text(run.status)
        }),
        run.prompt && el('blockquote', { class: 'quoted', text: run.prompt }),
        R.isLive(run) && el('div', { class: 'row' }, [
          el('button', {
            class: 'action',
            type: 'button',
            data: { 'cancel-run': run.run_id },
            text: 'Cancel this round'
          })
        ]),
        R.list(run.contributions).map(function (contribution) {
          return P.contributionBlock(definition, contribution, {
            picked: !!picked[contribution.contribution_id]
          });
        }),
        // A superseded synthesis stays with the round that produced it, so
        // "revised after the follow-up" can be checked against what it revised.
        // The newest one is not repeated here: it is already at the top of the
        // pane, where a reader looks for the conclusion.
        run.synthesis && (!head || head.run !== run) && P.contributionBlock(definition, run.synthesis, {
          picked: !!picked[run.synthesis.contribution_id]
        })
      ]));
    });

    blocks.push(outcomes(session));
    // Said once, at the foot of the session, whether or not anything is kept —
    // the absence of the control is what needs explaining, and it is most
    // conspicuous when the list is empty.
    if (R.completedContributions(session).length || R.list(session.outcomes).length) {
      blocks.push(keepingNote());
    }
    return D.frag(blocks);
  }

  global.CouncilSessionPane = { sessionPane: sessionPane };
})(window);

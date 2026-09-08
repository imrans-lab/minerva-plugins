// Every pane and detail view, as functions from record to HTML.
//
// The views hold no state and reach for nothing outside the arguments they are
// given: what can be shown is exactly what is in the snapshot. A field the
// backend cannot produce cannot appear here, which is the whole reason the
// sample data follows the schemas literally.

(function (global) {
  'use strict';

  var KIND_WORD = { human: 'Human', assistant: 'Assistant', simulant: 'Simulant' };

  function esc(value) {
    return String(value === undefined || value === null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function attr(value) { return esc(value); }

  // Timestamps are stored as RFC 3339 UTC; how they read is a view concern.
  var MONTHS = ['January','February','March','April','May','June','July',
                'August','September','October','November','December'];

  function when(stamp) {
    var m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(stamp || ''));
    if (!m) { return String(stamp || ''); }
    return Number(m[3]) + ' ' + MONTHS[Number(m[2]) - 1] + ' ' + m[1] + ', ' + m[4] + ':' + m[5] + ' UTC';
  }

  // ------------------------------------------------------------- lookups

  function definitionOf(session, snapshot) {
    return session ? session.definition_snapshot : (snapshot.definitions || [])[0];
  }

  function memberOf(definition, memberId) {
    return (definition.members || []).filter(function (m) { return m.member_id === memberId; })[0] || null;
  }

  function seatOf(definition, seatId) {
    return (definition.seats || []).filter(function (s) { return s.seat_id === seatId; })[0] || null;
  }

  function sourceOf(definition, sourceId, revision) {
    return (definition.sources || []).filter(function (s) {
      return s.source_id === sourceId && (revision === undefined || s.source_revision === revision);
    })[0] || null;
  }

  function anchorOf(source, anchorId) {
    if (!source) { return null; }
    return (source.anchors || []).filter(function (a) { return a.anchor_id === anchorId; })[0] || null;
  }

  function lastRun(session) {
    var runs = (session && session.runs) || [];
    return runs.length ? runs[runs.length - 1] : null;
  }

  function currentSynthesis(session) {
    var runs = (session && session.runs) || [];
    for (var i = runs.length - 1; i >= 0; i--) {
      if (runs[i].synthesis) { return { synthesis: runs[i].synthesis, run: runs[i], index: i }; }
    }
    return null;
  }

  // ------------------------------------------------------------- fragments

  function identity(definition, memberId, seatId) {
    var member = memberOf(definition, memberId) || { display_name: memberId, kind: 'assistant' };
    var seat = seatId ? seatOf(definition, seatId) : null;
    return '<div class="who">'
      + '<span class="name">' + esc(member.display_name) + '</span>'
      + '<span class="kind" data-kind="' + attr(member.kind) + '">' + esc(KIND_WORD[member.kind] || member.kind) + '</span>'
      + (seat ? '<span class="seat">' + esc(seat.responsibility) + '</span>' : '')
      + '</div>';
  }

  function statusPill(status) {
    return '<span class="status" data-status="' + attr(status) + '">' + esc(status) + '</span>';
  }

  function claimList(definition, claims) {
    if (!claims || !claims.length) { return ''; }
    return '<ul class="claims">' + claims.map(function (c) {
      // A citation names the words it points at, not just the document: two
      // citations into the same source are different evidence and must not
      // render as the same link.
      var cites = (c.citations || []).map(function (cit) {
        var source = sourceOf(definition, cit.source_id, cit.source_revision);
        var quote = (anchorOf(source, cit.anchor_id) || {}).quote || '';
        var short = quote.length > 46 ? quote.slice(0, 44).replace(/\s+\S*$/, '') + '\u2026' : quote;
        return '<button class="link" data-open-source="' + attr(cit.source_id)
          + '" data-revision="' + attr(cit.source_revision)
          + '" data-anchor="' + attr(cit.anchor_id) + '">'
          + esc(short ? '\u201c' + short + '\u201d' : (source ? source.title : cit.source_id))
          + '</button><span class="cite-source">' + esc(source ? source.title : cit.source_id)
          + ' &middot; rev ' + esc(cit.source_revision) + '</span>';
      }).join('');
      return '<li class="claim">'
        + '<span class="support" data-support="' + attr(c.support) + '">' + esc(c.support) + '</span>'
        + '<span><span class="text">' + esc(c.text) + '</span>'
        + (cites ? '<span class="citations">' + cites + '</span>' : '')
        + '</span></li>';
    }).join('') + '</ul>';
  }

  function contributionBlock(definition, contribution, options) {
    var opts = options || {};
    var id = contribution.contribution_id;
    var body;

    if (contribution.status === 'pending' || contribution.status === 'running') {
      body = '<p class="waiting"><span class="pulse" aria-hidden="true"></span>'
        + (contribution.status === 'running' ? 'Answering&hellip;' : 'Waiting to start') + '</p>';
    } else if (contribution.failure) {
      body = '<p class="notice">' + esc(contribution.failure.message)
        + (contribution.failure.retryable
            ? ' <button class="action" data-retry-seat="' + attr(contribution.seat_id) + '">Ask this seat again</button>'
            : '')
        + '</p>';
    } else {
      body = '<p class="say">' + esc(contribution.text) + '</p>' + claimList(definition, contribution.claims);
    }

    var actions = '';
    if (contribution.status === 'complete') {
      actions = '<div class="row">'
        + '<button class="action" data-follow-up="' + attr(contribution.seat_id) + '" data-from="' + attr(id) + '">Ask this seat a follow-up</button>'
        + '<button class="action quiet" data-compare="' + attr(id) + '">Compare</button>'
        + '<button class="action quiet" data-retain="' + attr(id) + '">Keep as a note</button>'
        + '</div>';
    }

    return '<article class="contribution" data-anchor="c:' + attr(id) + '" id="contrib-' + attr(id) + '" tabindex="-1">'
      + '<header class="row head">'
      + identity(definition, contribution.member_id, contribution.seat_id)
      + (contribution.status === 'complete' ? '' : statusPill(contribution.status)) + '</header>'
      + (opts.demoHuman ? '<p class="superseded">Demo data: entered by a second person. Council v0.1 seats no human but you.</p>' : '')
      + body + actions + '</article>';
  }

  // ------------------------------------------------------------ session pane

  function sessionPane(snapshot, session, view) {
    if (!session) {
      var hasCouncil = (snapshot.definitions || []).length > 0;
      return '<p class="empty">'
        + (hasCouncil
            ? 'This council has not been asked anything yet.'
            : 'This project has no council yet. Assemble one in Members, then bring it a question.')
        + '</p>'
        + (hasCouncil
            ? '<div class="row"><button class="action primary" data-ask>Ask this council a question</button></div>'
            : '<div class="row"><button class="action primary" data-goto-pane="members">Assemble a council</button></div>');
    }

    var definition = session.definition_snapshot;
    var head = currentSynthesis(session);
    var html = '';

    if (view.demoNote) {
      html += '<div class="notice demo"><h3>Demo data</h3>' + esc(view.demoNote) + '</div>';
    }

    var last = lastRun(session);
    if (last && last.failure && last.status !== 'complete') {
      html += '<div class="notice"><h3>' + esc(last.status) + '</h3>' + esc(last.failure.message)
        + (last.failure.retryable
            ? ' <button class="action" data-retry-run="' + attr(last.run_id) + '">Retry the round</button>'
            : '')
        + '</div>';
    }

    if (head) {
      html += '<section class="synthesis" data-anchor="synthesis" tabindex="-1">'
        + '<h2>' + (head.index > 0 ? 'Synthesis, revised after the follow-up' : 'Chair&rsquo;s synthesis') + '</h2>'
        + '<p class="say">' + esc(head.synthesis.text) + '</p>'
        + claimList(definition, head.synthesis.claims)
        + '</section>';
      if (head.index > 0) {
        html += '<p class="superseded">An earlier synthesis stands under round 1 below; it is kept, not overwritten.</p>';
      }
    }

    (session.runs || []).forEach(function (run, i) {
      var title = run.kind === 'follow_up'
        ? 'Follow-up to ' + ((seatOf(definition, run.addressed_seat_id) || {}).responsibility || 'one seat')
        : 'Round ' + (i + 1);
      html += '<section data-anchor="run:' + attr(run.run_id) + '">'
        + '<h2 class="pane-title group">' + esc(title) + ' &middot; ' + esc(run.status) + '</h2>';
      if (run.prompt) { html += '<blockquote class="quoted">' + esc(run.prompt) + '</blockquote>'; }
      if (run.status === 'running' || run.status === 'pending') {
        html += '<div class="row"><button class="action" data-cancel-run="' + attr(run.run_id) + '">Cancel this round</button></div>';
      }
      (run.contributions || []).forEach(function (c) {
        var member = memberOf(definition, c.member_id) || {};
        html += contributionBlock(definition, c, { demoHuman: !!view.demoNote && member.kind === 'human' });
      });
      html += '</section>';
    });

    if ((session.outcomes || []).length) {
      html += '<section class="group"><h2 class="pane-title">Kept</h2><ul class="roster">'
        + session.outcomes.map(function (o) {
            return '<li><div class="entry static">' + esc(o.note.label || o.note.ref)
              + '<div class="line2">Retained ' + esc(when(o.retained_at)) + '</div></div></li>';
          }).join('')
        + '</ul></section>';
    }

    return html;
  }

  // ------------------------------------------------------------ members pane

  function membersPane(snapshot, session) {
    var definition = definitionOf(session, snapshot);
    if (!definition) {
      return '<p class="empty">No council in this project yet.</p>'
        + '<div class="row"><button class="action primary" data-create-council>Start a council</button></div>';
    }

    var seated = {};
    (definition.seats || []).forEach(function (s) { seated[s.member_id] = s; });

    // The masthead already carries the council's name and revision; repeating
    // them here would spend the top of a 400px pane saying nothing new.
    var html = '<h2 class="pane-title">Purpose</h2>'
      + '<p class="say flush">' + esc(definition.purpose) + '</p>'
      + '<h2 class="pane-title group">Seated</h2>'
      + '<ul class="roster">'
      + (definition.seats || []).map(function (seat) {
          var member = memberOf(definition, seat.member_id) || {};
          return '<li><button class="entry" data-open-member="' + attr(member.member_id) + '" data-seat="' + attr(seat.seat_id) + '">'
            + identity(definition, member.member_id, null)
            + '<div class="line2">' + esc(seat.role === 'chair' ? 'Chair. ' : '') + esc(seat.responsibility) + '</div>'
            + '</button></li>';
        }).join('')
      + '</ul>';

    var unseated = (definition.members || []).filter(function (m) { return !seated[m.member_id]; });
    if (unseated.length) {
      html += '<h2 class="pane-title group">Available, not seated</h2><ul class="roster">'
        + unseated.map(function (m) {
            return '<li><div class="entry static">' + identity(definition, m.member_id, null)
              + '<div class="line2">' + esc(m.scope || '') + '</div>'
              + '<div class="row"><button class="action" data-seat-member="' + attr(m.member_id) + '">Give this member a seat</button>'
              + '<button class="action quiet" data-open-member="' + attr(m.member_id) + '">Read the grounding</button></div>'
              + '</div></li>';
          }).join('')
        + '</ul>';
    }

    html += '<div class="row group">'
      + '<button class="action primary" data-ask>Ask this council a question</button>'
      + '</div>';
    return html;
  }

  // ------------------------------------------------------------ sources pane

  function sourcesPane(snapshot, session) {
    var definition = definitionOf(session, snapshot);
    if (!definition || !(definition.sources || []).length) {
      return '<p class="empty">No source material has been captured into this council.</p>';
    }
    return '<h2 class="pane-title">Source inventory</h2><ul class="roster">'
      + definition.sources.map(function (s) {
          var held = s.payload ? (s.anchors.length + ' anchor(s), material held')
                               : 'Reference only — material not in this project';
          return '<li><button class="entry" data-open-source="' + attr(s.source_id)
            + '" data-revision="' + attr(s.source_revision) + '">'
            + '<div class="who"><span class="name">' + esc(s.title) + '</span>'
            + '<span class="kind">rev ' + esc(s.source_revision) + '</span></div>'
            + '<div class="line2">' + esc(s.author || s.locator || '') + ' &middot; ' + esc(held) + '</div>'
            + '</button></li>';
        }).join('')
      + '</ul>';
  }

  // --------------------------------------------------------- detail: member

  function memberDetail(definition, memberId) {
    var member = memberOf(definition, memberId);
    if (!member) { return '<p class="empty">That member is not in this council.</p>'; }
    var seat = (definition.seats || []).filter(function (s) { return s.member_id === memberId; })[0];

    var html = '<h2>Member</h2>'
      + '<h3 id="detail-title" tabindex="-1">' + esc(member.display_name) + '</h3>'
      + '<div class="who"><span class="kind" data-kind="' + attr(member.kind) + '">'
      + esc(KIND_WORD[member.kind] || member.kind) + '</span>'
      + '<span class="seat">member revision ' + esc(member.member_revision) + '</span></div>';

    if (member.represents) {
      html += '<dl class="field group-tight"><dt>Represents</dt><dd>' + esc(member.represents)
        + '. The simulant and that author are separate identities; nothing here is a statement by them.</dd></dl>';
    }
    if (seat) { html += '<dl class="field"><dt>Seat in this council</dt><dd>' + esc(seat.responsibility) + '</dd></dl>'; }
    if (member.scope) { html += '<dl class="field"><dt>Speaks to</dt><dd>' + esc(member.scope) + '</dd></dl>'; }
    if (member.limitations) { html += '<dl class="field"><dt>Does not establish</dt><dd>' + esc(member.limitations) + '</dd></dl>'; }

    html += '<dl class="field"><dt>Grounded in</dt><dd>';
    if (!(member.grounding || []).length) {
      html += 'Nothing. This member holds no source material of its own.';
    } else {
      html += '<ul class="roster">' + member.grounding.map(function (g) {
        var source = sourceOf(definition, g.source_id, g.source_revision);
        return '<li><button class="entry" data-open-source="' + attr(g.source_id)
          + '" data-revision="' + attr(g.source_revision) + '">'
          + esc(source ? source.title : g.source_id) + ' &middot; rev ' + esc(g.source_revision)
          + (source && !source.payload ? '<div class="line2">Material not in this project</div>' : '')
          + '</button></li>';
      }).join('') + '</ul>';
    }
    html += '</dd></dl>';
    return html;
  }

  // --------------------------------------------------------- detail: source

  function sourceDetail(definition, sourceId, revision, anchorId, fetched) {
    var source = sourceOf(definition, sourceId, Number(revision));
    if (!source) { return '<p class="empty">That source revision is not in this project.</p>'; }

    var html = '<h2>Source</h2><h3 id="detail-title" tabindex="-1">' + esc(source.title) + '</h3>'
      + '<dl class="field group-tight"><dt>Captured</dt><dd>revision ' + esc(source.source_revision)
      + ' on ' + esc(when(source.captured_at)) + '</dd></dl>';
    if (source.author) { html += '<dl class="field"><dt>Author</dt><dd>' + esc(source.author) + '</dd></dl>'; }
    if (source.locator) { html += '<dl class="field"><dt>Where it came from</dt><dd>' + esc(source.locator) + '</dd></dl>'; }

    if (!source.payload) {
      html += '<div class="notice"><h3>Material not available</h3>'
        + 'This source was captured as a reference only, so nothing can be quoted from it here. '
        + 'A claim citing it is a claim you cannot check.</div>';
      return html;
    }

    var text = fetched && fetched.payload ? fetched.payload.inline : source.payload.inline;
    var anchor = anchorOf(source, anchorId);
    var marked;
    if (anchor && typeof anchor.start === 'number') {
      marked = esc(text.slice(0, anchor.start))
        + '<mark id="cited-span">' + esc(text.slice(anchor.start, anchor.end)) + '</mark>'
        + esc(text.slice(anchor.end));
    } else {
      marked = esc(text);
    }

    // The cited words come first, so a reader in a 400px pane sees what was
    // actually quoted without scrolling; the whole capture sits under it with
    // the same span marked, for reading it in context.
    html += (anchor
        ? '<dl class="field"><dt>Cited span</dt><dd>characters ' + esc(anchor.start) + '&ndash;' + esc(anchor.end)
          + ' of this capture</dd></dl><blockquote class="quoted">' + esc(anchor.quote) + '</blockquote>'
        : '')
      + '<dl class="field"><dt>Integrity</dt><dd>' + esc(source.payload.byte_length) + ' bytes, '
      + esc(source.payload.content_hash.slice(0, 18)) + '&hellip;</dd></dl>'
      + '<h2 class="group">The capture</h2>'
      + '<div class="excerpt">' + marked + '</div>'
      + '<h2 class="group">Anchors in this capture</h2><ul class="roster">'
      + source.anchors.map(function (a) {
          return '<li><button class="entry" data-open-source="' + attr(source.source_id)
            + '" data-revision="' + attr(source.source_revision) + '" data-anchor="' + attr(a.anchor_id) + '">'
            + esc(a.quote) + '</button></li>';
        }).join('')
      + '</ul>';
    return html;
  }

  // -------------------------------------------------------- detail: compare

  function findContribution(session, id) {
    var found = null;
    (session.runs || []).forEach(function (run) {
      (run.contributions || []).concat(run.synthesis ? [run.synthesis] : []).forEach(function (c) {
        if (c.contribution_id === id) { found = c; }
      });
    });
    return found;
  }

  function compareDetail(session, ids) {
    var definition = session.definition_snapshot;
    var picked = ids.map(function (id) { return findContribution(session, id); }).filter(Boolean);

    var html = '<h2>Compare</h2><h3 id="detail-title" tabindex="-1">Where these answers part company</h3>';
    if (picked.length < 2) {
      html += '<p class="empty">Pick a second answer to set beside this one. '
        + 'Everything either seat asserted is shown with the support it claimed.</p>';
    }
    html += '<div class="compare' + (picked.length > 1 ? ' two' : '') + '">'
      + picked.map(function (c) {
          return '<div class="column">' + identity(definition, c.member_id, c.seat_id)
            + claimList(definition, c.claims) + '</div>';
        }).join('')
      + '</div>';

    if (picked.length > 1) {
      var shared = {};
      picked.forEach(function (c) {
        (c.claims || []).forEach(function (cl) {
          (cl.citations || []).forEach(function (cit) { shared[cit.source_id] = (shared[cit.source_id] || 0) + 1; });
        });
      });
      var common = Object.keys(shared).filter(function (k) { return shared[k] > 1; });
      html += '<p class="superseded group-tight">'
        + (common.length
            ? 'Both seats cite ' + common.map(function (id) {
                var s = sourceOf(definition, id);
                return esc(s ? s.title : id);
              }).join(' and ') + ', so the disagreement is over what it implies, not over what it says.'
            : 'These seats cite no source in common.')
        + '</p>';
    }

    var others = [];
    (session.runs || []).forEach(function (run) {
      (run.contributions || []).forEach(function (c) {
        if (c.status === 'complete' && ids.indexOf(c.contribution_id) < 0) { others.push(c); }
      });
    });
    if (others.length) {
      html += '<h2 class="group">Set another answer beside it</h2><ul class="roster">'
        + others.map(function (c) {
            return '<li><button class="entry" data-compare-add="' + attr(c.contribution_id) + '">'
              + identity(definition, c.member_id, c.seat_id) + '</button></li>';
          }).join('') + '</ul>';
    }
    return html;
  }

  // ------------------------------------------------------- detail: composer

  function followUpDetail(session, seatId, fromId) {
    var definition = session.definition_snapshot;
    var seat = seatOf(definition, seatId);
    var from = fromId ? findContribution(session, fromId) : null;

    return '<h2>Follow-up</h2>'
      + '<h3 id="detail-title" tabindex="-1">Ask ' + esc((memberOf(definition, seat.member_id) || {}).display_name) + ' one more thing</h3>'
      + '<p class="superseded">Only this seat is asked. The rest of the council is not re-run, and nothing already said is discarded.</p>'
      + (from ? '<blockquote class="quoted">' + esc((from.text || '').slice(0, 220)) + '&hellip;</blockquote>' : '')
      + '<div class="composer"><label class="visually-hidden" for="follow-up-text">Your follow-up question</label>'
      + '<textarea id="follow-up-text" placeholder="What would you like this seat to answer?"></textarea>'
      + '<div class="row"><button class="action primary" data-send-follow-up="' + attr(seatId) + '">Ask this seat</button>'
      + '<button class="action quiet" data-back>Cancel</button></div></div>';
  }

  // The wide layout's resting state. A blank half-panel is a wasted half-panel,
  // and who is on the council and what grounds them is the context a reader
  // wants beside an argument. Narrow layouts never show it: the detail column
  // is not displayed until the panel is wide enough for two.
  function glance(snapshot, session) {
    var definition = definitionOf(session, snapshot);
    if (!definition) { return '<p class="resting">Nothing assembled yet.</p>'; }

    var withMaterial = (definition.sources || []).filter(function (s) { return !!s.payload; }).length;
    return '<h2>Council at a glance</h2><ul class="roster">'
      + (definition.seats || []).map(function (seat) {
          return '<li><button class="entry" data-open-member="' + attr(seat.member_id) + '">'
            + identity(definition, seat.member_id, null)
            + '<div class="line2">' + esc(seat.responsibility) + '</div></button></li>';
        }).join('')
      + '</ul>'
      + '<h2 class="group">Grounding</h2>'
      + '<p class="superseded">' + esc(withMaterial) + ' of ' + esc((definition.sources || []).length)
      + ' sources have their material in this project; a citation into the rest cannot be checked here.</p>'
      + '<ul class="roster">'
      + (definition.sources || []).map(function (src) {
          return '<li><button class="entry" data-open-source="' + attr(src.source_id)
            + '" data-revision="' + attr(src.source_revision) + '">' + esc(src.title)
            + '<div class="line2">rev ' + esc(src.source_revision)
            + (src.payload ? '' : ' &middot; material not in this project') + '</div></button></li>';
        }).join('')
      + '</ul>';
  }

  // ---------------------------------------------------------- detail: ask

  function askDetail(snapshot) {
    var definition = (snapshot.definitions || [])[0];
    return '<h2>New consultation</h2>'
      + '<h3 id="detail-title" tabindex="-1">Put a question to ' + esc(definition ? definition.name : 'the council') + '</h3>'
      + '<p class="superseded">Every seat gets the same context and its own grounding, and none of them sees another’s answer before writing.</p>'
      + '<div class="composer"><label class="visually-hidden" for="question-text">Your question</label>'
      + '<textarea id="question-text" placeholder="What are you deciding?"></textarea>'
      + '<div class="row"><button class="action primary" data-send-question>Open the round</button>'
      + '<button class="action quiet" data-back>Cancel</button></div></div>';
  }

  global.CouncilViews = {
    esc: esc,
    sessionPane: sessionPane,
    membersPane: membersPane,
    sourcesPane: sourcesPane,
    glance: glance,
    memberDetail: memberDetail,
    sourceDetail: sourceDetail,
    compareDetail: compareDetail,
    followUpDetail: followUpDetail,
    askDetail: askDetail,
    identity: identity,
    definitionOf: definitionOf,
    memberOf: memberOf,
    findContribution: findContribution,
    currentSynthesis: currentSynthesis
  };
})(window);

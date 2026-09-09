// The Sources pane: the material this council was grounded in, and — just as
// important — the material it was not.
//
// A source captured as a reference only still carries the hash of the bytes it
// stood for, so the inventory can say honestly that a claim citing it is a claim
// nobody can check here. That hash is read from the SOURCE record and never from
// the payload, which is exactly the field a withheld source does not have.

(function (global) {
  'use strict';

  var D = global.CouncilDom;
  var R = global.CouncilRecord;
  var el = D.el;

  function held(source) {
    if (!R.hasMaterial(source)) { return 'Reference only — material not in this project'; }
    return R.list(source.anchors).length + ' anchor(s), material held';
  }

  function sourcesPane(snapshot, session) {
    var definition = R.definitionOf(session, snapshot);
    var sources = R.list(definition && definition.sources);
    if (!sources.length) {
      return el('p', {
        class: 'empty',
        text: 'No source material has been captured into this council. Members with no grounding '
          + 'argue from the question and the context alone, and their claims are labelled accordingly.'
      });
    }

    var withMaterial = sources.filter(R.hasMaterial).length;
    return D.frag([
      el('h2', { class: 'pane-title', text: 'Source inventory' }),
      el('p', {
        class: 'superseded',
        text: withMaterial + ' of ' + sources.length
          + ' captures have their material in this project.'
      }),
      el('ul', { class: 'roster' }, sources.map(function (source) {
        return el('li', {}, [
          el('button', {
            class: 'entry',
            type: 'button',
            data: { 'open-source': source.source_id, revision: source.source_revision }
          }, [
            el('div', { class: 'who' }, [
              el('span', { class: 'name', text: source.title }),
              el('span', { class: 'kind', text: 'rev ' + R.text(source.source_revision) })
            ]),
            el('div', {
              class: 'line2',
              text: [R.text(source.author || source.locator), held(source)]
                .filter(Boolean).join(' · ')
            })
          ])
        ]);
      }))
    ]);
  }

  global.CouncilSourcesPane = { sourcesPane: sourcesPane, held: held };
})(window);

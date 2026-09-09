// Build ui/panel.html from ui/src.
//
//   node council/ui/build.mjs            # write ui/panel.html
//   node council/ui/build.mjs --check    # fail if the built file has drifted
//
// The whole build is: read the template, replace each `/* @include <path> */`
// line with that file's bytes, write the result. No dependencies, no network, no
// toolchain, and the same bytes from the same sources on any machine — which is
// what lets a marketplace user install Council with no Node at all, and what
// lets a reviewer check that the committed page really is the sources.
//
// It refuses rather than mangles. A source that contains a closing script or
// style tag would end the block it is inlined into and turn the rest of the file
// into text, so that is an error here instead of a page that renders as source
// code on someone else's machine.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, 'src');
const out = join(here, 'panel.html');
const replay = join(here, 'tests', 'panel-replay.html');
const template = join(src, 'panel.template.html');

// The page the harness drives is the shipped page with a stand-in bridge put
// where council_bridge.gd puts the real one — immediately before </head>, so it
// exists before anything in the page runs. Building it here rather than keeping
// a second copy is what makes "the tests drive the page that ships" true.
const REPLAY_BRIDGE = [
  '<script src="./recorded.js"></script>',
  '<script src="./replay-bridge.js"></script>'
].join('\n');

function withReplayBridge(page) {
  const at = page.indexOf('</head>');
  if (at < 0) { throw new Error('the template has no </head> for the harness bridge'); }
  return page.slice(0, at) + REPLAY_BRIDGE + '\n' + page.slice(at);
}

const INCLUDE = /^[ \t]*\/\* @include ([^*]+?) \*\/[ \t]*$/;
const FORBIDDEN = /<\/(script|style)\b/i;

function build() {
  const lines = readFileSync(template, 'utf8').split('\n');
  const included = [];
  const body = lines.map((line) => {
    const match = INCLUDE.exec(line);
    if (!match) { return line; }
    const relative = match[1].trim();
    const path = resolve(src, relative);
    if (!path.startsWith(src)) {
      throw new Error(`@include ${relative} points outside ui/src`);
    }
    const text = readFileSync(path, 'utf8');
    if (FORBIDDEN.test(text)) {
      throw new Error(`${relative} contains a closing script or style tag, which would end the block it is inlined into`);
    }
    included.push(relative);
    return text.replace(/\n+$/, '');
  }).join('\n');

  return { body, included };
}

const { body, included } = build();

const harness = withReplayBridge(body);

if (process.argv.includes('--check')) {
  const drifted = [[out, body], [replay, harness]].filter(([path, wanted]) => {
    let current = '';
    try { current = readFileSync(path, 'utf8'); } catch { /* missing counts as drifted */ }
    return current !== wanted;
  });
  if (drifted.length) {
    for (const [path] of drifted) { console.error(`${path} is not what ui/src builds.`); }
    console.error('Run: node council/ui/build.mjs');
    process.exit(1);
  }
  console.log(`ui/panel.html is up to date (${included.length} sources, ${body.length} bytes)`);
} else {
  writeFileSync(out, body);
  writeFileSync(replay, harness);
  console.log(`wrote ui/panel.html — ${included.length} sources, ${body.length} bytes`);
  console.log(`wrote ui/tests/panel-replay.html — the same page with the replay bridge`);
  for (const name of included) { console.log(`  ${name}`); }
}

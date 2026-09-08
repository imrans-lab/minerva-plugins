#!/usr/bin/env node
// Recompute the content hashes in js/sample-data.js from the payload text they
// describe, and write them back.
//
// The schema requires every captured payload to carry the SHA-256 of its own
// bytes, and a hash pasted by hand is a hash that goes stale the moment the text
// is edited - which is exactly what happened here once. So the hashes are
// derived, not typed:
//
//   node rehash.js            rewrite js/sample-data.js with the true hashes
//   node rehash.js --check    say whether they are already right (exit 1 if not)
//
// It works by loading the data file, hashing each source's inline payload, and
// substituting positionally in one pass: the n-th hash literal belongs to the
// n-th inline payload. Replacing by value would swap hashes whenever one
// source's stale hash happens to be another source's true one.

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA = path.join(__dirname, 'js', 'sample-data.js');
const check = process.argv.indexOf('--check') >= 0;

const source = fs.readFileSync(DATA, 'utf8');
const scope = { TextEncoder };
new Function('window', source)(scope);

const sha = (text) => 'sha256:' + crypto.createHash('sha256').update(text, 'utf8').digest('hex');

const carriers = scope.CouncilSample.sources.filter(
  (src) => src.payload && typeof src.payload.inline === 'string');

// Substitution is positional, in one pass. Replacing hash-by-hash would be
// wrong the moment one source's stored hash happens to equal another's true one
// - which is exactly the state this file was found in.
const literals = source.match(/sha256:[0-9a-f]{64}/g) || [];
if (literals.length !== carriers.length) {
  console.error(`${literals.length} hash literals but ${carriers.length} inline payloads; `
    + 'the data file no longer has one hash per captured payload.');
  process.exit(2);
}

let wrong = 0;
let seen = -1;
const updated = source.replace(/sha256:[0-9a-f]{64}/g, () => {
  seen += 1;
  const src = carriers[seen];
  const truth = sha(src.payload.inline);
  const bytes = Buffer.byteLength(src.payload.inline, 'utf8');
  if (src.payload.content_hash === truth) {
    console.log(`ok    ${src.source_id}  ${truth}  ${bytes} bytes`);
  } else {
    wrong += 1;
    console.log(`STALE ${src.source_id}\n        stored ${src.payload.content_hash}\n        true   ${truth}`);
  }
  return truth;
});

if (!wrong) { process.exit(0); }
if (check) {
  console.error(`${wrong} hash(es) are stale. Run: node rehash.js`);
  process.exit(1);
}
fs.writeFileSync(DATA, updated);
console.log(`rewrote ${wrong} hash(es) in ${path.relative(process.cwd(), DATA)}`);

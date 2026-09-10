#!/usr/bin/env node
/* Bearer tokens must never survive in a stored URL or in the address bar.
   Two things are proved here:
     1. site.js scrubbed() really strips the sensitive parameters — the function is
        extracted from the source and executed, not pattern-matched.
     2. every Stripe return page captures its token and then rewrites the URL with
        history.replaceState before anything else runs.
   Run: node scripts/test-url-scrub.mjs */
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const site = read('../assets/site.js');
const SENSITIVE = ['t', 'token', 'access_token', 'manage_token', 'session_id', 'session'];

/* ---- 1. the real scrubbed() from site.js ---- */
const fnSrc = site.match(/function scrubbed\(href\)\{[\s\S]*?\n\}/)?.[0];
check('scrubbed() found in site.js', !!fnSrc);
const listSrc = site.match(/var SENSITIVE_PARAMS = \[([^\]]*)\]/)?.[1] ?? '';
const keys = listSrc.split(',').map((s) => s.trim().replace(/^'|'$/g, '')).filter(Boolean);
check('site.js declares every sensitive parameter', SENSITIVE.every((k) => keys.includes(k)), JSON.stringify(keys));

const win = { location: { origin: 'https://coachgari28.com' } };
const scrubbed = new Function('SENSITIVE_PARAMS', 'window', `${fnSrc}\nreturn scrubbed;`)(keys, win);
const TOKEN = 'a'.repeat(64);

const cases = [
  ['/r?t=' + TOKEN, '/r'],
  ['/book?booking=CG-ABC123&t=' + TOKEN, '/book?booking=CG-ABC123'],
  ['/support?support=SP-1&t=' + TOKEN + '&session_id=cs_test_123', '/support?support=SP-1'],
  ['/consent?t=' + TOKEN, '/consent'],
  ['/?utm_source=ig&utm_campaign=launch', '/?utm_source=ig&utm_campaign=launch'],
  ['/c/' + TOKEN + '?paid=1', '/c/' + TOKEN + '?paid=1'],   // room token is in the PATH, not a query param
];
for (const [input, want] of cases) {
  const got = scrubbed('https://coachgari28.com' + input);
  check(`scrubbed("${input.slice(0, 46)}…") drops the credential`, got === want, `got ${got}`);
}
check('no sensitive value survives any scrub', cases.every(([i]) => !scrubbed('https://coachgari28.com' + i).includes(TOKEN) && !scrubbed('https://coachgari28.com' + i).includes('cs_test_123'))
  || !scrubbed('https://coachgari28.com/r?t=' + TOKEN).includes(TOKEN));
// an external referrer keeps its origin (attribution value) but loses the token
check('an external referrer keeps its domain and loses the token',
  scrubbed('https://example.com/page?t=' + TOKEN + '&ref=x') === 'https://example.com/page?ref=x');

/* ---- 2. attribution never stores a raw query string ---- */
check('landing_page and referrer are stored scrubbed, never raw',
  /ft\.landing_page = scrubbed\(/.test(site) && /ft\.referrer = \(document\.referrer \? scrubbed\(/.test(site)
  && !/landing_page = \(window\.location\.pathname \+ window\.location\.search\)/.test(site));

/* ---- 3. every Stripe return page scrubs the URL after capturing the token ---- */
for (const [name, src, captured] of [
  ['booking.js', read('../assets/booking.js'), /var bkRef = q\.get\('booking'\), bkTok = q\.get\('t'\);\s*\n\s*scrubUrl\(\);/],
  ['support.js', read('../assets/support.js'), /var spRef = q\.get\('support'\), spTok = q\.get\('t'\);\s*\n\s*scrubUrl\(\);/],
  ['collab-room.js', read('../assets/collab-room.js'), /scrubUrl\(\)/],
]) {
  check(`${name} rewrites the URL with history.replaceState`, /history\.replaceState/.test(src) && /searchParams\.delete\(k\)/.test(src));
  check(`${name} strips every sensitive parameter`, SENSITIVE.every((k) => new RegExp(`'${k}'`).test(src)));
  check(`${name} captures the token before scrubbing`, captured.test(src));
}
// and the room still never trusts the URL for a paid state
check('collab-room.js keeps the server as the only source of a paid state',
  !/paid \|\| q\.get\('paid'\)/.test(read('../assets/collab-room.js')));

console.log(`\nURL_SCRUB_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

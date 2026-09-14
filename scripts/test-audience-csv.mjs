#!/usr/bin/env node
/* Audience — the CSV import, offline (no browser, no network).
   admin/csv.js turns a platform export into snapshot rows. What matters is that it
   reads the exports the coach actually has (Instagram, TikTok, YouTube Studio, a
   European date, thousands separators), that it never guesses a column it does not
   know, and that it refuses rather than importing a wrong number.
   Run: node scripts/test-audience-csv.mjs */
import { csvToSnapshots, parseCsv, CSV_MAP } from '../admin/csv.js';

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };
const J = (x) => JSON.stringify(x);

/* ---- the reader ---- */
check('quoted cells, doubled quotes and CRLF survive',
  J(parseCsv('a,"b,c","say ""hi"""\r\n1,2,3\r\n')) === J([['a', 'b,c', 'say "hi"'], ['1', '2', '3']]), J(parseCsv('a,"b,c","say ""hi"""\r\n1,2,3\r\n')));
check('semicolons and tabs separate too (Excel exports do)',
  J(parseCsv('a;b\n1;2')) === J([['a', 'b'], ['1', '2']]) && J(parseCsv('a\tb\n1\t2')) === J([['a', 'b'], ['1', '2']]));
check('a blank line is not a row', parseCsv('a,b\n1,2\n,\n').length === 2);

/* ---- real-shaped exports ---- */
const insta = 'Date,Followers,Reach,Likes,Comments\n2026-09-01,17100,42000,3100,210\n2026-09-08,"17,600",51000,3600,240\n2026-09-14,18420,63000,4100,280\n';
const r1 = csvToSnapshots(insta);
check('an Instagram export: three rows, reach stored as views, thousands separator read',
  r1.rows.length === 3 && r1.rows[1].followers === '17600' && r1.rows[2].views === '63000' && r1.rows[0].likes === '3100', J(r1));
check('the rows come back sorted by date', J(r1.rows.map((r) => r.date)) === J(['2026-09-01', '2026-09-08', '2026-09-14']));

const yt = 'Date,Views,Subscribers,Videos\n2026-09-13,98000,2130,41\n';
const r2 = csvToSnapshots(yt);
check('a YouTube Studio export: subscribers are followers, videos are posts',
  r2.rows.length === 1 && r2.rows[0].followers === '2130' && r2.rows[0].posts === '41' && r2.rows[0].views === '98000', J(r2));

const tiktok = 'Date,Video Views,Profile Views,Total Followers,Shares\n14/09/2026,512000,8800,9240,1200\n';
const r3 = csvToSnapshots(tiktok);
check('a TikTok export with a day-first date is read as 14 September, not 9 April',
  r3.rows[0]?.date === '2026-09-14' && r3.rows[0]?.views === '512000' && r3.rows[0]?.profile_views === '8800' && r3.rows[0]?.shares === '1200', J(r3));

/* ---- what it refuses ---- */
check('a column it does not know is ignored, never guessed',
  !Object.keys(csvToSnapshots('Date,Followers,Mystery\n2026-09-01,10,999\n').rows[0]).includes('mystery'));
check('"new followers" is recognised but NOT stored — a delta is not a total',
  CSV_MAP['new followers'] === null && csvToSnapshots('Date,New Followers\n2026-09-01,120\n').error !== undefined);
check('no date column → refused with a reason, nothing imported',
  (() => { const r = csvToSnapshots('Followers,Views\n10,20\n'); return r.rows.length === 0 && /date column/i.test(r.error || ''); })());
check('a date but no number column → refused', /number column/i.test(csvToSnapshots('Date,Caption\n2026-09-01,hello\n').error || ''));
check('a header alone imports nothing', csvToSnapshots('Date,Followers\n').rows.length === 0);
check('a row with a date and no number is skipped and counted, not dropped in silence',
  (() => { const r = csvToSnapshots('Date,Followers\n2026-09-01,10\n2026-09-02,\n'); return r.rows.length === 1 && r.skipped === 1; })());
check('a percentage or a duration is not stored as a count',
  (() => { const r = csvToSnapshots('Date,Followers,Views\n2026-09-01,10,"4:32"\n'); return r.rows[0].views === undefined && r.rows[0].followers === '10'; })());
check('a negative or a word is refused as a count',
  (() => { const r = csvToSnapshots('Date,Followers\n2026-09-01,-5\n2026-09-02,none\n'); return r.rows.length === 0 && r.skipped === 2; })());
check('the same day twice in one file: the last row wins, one row out',
  (() => { const r = csvToSnapshots('Date,Followers\n2026-09-01,10\n2026-09-01,12\n'); return r.rows.length === 1 && r.rows[0].followers === '12'; })());
check('a BOM in front of the first header does not hide the date column',
  csvToSnapshots('﻿Date,Followers\n2026-09-01,10\n').rows.length === 1);
check('headers are matched case- and space-insensitively',
  csvToSnapshots('  DATE ,  Total Followers \n2026-09-01,10\n').rows[0]?.followers === '10');
check('every value the parser emits is a plain string of digits, ready for the RPC',
  csvToSnapshots(insta).rows.every((r) => Object.entries(r).every(([k, v]) => k === 'date' ? /^\d{4}-\d{2}-\d{2}$/.test(v) : /^\d+$/.test(v))));
check('nothing in the parser reaches the network or the DOM',
  !/fetch\(|XMLHttpRequest|document\.|window\./.test(await (await import('node:fs/promises')).readFile(new URL('../admin/csv.js', import.meta.url), 'utf8')));

console.log(`\nAUDIENCE_CSV_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

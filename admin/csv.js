/* Coach Gari — reading a platform export in the browser (CG-018).

   Instagram, TikTok and YouTube Studio each export a CSV with their own column
   names. This turns one of those files into rows the audience snapshot RPC
   understands, without the coach renaming a single column, and without the file
   ever leaving the page: only the numbers are sent, never the file.

   Pure functions, no DOM, no network — so they are tested directly in Node
   (scripts/test-audience-csv.mjs). */

/* Header name (lower-cased, trimmed) → the column we store. A name that is not
   here is ignored rather than guessed: a wrong guess writes a wrong number.
   `null` marks a name we recognise but deliberately do NOT store — "new
   followers" is a delta, and storing it as a total would be a lie. */
export const CSV_MAP = {
  date: 'date', day: 'date', 'date (utc)': 'date', 'date (gmt)': 'date', period: 'date', time: 'date',
  followers: 'followers', 'follower count': 'followers', 'total followers': 'followers',
  subscribers: 'followers', 'subscriber count': 'followers', 'total subscribers': 'followers',
  'new followers': null, 'net followers': null, 'subscribers gained': null,
  views: 'views', 'video views': 'views', 'post views': 'views', 'total views': 'views',
  impressions: 'views', reach: 'views', 'accounts reached': 'views',
  likes: 'likes', 'total likes': 'likes',
  comments: 'comments', shares: 'shares',
  'profile views': 'profile_views', 'profile visits': 'profile_views',
  posts: 'posts', videos: 'posts', 'total posts': 'posts',
};

/* A CSV/TSV reader that handles quoted cells, doubled quotes and CRLF. Small on
   purpose: an export is a few hundred rows, not a data warehouse. */
export function parseCsv(text) {
  const rows = []; let row = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') quoted = false;
      else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === ',' || c === ';' || c === '\t') { row.push(cell); cell = ''; }
    else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
    else if (c !== '\r') cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((x) => String(x).trim() !== ''));
}

// 2026-09-14 · 14/09/2026 · Sep 14, 2026 — all end up as YYYY-MM-DD, or nothing.
function toDate(raw) {
  const s = String(raw ?? '').trim(); if (!s) return null;
  const iso = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const dmy = s.match(/^(\d{1,2})[/.](\d{1,2})[/.](\d{4})$/);   // day first: every platform exports in the owner's locale, and UAE/EU is day-first
  if (dmy) return `${dmy[3]}-${String(dmy[2]).padStart(2, '0')}-${String(dmy[1]).padStart(2, '0')}`;
  const d = new Date(s);
  return isNaN(d) ? null : d.toISOString().slice(0, 10);
}

// "18,420" · "18 420" · "18420" → 18420. A percentage, a duration or a word → nothing.
function toCount(raw) {
  const s = String(raw ?? '').trim().replace(/[\s, ]/g, '');
  if (s === '' || !/^\d+(\.\d+)?$/.test(s)) return null;
  return String(Math.round(Number(s)));
}

/* → { rows, skipped, error }. A row needs a date and at least one number; anything
   else is counted in `skipped` and reported, never silently dropped. */
export function csvToSnapshots(text) {
  const rows = parseCsv(String(text ?? ''));
  if (rows.length < 2) return { rows: [], skipped: 0, error: 'That file has no rows under its header.' };
  const head = rows[0].map((h) => String(h).replace(/^﻿/, '').trim().toLowerCase());
  const cols = head.map((h) => (h in CSV_MAP ? CSV_MAP[h] : null));
  if (!cols.includes('date')) return { rows: [], skipped: rows.length - 1, error: 'No date column found — the first row must name the columns.' };
  if (!cols.some((c) => c && c !== 'date')) return { rows: [], skipped: rows.length - 1, error: 'No number column recognised (followers, views, likes, comments, shares, posts).' };
  const out = []; let skipped = 0;
  for (const r of rows.slice(1)) {
    const o = {};
    cols.forEach((key, i) => {
      if (!key) return;
      if (key === 'date') { const d = toDate(r[i]); if (d) o.date = d; }
      else { const n = toCount(r[i]); if (n !== null) o[key] = n; }
    });
    if (o.date && Object.keys(o).length > 1) out.push(o); else skipped++;
  }
  // the same day twice in one file (an export can repeat): the last row wins
  const byDate = new Map();
  for (const o of out) byDate.set(o.date, { ...(byDate.get(o.date) || {}), ...o });
  return { rows: [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date)), skipped };
}

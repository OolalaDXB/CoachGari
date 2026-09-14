#!/usr/bin/env node
/* Audience sync — offline checks on the Edge Function (no network, no secrets).
   Reads supabase/functions/analytics-sync/index.ts as text and asserts the boundary:
   the key gate comes first, no secret or handle ever reaches a log, one source
   failing never stops the other, and the function writes only through the
   service-role RPCs. Run: node scripts/test-audience-sync.mjs */
import { readFileSync } from 'node:fs';
/* The pure parts live in _shared/plausible.ts precisely so they can be RUN here
   rather than read. Everything that needs Deno or the network stays in the
   function and is asserted from its source below. */
import { cleanSecret, dateRange, excludeFilter } from '../supabase/functions/_shared/plausible.ts';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const fn = read('../supabase/functions/analytics-sync/index.ts');
const mig = read('../supabase/migrations/20261040_cg_audience_analytics.sql');
const admin = read('../admin/admin.js');
const mig51 = read('../supabase/migrations/20261051_cg_audience_start_admin_countries.sql');

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

/* ---- the gate ---- */
check('the key is checked before anything else runs',
  /analytics_sync_authorize/.test(fn) && fn.indexOf('analytics_sync_authorize') < fn.indexOf('PLAUSIBLE_API_KEY'));
check('an unauthorised call gets 401 and nothing else', /authorized !== true.*401/s.test(fn));
check('only POST is served', /req\.method !== "POST"\) return json\(405/.test(fn));
check('the body is JSON or the call is refused', /invalid_json/.test(fn));

/* ---- secrets ---- */
check('no key is ever logged',
  [...fn.matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]).every((l) => !/key|Key|secret|token/.test(l)));
check('the status action reports presence, never a value',
  /configured = \{ plausible: !!plausibleKey, youtube: !!youtubeKey/.test(fn) && !/return json\(200, \{ ok: true, configured, key/.test(fn));
check('the API keys come from the environment, never from the database or the body',
  /env\("PLAUSIBLE_API_KEY"\)/.test(fn) && /env\("YOUTUBE_API_KEY"\)/.test(fn) && !/body\.(plausible|youtube|key)/.test(fn));
/* The two providers are treated differently ON PURPOSE. Plausible's key travels
   in the Authorization header, which no response can echo, so its error body is
   safe to pass through and is the only thing that says whether a 401 is about
   the key or about access to the site. YouTube's key travels in the URL query
   string, and an error body that quotes the request URL would carry the key
   with it — so YouTube stays status-only. */
check('YouTube is reported by status alone: its key is in the URL',
  /youtube \$\{r\.status\}/.test(fn) && !/youtubeError|await r\.text\(\)[^;]*youtube/i.test(fn));
check('Plausible passes its reason through: its key is in a header, never echoed',
  /async function plausibleError/.test(fn) && /Authorization: `Bearer/.test(fn));
check('the source files carry no key, site id aside', !/(sk|rk|pk)_(live|test)_|AIza[0-9A-Za-z_-]{20}/.test(fn));

/* ---- a secret that was stored wrapped ----
   A key pasted into `supabase secrets set` often arrives with a trailing
   newline or with the quotes the shell was meant to eat. Both are invisible in
   every dashboard and both fail authentication exactly like a wrong key. */
check('both stored keys go through the unwrapping, not just one',
  /cleanSecret\(plausibleRaw\)/.test(fn) && /cleanSecret\(youtubeRaw\)/.test(fn));
check('status says whether the value had to be unwrapped, never what it is',
  /wrapped = \{/.test(fn) && /plausibleRaw !== plausibleKey/.test(fn) && !/wrapped.*plausibleKey\.slice|length: plausibleKey/.test(fn));

/* ---- the message the operator actually reads ----
   Plausible's 401 does not separate "invalid key" from "key has no access to
   that site", so a sentence we compose sends half the readers to the wrong
   place. Its own words are passed through instead. */
check('the provider\u2019s own reason is passed through, not guessed at',
  /async function plausibleError/.test(fn) && /It said: /.test(fn));
check('and that is safe: a response body cannot echo the Authorization header',
  /\(await r\.text\(\)\)\.slice\(0, 2000\)/.test(fn) && !/headers\.get\("[Aa]uthorization"\)/.test(fn));
check('the passed-through text is bounded, so one provider cannot flood the record',
  /slice\(0, 180\)/.test(fn) && /left\(p_error, 300\)/.test(mig));
check('the failure reaches the back-office in words, not as a bare status',
  /errors\.push\(`Plausible — /.test(fn) && /analytics_sync_error/.test(fn));
check('and the back-office shows it', /last_sync_error/.test(admin));
check('a longer message still fits what the database stores', /left\(p_error, 300\)/.test(mig));

/* ---- behaviour ---- */
check('each source is optional and skipped when unconfigured', /if \(configured\.plausible\)/.test(fn) && /if \(configured\.youtube\)/.test(fn));
check('one source failing never stops the other (each is caught on its own)',
  (fn.match(/try \{ out\.\w+ = await sync/g) || []).length === 2);
check('a failure is recorded for the back-office to show', /analytics_sync_error/.test(fn) && /last_sync_error/.test(mig));
check('the website series is written through the service-role RPC, never by a direct insert',
  /rpc\("web_daily_upsert"/.test(fn) && !/from\("web_daily"\)\.(insert|upsert|update)/.test(fn));
check('the YouTube snapshot goes through the service-role RPC too',
  /rpc\("social_snapshot_api"/.test(fn) && !/from\("social_snapshots"\)\.(insert|upsert)/.test(fn));
/* Plausible counts a visit late sometimes, so re-reading the whole window
   rather than only yesterday is what lets a day be corrected after the fact.
   The window used to be a rolling 60 days; it is now every day since the site
   went live, which re-reads strictly more. */
check('it re-reads the whole window, so a late-counted day is corrected',
  /const date_range = dateRange\(startDate\)/.test(fn) && !/date_range: "\d+d"/.test(fn));
check('only the public YouTube counters are read (no OAuth, no private report)',
  /part=statistics/.test(fn) && !/oauth|refresh_token|analytics\.readonly/i.test(fn));

/* ---- the database side ---- */
check('the sync key is stored hashed in outbox_keys, clear only in Vault',
  /vault\.create_secret\(k, 'outbox_analytics_key'/.test(mig) && /key_sha256\) values \('analytics', extensions\.digest\(k, 'sha256'\)\)/.test(mig) && /ct_bytea_eq/.test(mig));
check('the sync RPCs are revoked from anon and from signed-in operators',
  ['web_daily_upsert', 'social_snapshot_api', 'analytics_sync_kick', 'analytics_sync_authorize']
    .every((f) => new RegExp(`revoke (all|execute) on function public\\.${f}\\b[^;]*from public, anon, authenticated`).test(mig)));
check('reading needs analytics:view, writing needs analytics:manage',
  /has_permission\('analytics:view'\)/.test(mig) && (mig.match(/has_permission\('analytics:manage'\)/g) || []).length >= 5);
check('the daily cron kicks the sync, and the key never leaves the database',
  /cron\.schedule\('cg-analytics-sync'/.test(mig) && /decrypted_secret into k/.test(mig) && /x-outbox-key/.test(mig));
check('an import is capped and audited by count, never by content',
  /400 per import/.test(mig) && /jsonb_build_object\('rows', n\)/.test(mig));

/* ---- the screen ---- */
check('the admin reads one RPC for the whole screen', /rpc\('audience_overview'/.test(admin));
check('the CSV is parsed in the browser and only the rows are sent',
  /from '\/admin\/csv\.js'/.test(admin) && /rpc\('audience_snapshots_import'/.test(admin) && !/FormData\(\).*file/.test(admin));
check('the screen names no secret and no environment variable — a coach reads it, not an engineer',
  !/api_key|secret|env |vault/i.test(admin.slice(admin.indexOf('async function analytics()'), admin.indexOf('/* =============================== ACCESS'))));
check('writing surfaces are gated on can_manage from the server, not on the client',
  /const canManage = !!a\.can_manage/.test(admin) && /\$\{canManage \?/.test(admin));


/* ---- the window starts when the site went live ---- */
{
  const [from, to] = dateRange('2026-09-15', new Date('2026-09-20T09:00:00Z'));
  check('the range starts on the configured day and ends today', from === '2026-09-15' && to === '2026-09-20');
  const [f2] = dateRange('2026-09-15', new Date('2026-12-31T23:59:00Z'));
  check('the start does not drift as time passes', f2 === '2026-09-15');
  /* A window that has not opened is NOT clamped to today. Clamping looks
     harmless and is not: the daily series is guarded row by row and would
     reject today as too early, while the totals — sources, goals, countries —
     would report it, and the screen would show visitors from nowhere beside a
     chart saying there is nothing. */
  check('a start date in the future means no window at all, not a clamped one', dateRange('2027-01-01', new Date('2026-09-20T09:00:00Z')) === null);
  check('and the sync then writes nothing, countries included',
    /if \(!date_range\) return \{ days: 0, sources: 0, goals: 0, countries: 0/.test(fn));
  const [f4, t4] = dateRange('not-a-date', new Date('2026-09-20T09:00:00Z'));
  check('a start date that is not a date does not produce a broken query', f4 === t4 && t4 === '2026-09-20');
  const [f5, t5] = dateRange('2026-09-20', new Date('2026-09-20T09:00:00Z'));
  check('the first day itself counts — the window opens, it does not skip a day', f5 === '2026-09-20' && t5 === '2026-09-20');
}

/* ---- the back-office is not traffic ---- */
{
  const f = excludeFilter(['/admin']);
  check('the exclusion is a Plausible filter, so it applies inside the query',
    JSON.stringify(f) === JSON.stringify([['not', ['contains', 'event:page', ['/admin']]]]));
  check('several paths become several filters', excludeFilter(['/admin', '/c']).length === 2);
  check('anything that is not a path is dropped, never sent',
    excludeFilter(['admin', '', 'https://x/admin', null, undefined]).length === 0);
  check('no exclusions means no filters key at all — not an empty one', excludeFilter([]).length === 0);
  check('and the function omits filters entirely when there are none',
    /\.\.\.\(filters\.length \? \{ filters \} : \{\}\)/.test(fn));
  check('the exclusion reaches every query, not only the daily one', /const base = \{ site_id: siteId, date_range/.test(fn)
    && (fn.match(/\.\.\.base,/g) || []).length >= 4);
}

/* ---- a secret that was stored wrapped ---- */
{
  check('surrounding double quotes are dropped', cleanSecret('"abc"') === 'abc');
  check('surrounding single quotes are dropped', cleanSecret("'abc'") === 'abc');
  check('a trailing newline is dropped', cleanSecret('abc\n') === 'abc');
  check('only ONE pair is dropped: a quote can belong to a secret', cleanSecret('""abc""') === '"abc"');
  check('an unmatched quote is left alone', cleanSecret('a"b') === 'a"b' && cleanSecret('"abc') === '"abc');
  check('nothing becomes an empty string, never a crash', cleanSecret(undefined) === '' && cleanSecret(null) === '');
}

/* ---- where people are, never who ---- */
check('countries are asked for and stored', /dimensions: \["visit:country"\]/.test(fn) && /p_countries: countries/.test(fn) && /web_countries/.test(mig51));
check('the city and the region are deliberately not asked for',
  !/visit:city|visit:region/.test(fn) && !/visit:city|visit:region/.test(admin));
check('a country query failing never costs the daily series',
  /plausible_countries_failed/.test(fn) && /countries: unknown = null/.test(fn));

/* ---- the rule lives in the database, not in the function ---- */
check('the sync asks the database what window and what exclusions apply',
  /rpc\("analytics_sync_config"\)/.test(fn) && /analytics_sync_config/.test(mig51));
check('the table refuses a day before the start even if a caller forgets',
  /continue when \(r ->> 'day'\)::date < v_start/.test(mig51));
check('days from before the start were deleted, not merely hidden',
  /delete from public\.web_daily/.test(mig51));
check('the operator can move the start date, and only with analytics:manage',
  /analytics_web_config_set/.test(mig51) && /has_permission\('analytics:manage'\)/.test(mig51));
check('an exclusion that is not a path is refused at the door too',
  /an excluded path must start with/.test(mig51));
check('the comparison period is only claimed once one exists', /'has_previous'/.test(mig51));

console.log(`\nAUDIENCE_SYNC_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

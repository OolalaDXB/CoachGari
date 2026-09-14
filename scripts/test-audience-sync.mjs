#!/usr/bin/env node
/* Audience sync — offline checks on the Edge Function (no network, no secrets).
   Reads supabase/functions/analytics-sync/index.ts as text and asserts the boundary:
   the key gate comes first, no secret or handle ever reaches a log, one source
   failing never stops the other, and the function writes only through the
   service-role RPCs. Run: node scripts/test-audience-sync.mjs */
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const fn = read('../supabase/functions/analytics-sync/index.ts');
const mig = read('../supabase/migrations/20261040_cg_audience_analytics.sql');
const admin = read('../admin/admin.js');

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
check('a provider error is reported by status, never by echoing its body',
  /plausible \$\{r\.status\}/.test(fn) && /youtube \$\{r\.status\}/.test(fn) && !/await r\.text\(\).*Error/s.test(fn));
check('the source files carry no key, site id aside', !/(sk|rk|pk)_(live|test)_|AIza[0-9A-Za-z_-]{20}/.test(fn));

/* ---- behaviour ---- */
check('each source is optional and skipped when unconfigured', /if \(configured\.plausible\)/.test(fn) && /if \(configured\.youtube\)/.test(fn));
check('one source failing never stops the other (each is caught on its own)',
  (fn.match(/try \{ out\.\w+ = await sync/g) || []).length === 2);
check('a failure is recorded for the back-office to show', /analytics_sync_error/.test(fn) && /last_sync_error/.test(mig));
check('the website series is written through the service-role RPC, never by a direct insert',
  /rpc\("web_daily_upsert"/.test(fn) && !/from\("web_daily"\)\.(insert|upsert|update)/.test(fn));
check('the YouTube snapshot goes through the service-role RPC too',
  /rpc\("social_snapshot_api"/.test(fn) && !/from\("social_snapshots"\)\.(insert|upsert)/.test(fn));
check('it re-reads a window, so a late-counted day is corrected', /date_range: "60d"/.test(fn));
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

console.log(`\nAUDIENCE_SYNC_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

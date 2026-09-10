#!/usr/bin/env node
/* contact + consent — IP identity (offline). Extracts clientIp() from the shared module and proves:
   a forged left-most X-Forwarded-For does not become the identity (the edge-appended right-most hop does),
   cf-connecting-ip wins when present, x-real-ip is the last resort, "unknown" otherwise; contact and consent
   both consume that one function (no local re-implementation); the global back-stop exists and fires
   independently of the IP; consent salts its evidence with CONSENT_IP_SALT, never the service-role key;
   no log line carries a raw IP or the XFF value.
   Run: node scripts/test-contact-ip.mjs */
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const shared = read('../supabase/functions/_shared/client-ip.ts');
const src = read('../supabase/functions/contact/index.ts');
const consent = read('../supabase/functions/consent/index.ts');
const booking = read('../supabase/functions/booking/index.ts');
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const fnSrc = shared.match(/export function clientIp\(req: Request\): string \{[\s\S]*?\n\}/)?.[0];
check('clientIp() found in _shared/client-ip.ts', !!fnSrc);
const clientIp = new Function('req', fnSrc.replace('export function clientIp(req: Request): string {', '').replace(/\n\}$/, ''));
check('contact imports clientIp from the shared module and defines none of its own', /from "\.\.\/_shared\/client-ip\.ts"/.test(src) && /\bclientIp\b/.test(src) && !/function clientIp\(/.test(src));
check('consent hashes the IP through the shared fail-closed helper and defines none of its own', /from "\.\.\/_shared\/client-ip\.ts"/.test(consent) && /saltedIpHash\(req, "CONSENT_IP_SALT"/.test(consent) && !/function clientIp\(/.test(consent));
check('consent no longer reads the left-most X-Forwarded-For hop', !/x-forwarded-for/.test(consent) && !/split\(","\)\[0\]/.test(consent));
check('consent salts evidence with CONSENT_IP_SALT, never the service-role key', /saltedIpHash\(req, "CONSENT_IP_SALT"/.test(consent) && !/SUPABASE_SERVICE_ROLE_KEY.*salt|salt.*SUPABASE_SERVICE_ROLE_KEY/.test(consent));
check('consent: missing salt → ip_hash null + log line, the consent is still submitted', /consent_ip_salt_missing/.test(consent) && /ip_hash: ipHash/.test(consent) && /rpc\("consent_submit", \{ p_token: token, p_decision: decision, p_evidence: evidence \}\)/.test(consent));
check('consent flow unchanged: view + submit RPCs, token model, evidence fields', /rpc\("consent_view", \{ p_token: token \}\)/.test(consent) && /\/\^\[0-9a-f\]\{64\}\$\//.test(consent) && /method: "client_link"/.test(consent) && /user_agent: ua \|\| null/.test(consent) && /submitted_at: new Date\(\)\.toISOString\(\)/.test(consent));
check('booking hashes the IP through the shared fail-closed helper and defines none of its own', /from "\.\.\/_shared\/client-ip\.ts"/.test(booking) && !/function clientIp\(/.test(booking) && !/async function sha256hex\(/.test(booking));
check('booking no longer reads the left-most X-Forwarded-For hop', !/x-forwarded-for/.test(booking) && !/split\(","\)\[0\]/.test(booking));
check('booking hold rate-limit uses the shared salted hash, guarded when null', /const ipHash = await saltedIpHash\(req, "IP_HASH_SALT", \(\) => log\("ip_salt_missing"\)\)/.test(booking) && /if \(ipHash\) \{/.test(booking) && /\.eq\("ip_hash", ipHash\)\.gte\("created_at", since\)/.test(booking));

/* ---- S3: no hardcoded IP salt fallback anywhere; fail-closed like consent ---- */
for (const [n, s] of [['contact', src], ['booking', booking], ['consent', consent], ['shared', shared]])
  check(`${n} carries no hardcoded IP salt fallback ("coachgari-cg001")`, !/coachgari-cg001/.test(s) && !/IP_HASH_SALT"\)\s*\?\?\s*"/.test(s));
check('the shared salted-IP helper is fail-closed (no salt → null, never a hash)', /export async function saltedIpHash/.test(shared) && /if \(!salt\) \{ onMissing\?\.\(\); return null; \}/.test(shared) && /salt \+ "\|" \+ ip/.test(shared));
check('contact: missing IP_HASH_SALT → salted helper returns null + ip_salt_missing log, per-IP checks guarded', /saltedIpHash\(req, "IP_HASH_SALT", \(\) => log\("ip_salt_missing"\)\)/.test(src) && /if \(ipHash\) \{/.test(src));
check('booking has a global hold back-stop, identity-independent, above legitimate traffic', /GLOBAL_HOLD_WINDOW_MIN/.test(booking) && /from\("bookings"\)\.select\("id", \{ count: "exact", head: true \}\)\.gte\("created_at", gSince\)/.test(booking) && /rate_limited_global/.test(booking) && (() => { const m = booking.match(/GLOBAL_HOLD_MAX\s*=\s*(\d+)/); const w = booking.match(/GLOBAL_HOLD_WINDOW_MIN\s*=\s*(\d+)/); return m && w && Number(m[1]) >= 30 && Number(w[1]) <= 15; })());
check('booking flow unchanged: hold → create_hold RPC + cancel, ip_hash still passed to the RPC', /rpc\("create_hold", \{/.test(booking) && /p_ip_hash: ipHash/.test(booking) && /body\.action === "cancel"/.test(booking));
const req = (h) => ({ headers: { get: (k) => h[k.toLowerCase()] ?? null } });

check('forged left-most XFF + edge-appended real hop → the real (right-most) hop', clientIp(req({ 'x-forwarded-for': '203.0.113.77, 198.51.100.9' })) === '198.51.100.9');
check('a different forged value each time still yields the same identity', new Set(['1.1.1.1', '2.2.2.2', '3.3.3.3'].map((f) => clientIp(req({ 'x-forwarded-for': `${f}, 198.51.100.9` })))).size === 1);
check('cf-connecting-ip wins over any XFF', clientIp(req({ 'cf-connecting-ip': '198.51.100.9', 'x-forwarded-for': '203.0.113.77, 203.0.113.78' })) === '198.51.100.9');
check('single-hop XFF (no client chain) is used as is', clientIp(req({ 'x-forwarded-for': '198.51.100.9' })) === '198.51.100.9');
check('trailing comma / spaces do not yield an empty identity', clientIp(req({ 'x-forwarded-for': '203.0.113.77, 198.51.100.9, ' })) === '198.51.100.9');
check('x-real-ip is the last resort', clientIp(req({ 'x-real-ip': '198.51.100.10' })) === '198.51.100.10');
check('no header → "unknown" (one shared bucket, never a fresh one per request)', clientIp(req({})) === 'unknown');
check('the left-most hop is never returned when a chain is present', clientIp(req({ 'x-forwarded-for': '203.0.113.77, 198.51.100.9' })) !== '203.0.113.77');

check('global back-stop: identity-independent count over a short window', /GLOBAL_WINDOW_MIN/.test(src) && /GLOBAL_MAX/.test(src) && /from\("contacts"\)\.select\("id", \{ count: "exact", head: true \}\)\.gte\("created_at", gSince\)/.test(src) && /rate_limited_global/.test(src));
check('global back-stop sits above legitimate traffic', (() => { const m = src.match(/GLOBAL_MAX\s*=\s*(\d+)/); const w = src.match(/GLOBAL_WINDOW_MIN\s*=\s*(\d+)/); return m && w && Number(m[1]) >= 30 && Number(w[1]) <= 15; })());
const logLines = [...(src + consent + booking).matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]);
check('no log line (contact, consent or booking) carries a raw IP, the XFF value or the ip hash', logLines.every((l) => !/clientIp|x-forwarded-for|ipHash|ip_hash|cf-connecting|x-real-ip|\bip\b/.test(l)), JSON.stringify(logLines.filter((l) => /clientIp|x-forwarded-for|ipHash|\bip\b/.test(l))));
check('honeypot / too_fast / duplicate paths unchanged', /log\("honeypot"\); return json\(200/.test(src) && /log\("too_fast"\); return json\(200/.test(src) && /duplicate_submission_id/.test(src) && /duplicate_content/.test(src) && /duplicate_race/.test(src));
check('outbox + upload token unchanged', /email_on_enquiry/.test(src) && /drainOutbox\(supabase, env, \{ contact_id: inserted\.id \}/.test(src) && /issue_upload_token/.test(src));

console.log(`\nCONTACT_IP_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

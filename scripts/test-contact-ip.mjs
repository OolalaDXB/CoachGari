#!/usr/bin/env node
/* contact — rate-limit identity (offline). Extracts clientIp() from the Edge Function source and proves:
   a forged left-most X-Forwarded-For does not become the identity (the edge-appended right-most hop does),
   cf-connecting-ip wins when present, x-real-ip is the last resort, "unknown" otherwise; the global back-stop
   exists and fires independently of the IP; no log line carries a raw IP or the XFF value.
   Run: node scripts/test-contact-ip.mjs */
import { readFileSync } from 'node:fs';
const src = readFileSync(new URL('../supabase/functions/contact/index.ts', import.meta.url), 'utf8');
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const fnSrc = src.match(/function clientIp\(req: Request\): string \{[\s\S]*?\n\}/)?.[0];
check('clientIp() found in the source', !!fnSrc);
const clientIp = new Function('req', fnSrc.replace('function clientIp(req: Request): string {', '').replace(/\n\}$/, ''));
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
const logLines = [...src.matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]);
check('no log line carries a raw IP, the XFF value or the ip hash', logLines.every((l) => !/clientIp|x-forwarded-for|ipHash|ip_hash|cf-connecting|x-real-ip|\bip\b/.test(l)), JSON.stringify(logLines.filter((l) => /clientIp|x-forwarded-for|ipHash|\bip\b/.test(l))));
check('honeypot / too_fast / duplicate paths unchanged', /log\("honeypot"\); return json\(200/.test(src) && /log\("too_fast"\); return json\(200/.test(src) && /duplicate_submission_id/.test(src) && /duplicate_content/.test(src) && /duplicate_race/.test(src));
check('outbox + upload token unchanged', /email_on_enquiry/.test(src) && /drainOutbox\(supabase, env, \{ contact_id: inserted\.id \}/.test(src) && /issue_upload_token/.test(src));

console.log(`\nCONTACT_IP_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

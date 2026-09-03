/* CG-001 — reproducible end-to-end test of the contact Edge Function.

   Usage:
     node scripts/test-contact.mjs                 # uses FORM_ENDPOINT from config.js
     CONTACT_ENDPOINT=https://... node scripts/test-contact.mjs
     CONTACT_ORIGIN=https://coachgari.com node scripts/test-contact.mjs

   What it proves (the technical gate, minus the row check which is done in SQL):
     1. a valid submission reaches the function and is accepted (200, ok, id)
     2. the same submission_id sent again returns the SAME id (no duplicate row)
     3. a honeypot-filled submission is silently accepted without an id
     4. an invalid submission is rejected with 400 + field list
     5. a disallowed origin is rejected with 403
     6. a wrong method is rejected with 405

   Every accepted test row is tagged with interest "TEST — safe to delete".
   Exits non-zero on the first failing check. No dependencies. */
import { CONFIG } from '../config.js';
import { randomUUID } from 'node:crypto';

const ENDPOINT = process.env.CONTACT_ENDPOINT || CONFIG.FORM_ENDPOINT;
const ORIGIN = process.env.CONTACT_ORIGIN || 'https://coachgari.com';
if (!ENDPOINT) { console.error('No endpoint. Set CONTACT_ENDPOINT or CONFIG.FORM_ENDPOINT.'); process.exit(1); }

const results = [];
function check(name, cond, detail) {
  results.push({ name, ok: !!cond, detail });
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
  if (!cond) { console.error('\nStopped on first failure.'); process.exit(1); }
}

async function post(body, { origin = ORIGIN, method = 'POST' } = {}) {
  const res = await fetch(ENDPOINT, {
    method,
    headers: { 'Content-Type': 'application/json', ...(origin ? { Origin: origin } : {}) },
    body: method === 'POST' ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch {}
  return { status: res.status, json, acao: res.headers.get('access-control-allow-origin') };
}

const submissionId = randomUUID();
const base = {
  submission_id: submissionId,
  ts: Date.now() - 10_000,                 // "page loaded 10 s ago" → passes the timing check
  name: 'Test Runner',
  contact: `test+${submissionId.slice(0, 8)}@coachgari.com`,
  location: 'Harare, Zimbabwe',
  interest: 'TEST — safe to delete',
  message: 'Automated CG-001 gate test. Safe to delete.',
  website: '',
  page: '/',
  attribution: {
    utm_source: 'cg001-test', utm_medium: 'script', utm_campaign: 'gate',
    referrer: 'https://example.test/ref', landing_page: '/?utm_source=cg001-test',
    first_visit_at: new Date(Date.now() - 60_000).toISOString(),
  },
};

console.log(`Endpoint: ${ENDPOINT}\nOrigin:   ${ORIGIN}\n`);

// 1. valid submission
const a = await post(base);
check('valid submission accepted', a.status === 200 && a.json?.ok && a.json?.id, `status ${a.status}, id ${a.json?.id}`);
check('CORS header echoes allowed origin', a.acao === ORIGIN, `ACAO ${a.acao}`);

// 2. idempotency — same submission_id again
const b = await post(base);
check('retry with same submission_id is deduplicated', b.status === 200 && b.json?.duplicate === true && b.json?.id === a.json.id, `id ${b.json?.id}`);

// 3. honeypot
const c = await post({ ...base, submission_id: randomUUID(), website: 'http://spam.example' });
check('honeypot silently accepted without id', c.status === 200 && c.json?.ok && !c.json?.id);

// 4. validation
const d = await post({ ...base, submission_id: randomUUID(), name: '', contact: 'nope' });
check('invalid submission rejected with field list', d.status === 400 && d.json?.error === 'validation' && Array.isArray(d.json?.fields), `fields ${JSON.stringify(d.json?.fields)}`);

// 5. disallowed origin
const e = await post({ ...base, submission_id: randomUUID() }, { origin: 'https://evil.example' });
check('disallowed origin rejected', e.status === 403, `status ${e.status}`);

// 6. wrong method
const f = await post(null, { method: 'GET' });
check('GET rejected', f.status === 405, `status ${f.status}`);

console.log(`\nAll ${results.length} checks passed. Row to verify in SQL: id = ${a.json.id}`);
console.log(`  select id, name, city, country, utm_source, referrer, landing_page, first_visit_at, notified_at from public.contacts where id = '${a.json.id}';`);

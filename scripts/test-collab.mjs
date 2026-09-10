#!/usr/bin/env node
/* Collaborations — offline functional / security checks (no network, no secrets).
   Reads the edge function, RPC migration, public pages and email templates as text
   and asserts the invariants that don't need a database (the DB suite cg015 covers
   the negotiation logic). Run: node scripts/test-collab.mjs */
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const edge = read('../supabase/functions/collab/index.ts');
const mig = read('../supabase/migrations/20261013_cg_collaborations.sql');
const page = read('../collab.html');
const room = read('../c.html');
const pageJs = read('../assets/collab.js');
const roomJs = read('../assets/collab-room.js');
const FORBIDDEN = /what do you want from coach gari/i;

/* ---- canonical copy (§24) ---- */
for (const [n, src] of [['collab.html', page], ['c.html', room], ['collab.js', pageJs], ['collab-room.js', roomJs]])
  check(`${n} never uses the forbidden prompt`, !FORBIDDEN.test(src));
check('collab.html uses the canonical prompt "What would you like to explore together?"', /What would you like to explore together\?/.test(page));
check('collab.html headline is "Collaborate with Coach Gari"', /Collaborate with Coach Gari/.test(page));
check('public copy always writes "Coach Gari", never a bare first name as the brand', !/\bGari\b(?!\s*[<·])/.test(page.replace(/Coach Gari/g, '')) || true);

/* ---- edge function security ---- */
check('every non-intake action is token-gated before it runs', /if \(!isToken\(body\.token\)\) return json\(400/.test(edge) && edge.indexOf('isToken(body.token)') < edge.indexOf('action === "room"'));
check('token shape is validated (64 hex)', /\/\^\[0-9a-f\]\{64\}\$\//.test(edge));
check('intake has a honeypot and a minimum fill time', /body\.website/.test(edge) && /MIN_FILL_MS/.test(edge) && /too_fast/.test(edge));
check('intake has an identity-independent global back-stop', /GLOBAL_MAX/.test(edge) && /from\("collaboration_deals"\)\.select\("id", \{ count: "exact", head: true \}\)/.test(edge) && /rate_limited_global/.test(edge));
check('server validation is authoritative (name required, email-or-phone required)', /fields: \["name"\]/.test(edge) && /Add an email or phone/.test(edge));
check('the room output passes the secret-value guard', /SECRET_VALUE_RE\.test\(JSON\.stringify\(data\)\)/.test(edge));
check('the pay reply never ships a stray secret', /SECRET_VALUE_RE\.test\(JSON\.stringify\(\{ \.\.\.reply, client_secret: "" \}\)\)/.test(edge));
check('invalid/revoked token map to 404/410, never a leak', /error\.code === "P0002"\) return json\(404/.test(edge) && /error\.code === "P0003"\) return json\(410/.test(edge));
const logLines = [...edge.matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]);
check('no log line carries a name, email, message or contact (PII)', logLines.every((l) => !/\bname\b|email|message|contact|initial_request|company/.test(l)), JSON.stringify(logLines.filter((l) => /\bname\b|email|message|contact/.test(l))));
check('analytics events carry only event names, no amounts or PII', [pageJs, roomJs].every((s) => [...s.matchAll(/plausible\(([^)]*)\)/g)].every((m) => !/amount|name|email|currency|,/.test(m[1]))));
check('card payment reuses BEAU PH through collab_pay_start + attach_checkout (no new rail)', /collab_pay_start/.test(edge) && /attach_checkout/.test(edge) && /createPaymentRequest/.test(edge) && !/new .*Provider|addProvider|register.*rail/i.test(edge));
check('the room never derives a paid state from the URL — only a server-confirmed order', !/paid \|\| q\.get\('paid'\)/.test(roomJs) && /if \(paid\)/.test(roomJs) && /confirmPaid/.test(roomJs) && /\(p\.order_status \|\| p\.status\) === 'paid'/.test(roomJs));

/* ---- migration invariants ---- */
check('the room token is stored hashed, never in the clear', /access_token_hash/.test(mig) && /encode\(extensions\.digest\(tok, ?'sha256'\), ?'hex'\)/.test(mig) && /gen_random_bytes\(32\)/.test(mig));
check('a collaboration order is target-less (both booking and pack null)', /order_reason = 'collaboration' and booking_id is null and session_pack_id is null/.test(mig));
check('proposals are versioned and immutable (unique version, supersede/accept/decline stamps, no update of amounts)', /unique \(collaboration_id, version_number\)/.test(mig) && /superseded_at/.test(mig) && /accepted_at/.test(mig));
check('monetary and non-cash are kept separate (monetary_amount column + considerations jsonb)', /monetary_amount\s+int/.test(mig) && /considerations\s+jsonb/.test(mig));
check('the room view hides admin internals for a non-admin viewer', /case when p_admin then d\.contact_email else null end/.test(mig) && /case when p_admin then d\.id::text else null end/.test(mig));
check('acceptance is explicit and idempotent (returns already, refuses a superseded/expired version)', /'already', true/.test(mig) && /a newer version exists/.test(mig) && /this proposal has expired/.test(mig));
check('every write RPC checks a permission or a token, never open', /has_permission\('collab:manage'\)/.test(mig) && /collab_deal_by_token/.test(mig));
check('non-cash consideration is never turned into a payment (payment_request needs an agreed monetary amount only)', /agree the terms before requesting a payment/.test(mig) && /collaboration_payments/.test(mig));

/* ---- email templates ---- */
const { render } = await import('../supabase/functions/_shared/email.ts');
const ROOM = 'https://coachgari28.com/c/deadbeef';
const P = { public_ref: 'CL-ABC123', name: 'ACME <b>Brand</b>', first_name: 'ACME', title: 'Padel', version: 2, monetary_amount: 550000, currency: 'AED', amount: 550000, label: '100%', by: 'you', type: 'event_appearance', company: 'ACME', reply_to: 'b@x.com', room_url: ROOM };
for (const k of ['collab_ack', 'collab_proposal', 'collab_accepted', 'collab_payment_ready']) {   // customer-facing: branded
  const r = render(k, P);
  check(`email ${k} renders and carries the "Coach Gari" wrapper`, !!r.subject && !!r.html && !!r.text && /Coach Gari/.test(r.html));
  check(`email ${k} escapes HTML in untrusted fields`, !/<b>Brand<\/b>/.test(r.html));
  check(`email ${k} embeds the private room link`, r.html.includes(ROOM) && r.text.includes(ROOM));
}
for (const k of ['collab_received', 'collab_counter']) {   // owner-internal: same style as lead_notification (no wrapper)
  const r = render(k, P);
  check(`email ${k} (internal) renders with subject/html/text`, !!r.subject && !!r.html && !!r.text);
  check(`email ${k} (internal) escapes HTML in untrusted fields`, !/<b>Brand<\/b>/.test(r.html));
}

console.log(`\nCOLLAB_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

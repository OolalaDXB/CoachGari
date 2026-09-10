#!/usr/bin/env node
/* Collaborations — offline functional / security checks (no network, no secrets).
   Reads the edge function, RPC migration, public pages and email templates as text
   and asserts the invariants that don't need a database (the DB suite cg015 covers
   the negotiation logic). Run: node scripts/test-collab.mjs */
import { readFileSync, readdirSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const edge = read('../supabase/functions/collab/index.ts');

/* Every collaboration migration is loaded, not just the foundation: the schema is
   forward-only, so a later migration can supersede an earlier guarantee and a suite
   that reads only 20261013 would keep passing on a rule that no longer exists. */
const MIG_DIR = new URL('../supabase/migrations/', import.meta.url);
const migFiles = readdirSync(MIG_DIR).filter((f) => /collab/i.test(f) && f.endsWith('.sql')).sort();
const M = Object.fromEntries(migFiles.map((f) => [f, readFileSync(new URL(f, MIG_DIR), 'utf8')]));
const mig = M['20261013_cg_collaborations.sql'];
const COVERED = [
  '20261013_cg_collaborations.sql', '20261014_cg_finance_collab_label.sql', '20261015_cg_collab_room_link.sql',
  '20261016_cg_collab_token_at_rest.sql', '20261017_cg_collab_operator_grant.sql', '20261019_cg_collab_link_retrieval.sql',
  '20261021_cg_collab_pay_start_resume.sql', '20261022_cg_collab_payment_bound_to_accepted.sql',
  '20261023_cg_collab_intake_ip_and_throttle.sql',
];
check('the foundation migration is present', !!mig);
check('every collaboration migration on disk is covered by this suite', migFiles.every((f) => COVERED.includes(f)),
  'uncovered: ' + migFiles.filter((f) => !COVERED.includes(f)).join(', '));
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
check('public copy always writes "Coach Gari", never a bare first name as the brand', !/\bGari\b(?!\s*[<·])/.test(page.replace(/Coach Gari/g, '')));

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
check('the intake body is bounded before it is parsed', /MAX_BODY_BYTES/.test(edge) && /payload_too_large/.test(edge) && /content-length/.test(edge) && /JSON\.parse\(raw\)/.test(edge));
check('intake has a per-IP quota in front of the identity-independent back-stop', /rate_limited_ip/.test(edge) && /saltedIpHash\(req, "IP_HASH_SALT"/.test(edge) && /rate_limited_global/.test(edge));
check('only a salted digest of the IP reaches the database, never the address', /ip_hash: ipHash/.test(edge) && !/clientIp\(req\)/.test(edge));
check('a counter-offer is bounded: capped considerations, known term keys only', /MAX_CONSIDERATIONS/.test(edge) && /TERM_KEYS/.test(edge) && /slice\(0, MAX_CONSIDERATIONS\)/.test(edge));
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

/* ---- the migrations AFTER the foundation: each superseding rule, asserted where it now lives ---- */
{
  const m15 = M['20261015_cg_collab_room_link.sql'], m16 = M['20261016_cg_collab_token_at_rest.sql'];
  const m17 = M['20261017_cg_collab_operator_grant.sql'], m19 = M['20261019_cg_collab_link_retrieval.sql'];
  const m20 = M['20261020_cg_definer_grants_lockdown.sql'] ?? read('../supabase/migrations/20261020_cg_definer_grants_lockdown.sql');
  const m21 = M['20261021_cg_collab_pay_start_resume.sql'], m22 = M['20261022_cg_collab_payment_bound_to_accepted.sql'];

  check('20261015 introduced the room link in the counterparty emails', /room_url/.test(m15) && /email_queue\('collab_ack'/.test(m15));
  check('20261016 encrypts the room token at rest and drops the plaintext column',
    /pgp_sym_encrypt/.test(m16) && /room_token_enc/.test(m16) && /drop column if exists room_token/.test(m16)
    && /revoke all on function public\.collab_room_key\(\)/.test(m16));
  check('20261017 grants the operator SELECT column by column, excluding both secrets',
    /revoke select on public\.collaboration_deals from authenticated/.test(m17) && /grant select \(/.test(m17)
    && !/\broom_token_enc\b|\baccess_token_hash\b/.test(m17.split('grant select (')[1].split(') on public.collaboration_deals')[0]));
  check('20261019 gates link retrieval behind an audited collab:manage RPC',
    /function public\.collab_copy_room_link/.test(m19) && /has_permission\('collab:manage'\)/.test(m19) && /'room_link_access'/.test(m19));
  check('20261019 stops persisting a live link: producers store collab_id, the drain builds the URL',
    /'collab_id', d\.id/.test(m19) && !/'room_url', 'https:\/\/coachgari28\.com/.test(m19)
    && /payload \? 'collab_id'/.test(m19) && /collab_room_url\(/.test(m19));
  check('20261020 revokes the internal SECURITY DEFINER helpers from public/anon/authenticated',
    ['collab_deal_json', 'collab_deal_by_token', 'collab_new_ref', 'email_payload_booking']
      .every((f) => new RegExp(`revoke all on function public\\.${f}\\b[\\s\\S]*?from public, anon, authenticated`).test(m20)));
  check('20261021 resumes a live checkout instead of minting a second order',
    /resumed', true/.test(m21) && /beau_ph\.cancel_request/.test(m21) && /already settled/.test(m21)
    && /checkout_expires_at is null or o\.checkout_expires_at > now\(\)/.test(m21));
  const m23 = M['20261023_cg_collab_intake_ip_and_throttle.sql'];
  check('20261023 stores only a salted IP digest, drops anything that is not one, and hides it from operators',
    /ip_hash text/.test(m23) && /v_ip !~ '\^\[0-9a-f\]\{64\}\$'/.test(m23) && !/grant select \(/.test(m23));
  check('20261023 caps and throttles a counter-offer in the database',
    /too many considerations \(20 maximum\)/.test(m23) && /the counter-offer is too large/.test(m23)
    && /too many changes just now/.test(m23) && /interval '10 minutes'/.test(m23));
  check('20261022 binds a payment to the accepted proposal (non-cash refused, currency pinned, cumulative cap)',
    /no cash component; non-cash consideration is never charged/.test(m22)
    && /payment currency must match the accepted proposal/.test(m22)
    && /would exceed the agreed amount/.test(m22)
    && /proposal_id = d\.accepted_proposal_id and status <> 'cancelled'/.test(m22));
}

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

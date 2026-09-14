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
  '20261023_cg_collab_intake_ip_and_throttle.sql', '20261034_cg_collab_workflow.sql', '20261038_cg_collab_close_delete_and_payment_state.sql',
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
check('collab.html headline is "Collaborate with me." — first person, like the rest of the site', /<h1[^>]*>Collaborate with me\.<\/h1>/.test(page));
check('the brand still carries the page for search and sharing, via <title>', /<title>[^<]*Coach Gari[^<]*<\/title>/.test(page));

/* collab.coachgari28.com is an alias to say out loud, not a second site. Everything on
   it lands on the one page at the apex. The checks that matter are that the rules are
   scoped by host — a source of /(.*) with no host condition would swallow the whole
   site — and that a room link typed against the subdomain keeps its token instead of
   dropping the visitor on the intake form. */
const vercel = JSON.parse(readFileSync(new URL('../vercel.json', import.meta.url), 'utf8'));
const SUB = 'collab.coachgari28.com';
const subRules = vercel.redirects.filter((r) => (r.has || []).some((h) => h.type === 'host' && h.value === SUB));
check('the subdomain has its redirect rules', subRules.length === 2, String(subRules.length));
check('every rule carrying a bare /(.*) source is scoped to a host',
  vercel.redirects.every((r) => r.source !== '/(.*)' || (r.has || []).some((h) => h.type === 'host')));
check('the catch-all sends the subdomain to the collab page',
  subRules.some((r) => r.source === '/(.*)' && r.destination === 'https://coachgari28.com/collab'));
check('a deal-room link on the subdomain keeps its token',
  subRules.some((r) => r.source === '/c/:token' && r.destination === 'https://coachgari28.com/c/:token'));
check('the token rule comes before the catch-all, or it would never be reached',
  vercel.redirects.findIndex((r) => r.source === '/c/:token') < vercel.redirects.findIndex((r) => r.source === '/(.*)'));
check('the redirects are temporary: /collab is noindex, and a cached 308 would block serving the page here later',
  subRules.every((r) => r.permanent === false));
check('no rule redirects the apex itself to the subdomain',
  !vercel.redirects.some((r) => String(r.destination).includes('//' + SUB)));

/* The page carries the site footer, not the plain document one: the wordmark and the
   bottom bar, lifted from index.html unchanged so the two cannot drift. What it does
   NOT carry is .f-top — three columns of home-page anchors, a newsletter form and the
   Support dialog, none of which exist on this page. */
const home = read('../index.html');
const lift = (src, re) => src.match(re)?.[0]?.replace(/\s+/g, ' ').trim();
const BOT = /<div class="f-bot">[\s\S]*?\n {4}<\/div>/;
check('collab carries the site footer', /<footer class="f-slim">/.test(page));
check('the wordmark is there', /<div class="wordmark">Coach Gari\.<\/div>/.test(page));
check('the bottom bar is the home one, unchanged', lift(page, BOT) === lift(home, BOT));
check('it does not drag in the home-page link columns', !/f-top|f-news|data-support-open/.test(page));
check('no dead home-page anchor is left in the footer', !/href="#(book|programme|about|contact|support)"/.test(page));
check('collab does not have to pull legal.css or site.js in for it',
  !/legal\.css/.test(page) && !/site\.js/.test(page));
check('the two config-driven footer links are resolved on this page',
  /data-config-href/.test(page) && /data-config-href/.test(read('../assets/collab.js')));
check('the page opens with the accent badge the rest of the site uses',
  /<span class="badge">Collaborations<\/span>/.test(page));
check('public copy always writes "Coach Gari", never a bare first name as the brand', !/\bGari\b(?!\s*[<·])/.test(page.replace(/Coach Gari/g, '')));

/* ---- edge function security ---- */
check('every non-intake action is token-gated before it runs', /if \(!isToken\(body\.token\)\) return json\(400/.test(edge) && edge.indexOf('isToken(body.token)') < edge.indexOf('action === "room"'));
check('token shape is validated (64 hex)', /\/\^\[0-9a-f\]\{64\}\$\//.test(edge));
check('intake has a honeypot and a minimum fill time', /body\.website/.test(edge) && /MIN_FILL_MS/.test(edge) && /too_fast/.test(edge));
check('intake has an identity-independent global back-stop', /GLOBAL_MAX/.test(edge) && /from\("collaboration_deals"\)\.select\("id", \{ count: "exact", head: true \}\)/.test(edge) && /rate_limited_global/.test(edge));
check('server validation is authoritative: only a reply channel is required (email or phone), the name is optional', !/fields: \["name"\]/.test(edge) && /Add an email or phone/.test(edge) && !/Please add your name/.test(pageJs));
check('the public form says so: every field optional, one way to reply', /Everything is optional, except one way to reply/.test(page) && /for="cl-name">Your name <span class="opt">optional<\/span>/.test(page));
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

  /* the workflow pass: polite decline, reminders, optional intake, whose move */
  const m34 = M['20261034_cg_collab_workflow.sql'];
  check('20261034 makes the intake name optional and keeps a reply channel mandatory',
    /alter column contact_name drop not null/.test(m34) && !/'name is required'/.test(m34) && /'an email or phone is required'/.test(m34));
  check('20261034 adds a polite admin decline that emails the requester once (deduped) and audits',
    /function public\.collab_admin_decline\(p_id uuid, p_note text/.test(m34) && /has_permission\('collab:manage'\)/.test(m34)
    && /email_queue\('collab_declined', d\.contact_email/.test(m34) && /':declined:coach'/.test(m34) && /'decline', e,/.test(m34));
  check('20261034 tells the owner when the counterparty declines from the room',
    /email_queue\('collab_declined', public\.email_owner_address\(\)/.test(m34) && /':declined:party'/.test(m34));
  check('20261034 reminders cover the four waits and are deduped per thing, never per run',
    /':reminder:proposal:' \|\| r\.version_number/.test(m34) && /':reminder:payment'/.test(m34)
    && /':reminder:owner:' \|\| r\.version_number/.test(m34) && /':reminder:owner:new'/.test(m34)
    && /is not null then n := n \+ 1/.test(m34));
  check('20261034 reminders run daily by pg_cron and are not callable by a browser role',
    /cron\.schedule\('cg-collab-reminders', '0 6 \* \* \*'/.test(m34)
    && /revoke all on function public\.collab_reminders\(interval\) from public, anon, authenticated/.test(m34));
  check('20261034 the email kind constraint carries the two new kinds', /'collab_declined','collab_reminder'\)\)/.test(m34));
  check('20261034 the admin list says whose move it is', /'waiting_on', case/.test(m34) && /then 'payment'/.test(m34) && /then 'them'/.test(m34) && /else 'you' end/.test(m34) && /'waiting_since'/.test(m34));
  const adminJs = read('../admin/collab.js'), adminCss = read('../admin/admin.css');
  check('admin: green agreed, violet in progress, red declined, grey closed',
    /\.cl-st\.st-agreed\{background:#e2f5e9/.test(adminCss) && /\.cl-st\.st-new,\.cl-st\.st-reviewing,\.cl-st\.st-negotiating\{background:#efe8fb/.test(adminCss)
    && /\.cl-st\.st-declined\{background:#fde7e5/.test(adminCss) && /\.cl-st\.st-closed\{background:#eef0f4/.test(adminCss) && /class="st cl-st /.test(adminJs));
  check('admin: Decline politely (with an optional personal line) sits next to Close, and Close sends nothing',
    /id="cl-decline">Decline politely/.test(adminJs) && /collab_admin_decline/.test(adminJs) && /p_note: note\.trim\(\) \|\| null/.test(adminJs) && /No email is sent/.test(adminJs));
  check('admin: the list shows whose move and for how long', /'Waiting on'/.test(adminJs) && /Your move/.test(adminJs) && /Their reply/.test(adminJs) && /waiting_since/.test(adminJs));
  const m38 = M['20261038_cg_collab_close_delete_and_payment_state.sql'];
  check('20261038 keeps the payment row in step with its order through a trigger (no more stale "waiting on payment")',
    /create trigger orders_collab_payment_sync after update of status on public\.orders/.test(m38) && /o\.status not in \('paid','partially_refunded','refunded'\)/.test(m38) && /then 'requested'/.test(m38));
  check('20261038 delete is collab:manage only and refuses a deal that collected money',
    /function public\.collab_admin_delete/.test(m38) && /has_permission\('collab:manage'\)/.test(m38) && /close it instead of deleting it/.test(m38) && /'delete', e,/.test(m38));
  check('admin: Close on every open deal (agreed included), Reopen only on closed/declined, Delete with the paid guard',
    /d\.status !== 'closed' \? `<button[^`]*id="cl-close"/.test(adminJs) && /\['closed', 'declined'\]\.includes\(d\.status\) \? `<button[^`]*id="cl-reopen"/.test(adminJs)
    && /collab_admin_delete/.test(adminJs) && /paidAny/.test(adminJs));
  check('room: same palette, and a settled room says so in one line',
    /\.cr-badge\.new, \.cr-badge\.negotiating, \.cr-badge\.reviewing \{ background: #EFE8FB/.test(room) && /\.cr-badge\.declined/.test(room)
    && /id="settled"/.test(room) && /declined: 'This collaboration was declined/.test(roomJs));
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
{   // the polite decline: courteous, quotes the personal line, leaves the door open; the owner flavour is internal
  const NOTE = 'Not this <i>season</i>, maybe next.';
  const r = render('collab_declined', { ...P, by: 'Coach Gari', note: NOTE });
  check('email collab_declined (requester) is courteous, quotes the note escaped, and leaves the door open',
    /Thank you/.test(r.html) && /not the right fit right now/.test(r.html) && r.html.includes('&lt;i&gt;season&lt;/i&gt;') && /coachgari28\.com\/collab/.test(r.html) && /Coach Gari/.test(r.html) && !/<b>Brand<\/b>/.test(r.html));
  const r2 = render('collab_declined', { ...P, by: 'Coach Gari', note: null });
  check('email collab_declined (requester) reads fine without a note', !/undefined|null/.test(r2.html) && !/border-left/.test(r2.html));
  const r3 = render('collab_declined', { ...P, by: 'counterparty', note: 'budget' });
  check('email collab_declined (owner) is internal: subject names the deal, no branded wrapper', /^Declined — CL-ABC123/.test(r3.subject) && !/Open your collaboration room/.test(r3.html) && /budget/.test(r3.text));
  const rp = render('collab_reminder', { ...P, about: 'proposal', expires_at: '2026-12-01T00:00:00Z' });
  check('email collab_reminder (proposal) nudges once, embeds the room link and the validity', /gentle nudge/.test(rp.html) && rp.html.includes(ROOM) && /valid until 1 December 2026/.test(rp.html) && /^Still there\?/.test(rp.subject));
  const rpay = render('collab_reminder', { ...P, about: 'payment' });
  check('email collab_reminder (payment) carries the amount and the room link', rpay.html.includes(ROOM) && /5,500\.00|5.500,00|AED/.test(rpay.html) && /payment waiting/.test(rpay.subject));
  const rc = render('collab_reminder', { ...P, about: 'counter' });
  const rn = render('collab_reminder', { ...P, about: 'new', name: null });
  check('email collab_reminder (owner) says whose move it is, internal style, and survives a missing name',
    /^Your move — collaboration CL-ABC123/.test(rc.subject) && /counter-offer #2/.test(rc.text) && !/Open your collaboration room/.test(rc.html)
    && /enquiry from someone/.test(rn.text) && !/<b>Brand<\/b>/.test(rc.html));
  const rr = render('collab_received', { ...P, name: null, company: 'ACME' });
  check('email collab_received falls back to the company when no name was given', /— ACME$/.test(rr.subject));
}

console.log(`\nCOLLAB_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

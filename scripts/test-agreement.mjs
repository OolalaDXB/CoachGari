#!/usr/bin/env node
/* The signed agreement — offline (no network, no database, no reader).
   Builds a real PDF from a fixture and checks the file is a file: a valid
   header, an xref whose offsets actually point at their objects, the page count
   the catalogue claims. Then checks the things that make it evidence rather
   than a printout — determinism, the two hashes, and what the document is
   allowed to claim about the signature.
   Run: node --experimental-strip-types scripts/test-agreement.mjs */
import { readFileSync } from 'node:fs';
import { buildAgreement, canonical, sha256hex, money } from '../supabase/functions/_shared/agreement.ts';
import { wrap, latin1, renderPdf } from '../supabase/functions/_shared/pdf.ts';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const fn = read('../supabase/functions/agreement/index.ts');
const mig = read('../supabase/migrations/20261043_cg_collab_agreement.sql');
const mig2 = read('../supabase/migrations/20261044_cg_agreement_issue.sql');
const doc = read('../supabase/functions/_shared/agreement.ts');
const admin = read('../admin/admin.js');
const adminCollab = read('../admin/collab.js');

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const SNAP = {
  deal: {
    id: '11111111-1111-4111-8111-111111111111', public_ref: 'CL-0E3014',
    company: 'Café Noël Sportswear FZ-LLC', contact_name: 'Amélie Rousseau',
    contact_email: 'amelie@example.com', contact_phone: '+971500000000',
    collaboration_type: 'brand_partnership', title: 'Padel capsule launch',
    location: 'Dubai Sports City', proposed_date_from: '2026-11-02', proposed_date_to: '2026-11-09',
  },
  proposal: {
    id: '22222222-2222-4222-8222-222222222222', version_number: 3,
    intro: 'Coach Gari will front the padel capsule launch across two shoot days and one live clinic. '.repeat(4),
    monetary_amount: 4500000, currency: 'AED',
    considerations: [
      { type: 'monetary', description: 'Appearance fee, two shoot days', amount: 3000000, currency: 'AED' },
      { type: 'non_cash', description: 'Full capsule wardrobe and two racquets', estimated_value: 750000, estimated_value_currency: 'AED' },
    ],
    terms: {
      deliverables: 'Two shoot days, one 90-minute clinic, four in-feed posts and eight stories. '.repeat(3),
      timing: 'Between 2 and 9 November 2026, dates confirmed no later than 14 days beforehand.',
      usage_rights: 'Organic and paid social for twelve months in the GCC. Out-of-home excluded.',
      exclusivity: 'No competing padel apparel brand for the term plus sixty days.',
      territory: 'United Arab Emirates, Saudi Arabia, Qatar.',
      payment_terms: 'Fifty per cent on signature, the balance within thirty days of the final delivery.',
      additional: '',
    },
    accepted_at: '2026-09-14T11:22:33.000Z',
    accepted_evidence: { by: 'counterparty', method: 'room_link', ip_hash: 'a'.repeat(64), user_agent: 'Mozilla/5.0 (iPhone)' },
  },
  org: {
    legal_name: 'Gari Coaching FZ-LLC', trading_name: 'Coach Gari', licence_no: 'RAKEZ-1234567',
    jurisdiction: 'RAK Economic Zone, United Arab Emirates', address: 'RAKEZ Business Zone, Ras Al Khaimah, UAE',
    email: 'collab@coachgari28.com', website: 'coachgari28.com',
  },
};

const built = await buildAgreement(SNAP);
const bytes = built.bytes;
const text = Buffer.from(bytes).toString('latin1');

/* ---- it is a PDF ---- */
check('the file starts as a PDF and ends where it says', text.startsWith('%PDF-1.4\n') && text.trimEnd().endsWith('%%EOF'));
check('there is an xref table and a startxref that points at it', (() => {
  const m = text.match(/startxref\n(\d+)\n%%EOF/);
  return !!m && text.slice(Number(m[1]), Number(m[1]) + 4) === 'xref';
})());
check('every xref offset lands on the object it claims', (() => {
  const m = text.match(/startxref\n(\d+)\n/);
  const table = text.slice(Number(m[1]));
  const rows = [...table.matchAll(/^(\d{10}) 00000 n $/gm)].map((r) => Number(r[1]));
  return rows.length > 0 && rows.every((off, i) => text.startsWith(`${i + 1} 0 obj`, off));
})(), 'an offset is wrong — readers will refuse the file');
check('the page tree count matches the pages actually written', (() => {
  const count = Number((text.match(/\/Type \/Pages \/Count (\d+)/) || [])[1]);
  const pages = (text.match(/\/Type \/Page\b/g) || []).length;
  return count > 0 && count === pages;
})());
check('a long agreement runs to more than one page rather than off the bottom',
  Number((text.match(/\/Count (\d+)/) || [])[1]) >= 2);
check('every content stream declares its true length',
  [...text.matchAll(/<< \/Length (\d+) >>\nstream\n([\s\S]*?)\nendstream/g)].every((m) => Number(m[1]) === m[2].length));
check('the file is a sensible size for a contract', bytes.length > 2000 && bytes.length < 200000, String(bytes.length));

/* ---- it is the same file every time ---- */
const again = await buildAgreement(SNAP);
check('rendering twice produces identical bytes — the hash keeps meaning something',
  Buffer.from(again.bytes).equals(Buffer.from(bytes)));
check('nothing in the writer reads the clock or a random source',
  !/Date\.now\(\)|new Date\(\)|Math\.random|crypto\.getRandomValues/.test(read('../supabase/functions/_shared/pdf.ts')));
check('the creation date comes from the acceptance, not from today',
  text.includes('D:20260914112233Z'));

/* ---- the two hashes ---- */
check('the record hash covers the terms', await (async () => {
  const changed = structuredClone(SNAP);
  changed.proposal.terms.exclusivity = 'None.';
  const b = await buildAgreement(changed);
  return b.recordHash !== built.recordHash;
})());
check('the record hash covers the moment of acceptance', await (async () => {
  const changed = structuredClone(SNAP);
  changed.proposal.accepted_at = '2026-09-15T11:22:33.000Z';
  const b = await buildAgreement(changed);
  return b.recordHash !== built.recordHash;
})());
check('the record hash ignores the letterhead — a new address is not a new agreement', await (async () => {
  const changed = structuredClone(SNAP);
  changed.org.address = 'Somewhere else entirely';
  const b = await buildAgreement(changed);
  return b.recordHash === built.recordHash;
})());
check('the canonical record is stable whatever order the keys arrive in', (() => {
  const shuffled = { org: SNAP.org, proposal: SNAP.proposal, deal: SNAP.deal };
  return canonical(shuffled) === canonical(SNAP);
})());
check('the record hash is printed in the document', text.includes(built.recordHash));
check('the file hash is a different thing from the record hash',
  (await sha256hex(bytes)) !== built.recordHash);

/* ---- what it says ---- */
check('the counterparty and the coach are both named',
  text.includes('Gari Coaching FZ-LLC') && text.includes('Cafe Noel Sportswear FZ-LLC'));
check('accents are folded, never written as a different letter',
  latin1('Amélie Rousseau') === 'Amelie Rousseau' && !text.includes('Am\xE9lie'));
check('the fee is shown with its currency and its thousands separated', text.includes('AED 45,000.00'));
check('an in-kind item is not presented as money payable',
  text.includes('In kind') && /estimate recorded for the parties/.test(text));
check('the reference and the version are on the document', text.includes('CL-0E3014') && text.includes('Version 3'));
check('an empty term is left out rather than printed blank', !/\(Additional terms\)/.test(text));
check('the acceptance is timestamped in both the local zone and UTC',
  text.includes('2026-09-14T11:22:33.000Z') && /Asia\/Dubai/.test(text));
// parentheses are escaped inside a PDF string, and a long hash wraps across lines
check('the device and the network identity are recorded',
  /Mozilla\/5\.0 \\\(iPhone\\\)/.test(text) && text.includes('a'.repeat(24)));
check('the IP hash is described as one-way, not as an address', /cannot be reversed/.test(text));

/* ---- what it must not claim ---- */
check('the UAE electronic transactions law is cited by name',
  /Federal Decree-Law No. 46 of 2021/.test(text));
check('it says plainly that this is NOT a qualified electronic signature',
  /not a Qualified Electronic Signature/.test(text));
check('it does not pretend to carry an accredited certificate',
  !/certified by|accredited certificate attached|qualified certificate issued to/i.test(text));
check('the governing law names the jurisdiction from the letterhead',
  /governed by the laws of the United Arab Emirates/.test(text) && text.includes('RAK Economic Zone'));
check('the overclaiming risk is written down in the source, not just avoided',
  /Overclaiming the legal weight/.test(doc));

/* ---- the plumbing ---- */
check('the key is checked before a record is even read',
  /agreement_authorize/.test(fn) && fn.indexOf('agreement_authorize') < fn.indexOf('collab_agreement_snapshot'));
check('the renderer decides nothing: terms, moment and evidence all come from the database',
  /collab_agreement_snapshot/.test(fn) && !/Date\.now\(\)|new Date\(\)\.toISOString/.test(fn));
check('storing is idempotent on the deal and the accepted version',
  /unique \(collaboration_id, proposal_id\)/.test(mig) && /on conflict \(collaboration_id, proposal_id\) do nothing/.test(mig));
check('a second render can never replace a signed document',
  /already has a signed agreement/.test(mig2) && /if exists \(select 1 from public\.collaboration_agreements where collaboration_id = p_collab\) then return null/.test(mig2));
check('only a PDF can be stored under the name of an agreement', /that is not a PDF/.test(mig) && /x255044462d/.test(mig));
check('the bytes are never handed out by a plain select',
  /grant select \(id, collaboration_id, proposal_id, version_number, record_sha256, byte_size, signed_at, created_at\)/.test(mig)
  && !/grant select on public\.collaboration_agreements/.test(mig));
check('downloading a contract is audited as an act', /'agreement', p_collab::text, 'download'/.test(mig));
check('the write RPCs belong to service_role alone',
  ['collab_agreement_snapshot', 'collab_agreement_record', 'collab_agreement_for_token']
    .every((f) => new RegExp(`revoke execute on function public\\.${f}\\b[^;]*from public, anon, authenticated`).test(mig)));
check('both sides of an acceptance produce a document, because the hook is on the fact',
  /after update of accepted_proposal_id on public\.collaboration_deals/.test(mig2));
check('the letterhead is stored as it was at signature, not as it is now', /org_snapshot/.test(mig));

/* ---- the screens ---- */
check('the back-office can download the agreement and check it',
  /rpc\('collab_agreement_get'/.test(adminCollab) && /rpc\('collab_agreement_status'/.test(adminCollab));
check('the bytes become a file in the browser, never a URL that can be forwarded',
  /URL\.createObjectURL/.test(adminCollab) && /revokeObjectURL/.test(adminCollab) && !/createSignedUrl/.test(adminCollab));
check('the screen does not overclaim the signature either',
  /not a qualified electronic signature/i.test(adminCollab));
check('the letterhead is editable where the rest of the settings live', /rpc\('org_profile_set'/.test(admin));

/* ---- the writer's own edges ---- */
check('a word longer than the line is broken, not overflowed',
  wrap('x'.repeat(400), 10.5, false, 200).every((l) => l.length < 400));
check('a blank paragraph survives as a blank line', wrap('a\n\nb', 10.5, false, 400).length === 3);
check('money refuses a missing currency rather than inventing one', money(1000, '') === '' && money(null, 'AED') === '');
check('an empty document still renders a valid file',
  (() => { const b = renderPdf({ title: 't', author: 'a', subject: 's', date: new Date(0), footer: 'f', blocks: [] });
           return Buffer.from(b).toString('latin1').trimEnd().endsWith('%%EOF'); })());

console.log(`\nAGREEMENT_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

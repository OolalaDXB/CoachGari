#!/usr/bin/env node
/* Payment links — the properties that must hold in the SOURCE, checked offline.

   A payment link is the first kind of money here that hangs off nothing: no
   booking, no package, often no client. That removes the safety rails the
   other flows lean on, so the ones that remain are worth pinning:

     * the amount is never taken from the request body — the coach wrote it
       into a row and only that row may price the Checkout Session;
     * the reference and the token are shape-checked before anything reaches
       the database;
     * the response cannot carry a Stripe secret;
     * the payer's page reads its credentials from the path, never from a
       query string that an ad network or a referrer header would carry away.

   Offline on purpose: these are properties of the code, and a suite that
   needs the network cannot run in CI or in a sandbox. Run:
     node scripts/test-paylink.mjs     (exit 1 on any failure)                */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fn = readFileSync(join(ROOT, 'supabase/functions/paylink/index.ts'), 'utf8');
const page = readFileSync(join(ROOT, 'pay.html'), 'utf8');
const pageJs = readFileSync(join(ROOT, 'assets/pay.js'), 'utf8');
const mig = readFileSync(join(ROOT, 'supabase/migrations/20261074_cg_payment_links.sql'), 'utf8');
const vercel = JSON.parse(readFileSync(join(ROOT, 'vercel.json'), 'utf8'));

let ok = 0, fail = 0; const log = [];
const check = (name, cond, note) => {
  if (cond) { ok++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${note ? ' — ' + note : ''}`); log.push(name); }
};

/* ---- the amount comes from the row, not from the caller ---- */
check('The Checkout amount is read from the DB row, not the request body',
  /amount:\s*Number\(request\.amount\)/.test(fn) && !/amount:\s*Number\(body\./.test(fn));
check('The currency is read from the DB row too',
  /currency:\s*String\(request\.currency\)/.test(fn));
check('The function never reads an amount off the body at all',
  !/body\.amount/.test(fn));

/* ---- credentials are shape-checked before the database sees them ---- */
check('The reference is matched against its exact shape', /REF_RE\s*=\s*\/\^PL-\[A-Z0-9\]\{6\}\$\//.test(fn));
check('The token must be 64 hex characters', /TOK_RE\s*=\s*\/\^\[0-9a-f\]\{64\}\$\//.test(fn));
check('A malformed reference or token is refused before any RPC',
  fn.indexOf('if (!reference || !token) return json(400') < fn.indexOf('createClient('));

/* ---- nothing secret leaves ---- */
check('The reply is scanned for provider secrets before it is sent', /SECRET_VALUE_RE\.test\(JSON\.stringify\(\{ \.\.\.reply/.test(fn));
check('The secret pattern covers live and test keys and webhook secrets',
  /sk\|rk/.test(fn) && /whsec_/.test(fn));

/* ---- the payer's page ---- */
check('The page takes its reference and token from the path', /location\.pathname\.split/.test(pageJs));
check('The page does not read the token from the query string', !/searchParams\.get\(['"]t['"]\)/.test(page));
check('The page re-asks the server after the Stripe redirect instead of trusting it',
  /q\.get\('paid'\)/.test(pageJs) && /action: 'state'/.test(pageJs));
check('The page never announces "paid" on the redirect alone',
  /l\.state === 'paid'/.test(pageJs));

/* ---- the page can actually run --------------------------------------
   The site's CSP is `script-src 'self'` with no 'unsafe-inline'. An inline
   module is refused by the browser without a word in the page, which leaves the
   markup's own loading text on screen for ever — which is how the first real
   payment link looked to the person holding it. These two assertions are the
   cheapest possible guard against repeating it. */
check('The page carries no inline script — the CSP refuses them', !/<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>/i.test(page));
check('It loads its module from a file instead', /<script[^>]+src="\/assets\/pay\.js"/.test(page));
check('A failure says something rather than leaving the loading text up', /start\(\)\.catch\(/.test(pageJs));

/* ---- the route is private ---- */
check('/pay/<ref>/<token> is rewritten to the page',
  (vercel.rewrites || []).some((r) => r.source === '/pay/:reference/:token' && r.destination === '/pay'));
const payHeaders = (vercel.headers || []).find((h) => h.source === '/pay/(.*)');
check('The route is noindex', !!payHeaders && payHeaders.headers.some((h) => h.key === 'X-Robots-Tag' && /noindex/.test(h.value)));
check('The route is never cached', !!payHeaders && payHeaders.headers.some((h) => h.key === 'Cache-Control' && /no-store/.test(h.value)));

/* ---- the database side ---- */
check('A payment link order carries no booking and no pack',
  /order_reason in \('support','collaboration','payment_link'\)\s*\n\s*and booking_id is null and session_pack_id is null/.test(mig));
check('Creating a link requires finance:manage', /has_permission\('finance:manage'\)/.test(mig));
check('A label is required — it is what the payer reads', /a label is required/.test(mig));
check('The amount has a floor and a ceiling', /p_amount < 1000/.test(mig) && /p_amount > 5000000/.test(mig));
check('The token is stored only as a sha256', /digest\(tok, 'sha256'\)/.test(mig) && !/values \([^)]*tok[,)]/.test(mig));
check('Withdrawing a link also cancels the request behind it', /beau_ph\.cancel_request/.test(mig));
check('A paid link cannot be withdrawn', /this link has been paid/.test(mig));
check('The card rail opts in to the `other` intent explicitly', /"intents":\["service","package","support","other"\]/.test(mig));

console.log(`\nPAYLINK_TESTS ok=${ok} fail=${fail}${log.length ? '\n' + log.join('\n') : ''}`);
process.exit(fail ? 1 : 0);

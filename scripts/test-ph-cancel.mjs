#!/usr/bin/env node
/* Provider cancellation — offline checks on the drain (no network, no secrets).

   The queue's behaviour is proved in the database by beau_ph_contract.sql §22.
   What is asserted here is the boundary of the Edge Function that delivers it:
   the key gate comes first, the only thing ever cancelled is what the queue
   returned, a provider reference never reaches a log, and a rail that cannot be
   retried into working is skipped rather than counted to five.

   Run: node scripts/test-ph-cancel.mjs */
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const fn = read('../supabase/functions/ph-cancel/index.ts');
const mig = read('../supabase/migrations/20261049_beau_ph_provider_cancellations.sql');
const stripe = read('../beau-ph/providers/stripe/adapter.ts');
const finance = read('../admin/finance.js');

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

/* ---- the gate ---- */
check('the key is checked before any provider is touched',
  /ph_cancel_authorize/.test(fn) && fn.indexOf('ph_cancel_authorize') < fn.indexOf('cancellations_due'));
check('an unauthorised call gets 401 and nothing else', /authorized !== true.*401/s.test(fn));
check('only POST is served', /req\.method !== "POST"\) return json\(405/.test(fn));
check('the body is JSON or the call is refused', /invalid_json/.test(fn));
check('only the drain action is accepted', /body\.action !== "drain"/.test(fn));

/* ---- what may be cancelled ---- */
check('the reference cancelled is the queue’s, never the caller’s',
  /a\.cancel\(r\.provider_reference, env\)/.test(fn) && !/body\.(provider_reference|reference|request|order)/.test(fn));
check('the queue is the only source of work', /rpc\("cancellations_due"/.test(fn) && !/from\("payment_requests"\)/.test(fn));
check('a paid request can never be queued: only cancelled and expired are',
  /new\.status not in \('cancelled','expired'\)/.test(mig));
check('one request is queued once', /unique references beau_ph\.payment_requests/.test(mig) && /on conflict \(request_id\) do nothing/.test(mig));

/* ---- secret hygiene ---- */
check('no provider reference, key or secret ever reaches a log',
  [...fn.matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]).every((l) => !/reference|key|Key|secret|token/.test(l)));
check('the source carries no credential', !/(sk|rk|pk)_(live|test)_|whsec_/.test(fn));
check('the drain never reads a provider credential itself — the adapter does',
  !/STRIPE_SECRET_KEY|PAYPAL_SECRET/.test(fn) && /STRIPE_SECRET_KEY/.test(stripe));

/* ---- what it does with an answer ---- */
check('a rail with no cancel is skipped with the reason, not retried',
  /typeof a\.cancel !== "function"/.test(fn) && /p_skip: true/.test(fn));
check('a rail whose deployment is not configured is skipped, not retried',
  /a\.runtime\(env\)\.configured/.test(fn) && (fn.match(/p_skip: true/g) || []).length >= 2);
check('a provider that says the session is already gone is success, not failure',
  /\\b\(404\|410\)\\b/.test(fn) || /404\|410/.test(fn));
check('a failure is recorded and retried, and gives up after five',
  /attempts \+ 1 >= 5 then 'failed'/.test(mig) && /attempts < 5/.test(mig));
check('a settled row is never reopened by a later mark', /if c\.status <> 'pending' then return to_jsonb\(c\); end if;/.test(mig));

/* ---- only rails that actually have a cancel are queued ---- */
check('the database mirrors the adapter’s supports.cancel',
  /supports_cancel/.test(mig) && /supports_cancel = \(key = 'stripe'\)/.test(mig));
check('and Stripe is indeed the adapter that supports it',
  /cancel: true/.test(stripe) && /checkout\/sessions\/\$\{encodeURIComponent\(providerReference\)\}\/expire/.test(stripe));

/* ---- the operator is told when it could not be delivered ---- */
check('Finance surfaces what could not be closed', /ph_cancellations_open/.test(finance) && /could not be closed at the provider/.test(finance));
check('and only what has actually given up, not what is still being retried',
  /filter\(\(c\) => c\.status === 'failed'\)/.test(finance));
check('the operator view is behind finance:view', /has_permission\('finance:view'\)/.test(mig.slice(mig.indexOf('ph_cancellations_open'))));

console.log(`\nPH_CANCEL_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

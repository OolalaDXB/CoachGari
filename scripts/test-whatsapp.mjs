#!/usr/bin/env node
/* WhatsApp rail — offline checks (no network, no secrets, no account).
   Reads the Edge Function and the migration as text and asserts the boundary:
   the key gate runs before anything, a phone number never reaches a log, the
   message can only be a template approved in the Meta console, and a rail that
   is not connected drops a time-bound reminder instead of hoarding it.
   Run: node scripts/test-whatsapp.mjs */
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const fn = read('../supabase/functions/whatsapp-outbox/index.ts');
const mig = read('../supabase/migrations/20261041_cg_session_reminders_notes.sql');
const email = read('../supabase/functions/_shared/email.ts');
const admin = read('../admin/admin.js');

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

/* ---- the gate ---- */
check('the key is checked before the provider credentials are even read',
  /whatsapp_outbox_authorize/.test(fn) && fn.indexOf('whatsapp_outbox_authorize') < fn.indexOf('WHATSAPP_TOKEN'));
check('an unauthorised call gets 401 and nothing else', /authorized !== true.*401/s.test(fn));
check('only POST is served', /req\.method !== "POST"\) return json\(405/.test(fn));
check('the status action reports presence, never a value',
  /configured = !!token && !!phoneId/.test(fn) && !/json\(200, \{ ok: true, configured, token/.test(fn));

/* ---- secrets and privacy ---- */
check('the credentials come from the environment, never from the body or the database',
  /env\("WHATSAPP_TOKEN"\)/.test(fn) && /env\("WHATSAPP_PHONE_NUMBER_ID"\)/.test(fn) && !/body\.(token|phone|to)/.test(fn));
check("a client's phone number never reaches a log",
  [...fn.matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]).every((l) => !/phone|to_phone|to:|number/i.test(l)));
check('a provider error is reported by status, never by echoing its body',
  /whatsapp \$\{res\.status\}/.test(fn) && !/await res\.text\(\)/.test(fn));
check('no credential is hard-coded', !/EAA[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9]{20,}/.test(fn));

/* ---- what it may send ---- */
// "type: text" is legitimate INSIDE a template parameter; what must not exist is a
// free-text message, which the Cloud API would only accept inside a 24-hour window.
check('only a template message is sent — business-initiated WhatsApp allows nothing else',
  /type: "template"/.test(fn) && !/type: "text",\s*text: \{/.test(fn)
  && (fn.match(/type: "text"/g) || []).length === 1 && /parameters: params/.test(fn));
check('the template name and its parameters come from the row, never from this file',
  /name: r\.template/.test(fn) && /r\.params/.test(fn));
check('parameters are stringified positionally, as the Cloud API expects',
  /\{ type: "text", text: String\(t\) \}/.test(fn));

/* ---- not connected ---- */
check('an unconnected rail skips the row with a reason instead of holding it',
  /if \(!configured\)/.test(fn) && /p_status: "skipped", p_error: "WhatsApp is not connected"/.test(fn));
check('the reason why holding is wrong is written down, not just done',
  /time-bound|already happened in the past|happened in the past/i.test(fn));

/* ---- the database side ---- */
check('the drain key is hashed at rest and clear only in Vault',
  /vault\.create_secret\(k, 'outbox_whatsapp_key'/.test(mig) && /key_sha256\) values \('whatsapp', extensions\.digest\(k, 'sha256'\)\)/.test(mig) && /ct_bytea_eq/.test(mig));
check('the rail RPCs are revoked from anon and from signed-in operators',
  ['whatsapp_queue', 'whatsapp_due', 'whatsapp_mark', 'whatsapp_outbox_kick', 'whatsapp_outbox_authorize', 'session_reminders']
    .every((f) => new RegExp(`revoke execute on function public\\.${f}\\b[^;]*from public, anon, authenticated`).test(mig)));
check('WhatsApp needs an explicit yes, and a phone number alone is never it',
  /whatsapp_opt_in\s+boolean not null default false/.test(mig) && /if r\.whatsapp_opt_in and r\.phone_norm is not null/.test(mig));
check('a person can turn every reminder off, on every channel',
  /reminders_opt_out boolean not null default false/.test(mig) && /and not c\.reminders_opt_out/.test(mig));
check('the opt-in records when and by whom', /whatsapp_opt_in_at/.test(mig) && /whatsapp_opt_in_by/.test(mig));
check('one reminder per session, ever: the dedupe key names the session and nothing else',
  /v_key := 'session:' \|\| r\.id \|\| ':reminder';/.test(mig)
  && !/v_key := [^;]*(now\(\)|current_date|clock_timestamp)/.test(mig));
check('the two channels are separate rows, so one failing never blocks the other',
  /v_key \|\| ':email'/.test(mig) && /v_key \|\| ':whatsapp'/.test(mig));
check('only a scheduled session in the window is reminded',
  /s\.status = 'scheduled'/.test(mig) && /s\.start_at > now\(\)/.test(mig) && /s\.start_at <= now\(\) \+ coalesce\(p_lead/.test(mig));
check('a failure is retried twice and then left alone with its error',
  /attempts < 2 then 'pending'/.test(mig) && /interval '5 minutes'/.test(mig));
check('the log carries a phone number, so reading it is a client-profile act',
  /whatsapp_events_view on public\.whatsapp_events for select to authenticated\s*\n?\s*using \(public\.has_permission\('client_profile:view'\)\)/.test(mig));

/* ---- the note ---- */
check('the one-line note needs the permission that writes a history, not the one that moves a diary',
  /has_permission\('coach:operations'\)/.test(mig) && /has_permission\('client_profile:manage'\)/.test(mig));
check('the note is linked to its session, so the history says which one',
  /crm_notes add column if not exists session_id/.test(mig) && /insert into public\.crm_notes \(crm_contact_id, session_id/.test(mig));
check('a note is one line, not an essay', /length\(v_body\) > 500/.test(mig));

/* ---- the screen ---- */
check('the Overview closes a session without opening anything',
  /rpc\('sessions_to_close'/.test(admin) && /rpc\('session_set_status', \{ p_id: id, p_status: status/.test(admin));
check('the line typed on the card is saved before the status changes it out of the list',
  /if \(!await saveNote\(\)\) return;/.test(admin));
check('the reminder switches are on the client, where the consent belongs',
  /rpc\('contact_messaging_set'/.test(admin) && /A number on file is not consent/.test(admin));
check('the reminder e-mail exists and reads like a reminder',
  /case "session_reminder"/.test(email) && /See you tomorrow/.test(email));

console.log(`\nWHATSAPP_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

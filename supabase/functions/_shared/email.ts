/* =============================================================
   Coach Gari — transactional email (Resend) shared by the Edge Functions.

   Sender    EMAIL_FROM      = Coach Gari <yoursession@coachgari28.com>
   Reply-To  EMAIL_REPLY_TO  = letsgo@coachgari28.com
   Key       RESEND_API_KEY  (server-side only; never logged, never returned)

   Nothing here decides WHETHER an email is due: the database queues rows in
   public.email_events from the authoritative state change (payment
   reconciled, confirmed booking cancelled / rescheduled, enquiry stored),
   each with a dedupe key. This module only DRAINS the queue:
     claim (leased rows, attempts+1) → render → Resend → result (sent / retry / failed)
   A send failure is a row state, never an exception that could reach the
   caller's booking / payment flow. The Resend Idempotency-Key is the row's
   dedupe key, so even a retried send after a lost response cannot double.

   No Deno API in this file: it is imported by the functions AND run by
   scripts/test-email.mjs under Node.
   ============================================================= */

export type Env = (name: string) => string | undefined;
export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export const DEFAULT_FROM = "Coach Gari <yoursession@coachgari28.com>";
export const DEFAULT_REPLY_TO = "letsgo@coachgari28.com";
const RESEND_API = "https://api.resend.com";

export type EmailConfig = { ready: boolean; missing: string[]; from: string; replyTo: string; hasKey: boolean };
/** "Name <addr>" from whatever shape the secret was stored in (a bare address, a stray ">", a missing name → "Coach Gari <addr>"). */
export function normaliseFrom(raw: string, fallback = DEFAULT_FROM): string {
  const s = (raw ?? "").trim();
  if (!s) return fallback;
  const addr = s.match(/[^\s<>"']+@[^\s<>"']+\.[^\s<>"']{2,}/)?.[0];
  if (!addr) return fallback;
  const name = s.replace(addr, "").replace(/[<>"']/g, "").trim();
  return `${name || "Coach Gari"} <${addr.toLowerCase()}>`;
}
export function emailConfig(env: Env): EmailConfig {
  const key = (env("RESEND_API_KEY") ?? "").trim();
  const from = normaliseFrom(env("EMAIL_FROM") ?? "");
  const replyTo = ((env("EMAIL_REPLY_TO") ?? "").trim().match(/[^\s<>"']+@[^\s<>"']+\.[^\s<>"']{2,}/)?.[0] ?? DEFAULT_REPLY_TO).toLowerCase();
  const missing = [!key && "RESEND_API_KEY", !(env("EMAIL_FROM") ?? "").trim() && "EMAIL_FROM", !(env("EMAIL_REPLY_TO") ?? "").trim() && "EMAIL_REPLY_TO"].filter(Boolean) as string[];
  return { ready: !!key, missing, from, replyTo, hasKey: !!key };
}
export const fromDomain = (from: string) => (from.match(/@([^>\s]+)/)?.[1] ?? "").toLowerCase();

/* ---- rendering --------------------------------------------- */
export type Payload = Record<string, unknown>;
export type Rendered = { subject: string; html: string; text: string };
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const str = (p: Payload, k: string, d = "") => (typeof p[k] === "string" || typeof p[k] === "number") ? String(p[k]) : d;
const firstName = (p: Payload) => str(p, "name").trim().split(/\s+/)[0] || "there";
export function whenParts(iso: string, tz: string): { date: string; time: string } {
  try {
    const d = new Date(iso);
    return { date: new Intl.DateTimeFormat("en-GB", { dateStyle: "full", timeZone: tz }).format(d),
             time: new Intl.DateTimeFormat("en-GB", { timeStyle: "short", timeZone: tz }).format(d) };
  } catch { return { date: iso, time: "" }; }
}
export function money(minor: unknown, cur: unknown): string {
  const n = Number(minor); const c = String(cur ?? "").toUpperCase();
  if (!Number.isFinite(n) || !c) return "";
  try { return new Intl.NumberFormat("en-GB", { style: "currency", currency: c }).format(n / 100); } catch { return `${c} ${(n / 100).toFixed(2)}`; }
}
const method = (p: Payload) => ({ stripe: "card", aani: "Aani", bank_transfer: "bank transfer", cash: "cash" } as Record<string, string>)[str(p, "method")] ?? str(p, "method", "card");

// the prepared templates (emails/session-*.html), as functions: same markup, same tone
const wrap = (eyebrow: string, title: string, body: string) => `<div style="font-family:system-ui,-apple-system,sans-serif;font-size:16px;line-height:1.6;color:#0A0A0B;max-width:560px;margin:0 auto;padding:32px 24px">
  <p style="margin:0 0 20px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6C6C78">Coach Gari · ${esc(eyebrow)}</p>
  <h1 style="margin:0 0 16px;font-size:26px;letter-spacing:-.02em;line-height:1.15">${title}</h1>
  ${body}
  <p style="margin:24px 0 0;font-size:13px;color:#6C6C78">Coach Gari · coachgari28.com</p>
</div>`;
const row = (k: string, v: string, bold = false) => `<tr><td style="padding:8px 0;color:#6C6C78;width:110px;vertical-align:top">${esc(k)}</td><td style="padding:8px 0;${bold ? "font-weight:700" : ""}">${esc(v)}</td></tr>`;
const table = (rows: string) => `<table style="border-collapse:collapse;width:100%;margin:0 0 24px;font-size:15px">${rows}</table>`;
const replyNote = (t: string) => `<p style="margin:0 0 8px;font-size:14px;color:#6C6C78">${esc(t)} Just reply to this email — it reaches Coach Gari directly.</p>`;

function sessionRows(p: Payload, whenLabel = "When") {
  const w = whenParts(str(p, "start_at"), str(p, "timezone", "UTC"));
  const dur = str(p, "duration_minutes"); const where = str(p, "where");
  return { w, html: row("What", str(p, "service_title"), true) + row(whenLabel, `${w.date} · ${w.time} (${str(p, "timezone")})`, true)
                    + (dur ? row("How long", `${dur} min`) : "") + (where ? row("Where", where) : "") + row("Reference", str(p, "reference")),
           text: [`What: ${str(p, "service_title")}`, `${whenLabel}: ${w.date} · ${w.time} (${str(p, "timezone")})`, dur ? `How long: ${dur} min` : "", where ? `Where: ${where}` : "", `Reference: ${str(p, "reference")}`].filter(Boolean).join("\n") };
}

export function render(kind: string, p: Payload): Rendered {
  switch (kind) {
    case "booking_confirmed": {
      const s = sessionRows(p);
      return { subject: `You're booked — ${str(p, "service_title")}, ${s.w.date}`,
        html: wrap("Confirmation", `You're booked, ${esc(firstName(p))}.`,
          `<p style="margin:0 0 20px">Here's your session. Put it in your calendar and Coach Gari will see you there.</p>${table(s.html)}${replyNote("Need to move it?")}`),
        text: `You're booked, ${firstName(p)}.\n\n${s.text}\n\nNeed to move it? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "reschedule": {
      const s = sessionRows(p, "Now");
      const prev = whenParts(str(p, "previous_start_at"), str(p, "previous_timezone", str(p, "timezone", "UTC")));
      return { subject: `Change to your session — ${str(p, "service_title")}`,
        html: wrap("Update", `Your session has moved, ${esc(firstName(p))}.`,
          `<p style="margin:0 0 20px">It was ${esc(prev.date)} · ${esc(prev.time)}. Here are the new details.</p>${table(s.html)}${replyNote("If the new time doesn't work,")}`),
        text: `Your session has moved, ${firstName(p)}.\nIt was ${prev.date} · ${prev.time}.\n\n${s.text}\n\nIf the new time doesn't work, just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "booking_cancelled": {
      const s = sessionRows(p, "Was");
      const by = str(p, "cancelled_by") === "coach" ? "Coach Gari had to cancel this session. Sorry about that — reply and we'll find another time." : "Your session is cancelled, as requested.";
      return { subject: `Cancelled — ${str(p, "service_title")}, ${s.w.date}`,
        html: wrap("Cancellation", `Session cancelled.`, `<p style="margin:0 0 20px">${esc(by)}</p>${table(s.html)}${replyNote("Want to rebook?")}`),
        text: `Session cancelled.\n${by}\n\n${s.text}\n\nWant to rebook? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "payment_confirmed": {
      const amt = money(p.paid_amount ?? p.amount, p.paid_currency ?? p.currency); const paid = whenParts(str(p, "paid_at"), "Asia/Dubai");
      const rows = row("Package", str(p, "pack_title"), true) + row("Sessions", str(p, "sessions")) + row("Amount", amt, true) + row("Paid by", method(p)) + row("Date", paid.date) + row("Reference", str(p, "public_ref", str(p, "order_reference")));
      return { subject: `Payment received — ${str(p, "pack_title")}`,
        html: wrap("Payment", `Thank you, ${esc(firstName(p))}.`, `<p style="margin:0 0 20px">Your payment is in and your package is active.</p>${table(rows)}${replyNote("Questions?")}`),
        text: `Thank you, ${firstName(p)}.\nYour payment is in and your package is active.\n\nPackage: ${str(p, "pack_title")}\nSessions: ${str(p, "sessions")}\nAmount: ${amt}\nPaid by: ${method(p)}\nDate: ${paid.date}\nReference: ${str(p, "public_ref", str(p, "order_reference"))}\n\nQuestions? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "support_thanks": {
      const amt = money(p.paid_amount ?? p.amount, p.paid_currency ?? p.currency);
      return { subject: `Thank you for supporting Coach Gari`,
        html: wrap("Support", `Thank you for supporting Coach Gari.`,
          `<p style="margin:0 0 20px">Your payment of <b>${esc(amt)}</b> is received. It goes straight into the coaching and the work that makes it possible.</p>${table(row("Amount", amt, true) + row("Reference", str(p, "public_ref", str(p, "order_reference"))))}${replyNote("Want to say hello?")}`),
        text: `Thank you for supporting Coach Gari.\nYour payment of ${amt} is received.\n\nAmount: ${amt}\nReference: ${str(p, "public_ref", str(p, "order_reference"))}\n\nWant to say hello? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "enquiry_received": {
      return { subject: `Got your message — Coach Gari`,
        html: wrap("Enquiry", `Got it, ${esc(firstName(p))}.`,
          `<p style="margin:0 0 20px">Your message has reached Coach Gari${p.interest ? ` (about <b>${esc(str(p, "interest"))}</b>)` : ""}. You'll get a straight answer soon, usually within a day.</p>${replyNote("Anything to add?")}`),
        text: `Got it, ${firstName(p)}.\nYour message has reached Coach Gari${p.interest ? ` (about ${str(p, "interest")})` : ""}. You'll get a straight answer soon, usually within a day.\n\nAnything to add? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "lead_notification": {   // owner, internal: what the contact function has always sent (emails/lead-notification.txt)
      const lines = [`Name: ${str(p, "name")}`, `Contact: ${str(p, "contact")}`, `Where: ${str(p, "where", "—")}`, `Interest: ${str(p, "interest", "—")}`, ``, str(p, "message", "(no message)"), ``,
                     `Attribution: ${str(p, "attribution", "direct")}`, `Submitted from: ${str(p, "page", "—")} at ${str(p, "created_at")}`, `Record: ${str(p, "record")}`];
      return { subject: `New enquiry — ${str(p, "interest", "General")} — ${str(p, "name")}`,
        html: `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.55;color:#0A0A0B">
    <p style="margin:0 0 14px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6C6C78">New enquiry · coachgari28.com</p>
    <p><b>${esc(str(p, "name"))}</b><br>${esc(str(p, "contact"))}<br>${esc(str(p, "where", "—"))}</p>
    <p><b>Interest:</b> ${esc(str(p, "interest", "—"))}</p>
    <p style="white-space:pre-wrap;border-left:3px solid #1540E8;padding-left:12px">${esc(str(p, "message", "(no message)"))}</p>
    <p style="font-size:13px;color:#6C6C78">Attribution: ${esc(str(p, "attribution", "direct"))}<br>From ${esc(str(p, "page", "—"))} · ${esc(str(p, "created_at"))}<br>Record ${esc(str(p, "record"))}</p>
  </div>`, text: lines.join("\n") };
    }
    case "payment_received": {   // owner, internal
      const amt = money(p.paid_amount ?? p.amount, p.paid_currency ?? p.currency); const type = str(p, "type", "payment");
      const what = type === "booking" ? `${str(p, "service_title")} · ${(() => { const w = whenParts(str(p, "start_at"), str(p, "timezone", "UTC")); return `${w.date} ${w.time} (${str(p, "timezone")})`; })()} · ${str(p, "reference")}`
                 : type === "package" ? `${str(p, "pack_title")} (${str(p, "sessions")} sessions) · ${str(p, "public_ref", str(p, "order_reference"))}`
                 : `Support Coach Gari · ${str(p, "public_ref", str(p, "order_reference"))}`;
      const who = str(p, "name") ? `${str(p, "name")}${p.contact ? " · " + str(p, "contact") : ""}` : (p.contact ? str(p, "contact") : "—");
      return { subject: `Payment received — ${amt} — ${type} — ${str(p, "public_ref", str(p, "reference", str(p, "order_reference")))}`,
        html: `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.55;color:#0A0A0B"><p><b>${esc(who)}</b></p><p>${esc(what)}</p><p>${esc(amt)} by ${esc(method(p))} · order ${esc(str(p, "order_reference"))}${p.mode === "test" ? " (test mode)" : ""}</p></div>`,
        text: `${who}\n${what}\n${amt} by ${method(p)} · order ${str(p, "order_reference")}` };
    }
    case "collab_ack": {   // to the requester
      return { subject: `Got your collaboration idea — Coach Gari`,
        html: wrap("Collaborate", `Thanks, ${esc(firstName(p))}.`,
          `<p style="margin:0 0 20px">Your idea has reached Coach Gari${p.title ? ` (<b>${esc(str(p, "title"))}</b>)` : ""}. We'll take a look and come back to you about whether there's a good fit.</p>${table(row("Reference", str(p, "public_ref"), true))}${replyNote("Anything to add?")}`),
        text: `Thanks, ${firstName(p)}.\nYour idea has reached Coach Gari${p.title ? ` (${str(p, "title")})` : ""}. We'll come back to you about whether there's a good fit.\n\nReference: ${str(p, "public_ref")}\n\nAnything to add? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "collab_proposal": {   // to the requester
      const amt = p.monetary_amount != null ? money(p.monetary_amount, p.currency) : "";
      return { subject: `A proposal from Coach Gari — ${str(p, "public_ref")}`,
        html: wrap("Collaborate", `Coach Gari has sent a proposal.`,
          `<p style="margin:0 0 20px">${esc(firstName(p))}, proposal #${esc(str(p, "version"))} is ready in your private collaboration room${amt ? ` (${esc(amt)})` : ""}. Open the room to review it, make a counter-offer or accept.</p>${table(row("Reference", str(p, "public_ref"), true))}${replyNote("Use the private link from your first email.")}`),
        text: `Coach Gari has sent a proposal.\n${firstName(p)}, proposal #${str(p, "version")} is ready in your private collaboration room${amt ? ` (${amt})` : ""}. Open the room to review, counter or accept.\n\nReference: ${str(p, "public_ref")}\n\nUse the private link from your first email.\n\nCoach Gari · coachgari28.com` };
    }
    case "collab_accepted": {   // to both sides
      const you = str(p, "by") === "you";
      return { subject: `Collaboration agreed — ${str(p, "public_ref")}`,
        html: wrap("Collaborate", `It's agreed.`,
          `<p style="margin:0 0 20px">${you ? "Thank you — you accepted" : `${esc(str(p, "by", "Coach Gari"))} accepted`} proposal #${esc(str(p, "version"))} for collaboration <b>${esc(str(p, "public_ref"))}</b>. Coach Gari will be in touch with the next steps${you ? ", including any payment" : ""}.</p>${replyNote("Questions?")}`),
        text: `It's agreed.\n${you ? "You accepted" : `${str(p, "by", "Coach Gari")} accepted`} proposal #${str(p, "version")} for collaboration ${str(p, "public_ref")}.\n\nQuestions? Just reply to this email — it reaches Coach Gari directly.\n\nCoach Gari · coachgari28.com` };
    }
    case "collab_payment_ready": {   // to the requester
      const amt = money(p.amount, p.currency);
      return { subject: `Payment ready — ${str(p, "public_ref")}`,
        html: wrap("Collaborate", `Your payment is ready.`,
          `<p style="margin:0 0 20px">${esc(firstName(p))}, the payment for your agreed collaboration is ready: <b>${esc(amt)}</b>${p.label ? ` (${esc(str(p, "label"))})` : ""}. Open your private collaboration room to pay by card.</p>${table(row("Amount", amt, true) + row("Reference", str(p, "public_ref")))}${replyNote("Use the private link from your first email.")}`),
        text: `Your payment is ready.\n${firstName(p)}, the payment for your agreed collaboration is ready: ${amt}${p.label ? ` (${str(p, "label")})` : ""}. Open your private collaboration room to pay by card.\n\nAmount: ${amt}\nReference: ${str(p, "public_ref")}\n\nUse the private link from your first email.\n\nCoach Gari · coachgari28.com` };
    }
    case "collab_received": {   // owner, internal
      return { subject: `New collaboration enquiry — ${str(p, "type", "other")} — ${str(p, "name")}`,
        html: `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.55;color:#0A0A0B">
    <p style="margin:0 0 14px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6C6C78">New collaboration · coachgari28.com</p>
    <p><b>${esc(str(p, "name"))}</b>${p.company ? `<br>${esc(str(p, "company"))}` : ""}${p.reply_to ? `<br>${esc(str(p, "reply_to"))}` : ""}</p>
    <p><b>Type:</b> ${esc(str(p, "type", "—"))}${p.title ? `<br><b>Subject:</b> ${esc(str(p, "title"))}` : ""}</p>
    <p style="font-size:13px;color:#6C6C78">Reference ${esc(str(p, "public_ref"))} · open it in the back-office.</p>
  </div>`,
        text: `New collaboration enquiry\n${str(p, "name")}${p.company ? " · " + str(p, "company") : ""}${p.reply_to ? " · " + str(p, "reply_to") : ""}\nType: ${str(p, "type", "—")}${p.title ? "\nSubject: " + str(p, "title") : ""}\nReference: ${str(p, "public_ref")}` };
    }
    case "collab_counter": {   // owner, internal
      const amt = p.monetary_amount != null ? money(p.monetary_amount, p.currency) : "—";
      return { subject: `Counter-offer — ${str(p, "public_ref")} — v${str(p, "version")}`,
        html: `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.55;color:#0A0A0B"><p><b>${esc(str(p, "name"))}</b> sent counter-offer #${esc(str(p, "version"))}</p><p>Amount: ${esc(amt)} · collaboration ${esc(str(p, "public_ref"))}</p><p style="font-size:13px;color:#6C6C78">Review it in the back-office.</p></div>`,
        text: `${str(p, "name")} sent counter-offer #${str(p, "version")}\nAmount: ${amt} · collaboration ${str(p, "public_ref")}` };
    }
    default:
      throw new Error(`no template for ${kind}`);
  }
}

/* ---- sending ------------------------------------------------ */
export type SendResult = { ok: true; id: string | null } | { ok: false; status: number | null; error: string };
export async function sendResend(cfg: EmailConfig, msg: { to: string; subject: string; html: string; text: string; idempotencyKey: string; replyTo?: string; refId?: string },
                                 env: Env, fetchImpl: Fetch = fetch): Promise<SendResult> {
  const key = (env("RESEND_API_KEY") ?? "").trim();
  if (!key) return { ok: false, status: null, error: "not_configured" };
  try {
    const r = await fetchImpl(`${RESEND_API}/emails`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "Idempotency-Key": msg.idempotencyKey.slice(0, 256) },
      body: JSON.stringify({ from: cfg.from, to: [msg.to], reply_to: msg.replyTo ?? cfg.replyTo, subject: msg.subject, html: msg.html, text: msg.text,
                             headers: msg.refId ? { "X-Entity-Ref-ID": msg.refId } : undefined }),
    });
    const j = await r.json().catch(() => ({})) as { id?: string; message?: string; name?: string };
    if (!r.ok) return { ok: false, status: r.status, error: `resend ${r.status}${j?.name ? " " + j.name : ""}` };   // never the body verbatim
    return { ok: true, id: typeof j?.id === "string" ? j.id : null };
  } catch (e) {
    return { ok: false, status: null, error: `network ${(e as Error).message}`.slice(0, 120) };
  }
}

/* ---- draining the outbox ------------------------------------ */
// deno-lint-ignore no-explicit-any
export type Db = { rpc: (fn: string, args?: Record<string, unknown>) => Promise<{ data: any; error: { code?: string; message?: string } | null }> };
export type Filter = { order_id?: string | null; booking_id?: string | null; contact_id?: string | null; limit?: number };
export type DrainSummary = { claimed: number; sent: number; retry: number; failed: number; skipped: string | null };

export async function drainOutbox(db: Db, env: Env, filter: Filter = {}, log: (event: string, data?: Record<string, unknown>) => void = () => {}, fetchImpl: Fetch = fetch): Promise<DrainSummary> {
  const cfg = emailConfig(env);
  const out: DrainSummary = { claimed: 0, sent: 0, retry: 0, failed: 0, skipped: null };
  if (!cfg.ready) { out.skipped = "not_configured"; log("email_skipped", { reason: "RESEND_API_KEY not configured", missing: cfg.missing }); return out; }
  const { data: rows, error } = await db.rpc("email_outbox_claim", { p_limit: filter.limit ?? 20, p_order_id: filter.order_id ?? null, p_booking_id: filter.booking_id ?? null, p_contact_id: filter.contact_id ?? null });
  if (error) { log("email_claim_failed", { code: error.code }); out.skipped = "claim_failed"; return out; }
  for (const row of (rows ?? []) as Array<{ id: string; kind: string; to_address: string; payload: Payload; dedupe_key: string | null; attempts: number }>) {
    out.claimed++;
    let rendered: Rendered;
    try { rendered = render(row.kind, row.payload ?? {}); }
    catch (e) { await db.rpc("email_outbox_result", { p_id: row.id, p_ok: false, p_error: `render ${(e as Error).message}`.slice(0, 120) }); out.failed++; continue; }
    const replyTo = row.kind === "lead_notification" && typeof row.payload?.contact === "string" && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(row.payload.contact) ? row.payload.contact : undefined;
    const res = await sendResend(cfg, { to: row.to_address, ...rendered, idempotencyKey: row.dedupe_key ?? row.id, replyTo, refId: row.dedupe_key ?? row.id }, env, fetchImpl);
    const { data } = await db.rpc("email_outbox_result", { p_id: row.id, p_ok: res.ok, p_provider_message_id: res.ok ? res.id : null, p_error: res.ok ? null : res.error });
    const state = data?.status ?? (res.ok ? "sent" : "pending");
    if (state === "sent") out.sent++; else if (state === "failed") out.failed++; else out.retry++;
    log(res.ok ? "email_sent" : "email_failed", { kind: row.kind, id: row.id, attempts: row.attempts, state, status: res.ok ? 200 : res.status });
  }
  return out;
}

/* ---- status (presence only, never values) ------------------- */
export async function emailStatus(env: Env, fetchImpl: Fetch = fetch): Promise<Record<string, unknown>> {
  const cfg = emailConfig(env);
  const domain = fromDomain(cfg.from);
  const status: Record<string, unknown> = { configured: cfg.ready, missing: cfg.missing, from: cfg.from, reply_to: cfg.replyTo, domain, domain_status: null };
  if (!cfg.ready) return status;
  try {
    const r = await fetchImpl(`${RESEND_API}/domains`, { headers: { Authorization: `Bearer ${(env("RESEND_API_KEY") ?? "").trim()}` } });
    const j = await r.json().catch(() => ({})) as { data?: Array<{ name: string; status: string; region?: string }> };
    if (!r.ok) { status.domain_status = r.status === 401 || r.status === 403 ? `api ${r.status} (a sending-only key cannot list domains; read the state in Resend → Domains)` : `api ${r.status}`; return status; }
    const d = (j.data ?? []).find((x) => x.name.toLowerCase() === domain);
    status.domain_status = d ? d.status : "not_added";
    status.domains_known = (j.data ?? []).map((x) => ({ name: x.name, status: x.status }));
  } catch (e) { status.domain_status = `unreachable ${(e as Error).message}`.slice(0, 80); }
  return status;
}

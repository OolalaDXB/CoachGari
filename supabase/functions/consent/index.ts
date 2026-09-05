/* =============================================================
   CG-010 — consent
   Client-facing consent link for sensitive fitness-progress
   tracking. The admin issues a scoped, one-time, 7-day token
   (consent_issue_link); the client opens /consent?t=<token> and
   this function serves the versioned notice and records their
   explicit accept / decline.
     POST {action:"view",   token}
          → {ok, first_name, consent_type, notice}
     POST {action:"submit", token, decision:"accept"|"decline"}
          → {ok, decision}
   Authorisation = the consent token only (256-bit random, only
   its SHA-256 is stored, single use, 7-day expiry). No JWT, no
   CRM access: the DB functions consent_view / consent_submit run
   as service_role and expose nothing beyond a first name and the
   public notice text. Evidence captured on submit = a salted hash
   of the client IP, a truncated user-agent and a timestamp — never
   the raw IP. Logs carry only the action and status, never the
   contact id or any measurement value.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";

const ALLOWED_ORIGINS = new Set(["https://coachgari.com", "https://www.coachgari.com"]);
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [/^https:\/\/[a-z0-9-]+\.vercel\.app$/i, /^http:\/\/localhost(:\d+)?$/i, /^http:\/\/127\.0\.0\.1(:\d+)?$/i];
const originAllowed = (o: string | null) => !o || ALLOWED_ORIGINS.has(o) || ALLOWED_ORIGIN_PATTERNS.some((r) => r.test(o));
function cors(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin" };
  if (origin && allowed) { h["Access-Control-Allow-Origin"] = origin; h["Access-Control-Allow-Methods"] = "POST, OPTIONS"; h["Access-Control-Allow-Headers"] = "Content-Type"; h["Access-Control-Max-Age"] = "86400"; }
  return h;
}
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "consent", event, ...data }));
const isToken = (s: unknown) => typeof s === "string" && /^[0-9a-f]{64}$/.test(s);

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Map DB error codes to client-safe responses. Never echo internals.
function rpcError(e: { code?: string; message?: string }, origin: string | null, allowed: boolean) {
  if (e.code === "P0002") return json(404, { ok: false, error: "invalid_token", message: "This link is not valid." }, origin, allowed);
  if (e.code === "P0003") return json(410, { ok: false, error: "expired", message: e.message || "This link has expired or was already used." }, origin, allowed);
  if (e.code === "P0005") return json(422, { ok: false, error: "not_available", message: "This is not available." }, origin, allowed);
  if (e.code === "22023") return json(422, { ok: false, error: "rejected", message: "Invalid request." }, origin, allowed);
  log("rpc_failed", { code: e.code }); return json(500, { ok: false, error: "server_error" }, origin, allowed);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  if (!isToken(body.token)) return json(400, { ok: false, error: "validation", fields: ["token"] }, origin, allowed);
  const token = String(body.token);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  if (body.action === "view") {
    const { data, error } = await supabase.rpc("consent_view", { p_token: token });
    if (error) return rpcError(error, origin, allowed);
    log("viewed", { status: "ok" });
    return json(200, { ok: true, first_name: data.first_name ?? null, consent_type: data.consent_type, notice: data.notice }, origin, allowed);
  }

  if (body.action === "submit") {
    const decision = body.decision === "accept" ? "accept" : body.decision === "decline" ? "decline" : null;
    if (!decision) return json(400, { ok: false, error: "validation", fields: ["decision"] }, origin, allowed);
    // Evidence: salted IP hash + truncated UA + timestamp. Never the raw IP.
    const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim();
    const salt = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const ua = (req.headers.get("user-agent") || "").slice(0, 200);
    const evidence = {
      method: "client_link",
      ip_hash: ip ? await sha256hex(salt + "|" + ip) : null,
      user_agent: ua || null,
      submitted_at: new Date().toISOString(),
    };
    const { data, error } = await supabase.rpc("consent_submit", { p_token: token, p_decision: decision, p_evidence: evidence });
    if (error) return rpcError(error, origin, allowed);
    log("submitted", { decision, status: "ok" });
    return json(200, { ok: true, decision: data.decision }, origin, allowed);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

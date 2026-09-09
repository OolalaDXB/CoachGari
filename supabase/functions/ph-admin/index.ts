/* =============================================================
   BEAU PH — operator runtime readiness (admin workspace helper)
     POST {action:"runtime"}   Authorization: Bearer <user JWT>
          → {ok, mode, providers:{<key>:{configured, mode?, embedded?, reason?,
                                         secrets:{<NAME>: true|false}}}}
   What it answers: "are the deployment secrets this rail needs present, and
   in which mode?" — PRESENCE ONLY. No value, prefix or length of any secret
   ever leaves this function. The secret NAMES come from the BEAU PH
   provider catalogue (beau_ph.providers.secrets, read through the caller's
   own session), never from the request body, so a page cannot probe
   arbitrary environment variables. Stripe's mode / key-mode consistency is
   the adapter's own runtime() verdict.
   Who may ask: a signed-in back-office user holding finance:view. The JWT is
   verified against Supabase Auth and the permission check runs inside the
   RPC the caller's session executes — never through the service role.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { stripe } from "../../../beau-ph/providers/stripe/adapter.ts";
import { originAllowed, corsHeaders as cors } from "../_shared/cors.ts";

const env = (name: string) => Deno.env.get(name);
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "ph-admin", event, ...data }));
const SECRET_VALUE_RE = /(sk|rk)_(live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}/;

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  const auth = req.headers.get("authorization") ?? "";
  const url = env("SUPABASE_URL"); const anon = env("SUPABASE_ANON_KEY");
  if (!url || !anon || !auth.startsWith("Bearer ")) return json(401, { ok: false, error: "unauthorized" }, origin, allowed);
  const client = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: { user }, error: uErr } = await client.auth.getUser();
  if (uErr || !user) return json(401, { ok: false, error: "unauthorized" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  if (body.action !== "runtime") return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);

  // the catalogue (and the finance:view check) through the caller's own session
  const { data: rails, error: rErr } = await client.rpc("beau_ph_rails");
  if (rErr) { log("forbidden", { code: rErr.code ?? null }); return json(rErr.code === "42501" ? 403 : 500, { ok: false, error: rErr.code === "42501" ? "forbidden" : "server_error" }, origin, allowed); }

  const mode = (env("PAYMENTS_MODE") ?? "").toLowerCase() || null;
  const providers: Record<string, unknown> = {};
  for (const r of (rails?.rails ?? []) as Array<{ provider: string; secrets?: string[] }>) {
    const names: string[] = Array.isArray(r.secrets) ? r.secrets : [];
    const secrets: Record<string, boolean> = {};
    for (const name of names) secrets[name] = !!(env(name) ?? "").length;
    const allPresent = names.length > 0 && names.every((n) => secrets[n]);
    providers[r.provider] = r.provider === "stripe"
      ? { ...stripe.runtime(env), secrets }
      : { configured: allPresent, mode: names.length ? mode : undefined, reason: names.length && !allPresent ? "secrets missing" : (names.length ? undefined : "no secret needed"), secrets };
  }
  const reply = { ok: true, mode, site_url: env("SITE_URL") ? "set" : "default", providers };
  if (SECRET_VALUE_RE.test(JSON.stringify(reply))) { log("public_guard_tripped"); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
  log("runtime", { providers: Object.keys(providers).length });
  return json(200, reply, origin, allowed);
});

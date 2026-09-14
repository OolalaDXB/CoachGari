/* Audience analytics — the sync (CG-018).

     POST {action:"sync"}     header x-outbox-key: <key held in outbox_keys>
       Pulls the website numbers from Plausible (Stats API v2) and the channel
       statistics from YouTube (Data API v3, public, API key only), writes them
       through service-role RPCs. Kicked by pg_cron once a day; "Sync now" in the
       back-office kicks the same way. Each source is optional: no key → skipped,
       and the reply says so. A source failing never blocks the other.

     POST {action:"status"}   same header
       Which sources are configured (secret PRESENCE only, never a value).

   Instagram and TikTok have no API a solo coach can use without an app review;
   those numbers come in by CSV export or by hand, in the back-office. */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const env = (n: string) => Deno.env.get(n);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "analytics-sync", event, ...data }));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const PLAUSIBLE_API = "https://plausible.io/api/v2/query";
const YOUTUBE_API = "https://www.googleapis.com/youtube/v3/channels";

type Sb = ReturnType<typeof createClient>;

/* A secret pasted into `supabase secrets set` often arrives wrapped: a trailing
   newline from a copy, or the quotes the shell was supposed to eat. Both are
   invisible in every dashboard and both produce an authentication failure that
   looks exactly like a wrong key, which is an hour of looking in the wrong
   place. Trim, then drop ONE matching pair of surrounding quotes — never more,
   because a quote can legitimately be part of a secret. */
export function cleanSecret(raw: string | undefined): string {
  let v = (raw ?? "").trim();
  if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1).trim();
  return v;
}

/* Plausible answers 401 for a token it does not accept at all. The message has
   to say which of the two it is, because the operator's next click depends on
   it: a refused key is a key problem, a refused site is a site problem, and
   "plausible 401" alone sends people to re-read their site id for nothing. */
async function plausibleQuery(key: string, body: Record<string, unknown>) {
  const r = await fetch(PLAUSIBLE_API, { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (r.status === 401) throw new Error("Plausible refused the key (401). It must be a Stats API key from Plausible → Settings → API keys; a Sites/Plugins key is a different token and is rejected here.");
  if (r.status === 403) throw new Error("Plausible refused access (403): the key is valid but has no access to this site, or the plan does not include the Stats API.");
  if (r.status === 404) throw new Error("Plausible does not know this site (404): plausible_site_id must be the domain exactly as registered.");
  if (!r.ok) throw new Error(`plausible ${r.status}`);   // status only, never the body (it can echo the site id / query)
  return await r.json() as { results: { metrics: number[]; dimensions: string[] }[] };
}

/* Plausible: 60 days of daily visitors/pageviews/visits/bounce/duration, the top sources
   and the goals of the last 30 days. site_id is the domain as registered in Plausible. */
export async function syncPlausible(sb: Sb, key: string, siteId: string) {
  const daily = await plausibleQuery(key, { site_id: siteId, metrics: ["visitors", "pageviews", "visits", "bounce_rate", "visit_duration"], date_range: "60d", dimensions: ["time:day"] });
  const rows = daily.results.map((x) => ({ day: x.dimensions[0], visitors: x.metrics[0], pageviews: x.metrics[1], visits: x.metrics[2], bounce_rate: x.metrics[3], visit_duration: x.metrics[4] }));
  let sources: unknown = null, goals: unknown = null;
  try {
    const s = await plausibleQuery(key, { site_id: siteId, metrics: ["visitors"], date_range: "30d", dimensions: ["visit:source"], order_by: [["visitors", "desc"]], pagination: { limit: 10 } });
    sources = s.results.map((x) => ({ source: x.dimensions[0], visitors: x.metrics[0] }));
  } catch (e) { log("plausible_sources_failed", { error: String(e).slice(0, 60) }); }
  try {
    const g = await plausibleQuery(key, { site_id: siteId, metrics: ["visitors", "events"], date_range: "30d", dimensions: ["event:goal"] });
    goals = g.results.map((x) => ({ goal: x.dimensions[0], visitors: x.metrics[0], events: x.metrics[1] }));
  } catch (e) { log("plausible_goals_failed", { error: String(e).slice(0, 60) }); }
  const { data, error } = await sb.rpc("web_daily_upsert", { p_rows: rows, p_sources: sources, p_goals: goals });
  if (error) throw new Error(`db ${error.code}`);
  return { days: data as number, sources: Array.isArray(sources) ? sources.length : 0, goals: Array.isArray(goals) ? goals.length : 0 };
}

/* YouTube: the channel's public counters, one snapshot for today. */
export async function syncYouTube(sb: Sb, key: string, channel: string) {
  const byHandle = channel.startsWith("@");
  const u = `${YOUTUBE_API}?part=statistics&${byHandle ? "forHandle" : "id"}=${encodeURIComponent(channel)}&key=${encodeURIComponent(key)}`;
  const r = await fetch(u);
  if (!r.ok) throw new Error(`youtube ${r.status}`);
  const j = await r.json() as { items?: { statistics?: Record<string, string> }[] };
  const st = j.items?.[0]?.statistics;
  if (!st) throw new Error("youtube channel not found");
  const snap = { followers: Number(st.subscriberCount ?? 0), views: Number(st.viewCount ?? 0), posts: Number(st.videoCount ?? 0) };
  const { error } = await sb.rpc("social_snapshot_api", { p_platform: "youtube", p: snap });
  if (error) throw new Error(`db ${error.code}`);
  return snap;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("analytics_sync_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }

  const { data: cfgRows } = await sb.from("analytics_config").select("plausible_site_id,youtube_channel_id").eq("id", 1).maybeSingle();
  const cfg = (cfgRows ?? {}) as { plausible_site_id?: string; youtube_channel_id?: string | null };
  const plausibleRaw = env("PLAUSIBLE_API_KEY"), youtubeRaw = env("YOUTUBE_API_KEY");
  const plausibleKey = cleanSecret(plausibleRaw), youtubeKey = cleanSecret(youtubeRaw);
  const configured = { plausible: !!plausibleKey, youtube: !!youtubeKey && !!cfg.youtube_channel_id };
  /* Presence only, as always — plus whether the stored value had to be unwrapped.
     That is a fact about the storage, not about the secret: it reveals nothing
     that could be used, and it is the difference between "your key is wrong"
     and "your key was stored with quotes around it". */
  const wrapped = { plausible: !!plausibleRaw && plausibleRaw !== plausibleKey, youtube: !!youtubeRaw && youtubeRaw !== youtubeKey };

  if (body.action === "status") { log("status", { ...configured, wrapped }); return json(200, { ok: true, configured, wrapped }); }
  if (body.action !== "sync" && body.action !== undefined) return json(400, { ok: false, error: "validation", fields: ["action"] });

  const out: Record<string, unknown> = { ok: true, configured };
  const errors: string[] = [];
  if (configured.plausible) {
    try { out.plausible = await syncPlausible(sb, plausibleKey, cfg.plausible_site_id || "coachgari28.com"); }
    catch (e) { const m = String(e).replace(/^Error:\s*/, "").slice(0, 200); errors.push(`Plausible — ${m}`); log("plausible_failed", { error: m }); }
  }
  if (configured.youtube) {
    try { out.youtube = await syncYouTube(sb, youtubeKey, cfg.youtube_channel_id!); }
    catch (e) { const m = String(e).replace(/^Error:\s*/, "").slice(0, 200); errors.push(`YouTube — ${m}`); log("youtube_failed", { error: m }); }
  }
  if (errors.length) { await sb.rpc("analytics_sync_error", { p_error: errors.join(" · ") }); out.errors = errors; }
  log("synced", { plausible: !!out.plausible, youtube: !!out.youtube, errors: errors.length });
  return json(200, out);
});

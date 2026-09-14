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
import { cleanSecret, dateRange, excludeFilter } from "../_shared/plausible.ts";

const env = (n: string) => Deno.env.get(n);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "analytics-sync", event, ...data }));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const PLAUSIBLE_API = "https://plausible.io/api/v2/query";
const YOUTUBE_API = "https://www.googleapis.com/youtube/v3/channels";

type Sb = ReturnType<typeof createClient>;

/* PLAUSIBLE'S OWN WORDS, NOT OUR GUESS AT THEM.
   This used to report the status alone, then a sentence we had written for each
   status. Both were wrong in the same way: Plausible's 401 does not separate
   "this key is invalid" from "this key has no access to that site", so any
   message we compose sends half the readers to check the wrong thing. Plausible
   says which it is in the response body, and that body carries no credential —
   it echoes at most the site id, which is a public domain name, and the query,
   which we wrote. So it is read and passed through, truncated.

   The Authorization header is never echoed by an HTTP response, so nothing that
   could be replayed can reach a log or the back-office this way. */
async function plausibleError(r: Response): Promise<string> {
  let detail = "";
  try {
    const t = (await r.text()).slice(0, 2000);
    try { detail = String((JSON.parse(t) as { error?: unknown }).error ?? "").trim(); } catch { detail = t.trim(); }
  } catch { /* a body we cannot read is not worth failing differently over */ }
  detail = detail.replace(/\s+/g, " ").slice(0, 180);
  const hint = r.status === 401
    ? " Check both: the key must be a Stats API key, and it must have access to this exact site id."
    : r.status === 404 ? " plausible_site_id must be the domain exactly as registered in Plausible."
    : "";
  return `Plausible refused the request (${r.status}).${detail ? ` It said: "${detail}".` : ""}${hint}`;
}

async function plausibleQuery(key: string, body: Record<string, unknown>) {
  const r = await fetch(PLAUSIBLE_API, { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(await plausibleError(r));
  return await r.json() as { results: { metrics: number[]; dimensions: string[] }[] };
}

export async function syncPlausible(sb: Sb, key: string, siteId: string, startDate: string, excludePaths: string[]) {
  const date_range = dateRange(startDate);
  const filters = excludeFilter(excludePaths);
  const base = { site_id: siteId, date_range, ...(filters.length ? { filters } : {}) };

  const daily = await plausibleQuery(key, { ...base, metrics: ["visitors", "pageviews", "visits", "bounce_rate", "visit_duration"], dimensions: ["time:day"] });
  const rows = daily.results.map((x) => ({ day: x.dimensions[0], visitors: x.metrics[0], pageviews: x.metrics[1], visits: x.metrics[2], bounce_rate: x.metrics[3], visit_duration: x.metrics[4] }));

  /* Sources, goals and countries are each optional: one of them failing must not
     cost us the daily series, which is the part nothing else can reconstruct. */
  let sources: unknown = null, goals: unknown = null, countries: unknown = null;
  try {
    const s = await plausibleQuery(key, { ...base, metrics: ["visitors"], dimensions: ["visit:source"], order_by: [["visitors", "desc"]], pagination: { limit: 10 } });
    sources = s.results.map((x) => ({ source: x.dimensions[0], visitors: x.metrics[0] }));
  } catch (e) { log("plausible_sources_failed", { error: String(e).slice(0, 60) }); }
  try {
    const g = await plausibleQuery(key, { ...base, metrics: ["visitors", "events"], dimensions: ["event:goal"] });
    goals = g.results.map((x) => ({ goal: x.dimensions[0], visitors: x.metrics[0], events: x.metrics[1] }));
  } catch (e) { log("plausible_goals_failed", { error: String(e).slice(0, 60) }); }
  try {
    /* WHERE people are, never who. The country is the commercial question —
       what to price in what currency, which rails to open — and it is also the
       coarsest location Plausible reports. We deliberately do not ask for the
       region or the city: neither would change a decision, and both narrow a
       visitor down further than a visitor count needs to. */
    const c = await plausibleQuery(key, { ...base, metrics: ["visitors"], dimensions: ["visit:country"], order_by: [["visitors", "desc"]], pagination: { limit: 30 } });
    countries = c.results.map((x) => ({ country: x.dimensions[0], visitors: x.metrics[0] })).filter((x) => x.country);
  } catch (e) { log("plausible_countries_failed", { error: String(e).slice(0, 60) }); }

  const { data, error } = await sb.rpc("web_daily_upsert", { p_rows: rows, p_sources: sources, p_goals: goals, p_countries: countries });
  if (error) throw new Error(`db ${error.code}`);
  return { days: data as number, sources: Array.isArray(sources) ? sources.length : 0,
           goals: Array.isArray(goals) ? goals.length : 0, countries: Array.isArray(countries) ? countries.length : 0,
           from: date_range[0], excluded: excludePaths };
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

  /* One RPC rather than a table read: the start date and the exclusions are the
     rule the numbers are computed under, and the database is where that rule
     lives. */
  const { data: cfgRow } = await sb.rpc("analytics_sync_config");
  const cfg = (cfgRow ?? {}) as { site_id?: string; start_date?: string; exclude_paths?: string[] | null; youtube_channel_id?: string | null };
  const startDate = cfg.start_date || "2026-09-15";
  const excludePaths = Array.isArray(cfg.exclude_paths) ? cfg.exclude_paths : ["/admin"];
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
    try { out.plausible = await syncPlausible(sb, plausibleKey, cfg.site_id || "coachgari28.com", startDate, excludePaths); }
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

/* =============================================================
   CG-004 — upload
   Signed uploads for enquiry attachments (photos / videos).
     POST {action:"sign",    submission_id, filename, content_type, size}
          → {path, token, url}  (PUT the raw file to `url`)
     POST {action:"confirm", submission_id, path}
          → {status:"uploaded"|"failed"}
   Ownership = the submission_id the browser generated for its own
   enquiry; window = 30 min after the enquiry; limits = 3 files,
   50 MB total, images and videos only (also enforced by the bucket
   and the database). The bucket is private; only coach:operations
   can read the files through the back-office.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "enquiry-media";
const ALLOWED_ORIGINS = new Set(["https://coachgari.com", "https://www.coachgari.com"]);
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [/^https:\/\/[a-z0-9-]+\.vercel\.app$/i, /^http:\/\/localhost(:\d+)?$/i, /^http:\/\/127\.0\.0\.1(:\d+)?$/i];
const originAllowed = (o: string | null) => !o || ALLOWED_ORIGINS.has(o) || ALLOWED_ORIGIN_PATTERNS.some((r) => r.test(o));
function cors(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin" };
  if (origin && allowed) { h["Access-Control-Allow-Origin"] = origin; h["Access-Control-Allow-Methods"] = "POST, OPTIONS"; h["Access-Control-Allow-Headers"] = "Content-Type"; h["Access-Control-Max-Age"] = "86400"; }
  return h;
}
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "upload", event, ...data }));
const isUuid = (s: unknown) => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s);

function rpcError(e: { code?: string; message?: string }, origin: string | null, allowed: boolean) {
  if (e.code === "P0002") return json(404, { ok: false, error: "not_found", message: e.message }, origin, allowed);
  if (e.code === "P0003" || e.code === "22023") return json(422, { ok: false, error: "rejected", message: e.message }, origin, allowed);
  log("rpc_failed", { code: e.code }); return json(500, { ok: false, error: "server_error" }, origin, allowed);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  if (!isUuid(body.submission_id)) return json(400, { ok: false, error: "validation", fields: ["submission_id"] }, origin, allowed);
  const submissionId = String(body.submission_id);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  if (body.action === "sign") {
    const filename = typeof body.filename === "string" ? body.filename.slice(0, 200) : "file";
    const contentType = typeof body.content_type === "string" ? body.content_type.toLowerCase() : "";
    const size = Number(body.size);
    if (!/^(image|video)\/[a-z0-9.+-]+$/.test(contentType)) return json(422, { ok: false, error: "rejected", message: "only photos and videos" }, origin, allowed);
    if (!Number.isFinite(size) || size <= 0 || size > 52428800) return json(422, { ok: false, error: "rejected", message: "file too large (50 MB max)" }, origin, allowed);

    const { data: r, error } = await supabase.rpc("reserve_contact_media", { p_submission_id: submissionId, p_original_name: filename, p_content_type: contentType, p_size_bytes: Math.round(size) });
    if (error) return rpcError(error, origin, allowed);

    const { data: s, error: sErr } = await supabase.storage.from(BUCKET).createSignedUploadUrl(r.path);
    if (sErr || !s) { log("sign_failed", { message: sErr?.message }); await supabase.rpc("confirm_contact_media", { p_submission_id: submissionId, p_path: r.path, p_ok: false }); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
    log("signed", { media_id: r.media_id });
    return json(200, { ok: true, path: r.path, token: s.token, url: s.signedUrl }, origin, allowed);
  }

  if (body.action === "confirm") {
    const path = typeof body.path === "string" ? body.path : "";
    if (!/^contacts\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.[a-z0-9]{1,8}$/.test(path)) return json(400, { ok: false, error: "validation", fields: ["path"] }, origin, allowed);
    const dir = path.slice(0, path.lastIndexOf("/")); const name = path.slice(path.lastIndexOf("/") + 1);
    const { data: list } = await supabase.storage.from(BUCKET).list(dir, { search: name, limit: 5 });
    const exists = !!list?.some((o) => o.name === name);
    const { data, error } = await supabase.rpc("confirm_contact_media", { p_submission_id: submissionId, p_path: path, p_ok: exists });
    if (error) return rpcError(error, origin, allowed);
    if (!exists) await supabase.storage.from(BUCKET).remove([path]).catch(() => {});
    log("confirmed", { media_id: data.media_id, status: data.status });
    return json(200, { ok: true, status: data.status }, origin, allowed);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

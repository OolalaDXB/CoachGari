/* Coach Gari — the agreement renderer (CG-020).

     POST {action:"issue", collab_id:"<uuid>"}    header x-outbox-key
       Reads the frozen record, renders the PDF, stores it with its hashes.
       Called by a trigger the moment a deal acquires an accepted proposal, and
       by the back-office button when that did not happen.

     POST {action:"preview", collab_id:"<uuid>"}  header x-outbox-key
       Renders without storing, and reports the size and both hashes. For
       checking a change to the document before it is issued for real.

   Nothing here decides anything: the terms, the moment and the evidence all
   come from the database, already frozen by the acceptance. This turns them
   into a file and hands the file back for storage.

   Storing is idempotent on (deal, proposal), so a retry, a redeploy or a
   double-fired trigger cannot produce a second, differing contract. */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { buildAgreement, sha256hex, type Snapshot } from "../_shared/agreement.ts";

const env = (n: string) => Deno.env.get(n);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "agreement", event, ...data }));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

const b64 = (bytes: Uint8Array) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("agreement_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }

  const action = body.action === undefined ? "issue" : String(body.action);
  if (action !== "issue" && action !== "preview") return json(400, { ok: false, error: "validation", fields: ["action"] });
  if (!isUuid(body.collab_id)) return json(400, { ok: false, error: "validation", fields: ["collab_id"] });
  const collabId = String(body.collab_id);

  const { data: snap, error: snapErr } = await sb.rpc("collab_agreement_snapshot", { p_collab: collabId });
  if (snapErr) {
    // P0002 no such deal · P0003 nothing accepted — both are "not our business", not failures
    log("snapshot_refused", { code: snapErr.code });
    return json(snapErr.code === "P0002" ? 404 : 409, { ok: false, error: "unavailable" });
  }

  let bytes: Uint8Array, recordHash: string;
  try {
    const built = await buildAgreement(snap as unknown as Snapshot);
    bytes = built.bytes; recordHash = built.recordHash;
  } catch (e) {
    log("render_failed", { error: String(e).slice(0, 120) });
    return json(500, { ok: false, error: "server_error" });
  }
  const fileHash = await sha256hex(bytes);

  if (action === "preview") {
    log("previewed", { bytes: bytes.length });
    return json(200, { ok: true, bytes: bytes.length, record_sha256: recordHash, file_sha256: fileHash });
  }

  const proposalId = ((snap as Record<string, Record<string, unknown>>).proposal ?? {}).id;
  const evidence = ((snap as Record<string, Record<string, unknown>>).proposal ?? {}).accepted_evidence ?? {};
  const org = (snap as Record<string, unknown>).org ?? {};

  const { data: rec, error: recErr } = await sb.rpc("collab_agreement_record", {
    p_collab: collabId, p_proposal: proposalId, p_pdf_b64: b64(bytes),
    p_record_hash: recordHash, p_evidence: evidence, p_org: org,
  });
  if (recErr) { log("store_failed", { code: recErr.code }); return json(500, { ok: false, error: "server_error" }); }

  const created = !!(rec as Record<string, unknown>)?.created;
  log(created ? "issued" : "already_issued", { bytes: bytes.length });
  return json(200, { ok: true, created, bytes: bytes.length, record_sha256: recordHash, file_sha256: fileHash });
});

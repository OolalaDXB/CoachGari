#!/usr/bin/env node
/* Deploy the Supabase Edge Functions from the repo — the same multi-file bundles the project has always used.

   For each function under supabase/functions/<name>/index.ts the bundle is the entrypoint plus every file its
   RELATIVE imports reach (../_shared/*, ../../../beau-ph/**), named by repo-relative path; npm:/jsr:/https: and
   type-only imports are left to the runtime. Every function deploys with verify_jwt=false: each one enforces its
   own boundary (CORS allowlist, Stripe signature, database-issued key, user JWT checked in code).

   Usage
     node scripts/deploy-functions.mjs --list                      what would deploy, with each bundle (no network, no token)
     node scripts/deploy-functions.mjs                             deploy every function
     node scripts/deploy-functions.mjs --only contact,booking      a subset
     node scripts/deploy-functions.mjs --changed <git ref>         only functions whose bundle contains a file changed since <ref>
   Needs SUPABASE_ACCESS_TOKEN (a personal access token, never committed) and SUPABASE_PROJECT_REF in the environment.
   The token is sent as a bearer header to api.supabase.com only and never printed. */
import { readdir, readFile, stat } from 'node:fs/promises';
import { execSync } from 'node:child_process';
import { dirname, join, normalize, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FN_DIR = join(ROOT, 'supabase/functions');
const args = process.argv.slice(2);
const flag = (n) => { const i = args.indexOf(n); return i === -1 ? null : (args[i + 1] ?? ''); };
const LIST = args.includes('--list');
const ONLY = flag('--only')?.split(',').map((s) => s.trim()).filter(Boolean) ?? null;
const CHANGED_REF = flag('--changed');

const exists = (p) => stat(p).then(() => true, () => false);

/* relative import closure of one file (static import/export ... from "…" and dynamic import("…")) */
async function closure(entry) {
  const seen = new Set(); const queue = [entry];
  while (queue.length) {
    const file = queue.shift(); if (seen.has(file)) continue; seen.add(file);
    const src = await readFile(file, 'utf8');
    for (const m of src.matchAll(/(?:import|export)\s+(?:type\s+)?[^'"]*?from\s*["']([^"']+)["']|import\s*\(\s*["']([^"']+)["']\s*\)/g)) {
      const spec = m[1] ?? m[2];
      if (!spec || !spec.startsWith('.')) continue;                                  // npm:, jsr:, https: → runtime
      if (/^(?:import|export)\s+type\s/.test(m[0])) continue;                          // erased by the bundler
      const target = normalize(join(dirname(file), spec));
      if (!(await exists(target))) throw new Error(`${relative(ROOT, file)} imports missing ${spec}`);
      queue.push(target);
    }
  }
  return [...seen].map((f) => relative(ROOT, f)).sort();
}

const names = (await readdir(FN_DIR, { withFileTypes: true })).filter((d) => d.isDirectory() && !d.name.startsWith('_')).map((d) => d.name).sort();
const bundles = {};
for (const name of names) {
  const entry = join(FN_DIR, name, 'index.ts');
  if (!(await exists(entry))) continue;
  bundles[name] = { entrypoint: relative(ROOT, entry), files: await closure(entry) };
}

let selected = Object.keys(bundles);
if (ONLY) { const bad = ONLY.filter((n) => !bundles[n]); if (bad.length) { console.error(`unknown function(s): ${bad.join(', ')}`); process.exit(1); } selected = ONLY; }
if (CHANGED_REF) {
  let changed;
  try { changed = new Set(execSync(`git diff --name-only ${CHANGED_REF} HEAD`, { cwd: ROOT }).toString().split('\n').filter(Boolean)); }
  catch { console.error(`cannot diff against ${CHANGED_REF}; deploying every function instead`); changed = null; }
  if (changed) selected = selected.filter((n) => bundles[n].files.some((f) => changed.has(f)));
}

for (const n of selected) console.log(`${LIST ? 'would deploy' : 'deploy'}  ${n}  (${bundles[n].files.length} files)${LIST ? '\n    ' + bundles[n].files.join('\n    ') : ''}`);
if (!selected.length) console.log('nothing to deploy');
if (LIST || !selected.length) process.exit(0);

const token = process.env.SUPABASE_ACCESS_TOKEN; const ref = process.env.SUPABASE_PROJECT_REF;
if (!token || !ref) { console.error('SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF are required'); process.exit(1); }

let failed = 0;
for (const name of selected) {
  const b = bundles[name];
  const form = new FormData();
  form.append('metadata', JSON.stringify({ name, entrypoint_path: b.entrypoint, verify_jwt: false }));
  for (const f of b.files) form.append('file', new Blob([await readFile(join(ROOT, f))], { type: 'text/plain' }), f);
  const r = await fetch(`https://api.supabase.com/v1/projects/${ref}/functions/deploy?slug=${encodeURIComponent(name)}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: form,
  });
  const body = await r.text();
  if (!r.ok) { failed++; console.error(`FAIL  ${name}: HTTP ${r.status} ${body.slice(0, 300)}`); continue; }
  let v = '?'; try { v = JSON.parse(body).version ?? '?'; } catch { /* ignore */ }
  console.log(`OK    ${name} → version ${v}`);
}
process.exit(failed ? 1 : 0);

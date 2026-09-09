/* Internal link + asset check for the static site.
   - #anchors must resolve to an id on the same page
   - /root-absolute links must resolve to a file (clean URLs -> dir/index.html)
   - external, mailto, tel and bare "#" are ignored
   Exits non-zero on any broken reference. No dependencies. */
import { readFileSync, existsSync, statSync } from 'node:fs';
import { readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
    const p = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else if (entry.name.endsWith('.html')) out.push(p);
  }
  return out;
}

function stripComments(html) {
  return html.replace(/<!--[\s\S]*?-->/g, '');
}

function idsOf(html) {
  const ids = new Set();
  for (const m of html.matchAll(/\sid=["']([^"']+)["']/g)) ids.add(m[1]);
  // declared anchor aliases (body[data-anchor-aliases]="old:new …", resolved by site.js) count as ids
  // only when their target id exists on the page
  const decl = html.match(/data-anchor-aliases=["']([^"']+)["']/);
  if (decl) for (const pair of decl[1].trim().split(/\s+/)) {
    const [alias, target] = pair.split(':');
    if (alias && target && ids.has(target)) ids.add(alias);
  }
  return ids;
}

function resolveAbsolute(ref) {
  const clean = ref.split('#')[0].split('?')[0];
  if (!clean || clean === '/') return existsSync(join(ROOT, 'index.html'));
  const target = join(ROOT, clean);
  if (existsSync(target) && statSync(target).isFile()) return true;      // exact file
  if (existsSync(join(target, 'index.html'))) return true;               // clean URL -> dir
  if (existsSync(target + '.html')) return true;                         // clean URL -> file.html
  return false;
}

const files = walk(ROOT);
const errors = [];

for (const file of files) {
  const raw = stripComments(readFileSync(file, 'utf8'));
  const ids = idsOf(raw);
  const rel = file.replace(ROOT + '/', '');

  for (const m of raw.matchAll(/\s(?:href|src)=["']([^"']*)["']/g)) {
    const ref = m[1].trim();
    if (!ref || ref === '#') continue;
    if (/^(https?:|mailto:|tel:|data:)/i.test(ref)) continue;

    if (ref.startsWith('#')) {
      const id = ref.slice(1);
      if (!ids.has(id)) errors.push(`${rel}: dead anchor ${ref}`);
    } else if (ref.startsWith('/')) {
      if (!resolveAbsolute(ref)) errors.push(`${rel}: missing target ${ref}`);
    }
    // relative non-root links: none expected in this repo
  }
  // responsive images: every candidate in a srcset must resolve; <picture> sources need type + srcset; <img> needs width/height
  for (const m of raw.matchAll(/\ssrcset=["']([^"']*)["']/g)) {
    for (const cand of m[1].split(',')) {
      const url = cand.trim().split(/\s+/)[0];
      if (url && url.startsWith('/') && !resolveAbsolute(url)) errors.push(`${rel}: missing srcset target ${url}`);
    }
  }
  for (const m of raw.matchAll(/<source\b[^>]*>/g)) {
    if (!/\stype=["']image\//.test(m[0]) || !/\ssrcset=/.test(m[0])) errors.push(`${rel}: <source> without type/srcset: ${m[0].slice(0, 80)}`);
  }
  for (const m of raw.matchAll(/<img\b[^>]*\ssrcset=[^>]*>/g)) {
    if (!/\swidth=["']\d+["']/.test(m[0]) || !/\sheight=["']\d+["']/.test(m[0])) errors.push(`${rel}: responsive <img> without width/height: ${m[0].slice(0, 80)}`);
    if (!/\salt=/.test(m[0])) errors.push(`${rel}: <img> without alt: ${m[0].slice(0, 80)}`);
  }
}

if (errors.length) {
  console.error('Broken internal references:\n  ' + errors.join('\n  '));
  process.exit(1);
}
console.log(`Link check OK — ${files.length} pages, no broken internal references.`);

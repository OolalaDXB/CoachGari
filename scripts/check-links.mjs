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
}

if (errors.length) {
  console.error('Broken internal references:\n  ' + errors.join('\n  '));
  process.exit(1);
}
console.log(`Link check OK — ${files.length} pages, no broken internal references.`);

#!/usr/bin/env node
/* Web derivatives for the approved shoot photos.
   Source (kept as delivered, never overwritten):  assets/img/source/<name>.png
   Output:                                          assets/img/shoot/<slug>-<w>.avif | .webp  +  <slug>.jpg (fallback, ≤1280)
                                                    assets/img/shoot/manifest.json  (intrinsic sizes, for width/height attributes)
   Also copies assets/img/source/Zimbabwe_Bird.svg → assets/img/zimbabwe-bird.svg unchanged (SVG stays SVG).

   Quality is deliberately high (AVIF 62, WebP 84, JPEG 86, no extra sharpening or smoothing) so skin, beard and
   fabric texture survive; the width ladder covers a 2× 800 px column without serving the 1100+ px PNGs.
   Requires sharp:  npm i --no-save sharp   (not a runtime dependency of the site).
   Run: node scripts/build-images.mjs        Exit 1 if a source is missing. */
import { readdir, mkdir, writeFile, copyFile, stat } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'assets/img/source');
const OUT = join(ROOT, 'assets/img/shoot');
const PHOTOS = {
  'smiling_athlete_on_cardio_machine.png':      'coach-gari-about',
  'muscular_athlete_s_dumbbell_front_raise.png': 'coach-gari-personal-training',
  'athletic_twist_in_a_tropical_city_gym.png':   'coach-gari-movement',
};
const WIDTHS = [640, 960, 1280];

let sharp;
try { sharp = (await import('sharp')).default; }
catch {
  try { const g = (await import('node:child_process')).execSync('npm root -g').toString().trim(); sharp = createRequire(g + '/')('sharp'); }
  catch { console.error('sharp is not installed: npm i --no-save sharp'); process.exit(1); }
}

const exists = (p) => stat(p).then(() => true, () => false);
if (!(await exists(SRC))) { console.error(`missing ${SRC}: put the approved PNGs and Zimbabwe_Bird.svg there`); process.exit(1); }
await mkdir(OUT, { recursive: true });
const present = new Set(await readdir(SRC));
const manifest = {};
let missing = 0;

for (const [file, slug] of Object.entries(PHOTOS)) {
  if (!present.has(file)) { console.error(`MISSING  ${file}`); missing++; continue; }
  const src = sharp(join(SRC, file), { failOn: 'none' });
  const meta = await src.metadata();
  manifest[slug] = { source: file, width: meta.width, height: meta.height };
  for (const w of WIDTHS) {
    if (w > meta.width) continue;                                    // never upscale
    const base = src.clone().resize({ width: w, withoutEnlargement: true, kernel: 'lanczos3' });
    await base.clone().avif({ quality: 62, effort: 6, chromaSubsampling: '4:4:4' }).toFile(join(OUT, `${slug}-${w}.avif`));
    await base.clone().webp({ quality: 84, effort: 5, smartSubsample: true }).toFile(join(OUT, `${slug}-${w}.webp`));
  }
  const built = WIDTHS.filter((w) => w <= meta.width);
  // the <img> fallback: the largest ladder step the source can honour, as JPEG
  await src.clone().resize({ width: Math.min(1280, meta.width), withoutEnlargement: true, kernel: 'lanczos3' })
    .jpeg({ quality: 86, mozjpeg: true, chromaSubsampling: '4:4:4' }).toFile(join(OUT, `${slug}.jpg`));
  manifest[slug].widths = built;
  console.log(`OK       ${file} → ${slug} (${meta.width}×${meta.height}) widths ${built.join(', ')}`);
}

if (present.has('Zimbabwe_Bird.svg')) {
  await copyFile(join(SRC, 'Zimbabwe_Bird.svg'), join(ROOT, 'assets/img/zimbabwe-bird.svg'));
  console.log('OK       Zimbabwe_Bird.svg → assets/img/zimbabwe-bird.svg (unchanged)');
} else { console.error('MISSING  Zimbabwe_Bird.svg'); missing++; }

await writeFile(join(OUT, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
process.exit(missing ? 1 : 0);

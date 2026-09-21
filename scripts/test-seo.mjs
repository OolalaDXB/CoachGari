#!/usr/bin/env node
/* Discoverability — offline checks on what the crawler is actually served.
   No network: everything asserted here is in the files this repo deploys.

   The point of this suite is the lesson the service-worker scope taught: a thing that is
   "obviously fine" is fine until it silently is not. Titles drift, a canonical points at
   the wrong host after a domain change, someone adds a page and forgets the sitemap, a
   noindex meets a Disallow and the pair does the opposite of what each intends.

   Run: node scripts/test-seo.mjs   */
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const SITE = 'https://coachgari28.com';
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : '  → ' + extra}`); };
const read = (p) => readFile(join(ROOT, p), 'utf8');

// The pages meant to be found, and the ones deliberately kept out of the index.
const INDEXED = [['index.html', '/'], ['legal.html', '/legal'], ['privacy.html', '/privacy']];
const HIDDEN = ['routes/a/index.html', 'routes/b/index.html', 'collab.html', 'consent.html', 'r.html', 'c.html'];

/* Intent pages: one per thing someone searches for, written as drafts. Each carries
   <meta name="cg-draft"> and must be invisible while it does — noindex, out of the
   sitemap, linked from nothing public. The checks below run in BOTH directions, which is
   what makes publishing a single decision instead of four things to remember: drop the
   draft marker and the page must be indexable and in the sitemap, or the suite fails. */
const INTENT = [
  ['padel-coaching-dubai.html', '/padel-coaching-dubai'],
  ['personal-training-dubai.html', '/personal-training-dubai'],
  ['online-coaching.html', '/online-coaching'],
  ['corporate-wellness-dubai.html', '/corporate-wellness-dubai'],
];

/* ---- every indexable page carries the four things a result needs ---- */
for (const [file, path] of INDEXED) {
  const h = await read(file);
  const title = (h.match(/<title>([^<]*)<\/title>/) || [])[1] || '';
  const desc = (h.match(/<meta name="description" content="([^"]*)"/) || [])[1] || '';
  check(`${path}: has a title of a usable length`, title.length >= 20 && title.length <= 65, `${title.length} chars: ${title}`);
  check(`${path}: has a meta description of a usable length`, desc.length >= 70 && desc.length <= 165, `${desc.length} chars`);
  check(`${path}: canonical points at its own https URL on the live host`,
    h.includes(`<link rel="canonical" href="${SITE}${path}">`), (h.match(/rel="canonical"[^>]*/) || ['none'])[0]);
  check(`${path}: exactly one h1`, (h.match(/<h1[\s>]/g) || []).length === 1, String((h.match(/<h1[\s>]/g) || []).length));
  check(`${path}: is not accidentally noindex`, !/name="robots"[^>]*noindex/.test(h));

  // Open Graph: a link shared in a message renders as a card, not a bare URL
  for (const tag of ['og:type', 'og:title', 'og:description', 'og:image', 'og:url']) {
    check(`${path}: ${tag}`, new RegExp(`property="${tag}"`).test(h));
  }
  check(`${path}: twitter:card is summary_large_image`, /name="twitter:card" content="summary_large_image"/.test(h));
  const og = (h.match(/property="og:image" content="([^"]*)"/) || [])[1] || '';
  check(`${path}: og:image is an absolute URL (relative ones are silently dropped)`, og.startsWith('https://'), og);
  const ogPath = og.replace(SITE, '').split('?')[0];
  check(`${path}: og:image resolves to a file in the repo`, !!ogPath && existsSync(join(ROOT, ogPath)), ogPath);
  const ogTitle = (h.match(/property="og:title" content="([^"]*)"/) || [])[1] || '';
  check(`${path}: og:url and og:title match the page`, h.includes(`property="og:url" content="${SITE}${path}"`) && ogTitle === title.replace(/&amp;/g, '&amp;'), ogTitle);
}

/* ---- the pages that must stay out ---- */
for (const f of HIDDEN) {
  if (!existsSync(join(ROOT, f))) { check(`${f}: exists`, false); continue; }
  const h = await read(f);
  check(`${f}: sends noindex`, /name="robots"[^>]*noindex/.test(h) || /X-Robots-Tag/i.test(h), 'no robots meta');
}

/* ---- intent pages: complete now, invisible until published ---- */
{
  const sitemap = await read('sitemap.xml');
  const publicPages = ['index.html', 'legal.html', 'privacy.html', 'routes/a/index.html', 'routes/b/index.html', 'collab.html'];
  const publicHtml = (await Promise.all(publicPages.map((p) => read(p).catch(() => '')))).join('\n');

  for (const [file, path] of INTENT) {
    if (!existsSync(join(ROOT, file))) { check(`${path}: exists`, false); continue; }
    const h = await read(file);
    const draft = /name="cg-draft"/.test(h);
    const noindex = /name="robots"[^>]*noindex/.test(h);
    const inSitemap = sitemap.includes(`${SITE}${path}`);

    // whichever state it is in, it has to be in that state completely
    check(`${path}: draft marker and noindex agree`, draft === noindex, `draft=${draft} noindex=${noindex}`);
    check(`${path}: ${draft ? 'a draft is out of the sitemap' : 'a published page is in the sitemap'}`, draft !== inSitemap, `draft=${draft} inSitemap=${inSitemap}`);
    if (draft) {
      // a link to the PAGE, not the homepage anchor of the same name: "#online-coaching"
      // is a section on the home page and has nothing to do with /online-coaching
      check(`${path}: nothing public links to it while it is a draft`,
        !publicHtml.includes(`href="${path}"`), 'linked from a public page');
      check(`${path}: carries the ribbon that says it is not live`, /class="draft-note"/.test(h));
    } else {
      check(`${path}: the draft ribbon is gone once published`, !/class="draft-note"/.test(h));
    }

    // the rest must be right from the start, so publishing is a deletion and nothing else
    const title = (h.match(/<title>([^<]*)<\/title>/) || [])[1] || '';
    const desc = (h.match(/<meta name="description" content="([^"]*)"/) || [])[1] || '';
    check(`${path}: title of a usable length`, title.length >= 20 && title.length <= 70, `${title.length}: ${title}`);
    check(`${path}: description of a usable length`, desc.length >= 70 && desc.length <= 185, String(desc.length));
    check(`${path}: canonical is its own final URL`, h.includes(`<link rel="canonical" href="${SITE}${path}">`));
    check(`${path}: exactly one h1`, (h.match(/<h1[\s>]/g) || []).length === 1);
    check(`${path}: Open Graph is complete`, ['og:type', 'og:title', 'og:description', 'og:image', 'og:url'].every((t) => h.includes(`property="${t}"`)));

    const block = (h.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/) || [])[1];
    let data = null; try { data = JSON.parse(block); } catch {}
    check(`${path}: structured data is valid JSON`, !!data, 'unparseable');
    if (data) {
      const types = (data['@graph'] || [data]).map((n) => n['@type']);
      check(`${path}: describes a Service and a breadcrumb`, types.includes('Service') && types.includes('BreadcrumbList'), types.join(','));
      // an FAQ block that markup claims but the page does not show is a rich result built on nothing
      const faq = (data['@graph'] || []).find((n) => n['@type'] === 'FAQPage');
      if (faq) {
        const asked = faq.mainEntity.map((q) => q.name);
        const shown = [...h.matchAll(/<summary>([\s\S]*?)<\/summary>/g)].map((m) => m[1].replace(/<[^>]*>/g, '').trim());
        const missing = asked.filter((q) => !shown.some((s) => s.toLowerCase().startsWith(q.toLowerCase().slice(0, 18))));
        check(`${path}: every question in the FAQ markup is actually on the page`, missing.length === 0, missing.join(' | '));
      }
    }
    // real content, not a stub: an intent page that does not out-write the homepage section it replaces is pointless
    const words = h.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->/g, '').replace(/<[^>]*>/g, ' ').split(/\s+/).filter(Boolean).length;
    check(`${path}: carries enough text to rank for anything`, words >= 450, `${words} words`);
    // and links to its siblings, so a crawler can walk between them
    const sibs = INTENT.filter(([, p]) => p !== path).filter(([, p]) => h.includes(`href="${p}"`)).length;
    check(`${path}: links to the other intent pages`, sibs >= 2, String(sibs));
  }
}

/* ---- robots.txt ---- */
{
  const r = await read('robots.txt');
  check('robots.txt: declares the sitemap, absolute', r.includes(`Sitemap: ${SITE}/sitemap.xml`));
  check('robots.txt: keeps the tokenised routes out', /Disallow: \/r\//.test(r) && /Disallow: \/c\//.test(r));
  check('robots.txt: keeps the back-office out', /Disallow: \/admin/.test(r));
  check('robots.txt: does not block the site itself', !/^Disallow: \/$/m.test(r));
  /* A page that says noindex must be crawlable, or the crawler never reads the noindex and
     can list the bare URL anyway. Disallow and noindex are not two belts for one job. */
  const disallowed = [...r.matchAll(/^Disallow: (\S+)/gm)].map((m) => m[1]);
  for (const f of HIDDEN) {
    const h = await read(f).catch(() => '');
    if (!/name="robots"[^>]*noindex/.test(h)) continue;
    const routes = { 'routes/a/index.html': '/routes/a', 'routes/b/index.html': '/routes/b', 'collab.html': '/collab', 'consent.html': '/consent', 'r.html': '/r', 'c.html': '/c' };
    const url = routes[f]; if (!url) continue;
    if (url === '/r' || url === '/c') continue;                 // tokenised: never linked, never crawled, blocked on purpose
    // robots prefixes match literally: "Disallow: /r/" blocks /r/… and not /routes/…,
    // so the trailing slash is load-bearing and must not be trimmed before comparing.
    check(`robots.txt: does not Disallow ${url}, which carries a noindex`,
      !disallowed.some((d) => url.startsWith(d)), disallowed.join(' '));
  }
}

/* ---- sitemap ---- */
{
  const s = await read('sitemap.xml');
  const locs = [...s.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
  check('sitemap: lists every indexable page, and only those',
    locs.length === INDEXED.length && INDEXED.every(([, p]) => locs.includes(`${SITE}${p}`)), locs.join(' '));
  check('sitemap: every URL is absolute and on the live host', locs.every((l) => l.startsWith(`${SITE}/`)), locs.join(' '));
  const hiddenUrls = ['/admin', '/collab', '/consent', '/routes/', '/r/', '/c/', '/p/'];
  check('sitemap: lists nothing that sends noindex or is private',
    !locs.some((l) => hiddenUrls.some((h) => l.includes(h))), locs.join(' '));
}

/* ---- structured data ---- */
{
  const h = await read('index.html');
  const block = (h.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/) || [])[1];
  check('home: carries structured data', !!block);
  let data = null;
  try { data = JSON.parse(block); check('home: the structured data is valid JSON', true); }
  catch (e) { check('home: the structured data is valid JSON', false, e.message); }
  if (data) {
    const graph = data['@graph'] || [data];
    const types = graph.map((n) => n['@type']);
    check('home: describes the person, the business and the site', ['Person', 'ProfessionalService', 'WebSite'].every((t) => types.includes(t)), types.join(','));
    const svc = graph.find((n) => n['@type'] === 'ProfessionalService');
    const offers = svc?.hasOfferCatalog?.itemListElement || [];
    check('home: the offer catalogue is not empty', offers.length >= 4, String(offers.length));
    // an offer that points at an anchor which does not exist is a promise the page breaks
    const ids = [...h.matchAll(/id="([a-z-]+)"/g)].map((m) => m[1]);
    const bad = offers.map((o) => o.itemOffered?.url || '').filter((u) => u.includes('#') && !ids.includes(u.split('#')[1]));
    check('home: every offer URL points at an anchor that exists on the page', bad.length === 0, bad.join(' '));
    /* Nothing invented to please a validator: no phone and no price, because neither is
       stated anywhere a reader could check. See the comment above the block. */
    check('home: claims no telephone it cannot back up', !JSON.stringify(data).includes('telephone'));
    check('home: claims no price in the markup', !/"price"/.test(JSON.stringify(data)));
  }
}

/* ---- the catalogue is readable without JavaScript ---- */
{
  const h = await read('index.html');
  const host = (h.match(/<div class="shop[^"]*" data-catalogue[^>]*>([\s\S]*?)<\/div>\s*<\/div>/) || [])[1] || '';
  check('home: the programmes section is not an empty spinner for a crawler', host.length > 400, `${host.length} chars`);
  for (const name of ['Online coaching', 'conversation', 'group sessions', 'Padel coaching']) {
    check(`home: "${name}" is in the served HTML, not only in the rendered page`, host.toLowerCase().includes(name.toLowerCase()));
  }
  check('home: the fallback carries no price, so it cannot drift from the database',
    !/\$|AED|USD|\bprice\b/i.test(host), host.slice(0, 120));
}

console.log(`\nSEO_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

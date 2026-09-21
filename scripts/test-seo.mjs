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

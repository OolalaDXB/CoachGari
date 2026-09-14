/* A PDF writer, by hand (CG-020).

   The agreement has to leave the database as a document someone can file, print
   and send to a lawyer. That needs a real PDF, and this project allows no
   third-party runtime dependency in an Edge Function that produces legal
   evidence — a library that changes under us changes the bytes we hashed.

   So: PDF 1.4, the two standard Helvetica faces (no font embedding, because the
   base 14 are guaranteed by every reader), WinAnsi text, and an xref table
   whose offsets are counted, not guessed.

   DETERMINISTIC ON PURPOSE. Nothing here reads the clock or a random source:
   the creation date is passed in, and the file id is derived from the content.
   The same input produces the same bytes, so the SHA-256 recorded at signature
   time keeps meaning something.

   Latin-1 only. Anything outside it is transliterated (é → e) or dropped rather
   than written as a byte the reader would show as a different letter. */

// Helvetica and Helvetica-Bold advance widths, 1000 units per em, ASCII 32..126.
const W_REG = [278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584];
const W_BOLD = [278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584];

/* Accents carry meaning in a name; a mangled byte carries a different letter.
   Fold what folds, drop what does not. */
const FOLD: Record<string, string> = {
  'à':'a','á':'a','â':'a','ä':'a','ã':'a','å':'a','ç':'c','è':'e','é':'e','ê':'e','ë':'e',
  'ì':'i','í':'i','î':'i','ï':'i','ñ':'n','ò':'o','ó':'o','ô':'o','ö':'o','õ':'o','ø':'o',
  'ù':'u','ú':'u','û':'u','ü':'u','ý':'y','ÿ':'y','œ':'oe','æ':'ae','ß':'ss',
  '’':"'", '‘':"'", '“':'"', '”':'"', '–':'-', '—':'-', '…':'...', '·':'-', '€':'EUR', ' ':' ',
};
export function latin1(s: string): string {
  let out = '';
  for (const ch of String(s ?? '')) {
    const f = FOLD[ch] ?? FOLD[ch.toLowerCase()];
    if (f) { out += ch === ch.toLowerCase() ? f : f.charAt(0).toUpperCase() + f.slice(1); continue; }
    const c = ch.codePointAt(0)!;
    out += c >= 32 && c <= 126 ? ch : (c === 10 ? '\n' : (c < 32 ? '' : '?'));
  }
  return out;
}
const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
const widthOf = (s: string, size: number, bold: boolean) => {
  const t = bold ? W_BOLD : W_REG; let w = 0;
  for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); w += (c >= 32 && c <= 126 ? t[c - 32] : 556); }
  return (w * size) / 1000;
};

/* Greedy wrap. A word longer than the line is broken rather than overflowing the
   page — a URL or a licence number must stay inside the margin. */
export function wrap(text: string, size: number, bold: boolean, max: number): string[] {
  const out: string[] = [];
  for (const para of latin1(text).split('\n')) {
    if (!para.trim()) { out.push(''); continue; }
    let line = '';
    for (const word of para.split(/\s+/)) {
      const probe = line ? line + ' ' + word : word;
      if (widthOf(probe, size, bold) <= max) { line = probe; continue; }
      if (line) out.push(line);
      if (widthOf(word, size, bold) <= max) { line = word; continue; }
      let chunk = '';
      for (const ch of word) {
        if (widthOf(chunk + ch, size, bold) > max) { out.push(chunk); chunk = ch; } else chunk += ch;
      }
      line = chunk;
    }
    out.push(line);
  }
  return out;
}

export type Block =
  | { t: 'title'; text: string }
  | { t: 'h'; text: string }
  | { t: 'p'; text: string }
  | { t: 'small'; text: string }
  | { t: 'kv'; k: string; v: string }
  | { t: 'rule' }
  | { t: 'gap' };

const PAGE_W = 595.28, PAGE_H = 841.89;          // A4, points
const M_X = 56, M_TOP = 64, M_BOT = 64;
const BODY_W = PAGE_W - M_X * 2;
const KEY_W = 132;

type Op = { s: string };

/* Lay the blocks out into pages of content-stream operators. */
function layout(blocks: Block[], footer: string): Op[][] {
  const pages: Op[][] = []; let ops: Op[] = []; let y = PAGE_H - M_TOP;
  const foot = latin1(footer);
  const newPage = () => { pages.push(ops); ops = []; y = PAGE_H - M_TOP; };
  const room = (h: number) => { if (y - h < M_BOT) newPage(); };
  const text = (s: string, x: number, size: number, bold: boolean, grey = false) => {
    ops.push({ s: `BT /${bold ? 'F2' : 'F1'} ${size} Tf ${grey ? '0.42 0.42 0.45 rg' : '0 0 0 rg'} 1 0 0 1 ${x.toFixed(2)} ${y.toFixed(2)} Tm (${esc(s)}) Tj ET` });
  };

  for (const b of blocks) {
    if (b.t === 'gap') { room(14); y -= 14; continue; }
    if (b.t === 'rule') {
      room(18); y -= 6;
      ops.push({ s: `0.85 0.85 0.87 RG 0.7 w ${M_X} ${y.toFixed(2)} m ${(PAGE_W - M_X).toFixed(2)} ${y.toFixed(2)} l S` });
      y -= 12; continue;
    }
    if (b.t === 'kv') {
      const size = 10.5;
      const vLines = wrap(b.v || '—', size, false, BODY_W - KEY_W);
      room(vLines.length * 14 + 4);
      const top = y;
      text(latin1(b.k), M_X, size, false, true);
      y = top;
      for (const l of vLines) { text(l, M_X + KEY_W, size, false); y -= 14; }
      y -= 2; continue;
    }
    const size = b.t === 'title' ? 20 : b.t === 'h' ? 12 : b.t === 'small' ? 8.6 : 10.5;
    const bold = b.t === 'title' || b.t === 'h';
    const lead = b.t === 'title' ? 26 : b.t === 'small' ? 11.5 : 14.5;
    const lines = wrap(b.text, size, bold, BODY_W);
    if (b.t === 'h') { room(lead + 8); y -= 8; }
    for (const l of lines) { room(lead); text(l, M_X, size, bold, b.t === 'small'); y -= lead; }
    if (b.t === 'title') y -= 6;
  }
  pages.push(ops);

  // page numbers and the running footer, added once the count is known
  return pages.map((p, i) => [...p, {
    s: `BT /F1 8 Tf 0.42 0.42 0.45 rg 1 0 0 1 ${M_X} ${(M_BOT - 26).toFixed(2)} Tm (${esc(foot)}) Tj ET` +
       ` BT /F1 8 Tf 0.42 0.42 0.45 rg 1 0 0 1 ${(PAGE_W - M_X - 48).toFixed(2)} ${(M_BOT - 26).toFixed(2)} Tm (${esc(`Page ${i + 1} of ${pages.length}`)}) Tj ET`,
  }]);
}

/* A PDF date string, built from the value handed in. Never from the clock. */
function pdfDate(d: Date): string {
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  return `D:${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
}

export function renderPdf(opts: { title: string; author: string; subject: string; date: Date; footer: string; blocks: Block[] }): Uint8Array {
  const pages = layout(opts.blocks, opts.footer);
  const n = pages.length;

  // object numbering: 1 catalog · 2 pages · 3 info · 4 F1 · 5 F2 · then page/content pairs
  const firstPage = 6;
  const objs: string[] = [];
  const put = (i: number, body: string) => { objs[i - 1] = body; };

  put(1, `<< /Type /Catalog /Pages 2 0 R >>`);
  put(2, `<< /Type /Pages /Count ${n} /Kids [${pages.map((_, i) => `${firstPage + i * 2} 0 R`).join(' ')}] >>`);
  put(3, `<< /Title (${esc(latin1(opts.title))}) /Author (${esc(latin1(opts.author))}) /Subject (${esc(latin1(opts.subject))}) /Producer (Coach Gari) /CreationDate (${pdfDate(opts.date)}) /ModDate (${pdfDate(opts.date)}) >>`);
  put(4, `<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>`);
  put(5, `<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>`);

  pages.forEach((ops, i) => {
    const pageNo = firstPage + i * 2, contentNo = pageNo + 1;
    const stream = ops.map((o) => o.s).join('\n');
    put(pageNo, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PAGE_W.toFixed(2)} ${PAGE_H.toFixed(2)}] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents ${contentNo} 0 R >>`);
    put(contentNo, `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  });

  // assemble, counting byte offsets as we go (Latin-1: one char, one byte)
  let out = `%PDF-1.4\n%\xE2\xE3\xCF\xD3\n`;
  const offsets: number[] = [];
  objs.forEach((body, i) => { offsets[i] = out.length; out += `${i + 1} 0 obj\n${body}\nendobj\n`; });

  // a file id derived from the content, so two identical documents are identical files
  let h = 0x811c9dc5;
  for (let i = 0; i < out.length; i++) { h ^= out.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  const id = h.toString(16).padStart(8, '0').repeat(4);

  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) out += `${String(o).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Info 3 0 R /ID [<${id}> <${id}>] >>\nstartxref\n${xref}\n%%EOF\n`;

  const bytes = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) bytes[i] = out.charCodeAt(i) & 0xff;
  return bytes;
}

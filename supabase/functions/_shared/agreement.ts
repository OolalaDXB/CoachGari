/* The collaboration agreement, as a document (CG-020).

   Until now an agreed collaboration lived only as rows. That is enough to run
   the deal and not enough to sell one: a brand's finance team files a document,
   not a database. This turns the frozen proposal into a one-file agreement and
   records how it was signed.

   ON THE SIGNATURE. This is an electronic signature under UAE Federal
   Decree-Law No. 46 of 2021 on Electronic Transactions and Trust Services. It
   is NOT a Qualified Electronic Signature — that requires a certificate from a
   trust service provider accredited by the TDRA, which this system does not
   issue and does not pretend to. What it does provide is what the law weighs
   when deciding whether an electronic signature is reliable:

     · the signatory is linked to the signature — the room link is issued to one
       deal and one counterparty, and the identity they gave at intake travels
       with it;
     · the method was under the signatory's control — a private link, revocable,
       never published;
     · the act of signing is evidenced — timestamp, salted IP hash, user agent,
       and the exact text that was on screen;
     · any later change is detectable — the record is hashed, the file is
       hashed, and both hashes are stored.

   Say no more than that in the document itself. Overclaiming the legal weight
   of a signature is the one thing that would make this worse than no document. */
import { renderPdf, type Block } from "./pdf.ts";

export type Snapshot = {
  deal: Record<string, unknown>;
  proposal: Record<string, unknown>;
  org: Record<string, unknown>;
};

const s = (o: Record<string, unknown>, k: string, d = "") => {
  const v = o?.[k];
  return v === null || v === undefined || v === "" ? d : String(v);
};

export function money(minor: unknown, cur: unknown): string {
  // null is not zero. On a contract, "AED 0.00" where nothing was agreed is a
  // wrong number, and a wrong number is worse than a blank.
  if (minor === null || minor === undefined || minor === "") return "";
  const n = Number(minor), c = String(cur ?? "").toUpperCase();
  if (!Number.isFinite(n) || !c) return "";
  const whole = (n / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${c} ${whole}`;
}

const TERM_LABELS: [string, string][] = [
  ["deliverables", "Deliverables"],
  ["timing", "Timing"],
  ["usage_rights", "Usage rights"],
  ["exclusivity", "Exclusivity"],
  ["territory", "Territory"],
  ["payment_terms", "Payment terms"],
  ["additional", "Additional terms"],
];

const TYPE_LABELS: Record<string, string> = {
  brand_partnership: "Brand partnership",
  sponsored_content: "Sponsored content",
  event_appearance: "Event appearance",
  corporate_activation: "Corporate activation",
  padel_sport: "Padel / sport",
  affiliate_ambassador: "Affiliate or ambassador",
  product_collaboration: "Product collaboration",
  other: "Collaboration",
};

/* A stable text of the record, so the same agreement always hashes the same.
   Key order is fixed here rather than taken from the database row. */
export function canonical(snap: Snapshot): string {
  const d = snap.deal, p = snap.proposal;
  const terms = (p.terms ?? {}) as Record<string, unknown>;
  const cons = Array.isArray(p.considerations) ? p.considerations as Record<string, unknown>[] : [];
  return JSON.stringify({
    ref: s(d, "public_ref"),
    version: Number(p.version_number ?? 0),
    type: s(d, "collaboration_type"),
    title: s(d, "title"),
    counterparty: { name: s(d, "contact_name"), company: s(d, "company"), email: s(d, "contact_email") },
    intro: s(p, "intro"),
    amount: p.monetary_amount ?? null,
    currency: s(p, "currency"),
    considerations: cons.map((c) => ({
      type: s(c, "type"), description: s(c, "description"),
      amount: c.amount ?? null, currency: s(c, "currency"),
      estimated_value: c.estimated_value ?? null, estimated_value_currency: s(c, "estimated_value_currency"),
    })),
    terms: Object.fromEntries(TERM_LABELS.map(([k]) => [k, String(terms[k] ?? "")])),
    accepted_at: s(p, "accepted_at"),
  });
}

export async function sha256hex(input: string | Uint8Array): Promise<string> {
  const data = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const d = await crypto.subtle.digest("SHA-256", data as BufferSource);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const when = (iso: string, tz: string) => {
  try {
    return new Intl.DateTimeFormat("en-GB", { dateStyle: "long", timeStyle: "short", timeZone: tz }).format(new Date(iso)) + ` (${tz})`;
  } catch { return iso; }
};

/* → { bytes, recordHash }. The file hash is taken by the caller from the bytes,
   so the two hashes are computed over genuinely different things. */
export async function buildAgreement(snap: Snapshot): Promise<{ bytes: Uint8Array; recordHash: string; blocks: Block[] }> {
  const d = snap.deal, p = snap.proposal, org = snap.org ?? {};
  const recordHash = await sha256hex(canonical(snap));
  const acceptedAt = s(p, "accepted_at") || new Date(0).toISOString();
  const ev = (p.accepted_evidence ?? {}) as Record<string, unknown>;
  const terms = (p.terms ?? {}) as Record<string, unknown>;
  const cons = Array.isArray(p.considerations) ? p.considerations as Record<string, unknown>[] : [];
  const ref = s(d, "public_ref");

  const coachName = s(org, "legal_name") || s(org, "trading_name") || "Coach Gari";
  const counterparty = s(d, "company") || s(d, "contact_name") || "the Counterparty";

  const blocks: Block[] = [
    { t: "title", text: "Collaboration Agreement" },
    { t: "small", text: `${TYPE_LABELS[s(d, "collaboration_type")] ?? "Collaboration"} · Reference ${ref} · Version ${s(p, "version_number", "1")}` },
    { t: "rule" },

    { t: "h", text: "The parties" },
    { t: "kv", k: "Coach", v: [coachName, s(org, "licence_no") && `Licence ${s(org, "licence_no")}`, s(org, "jurisdiction"), s(org, "address"), s(org, "email")].filter(Boolean).join("\n") },
    { t: "kv", k: "Counterparty", v: [s(d, "company"), s(d, "contact_name"), s(d, "contact_email"), s(d, "contact_phone")].filter(Boolean).join("\n") || "—" },

    { t: "h", text: "What is agreed" },
  ];

  if (s(d, "title")) blocks.push({ t: "kv", k: "Subject", v: s(d, "title") });
  if (s(p, "intro")) blocks.push({ t: "p", text: s(p, "intro") });
  if (s(d, "location")) blocks.push({ t: "kv", k: "Location", v: s(d, "location") });
  if (s(d, "proposed_date_from")) {
    const to = s(d, "proposed_date_to");
    blocks.push({ t: "kv", k: "Dates", v: to && to !== s(d, "proposed_date_from") ? `${s(d, "proposed_date_from")} to ${to}` : s(d, "proposed_date_from") });
  }

  blocks.push({ t: "h", text: "Consideration" });
  const fee = money(p.monetary_amount, p.currency);
  blocks.push({ t: "kv", k: "Fee", v: fee || "No cash fee" });
  if (cons.length) {
    for (const c of cons) {
      const val = money(c.amount, c.currency) || money(c.estimated_value, c.estimated_value_currency);
      blocks.push({
        t: "kv",
        k: s(c, "type") === "monetary" ? "Cash item" : "In kind",
        v: [s(c, "description", "—"), val && `Value: ${val}`].filter(Boolean).join("\n"),
      });
    }
    if (cons.some((c) => s(c, "type") !== "monetary")) {
      blocks.push({ t: "small", text: "A value shown against an in-kind item is an estimate recorded for the parties' reference. It is not a cash amount payable." });
    }
  }

  const written = TERM_LABELS.filter(([k]) => String(terms[k] ?? "").trim());
  if (written.length) {
    blocks.push({ t: "h", text: "Terms" });
    for (const [k, label] of written) blocks.push({ t: "kv", k: label, v: String(terms[k]) });
  }

  blocks.push(
    { t: "h", text: "Acceptance" },
    { t: "p", text: `${counterparty} accepted version ${s(p, "version_number", "1")} of this proposal through the private collaboration room issued for reference ${ref}. The acceptance was recorded by the system at the moment it was given; the text above is the text that was on screen.` },
    { t: "kv", k: "Accepted", v: when(acceptedAt, "Asia/Dubai") },
    { t: "kv", k: "Accepted (UTC)", v: acceptedAt },
    { t: "kv", k: "By", v: s(ev, "by") === "coach" ? `${coachName} (${s(ev, "actor", "operator")})` : counterparty },
    { t: "kv", k: "Method", v: s(ev, "method") === "room_link" ? "Private collaboration room link" : s(ev, "method", "Back-office") },
    { t: "kv", k: "Device", v: s(ev, "user_agent", "Not recorded") },
    { t: "kv", k: "Network identity", v: s(ev, "ip_hash") ? `Salted SHA-256: ${s(ev, "ip_hash")}` : "Not recorded" },
    { t: "small", text: "The network identity is a one-way salted hash. The originating IP address is never stored, and the hash cannot be reversed to recover it." },

    { t: "h", text: "Electronic signature" },
    { t: "p", text: "This agreement is concluded by electronic signature under Federal Decree-Law No. 46 of 2021 of the United Arab Emirates concerning Electronic Transactions and Trust Services. The parties agree that an electronic signature satisfies any requirement of signature and that this document is admissible as evidence of what was agreed." },
    { t: "p", text: "This is an electronic signature, not a Qualified Electronic Signature: no certificate issued by a trust service provider accredited by the Telecommunications and Digital Government Regulatory Authority is attached. Its reliability rests on the record below." },
    { t: "kv", k: "Record hash", v: `SHA-256 ${recordHash}` },
    { t: "small", text: "The record hash covers the terms, the consideration and the moment of acceptance. The issuer separately records the SHA-256 of this file. Any change to either is detectable by recomputing the hash." },

    { t: "h", text: "Governing law" },
    { t: "p", text: `This agreement is governed by the laws of the United Arab Emirates${s(org, "jurisdiction") ? ` as applied in ${s(org, "jurisdiction")}` : ""}, and the parties submit to the competent courts of that jurisdiction.` },
    { t: "gap" },
    { t: "small", text: `Issued by ${coachName}${s(org, "website") ? ` · ${s(org, "website")}` : ""}. This document was generated from the accepted record; it is not a draft for negotiation.` },
  );

  const bytes = renderPdf({
    title: `Collaboration Agreement ${ref}`,
    author: coachName,
    subject: `Collaboration agreement between ${coachName} and ${counterparty}`,
    date: new Date(acceptedAt),
    footer: `${ref} · version ${s(p, "version_number", "1")} · record ${recordHash.slice(0, 16)}`,
    blocks,
  });

  return { bytes, recordHash, blocks };
}

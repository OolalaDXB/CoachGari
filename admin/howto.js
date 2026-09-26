/* =====================================================================
   How to — the back-office explaining itself.

   Written here rather than linked to a document elsewhere, for one reason
   that decides it: when a button is renamed, the page describing it changes
   in the SAME commit. A guide that lives outside the code drifts, and a
   drifted guide is worse than none — it teaches a screen that no longer
   exists and costs the reader their trust in the rest of it.

   It also means the pages work where the coach actually is: offline in the
   installed app, on a phone between clients, with no second account to hold
   and nothing to share.

   Every page here is written for the person doing the work, not for the
   person who built it. Two rules kept while writing:

     * say what is NOT automatic as plainly as what is. Most of the wasted
       hours in a back-office come from believing something was sent;
     * name the screen and the button exactly as they are labelled. A guide
       that paraphrases the interface makes the reader translate.

   Deep links: #howto/<topic>. Other screens link into a topic directly, so
   "How does this work?" lands on the paragraph rather than on a contents
   page the reader then has to search.
   ===================================================================== */
let C = null;
export function initHowto(ctx) { C = ctx; }

const SITE = () => (typeof location !== 'undefined' ? location.origin : '');

/* Prose lives in one place per topic. Kept as plain strings rather than a
   markdown renderer: three pages do not justify a parser, and a parser is one
   more thing that can render a half-escaped client name one day. */
const TOPICS = {
  leads: {
    label: 'A new lead',
    title: 'When a lead arrives',
    lead: 'Nothing is sent to the person automatically. The first message they get is one you write.',
    body: () => `
      <h3>What happens on its own</h3>
      <p><b>You get an email</b> at letsgo@coachgari28.com with their name, how to reach them, where they
      are and what they asked about. That is your signal.</p>
      <p><b>They get an email back — only if they left an email address.</b> Most leads so far have left a
      phone number instead, so the acknowledgement had nobody to go to. Assume they have heard nothing
      from you yet.</p>
      <p><b>No WhatsApp message is ever sent automatically.</b> This is not a setting waiting to be
      switched on: WhatsApp does not allow a business to send free text to someone who has not written
      first — only a template approved by Meta in advance.</p>

      <h3>Writing the first message</h3>
      <p>Open <b>Clients → Leads</b> and click the row. On their record, next to the phone number, press
      <b>Message</b>.</p>
      <p>Pick one of the three starters, edit the words, and press <b>Open WhatsApp</b>. WhatsApp opens with
      the text ready; you press send there.</p>
      <p>The message is then saved to their notes, marked <i>opened</i> — not <i>sent</i>. The last step
      happened inside WhatsApp, where this app cannot see it, and a note that claimed more than it knows
      would be worth less than none.</p>
      <p>If the button reads <b>Not reachable</b>, the number on file is incomplete. Ask the person for it
      rather than guessing — a number one digit off belongs to somebody else.</p>`,
    go: [['Open Leads', '#crm/leads']],
  },

  packages: {
    label: 'Packages',
    title: 'Selling a package',
    lead: 'A package is what turns a conversation into something you can charge for and count.',
    body: () => `
      <h3>Creating it</h3>
      <p>On the client's record, open <b>Sessions</b> and press <b>New package</b>.</p>
      <ul>
        <li><b>Title</b> — what you are selling, in their words. This is printed on their receipt and on
        the payment page.</li>
        <li><b>Total sessions</b> — how many sessions it buys. Each session you log counts against it.
        A one-off payment is simply <b>1</b>.</li>
        <li><b>Price</b> and <b>Currency</b> — this becomes the amount on the link.</li>
        <li><b>Status</b> — leave it <code>unpaid</code>. It turns to paid by itself when the money lands.</li>
      </ul>
      <p>The title is worth a second's thought: it is photographed at the moment of sale, so changing it
      later does not rewrite what the client already read.</p>

      <h3>Sending it to them</h3>
      <p>Open the package and press <b>Recap &amp; share</b>. A secure link is created, with a message
      already written — their name, the package, sessions used, the amount due and the payment reference.
      Edit it, then choose <b>WhatsApp</b>, <b>Email</b>, <b>Copy message</b> or <b>Copy link</b>.</p>
      <p>Nothing is sent for you. You read it and you send it.</p>
      <p>The client's page offers <b>card, Aani or bank transfer</b>. It shows the recap and the payment —
      never body measurements, health data or your private notes.</p>
      <p>Sent to the wrong person? <b>Revoke link</b>, in the same place, kills it immediately.</p>

      <h3>After the session</h3>
      <p>Use <b>Done</b> and the one-line note on the session card. Five seconds, and it is what makes the
      client's history worth reading in three months.</p>`,
    go: [['Open Clients', '#crm/contacts']],
  },

  links: {
    label: 'Payment links',
    title: 'A payment link for anyone',
    lead: 'A label, an amount and a URL — for someone with no package, and who need not be in the system at all.',
    body: () => `
      <p>Use this when there is no course of sessions to track: someone you met at the court, a friend of a
      client, a single session quoted over the phone.</p>

      <h3>Making one</h3>
      <p>Go to <b>Finance → Payment links</b> and fill four fields:</p>
      <ul>
        <li><b>What it is for</b> — the label. This is what the payer reads on the page and on their bank
        statement, so write it as they would understand it: <i>Strength Training — September</i>, not
        <i>PL-3</i>.</li>
        <li><b>Amount</b> and <b>Currency</b>.</li>
        <li><b>Valid for</b> — 7, 30 or 90 days. After that the link says it has expired instead of taking
        money.</li>
      </ul>
      <p>Press <b>Create link</b>. It appears once, at the top: <b>Copy link</b> or <b>Copy message</b>.
      Copy it before you leave the page — it is stored scrambled, so nothing can show it to you again. If
      you lose it, withdraw that link and make another; no harm done.</p>

      <h3>Afterwards</h3>
      <p>Every link you have made is listed below, with its status. <b>Withdraw</b> kills one that has not
      been paid. A link that <i>has</i> been paid cannot be withdrawn — that is the point of it.</p>
      <p>This kind takes <b>card only</b> today. If you need Aani or a bank transfer, sell it as a package
      instead.</p>
      <p>The payment lands in <b>Finance → Transactions</b> with everything else.</p>`,
    go: [['Open Payment links', '#finance/links']],
  },

  choosing: {
    label: 'Which link?',
    title: 'Package link, or Finance link?',
    lead: 'If you will be counting their sessions, use a package. Otherwise a Finance link is faster.',
    body: () => `
      <div class="ad-table-wrap"><table class="ad-table"><tbody>
        <tr><th></th><th>Package link</th><th>Finance link</th></tr>
        <tr><td>Use it when</td><td>They are becoming a client</td><td>One-off, or not in the system</td></tr>
        <tr><td>Needs a client record</td><td>Yes</td><td>No</td></tr>
        <tr><td>Counts sessions</td><td>Yes</td><td>No</td></tr>
        <tr><td>Ways to pay</td><td>Card, Aani, bank transfer</td><td>Card</td></tr>
        <tr><td>Where</td><td>Their record → Sessions → Recap &amp; share</td><td>Finance → Payment links</td></tr>
      </tbody></table></div>
      <p>Both end in the same place: the payment appears in <b>Finance → Transactions</b>, and the person's
      card statement reads the label you wrote.</p>

      <h3>The one thing that is automatic</h3>
      <p>Once somebody is a client, they get <b>a reminder the day before a session</b>, by email. It can
      also go by WhatsApp — but only for people who have agreed, and that switch is on their own record.
      <b>A phone number on file is not permission.</b></p>`,
    go: [['Open Finance', '#finance/transactions']],
  },
};

export const HOWTO_KEYS = Object.keys(TOPICS);

/* One screen per topic, so the sub-navigation is the contents page and a deep
   link lands on the answer rather than on a list of questions. */
export function howtoScreen(key) {
  return async function () {
    const { esc, view } = C;
    const t = TOPICS[key] || TOPICS.leads;
    view.innerHTML = `
      <div class="ad-head"><div><h1>${esc(t.title)}</h1><p class="ad-muted">${esc(t.lead)}</p></div></div>
      <div class="ad-panel ho-page">${t.body()}</div>
      ${(t.go || []).length ? `<div class="cg-actions" style="margin-top:14px">
        ${t.go.map(([label, href]) => `<a class="btn btn-accent btn-sm" href="${esc(href)}">${esc(label)} →</a>`).join('')}
      </div>` : ''}`;
  };
}

/* The link other screens use. Small, quiet, and it goes straight to the topic —
   a "How does this work?" that opens a contents page has not helped anyone. */
export function howtoLink(key, label = 'How does this work?') {
  return `<a class="ho-hint" href="#howto/${key}">${label}</a>`;
}

export function howtoSubs() {
  return HOWTO_KEYS.map((k) => ({ key: k, label: TOPICS[k].label, show: () => true, run: howtoScreen(k) }));
}

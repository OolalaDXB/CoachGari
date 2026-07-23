/* ============================================================
   Basic-Auth gate for the proposal page (index.html) only.
   Everything under /routes/* stays public.

   The password is read from the PROPOSAL_PASSWORD environment
   variable — set it in Vercel:
     Project → Settings → Environment Variables → PROPOSAL_PASSWORD
   The username is "gari".

   If PROPOSAL_PASSWORD is unset the proposal stays locked for
   everyone (fails closed) — it is never exposed by accident.

   This runs on the free tier (Edge Middleware), unlike Vercel's
   native Password Protection, and it scopes protection to the
   proposal alone rather than the whole site.
   ============================================================ */
export const config = { matcher: ['/', '/index.html'] };

export default function middleware(request) {
  const USER = 'gari';
  const PASS =
    (globalThis.process && globalThis.process.env && globalThis.process.env.PROPOSAL_PASSWORD) || '';

  const header = request.headers.get('authorization') || '';
  const [scheme, encoded] = header.split(' ');

  if (PASS && scheme === 'Basic' && encoded) {
    const decoded = atob(encoded);
    const i = decoded.indexOf(':');
    if (decoded.slice(0, i) === USER && decoded.slice(i + 1) === PASS) {
      return; // credentials OK — let the request through
    }
  }

  return new Response('Authentication required.', {
    status: 401,
    headers: {
      'WWW-Authenticate': 'Basic realm="Coach Gari — proposal", charset="UTF-8"',
    },
  });
}

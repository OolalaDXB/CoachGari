/* =============================================================
   Coach Gari — browser origin allowlist shared by every browser-facing
   Edge Function (booking, contact, upload, consent, checkout, report).

   One list, one rule. Never `Access-Control-Allow-Origin: *`: the allowed
   origin is echoed back only when it is on this list. Requests without an
   Origin header (curl, tests, server-to-server) are not a CORS concern and
   pass; every function still validates its own input and permissions.

   Canonical production domain: https://coachgari28.com (www allowed during
   the redirect/cut-over). coachgari.com stays allowed for the earlier and
   future apex. The Vercel production alias and the project's own preview /
   branch deployments (coachgariv0-*.vercel.app) stay allowed for testing;
   other *.vercel.app sites are not.
   ============================================================= */

export const ALLOWED_ORIGINS: ReadonlySet<string> = new Set([
  "https://coachgari28.com",
  "https://www.coachgari28.com",
  "https://coachgari.com",
  "https://www.coachgari.com",
  "https://coachgariv0.vercel.app",
]);

export const ALLOWED_ORIGIN_PATTERNS: readonly RegExp[] = [
  /^https:\/\/coachgariv0(-[a-z0-9-]+)?\.vercel\.app$/i,   // Vercel preview / branch aliases of this project
  /^http:\/\/localhost(:\d+)?$/i,
  /^http:\/\/127\.0\.0\.1(:\d+)?$/i,
];

export function originAllowed(origin: string | null): boolean {
  if (!origin) return true;
  return ALLOWED_ORIGINS.has(origin) || ALLOWED_ORIGIN_PATTERNS.some((re) => re.test(origin));
}

/** JSON response headers with CORS echoed only for an allowed origin. */
export function corsHeaders(origin: string | null, allowed: boolean, methods = "POST, OPTIONS"): Record<string, string> {
  const h: Record<string, string> = {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  };
  if (origin && allowed) {
    h["Access-Control-Allow-Origin"] = origin;
    h["Access-Control-Allow-Methods"] = methods;
    h["Access-Control-Allow-Headers"] = "Content-Type";
    h["Access-Control-Max-Age"] = "86400";
  }
  return h;
}

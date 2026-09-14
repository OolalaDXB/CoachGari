/* The pure parts of the Plausible sync: what window to ask for, what to leave
   out, and how to read a secret that may have been stored wrapped.

   They live here rather than in the function because they import nothing —
   no Deno, no npm — so a test can run them for real instead of reading the
   source and hoping. Everything that needs the network or the database stays
   in ../analytics-sync/index.ts. */

/* A secret pasted into `supabase secrets set` often arrives wrapped: a trailing
   newline from a copy, or the quotes the shell was supposed to eat. Both are
   invisible in every dashboard and both produce an authentication failure that
   looks exactly like a wrong key, which is an hour spent looking in the wrong
   place. Trim, then drop ONE matching pair of surrounding quotes — never more,
   because a quote can legitimately be part of a secret. */
export function cleanSecret(raw: string | undefined | null): string {
  let v = (raw ?? "").trim();
  if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1).trim();
  return v;
}

/* THE BACK-OFFICE IS NOT TRAFFIC. /admin is the coach at work, and counting his
   working day as audience is the most flattering and least useful mistake a
   dashboard can make: the figure rises exactly when nobody new arrived.

   The exclusion is expressed as a Plausible filter so it applies inside the
   query. Filtering our own table afterwards would not give the same answer: a
   visitor who saw a public page and then an admin page is one visitor either
   way, and only Plausible can decide which sessions that leaves.

   Anything that is not a path is dropped rather than sent — a filter Plausible
   rejects would cost the whole sync, and a silently wrong filter would cost the
   numbers. */
export function excludeFilter(paths: readonly string[]): unknown[] {
  return (paths ?? [])
    .filter((p) => typeof p === "string" && p.startsWith("/"))
    .map((p) => ["not", ["contains", "event:page", [p]]]);
}

/* The window starts the day the site went live, not "the last 60 days": before
   that it is the build — our own visits, the checks before launch, the test
   payment — and nothing downstream can tell one from the other afterwards.

   A start date that has not arrived yet returns NULL rather than a range
   clamped to today. Clamping looks harmless and is not: the daily series is
   guarded row by row and would reject today as too early, while the totals —
   sources, goals, countries — would happily report it, and the screen would
   show five visitors from nowhere beside a chart that says there is nothing.
   One window or no window; never a different one per panel. */
export function dateRange(startDate: string, today: Date = new Date()): [string, string] | null {
  const end = today.toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(startDate ?? "")) return [end, end];
  if (startDate > end) return null;
  return [startDate, end];
}

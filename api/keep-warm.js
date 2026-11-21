// Keeps the free Supabase project from pausing.
//
// A free project pauses after a week of too little database activity, and a
// paused project loses its DNS record, so the console would show "Failed to
// fetch" with nothing to say why. Supabase's docs say "a few user requests to
// the database each day over the previous week" typically prevents it.
//
// vercel.json runs this once a day as a Vercel Cron Job, the most the Hobby
// plan allows, so each run makes several different reads. It runs on Vercel,
// not GitHub Actions, on purpose: my other project's keep-warm ran on Actions
// and stopped silently when the GitHub account was locked over billing.
//
// It reads with the public anon key through the same public-read policies the
// console uses, so the endpoint needs no secret.

const READS = [
  'plans?select=id&limit=1',
  'ticket_queue?select=id&limit=1',
  'invoice_overview?select=id&limit=1',
  'playbook_stats?select=playbook&limit=1',
];

export async function GET() {
  const url = process.env.VITE_SUPABASE_URL;
  const key = process.env.VITE_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return Response.json(
      { ok: false, error: 'VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY is not set for this deployment' },
      { status: 500 },
    );
  }

  const results = [];
  for (const path of READS) {
    try {
      const r = await fetch(`${url}/rest/v1/${path}`, { headers: { apikey: key } });
      results.push({ path, status: r.status });
    } catch (e) {
      // A paused project loses its DNS record, so the fetch itself throws.
      results.push({ path, status: 0, error: e.cause?.code || e.message });
    }
  }

  const ok = results.every((r) => r.status === 200);
  // 502 makes a failed run stand out in the Vercel logs and cron history.
  return Response.json({ ok, at: new Date().toISOString(), results }, { status: ok ? 200 : 502 });
}

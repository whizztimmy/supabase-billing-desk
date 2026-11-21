import { useMemo } from 'react';
import { supabase } from '../supabase';
import { useQuery } from '../api';
import { dateOnly, duration, titleCase, usd } from '../format';
import { Badge, ErrorNote, SkeletonRows } from '../components/ui';
import type { PlaybookStat, SpendSignal, WeeklyCount } from '../types';

const RECENT_WEEKS = 4;

// Weekly ticket counts for one cause. Each row is drawn on its own scale, so
// the shape of the trend is readable even for a small cause; the last four
// weeks are in the accent colour, the weeks before in grey.
function Sparkline({ weeks, counts, label }: { weeks: string[]; counts: number[]; label: string }) {
  const width = 150;
  const height = 28;
  const gap = 2;
  const bar = (width - gap * (weeks.length - 1)) / weeks.length;
  const max = Math.max(1, ...counts);
  return (
    <svg className="spark" width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img"
         aria-label={`${label}: ${counts.join(', ')} tickets a week over ${weeks.length} weeks`}>
      {counts.map((n, i) => {
        const h = n === 0 ? 1 : Math.max(2, (n / max) * height);
        return (
          <rect key={weeks[i]} x={i * (bar + gap)} y={height - h} width={bar} height={h} rx={1.5}
                className={i >= weeks.length - RECENT_WEEKS ? '' : 'quiet'}>
            <title>{`Week from ${dateOnly(weeks[i])}: ${n} ticket${n === 1 ? '' : 's'}`}</title>
          </rect>
        );
      })}
    </svg>
  );
}

export default function Patterns() {
  const stats = useQuery<PlaybookStat[]>('playbook-stats', () => supabase.from('playbook_stats').select('*'));
  const weekly = useQuery<WeeklyCount[]>('tickets-weekly', () => supabase.from('tickets_weekly').select('*').order('week_start'));
  const signals = useQuery<SpendSignal[]>('spend-signals', () => supabase.from('spend_spike_signals').select('*'));

  const rows = useMemo(() => {
    const weeks = [...new Set((weekly.data ?? []).map((w) => w.week_start))].sort();
    return (stats.data ?? [])
      .filter((s) => s.tickets > 0)
      .sort((a, b) => b.tickets - a.tickets)
      .map((s) => {
        const counts = weeks.map((w) => weekly.data?.find((x) => x.week_start === w && x.playbook === s.playbook)?.tickets ?? 0);
        const recent = counts.slice(-RECENT_WEEKS).reduce((a, b) => a + b, 0);
        const before = counts.slice(-2 * RECENT_WEEKS, -RECENT_WEEKS).reduce((a, b) => a + b, 0);
        return { ...s, weeks, counts, recent, before, rising: recent >= 8 && recent >= before * 1.5 };
      });
  }, [stats.data, weekly.data]);

  const total = rows.reduce((sum, r) => sum + r.tickets, 0);
  const maxShare = Math.max(1, ...rows.map((r) => Number(r.share_pct ?? 0)));
  const rising = rows.filter((r) => r.rising).sort((a, b) => (b.recent - b.before) - (a.recent - a.before))[0];
  const loading = stats.loading || weekly.loading;

  return (
    <main className="page">
      <div className="page-head">
        <div>
          <h1>Patterns</h1>
          <p>Every solved ticket records the playbook that settled it. Counted over twelve weeks, that shows which causes fill the queue, and which one is growing and deserves a doc, a product change or a tool.</p>
        </div>
      </div>

      {(stats.error || weekly.error) && <ErrorNote message={(stats.error ?? weekly.error)!} />}

      {rising && (
        <div className="callout amber" style={{ marginBottom: 20 }}>
          <strong>{rising.title} is climbing.</strong> {rising.recent} tickets in the last four weeks against {rising.before} in
          the four before. That is the cause to act on first: a clearer line in the docs or the dashboard would remove
          the question before it reaches support.
        </div>
      )}

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Cause</th>
              <th className="num">Tickets</th>
              <th>Share of {total || ''} solved</th>
              <th className="hide-narrow">Weekly trend</th>
              <th className="num hide-narrow">Median first reply</th>
              <th className="num hide-narrow">Escalated</th>
            </tr>
          </thead>
          <tbody>
            {loading && <SkeletonRows columns={6} rows={8} />}
            {!loading && rows.map((r) => (
              <tr key={r.playbook}>
                <td>
                  <span className="primary">{r.title}</span>{' '}
                  {r.rising && <Badge tone="amber">Rising</Badge>}
                </td>
                <td className="num">{r.tickets}</td>
                <td>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <div className="bar-track" style={{ flex: 1 }} title={`${r.share_pct}% of solved tickets`}>
                      <div className="bar-fill" style={{ width: `${(Number(r.share_pct ?? 0) / maxShare) * 100}%` }} />
                    </div>
                    <span className="num muted small" style={{ width: 44 }}>{r.share_pct}%</span>
                  </div>
                </td>
                <td className="hide-narrow"><Sparkline weeks={r.weeks} counts={r.counts} label={r.title} /></td>
                <td className="num hide-narrow">{r.median_first_response_min === null ? '' : duration(Number(r.median_first_response_min) / 60)}</td>
                <td className="num hide-narrow">{r.escalated || ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted small" style={{ marginTop: 8 }}>
        Each trend is drawn on its own scale. The last four weeks are highlighted; hover a bar for its count.
      </p>

      <h2 style={{ marginTop: 36 }}>Spend signals</h2>
      <p className="muted" style={{ margin: '4px 0 14px', maxWidth: '68ch' }}>
        Organizations under 30 days old that are running compute far beyond anything they have paid for. Seen on the
        day, this is a message to the customer. Seen as an unpaid invoice weeks later, it is a loss.
      </p>
      {signals.error && <ErrorNote message={signals.error} />}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Organization</th><th>Plan</th><th className="num">Age</th><th>Largest compute</th>
              <th className="num">Monthly run rate</th><th className="num">Paid to date</th>
            </tr>
          </thead>
          <tbody>
            {signals.loading && <SkeletonRows columns={6} rows={1} />}
            {signals.data?.map((s) => (
              <tr key={s.org_id}>
                <td><span className="primary">{s.name}</span><div className="secondary mono">{s.org_id}</div></td>
                <td>{titleCase(s.plan)}</td>
                <td className="num">{s.age_days} days</td>
                <td>{s.largest_size}</td>
                <td className="num">{usd(s.monthly_run_rate)}</td>
                <td className="num">{usd(s.lifetime_paid)}</td>
              </tr>
            ))}
            {signals.data?.length === 0 && <tr><td colSpan={6} className="empty">No signals today.</td></tr>}
          </tbody>
        </table>
      </div>
    </main>
  );
}

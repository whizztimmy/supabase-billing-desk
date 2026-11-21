import { useMemo } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { supabase } from '../supabase';
import { useQuery } from '../api';
import { duration, hoursBetween, titleCase } from '../format';
import { useDemoNow } from '../App';
import { Badge, ErrorNote, SkeletonRows, Status, severityTone, slaTone } from '../components/ui';
import type { QueueTicket } from '../types';

const VIEWS: { id: string; label: string; test: (t: QueueTicket) => boolean }[] = [
  { id: 'all', label: 'All open', test: () => true },
  { id: 'overdue', label: 'Reply overdue', test: (t) => t.sla_state === 'overdue' },
  { id: 'escalate', label: 'To escalate', test: (t) => t.escalate_to !== null },
  { id: 'payments', label: 'Failed payments', test: (t) => t.topic === 'failed payment' },
  { id: 'refunds', label: 'Refund enquiries', test: (t) => t.category === 'Refund enquiry' },
];

// "due in 40m" or "1h 20m over", measured against the demo's fixed clock.
function dueLabel(ticket: QueueTicket, now: string | null): string {
  if (!now) return '';
  const hours = hoursBetween(now, ticket.first_response_due);
  return hours < 0 ? `${duration(hours)} over` : `due in ${duration(hours)}`;
}

export default function Inbox() {
  const navigate = useNavigate();
  const now = useDemoNow();
  const [params, setParams] = useSearchParams();
  const view = VIEWS.find((v) => v.id === params.get('view')) ?? VIEWS[0];
  const search = params.get('q') ?? '';

  const queue = useQuery<QueueTicket[]>('queue', () =>
    supabase.from('ticket_queue').select('*').order('first_response_due', { ascending: true }));

  const tickets = queue.data ?? [];
  const visible = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return tickets.filter(view.test).filter((t) =>
      !needle || `${t.subject} ${t.org_name} ${t.requester_name} ${t.diagnosis}`.toLowerCase().includes(needle));
  }, [tickets, view, search]);

  function update(next: Record<string, string>) {
    const merged = new URLSearchParams(params);
    for (const [k, v] of Object.entries(next)) {
      if (v && v !== 'all') merged.set(k, v); else merged.delete(k);
    }
    setParams(merged, { replace: true });
  }

  const count = (id: string) => tickets.filter(VIEWS.find((v) => v.id === id)!.test).length;

  return (
    <main className="page">
      <div className="page-head">
        <div>
          <h1>Inbox</h1>
          <p>Open billing tickets, sorted by when the first reply is due. Each one has already been checked against the account, so the cause is on the row.</p>
        </div>
      </div>

      <dl className="summary">
        <div><dt>Open tickets</dt><dd>{queue.loading ? ' ' : tickets.length}</dd></div>
        <div><dt>Reply overdue</dt><dd>{queue.loading ? ' ' : count('overdue')}</dd></div>
        <div><dt>Billing errors to escalate</dt><dd>{queue.loading ? ' ' : tickets.filter((t) => t.escalate_to === 'Billing Engineering').length}</dd></div>
        <div><dt>No playbook matched</dt><dd>{queue.loading ? ' ' : tickets.filter((t) => t.playbook === 'needs_review').length}</dd></div>
      </dl>

      <div className="toolbar">
        <div className="tabs" role="tablist" aria-label="Views">
          {VIEWS.map((v) => (
            <button key={v.id} type="button" role="tab" aria-selected={v.id === view.id}
                    className={v.id === view.id ? 'active' : ''} onClick={() => update({ view: v.id })}>
              {v.label} <span className="count">{queue.loading ? '' : count(v.id)}</span>
            </button>
          ))}
        </div>
        <input className="input search" type="search" placeholder="Search subject, customer or cause"
               aria-label="Search tickets" value={search} onChange={(e) => update({ q: e.target.value })} />
      </div>

      {queue.error && <div style={{ marginTop: 16 }}><ErrorNote message={queue.error} /></div>}

      <div className="table-wrap stack" style={{ marginTop: 16 }}>
        <table>
          <thead>
            <tr>
              <th>First reply</th>
              <th>Severity</th>
              <th>Ticket</th>
              <th className="hide-narrow">Customer says</th>
              <th>Account shows</th>
            </tr>
          </thead>
          <tbody>
            {queue.loading && <SkeletonRows columns={5} rows={8} />}
            {!queue.loading && visible.map((t) => (
              <tr key={t.id} className="clickable" onClick={() => navigate(`/tickets/${t.id}`)}>
                <td>
                  <Status tone={slaTone[t.sla_state]}>{titleCase(t.sla_state)}</Status>
                  <div className="secondary">{dueLabel(t, now)}</div>
                </td>
                <td><Badge tone={severityTone[t.severity]}>{t.severity}</Badge></td>
                <td>
                  <Link to={`/tickets/${t.id}`} className="primary" onClick={(e) => e.stopPropagation()}>{t.subject}</Link>
                  <div className="secondary">{t.requester_name} · {t.org_name} · {titleCase(t.plan)}</div>
                </td>
                <td className="hide-narrow">{titleCase(t.topic)}</td>
                <td>
                  <div>{t.diagnosis}</div>
                  {t.escalate_to && <div style={{ marginTop: 4 }}><Badge tone="blue">Escalate to {t.escalate_to}</Badge></div>}
                </td>
              </tr>
            ))}
            {!queue.loading && !queue.error && visible.length === 0 && (
              <tr><td colSpan={5} className="empty">No tickets match this view.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </main>
  );
}

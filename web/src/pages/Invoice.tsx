import { Link, useParams } from 'react-router-dom';
import { supabase } from '../supabase';
import { useQuery } from '../api';
import { day, dayTime, titleCase, usd } from '../format';
import { Badge, ErrorNote, SkeletonLines, Status, invoiceTone } from '../components/ui';
import InvoiceLines from '../components/InvoiceLines';
import type { Dispute, InvoiceLine, InvoiceOverview, PaymentAttempt } from '../types';

export default function Invoice() {
  const { id } = useParams();
  const invoiceId = Number(id);

  const invoice = useQuery<InvoiceOverview>(`invoice-${id}`, () =>
    supabase.from('invoice_overview').select('*').eq('id', invoiceId).single());
  const lines = useQuery<InvoiceLine[]>(`explain-${id}`, () =>
    supabase.rpc('explain_invoice', { p_invoice: invoiceId }));
  const attempts = useQuery<PaymentAttempt[]>(`attempts-${id}`, () =>
    supabase.from('payment_attempts').select('*').eq('invoice_id', invoiceId).order('attempted_at'));
  const disputes = useQuery<Dispute[]>(`disputes-${id}`, () =>
    supabase.from('disputes').select('*').eq('invoice_id', invoiceId));

  const inv = invoice.data;
  const mismatched = lines.data?.filter((l) => l.matches === false) ?? [];
  const issued = lines.data?.reduce((s, l) => s + Number(l.amount ?? 0), 0) ?? 0;
  const expected = lines.data?.reduce((s, l) => s + Number(l.expected_amount ?? 0), 0) ?? 0;
  const collected = attempts.data?.filter((a) => a.status === 'succeeded').length ?? 0;

  return (
    <main className="page">
      <nav className="crumbs" aria-label="Breadcrumb">
        <Link to="/">Inbox</Link><span>/</span><span>Invoice</span>
      </nav>

      {invoice.error && <ErrorNote message={invoice.error} />}

      {inv ? (
        <div className="page-head">
          <div>
            <h1 className="mono" style={{ fontSize: 18 }}>{inv.number}</h1>
            <p>
              {inv.org_name} · usage from {day(inv.usage_period_start)} to {day(inv.usage_period_end)} on {titleCase(inv.usage_plan)}
              {inv.fee_plan !== inv.usage_plan && <>, plan fee for {titleCase(inv.fee_plan)}</>}
              {inv.usage_plan === 'pro' && <> · spend cap {inv.spend_cap ? 'on' : 'off'}</>}
            </p>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: 22, fontWeight: 600 }} className="num">{usd(inv.total)}</div>
            <Status tone={invoiceTone(inv.status)}>
              {inv.status_label}{inv.days_overdue ? `, ${inv.days_overdue} days overdue` : ''}
            </Status>
          </div>
        </div>
      ) : !invoice.error && <SkeletonLines lines={3} />}

      {lines.data && mismatched.length > 0 && (
        <div className="callout red" style={{ marginBottom: 16 }}>
          <strong>This invoice does not match its usage records.</strong> It says {usd(issued)}; rebuilding it from
          what the organization used gives {usd(expected)}, a difference of {usd(issued - expected)}. The lines that
          differ are marked below. This is a billing error to escalate, not an invoice to explain.
        </div>
      )}
      {lines.data && mismatched.length === 0 && lines.data.length > 0 && (
        <div className="callout" style={{ marginBottom: 16 }}>
          Rebuilt from the usage records, this invoice comes to the same {usd(expected)}. Every line matches.
        </div>
      )}
      {collected > 1 && (
        <div className="callout red" style={{ marginBottom: 16 }}>
          <strong>Collected {collected} times.</strong> One invoice, {collected} successful charges. See the payment attempts below.
        </div>
      )}

      {lines.error && <ErrorNote message={lines.error} />}
      {lines.loading && <div className="panel"><div className="panel-body"><SkeletonLines lines={6} /></div></div>}
      {lines.data && <InvoiceLines lines={lines.data} compare />}

      <div className="layout" style={{ marginTop: 24, gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)' }}>
        <section className="panel">
          <div className="panel-head"><h2>Payment attempts</h2></div>
          <div className="panel-body">
            {attempts.data?.length === 0 && <p className="muted">No charge was attempted.</p>}
            {attempts.data?.map((a) => (
              <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', gap: 12, marginTop: 0, marginBottom: 10 }}>
                <span>
                  <Status tone={a.status === 'succeeded' ? 'green' : 'red'}>{titleCase(a.status)}</Status>
                  {a.decline_code && <span className="mono muted" style={{ marginLeft: 8 }}>{a.decline_code}</span>}
                </span>
                <span className="muted small">{dayTime(a.attempted_at)} · <span className="num">{usd(a.amount)}</span></span>
              </div>
            ))}
            {attempts.loading && <SkeletonLines lines={2} />}
          </div>
        </section>

        <section className="panel" style={{ marginTop: 0 }}>
          <div className="panel-head"><h2>Disputes</h2></div>
          <div className="panel-body">
            {disputes.data?.length === 0 && <p className="muted">None. The cardholder has not asked their bank to reverse this charge.</p>}
            {disputes.data?.map((d) => (
              <dl className="kv" key={d.id}>
                <dt>Status</dt><dd><Badge tone="amber">{d.status.replace(/_/g, ' ')}</Badge></dd>
                <dt>Reason given</dt><dd>{d.reason}</dd>
                <dt>Amount</dt><dd>{usd(d.amount)}</dd>
                <dt>Opened</dt><dd>{day(d.opened_at)}</dd>
                <dt>Evidence due</dt><dd>{day(d.evidence_due_by)}</dd>
              </dl>
            ))}
            {disputes.loading && <SkeletonLines lines={2} />}
          </div>
        </section>
      </div>
    </main>
  );
}

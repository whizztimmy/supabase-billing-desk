import { Link, useParams } from 'react-router-dom';
import { supabase } from '../supabase';
import { useQuery } from '../api';
import { country, day, dayTime, monthYear, titleCase, usd } from '../format';
import { Badge, CopyButton, ErrorNote, SkeletonLines, Status, invoiceTone, severityTone } from '../components/ui';
import type { Finding, InvoiceOverview, PlaybookSource, Project, TicketContext } from '../types';

function FindingPanel({ finding, source }: { finding: Finding; source?: PlaybookSource }) {
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{finding.title}</h2>
        {finding.escalate_to
          ? <Badge tone="blue">Escalate to {finding.escalate_to}</Badge>
          : finding.playbook === 'needs_review'
            ? <Badge tone="amber">Needs a person</Badge>
            : <Badge tone="green">Support can settle this</Badge>}
      </div>
      <div className="panel-body">
        <div>
          <div className="section-label">What happened</div>
          <p>{finding.cause}</p>
        </div>

        {finding.evidence.length > 0 && (
          <div>
            <div className="section-label">Evidence from the account</div>
            <dl className="kv">
              {finding.evidence.map((e) => (
                <div key={e.label} style={{ display: 'contents' }}>
                  <dt>{e.label}</dt>
                  <dd>{e.value}</dd>
                </div>
              ))}
            </dl>
          </div>
        )}

        <div className="callout">
          <div className="section-label" style={{ marginBottom: 2 }}>Next step</div>
          {finding.next_step}
        </div>

        {finding.reply && (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
              <div className="section-label" style={{ margin: 0 }}>Drafted first reply</div>
              <CopyButton text={finding.reply} label="Copy reply" />
            </div>
            <pre className="reply">{finding.reply}</pre>
          </div>
        )}

        <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', alignItems: 'baseline' }}>
          {source && (
            <details style={{ flex: '1 1 100%' }} open={false}>
              <summary>The SQL that reached this</summary>
              <pre className="code">{source.sql}</pre>
            </details>
          )}
          {finding.doc_url && (
            <a className="link small" href={finding.doc_url} target="_blank" rel="noreferrer">Documentation for the customer</a>
          )}
        </div>
      </div>
    </section>
  );
}

export default function Ticket() {
  const { id } = useParams();
  const ticketId = Number(id);

  const context = useQuery<TicketContext>(`context-${id}`, () =>
    supabase.from('ticket_context').select('*').eq('ticket_id', ticketId).single());
  const findings = useQuery<Finding[]>(`findings-${id}`, () =>
    supabase.rpc('diagnose_ticket', { p_ticket: ticketId }));
  const sources = useQuery<PlaybookSource[]>('playbook-sources', () =>
    supabase.from('playbook_source').select('*'));

  const escalates = findings.data?.some((f) => f.escalate_to) ?? false;
  const note = useQuery<string>(`note-${id}`, () =>
    supabase.rpc('escalation_note', { p_ticket: ticketId }), escalates);

  const orgId = context.data?.org_id;
  const projects = useQuery<Project[]>(`projects-${orgId}`, () =>
    supabase.from('projects').select('*').eq('org_id', orgId!).order('id'), Boolean(orgId));
  const invoices = useQuery<InvoiceOverview[]>(`invoices-${orgId}`, () =>
    supabase.from('invoice_overview').select('*').eq('org_id', orgId!).order('issued_at', { ascending: false }), Boolean(orgId));

  const c = context.data;

  return (
    <main className="page">
      <nav className="crumbs" aria-label="Breadcrumb">
        <Link to="/">Inbox</Link><span>/</span><span>Ticket #{id}</span>
      </nav>

      {context.error && <ErrorNote message={context.error} />}

      <div className="layout">
        <div>
          {c ? (
            <>
              <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginBottom: 6 }}>
                <Badge tone={severityTone[c.severity]}>{c.severity}</Badge>
                <span className="muted small">{c.category} · received {dayTime(c.created_at)}</span>
              </div>
              <h1>{c.subject}</h1>
              <p className="muted" style={{ margin: '4px 0 14px' }}>{c.requester_name}, {c.org_name}</p>
              <div className="message">{c.body}</div>
              <p className="small muted" style={{ marginTop: 8 }}>
                The customer's words set the topic ({c.topic}). The cause below comes from the account.
              </p>
            </>
          ) : !context.error && <SkeletonLines lines={5} />}

          <div style={{ marginTop: 24 }}>
            {findings.error && <ErrorNote message={findings.error} />}
            {findings.loading && <div className="panel"><div className="panel-body"><SkeletonLines lines={6} /></div></div>}
            {findings.data?.map((f) => (
              <FindingPanel key={f.playbook} finding={f}
                            source={sources.data?.find((s) => s.id === f.playbook)} />
            ))}
            {note.data && (
              <section className="panel">
                <div className="panel-head">
                  <h2>Escalation note</h2>
                  <CopyButton text={note.data} label="Copy note" />
                </div>
                <div className="panel-body">
                  <p className="muted small">Written so the person receiving it can act without opening the ticket.</p>
                  <pre className="code" style={{ whiteSpace: 'pre-wrap', maxHeight: 'none' }}>{note.data}</pre>
                </div>
              </section>
            )}
          </div>
        </div>

        <aside>
          <section className="panel">
            <div className="panel-head"><h2>Account</h2></div>
            <div className="panel-body">
              {c ? (
                <dl className="kv">
                  <dt>Organization</dt><dd className="mono">{c.org_id}</dd>
                  <dt>Plan</dt><dd>{titleCase(c.plan)}</dd>
                  <dt>Spend cap</dt><dd>{c.plan === 'pro' ? (c.spend_cap ? 'On' : 'Off') : 'Not available on this plan'}</dd>
                  <dt>Restriction</dt>
                  <dd>{c.restriction_status ? <Badge tone="amber">{c.restriction_status.replace(/_/g, ' ')}</Badge> : 'None'}</dd>
                  <dt>Credits</dt><dd>{usd(c.credit_balance)}</dd>
                  <dt>Card</dt>
                  <dd>
                    {c.card_brand
                      ? <>{c.card_brand} ending {c.card_last4}, {country(c.card_country)}{' '}
                          {c.card_expired
                            ? <Badge tone="red">Expired {monthYear(c.card_expires)}</Badge>
                            : <span className="muted">valid to {monthYear(c.card_expires)}</span>}</>
                      : 'No card on file'}
                  </dd>
                  <dt>Tax ID</dt><dd>{c.tax_id ?? 'None'}</dd>
                </dl>
              ) : <SkeletonLines lines={5} />}
            </div>
          </section>

          <section className="panel">
            <div className="panel-head"><h2>Projects</h2></div>
            <div className="panel-body">
              {projects.data?.length === 0 && <p className="muted">No projects.</p>}
              {projects.data?.map((p) => (
                <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', gap: 10, marginTop: 0, marginBottom: 8 }}>
                  <span><span className="mono">{p.name}</span> <span className="muted small">{p.compute_size}</span></span>
                  {p.status === 'paused'
                    ? <Status tone="red">Paused: {p.pause_reason?.replace(/_/g, ' ')}</Status>
                    : <Status tone="green">Active</Status>}
                </div>
              ))}
              {projects.loading && orgId && <SkeletonLines lines={2} />}
            </div>
          </section>

          <section className="panel">
            <div className="panel-head"><h2>Invoices</h2></div>
            <div className="panel-body">
              {invoices.data?.length === 0 && <p className="muted">No invoices. Nothing has ever been billed.</p>}
              {invoices.data?.map((inv) => (
                <Link key={inv.id} to={`/invoices/${inv.id}`}
                      style={{ display: 'flex', justifyContent: 'space-between', gap: 10, marginTop: 0, marginBottom: 10 }}>
                  <span>
                    <span className="link mono">{inv.number}</span>
                    <span className="secondary muted small" style={{ display: 'block' }}>
                      {day(inv.issued_at)}{inv.id === c?.invoice_id ? ' · in question' : ''}
                    </span>
                  </span>
                  <span style={{ textAlign: 'right' }}>
                    <span className="num" style={{ display: 'block' }}>{usd(inv.total)}</span>
                    <Status tone={invoiceTone(inv.status)}>{inv.status_label}</Status>
                  </span>
                </Link>
              ))}
              {invoices.loading && orgId && <SkeletonLines lines={2} />}
            </div>
          </section>
        </aside>
      </div>
    </main>
  );
}

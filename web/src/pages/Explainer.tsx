import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { supabase } from '../supabase';
import { useQuery } from '../api';
import { num, usd } from '../format';
import { CopyButton, ErrorNote, SkeletonLines } from '../components/ui';
import InvoiceLines from '../components/InvoiceLines';
import type { Addon, ComputeSize, InvoiceLine, Plan, UsageMetric } from '../types';

interface ProjectInput { name: string; size: string; hours: number; addons: string[] }
interface Scenario { plan: string; cap: boolean; tax: number; projects: ProjectInput[]; usage: Record<string, number> }

const MONTH_HOURS = 744;
const project = (name: string, size = 'micro', addons: string[] = []): ProjectInput => ({ name, size, hours: MONTH_HOURS, addons });

const PRESETS: { label: string; scenario: Scenario }[] = [
  { label: 'One project on Pro', scenario: { plan: 'pro', cap: true, tax: 0, projects: [project('production')], usage: {} } },
  { label: 'Three projects', scenario: { plan: 'pro', cap: true, tax: 0, projects: [project('production'), project('staging'), project('preview')], usage: {} } },
  { label: 'Traffic spike, cap off', scenario: { plan: 'pro', cap: false, tax: 0, projects: [project('production', 'medium')], usage: { egress: 1900, function_invocations: 14000000 } } },
  { label: 'Same spike, cap on', scenario: { plan: 'pro', cap: true, tax: 0, projects: [project('production', 'medium')], usage: { egress: 1900, function_invocations: 14000000 } } },
  { label: 'Add-ons with the cap on', scenario: { plan: 'pro', cap: true, tax: 0, projects: [project('production', 'small', ['ipv4', 'pitr_7'])], usage: { egress: 310 } } },
  { label: 'Free Plan, over quota', scenario: { plan: 'free', cap: false, tax: 0, projects: [project('side-project', 'nano')], usage: { egress: 40, mau: 80000 } } },
];

// The scenario lives in the URL, so an explained invoice can be shared as a link.
function readScenario(raw: string | null): Scenario {
  if (!raw) return PRESETS[0].scenario;
  try {
    const parsed = JSON.parse(raw) as Scenario;
    if (typeof parsed.plan === 'string' && Array.isArray(parsed.projects)) return { ...PRESETS[0].scenario, ...parsed };
  } catch {
    // A mangled link falls back to the first preset.
  }
  return PRESETS[0].scenario;
}

export default function Explainer() {
  const [params, setParams] = useSearchParams();
  const [scenario, setScenario] = useState<Scenario>(() => readScenario(params.get('s')));
  const [settled, setSettled] = useState(scenario);

  const plans = useQuery<Plan[]>('plans', () => supabase.from('plans').select('*').order('sort'));
  const sizes = useQuery<ComputeSize[]>('sizes', () => supabase.from('compute_sizes').select('*').order('sort'));
  const metrics = useQuery<UsageMetric[]>('metrics', () => supabase.from('usage_metrics').select('*').order('sort'));
  const addons = useQuery<Addon[]>('addons', () => supabase.from('addons').select('*').order('sort'));

  // Wait for typing to pause before asking the database, and keep the URL in step.
  useEffect(() => {
    const timer = window.setTimeout(() => {
      setSettled(scenario);
      setParams({ s: JSON.stringify(scenario) }, { replace: true });
    }, 250);
    return () => window.clearTimeout(timer);
  }, [scenario, setParams]);

  const request = useMemo(() => ({
    p_plan: settled.plan,
    p_spend_cap: settled.cap,
    p_projects: settled.projects.map((p) => ({
      name: p.name, size: p.size, hours: p.hours,
      addons: Object.fromEntries(p.addons.map((a) => [a, p.hours])),
    })),
    p_usage: Object.fromEntries(Object.entries(settled.usage).filter(([, v]) => v > 0)),
    p_tax_rate: settled.tax / 100,
  }), [settled]);

  const quote = useQuery<InvoiceLine[]>(JSON.stringify(request), () => supabase.rpc('quote_invoice', request));
  const total = quote.data?.reduce((s, l) => s + Number(l.amount ?? 0), 0) ?? 0;

  const plan = plans.data?.find((p) => p.id === scenario.plan);
  const paid = scenario.plan !== 'free';
  const orgMetrics = metrics.data?.filter((m) => m.scope === 'org') ?? [];

  const patch = (next: Partial<Scenario>) => setScenario((s) => ({ ...s, ...next }));
  const patchProject = (index: number, next: Partial<ProjectInput>) =>
    patch({ projects: scenario.projects.map((p, i) => (i === index ? { ...p, ...next } : p)) });

  function setPlan(id: string) {
    // The Free Plan runs Nano or Micro compute and has no add-ons.
    const projects = id === 'free'
      ? scenario.projects.slice(0, 2).map((p) => ({ ...p, size: ['nano', 'micro'].includes(p.size) ? p.size : 'nano', addons: [] }))
      : scenario.projects.map((p) => ({ ...p, size: p.size === 'nano' ? 'micro' : p.size }));
    patch({ plan: id, projects });
  }

  const catalogLoading = plans.loading || sizes.loading || metrics.loading || addons.loading;
  const catalogError = plans.error ?? sizes.error ?? metrics.error ?? addons.error;

  return (
    <main className="page">
      <div className="page-head">
        <div>
          <h1>Invoice explainer</h1>
          <p>Describe an organization and a month of usage. The invoice is built line by line with Supabase's published prices, and every line says why it is there. The same SQL function checks the invoices in the inbox.</p>
        </div>
        <CopyButton text={window.location.href} label="Copy link to this invoice" />
      </div>

      <div className="presets" style={{ marginBottom: 20 }}>
        {PRESETS.map((p) => (
          <button key={p.label} type="button" className="btn" onClick={() => setScenario(p.scenario)}>{p.label}</button>
        ))}
      </div>

      {catalogError && <ErrorNote message={catalogError} />}

      <div className="explainer">
        <form className="panel" onSubmit={(e) => e.preventDefault()}>
          <div className="panel-head"><h2>Organization</h2></div>
          <div className="panel-body">
            {catalogLoading ? <SkeletonLines lines={8} /> : (
              <>
                <div className="form-grid">
                  <label className="field">Plan
                    <select className="select" value={scenario.plan} onChange={(e) => setPlan(e.target.value)}>
                      {plans.data?.map((p) => <option key={p.id} value={p.id}>{p.name} ({usd(p.monthly_fee)})</option>)}
                    </select>
                  </label>
                  <label className="field">Tax rate, %
                    <input className="input" type="number" min={0} max={30} step={0.5} value={scenario.tax}
                           onChange={(e) => patch({ tax: Math.max(0, Number(e.target.value)) })} />
                  </label>
                </div>
                <label className="toggle" style={{ opacity: plan?.spend_cap_available ? 1 : 0.55 }}>
                  <input type="checkbox" checked={scenario.cap && Boolean(plan?.spend_cap_available)} disabled={!plan?.spend_cap_available}
                         onChange={(e) => patch({ cap: e.target.checked })} />
                  Spend cap {plan?.spend_cap_available ? '' : <span className="muted" style={{ fontWeight: 400 }}>(Pro only)</span>}
                </label>

                <div>
                  <div className="section-label">Projects</div>
                  {scenario.projects.map((p, i) => (
                    <div className="project" key={i}>
                      <div className="project-row">
                        <label className="field">Name
                          <input className="input" value={p.name} onChange={(e) => patchProject(i, { name: e.target.value })} />
                        </label>
                        <label className="field">Compute
                          <select className="select" value={p.size} onChange={(e) => patchProject(i, { size: e.target.value })}>
                            {sizes.data?.filter((s) => (paid ? s.id !== 'nano' : ['nano', 'micro'].includes(s.id)))
                              .map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                          </select>
                        </label>
                        <label className="field">Hours
                          <input className="input" type="number" min={0} max={MONTH_HOURS} value={p.hours}
                                 onChange={(e) => patchProject(i, { hours: Math.min(MONTH_HOURS, Math.max(0, Number(e.target.value))) })} />
                        </label>
                        <button type="button" className="btn icon" aria-label={`Remove ${p.name}`}
                                disabled={scenario.projects.length === 1}
                                onClick={() => patch({ projects: scenario.projects.filter((_, j) => j !== i) })}>×</button>
                      </div>
                      {paid && (
                        <div className="checks">
                          {addons.data?.map((a) => (
                            <label className="toggle" key={a.id} style={{ fontWeight: 400 }}>
                              <input type="checkbox" checked={p.addons.includes(a.id)}
                                     onChange={(e) => patchProject(i, { addons: e.target.checked ? [...p.addons, a.id] : p.addons.filter((x) => x !== a.id) })} />
                              {a.line_name.replace(' Hours', '')}
                            </label>
                          ))}
                        </div>
                      )}
                    </div>
                  ))}
                  <button type="button" className="btn" style={{ marginTop: 8 }}
                          disabled={!paid && scenario.projects.length >= 2}
                          onClick={() => patch({ projects: [...scenario.projects, project(`project-${scenario.projects.length + 1}`, paid ? 'micro' : 'nano')] })}>
                    Add a project
                  </button>
                  <p className="muted small" style={{ marginTop: 6 }}>A full month is {MONTH_HOURS} hours. A paused project is billed only for the hours it ran.</p>
                </div>

                <div>
                  <div className="section-label">Usage this month</div>
                  <div className="form-grid">
                    {orgMetrics.map((m) => {
                      const quota = paid ? m.paid_quota : m.free_quota;
                      return (
                        <label className="field" key={m.id}>{m.line_name}
                          <input className="input" type="number" min={0} placeholder={quota === null ? 'Not on Free' : `${num(quota)} included`}
                                 disabled={quota === null} value={scenario.usage[m.id] ?? ''}
                                 onChange={(e) => patch({ usage: { ...scenario.usage, [m.id]: Math.max(0, Number(e.target.value)) } })} />
                        </label>
                      );
                    })}
                  </div>
                </div>
              </>
            )}
          </div>
        </form>

        <section>
          <div className="panel">
            <div className="total-row" style={{ borderTop: 0 }}>
              <span>
                <span className="section-label" style={{ display: 'block', marginBottom: 0 }}>This month's invoice</span>
                <span className="muted small">{plan?.name ?? ''}{paid && plan?.spend_cap_available ? `, spend cap ${scenario.cap ? 'on' : 'off'}` : ''}</span>
              </span>
              <strong>{quote.data ? usd(total) : ' '}</strong>
            </div>
          </div>
          <div style={{ marginTop: 16 }}>
            {quote.error && <ErrorNote message={quote.error} />}
            {!quote.data && quote.loading && <div className="panel"><div className="panel-body"><SkeletonLines lines={6} /></div></div>}
            {quote.data && <InvoiceLines lines={quote.data} />}
          </div>
        </section>
      </div>
    </main>
  );
}

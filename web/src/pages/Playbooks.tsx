import { supabase } from '../supabase';
import { useQuery } from '../api';
import { ErrorNote, SkeletonLines } from '../components/ui';
import type { PlaybookSource } from '../types';

export default function Playbooks() {
  const playbooks = useQuery<PlaybookSource[]>('playbook-sources', () =>
    supabase.from('playbook_source').select('*').order('sort'));

  return (
    <main className="page">
      <div className="page-head">
        <div>
          <h1>Playbooks</h1>
          <p>A playbook is one query that checks an account for one cause. The SQL shown here is read back from the database, so it is the code that runs, not a description of it. The cause always comes from the account. Thirteen of the sixteen use nothing else; the pre-sales, refund and tax playbooks also look at the form's category or the wording, to know what the customer is asking for.</p>
        </div>
      </div>

      {playbooks.error && <ErrorNote message={playbooks.error} />}
      {playbooks.loading && <div className="panel"><div className="panel-body"><SkeletonLines lines={8} /></div></div>}

      {playbooks.data?.map((p) => (
        <section className="panel" key={p.id}>
          <div className="panel-head">
            <div>
              <h2>{p.title}</h2>
              <p className="muted" style={{ marginTop: 2 }}>{p.applies_when}</p>
            </div>
            {p.doc_url && <a className="link small" href={p.doc_url} target="_blank" rel="noreferrer">Documentation</a>}
          </div>
          <div className="panel-body">
            <details>
              <summary><span className="mono">pb_{p.id}</span></summary>
              <pre className="code">{p.sql}</pre>
            </details>
          </div>
        </section>
      ))}
    </main>
  );
}

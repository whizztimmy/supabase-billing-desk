import { supabase } from '../supabase';
import { useQuery } from '../api';
import { Badge, ErrorNote, SkeletonRows } from '../components/ui';
import type { Setting } from '../types';

export default function About() {
  const settings = useQuery<Setting[]>('settings-about', () => supabase.from('demo_settings').select('*').order('kind'));

  return (
    <main className="page">
      <div className="prose">
        <h1>About this project</h1>
        <p>
          Billing Desk is a billing support console for a billing system shaped like Supabase's. I am Timothy Adetunji,
          and I built it while applying for Supabase's Billing Support Specialist role. I have not held a billing
          support job, so instead of saying I could do one, I set up twenty organizations, billed them by Supabase's
          published rules, let things go wrong in their accounts the way they go wrong for real customers, and worked
          the tickets.
        </p>
        <p>
          It is an independent project. The colours follow the Supabase dashboard because that is the product it is
          about, but it is not made by, endorsed by or affiliated with Supabase.
        </p>

        <h2>What is real</h2>
        <ul>
          <li>Plan prices, compute and usage prices, quotas and add-on prices, from Supabase's documentation. Each row in the price list stores the page it came from.</li>
          <li>The billing rules: plan fees in advance and usage in arrears, compute credits that offset compute only, a spend cap on Pro that never covers add-ons, credits used before the card, and no refunds to cards.</li>
          <li>The vocabulary: invoice statuses and decline codes are Stripe's, the credit ledger follows Orb's, and ticket categories and organization restriction states are the ones in Supabase's dashboard source.</li>
        </ul>

        <h2>What is invented</h2>
        <ul>
          <li>Every organization, person, card, invoice and ticket. No real customer data is here or was ever used.</li>
          <li>The two billing errors in the inbox, a double charge and an invoice missing its compute credits, were planted so the playbooks had something real to find.</li>
        </ul>

        <h2>What is simplified</h2>
        <ul>
          <li>Usage is billed as one monthly quantity. Supabase meters disk, storage and add-ons by the hour.</li>
          <li>Every billing cycle starts on the 1st or the 10th of the month.</li>
          <li>The console is read-only. Nothing here sends a reply, issues a credit or changes an account.</li>
          <li>I do not know how Supabase's internal tools work beyond what its team has said in public, and nothing here claims to.</li>
        </ul>

        <h2>Settings and assumptions</h2>
        <p>Where Supabase does not publish a number, the demo had to pick one. Those are marked as assumed.</p>
      </div>

      {settings.error && <ErrorNote message={settings.error} />}
      <div className="table-wrap" style={{ marginTop: 14, maxWidth: 900 }}>
        <table>
          <thead><tr><th>Setting</th><th>Value</th><th>Basis</th><th>Note</th></tr></thead>
          <tbody>
            {settings.loading && <SkeletonRows columns={4} rows={4} />}
            {settings.data?.map((s) => (
              <tr key={s.key}>
                <td className="mono">{s.key}</td>
                <td className="mono">{s.value}</td>
                <td><Badge tone={s.kind === 'assumed' ? 'amber' : s.kind === 'documented' ? 'green' : 'gray'}>{s.kind}</Badge></td>
                <td>{s.note}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="prose" style={{ marginTop: 28 }}>
        <h2>How it is built</h2>
        <p>
          Everything that decides anything is SQL in Postgres on Supabase: the invoice engine, the playbooks, the inbox
          and the patterns. The browser reads through the public API with row level security on every table, and the
          API cannot write. The rules are pinned by a test suite that runs the whole database in PGlite, with no
          network. The source is at{' '}
          <a className="link" href="https://github.com/whizztimmy/supabase-billing-desk" target="_blank" rel="noreferrer">github.com/whizztimmy/supabase-billing-desk</a>.
        </p>
      </div>
    </main>
  );
}

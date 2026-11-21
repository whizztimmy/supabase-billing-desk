import { Link } from 'react-router-dom';
import Flow, { type FlowNode } from '../components/Flow';
import { Badge } from '../components/ui';
import type { Tone } from '../types';

const ROUTING: FlowNode[] = [
  { id: 'form', x: 230, y: 16, width: 220, title: 'Support form', detail: 'Category, severity, project', kind: 'existing' },
  { id: 'front', x: 230, y: 132, width: 220, title: 'Front', detail: 'Category saved as Type', kind: 'existing' },
  { id: 'growth', x: 40, y: 268, width: 180, title: 'Growth team', detail: 'Sales enquiry', kind: 'existing' },
  { id: 'billing', x: 250, y: 268, width: 180, title: 'Billing support', detail: 'Billing, Refund enquiry', kind: 'existing' },
  { id: 'engineers', x: 460, y: 268, width: 180, title: 'Support engineers', detail: 'All other categories', kind: 'existing' },
];

const BILLING_LANE: FlowNode[] = [
  { id: 'arrives', x: 220, y: 16, width: 240, title: 'Billing ticket arrives', detail: 'In the billing inbox', kind: 'existing' },
  { id: 'playbooks', x: 220, y: 132, width: 240, title: 'Playbooks run', detail: 'Read-only, on billing data', kind: 'added' },
  { id: 'note', x: 220, y: 248, width: 240, title: 'Private note on the ticket', detail: 'Cause, evidence, next step', kind: 'added' },
  { id: 'known', x: 40, y: 384, width: 180, title: 'Known cause', detail: 'Agent sends a draft', kind: 'added' },
  { id: 'error', x: 250, y: 384, width: 180, title: 'Billing error', detail: 'Handover to engineers', kind: 'added' },
  { id: 'nomatch', x: 460, y: 384, width: 180, title: 'No match', detail: 'Worked by hand', kind: 'existing' },
  { id: 'tagged', x: 220, y: 520, width: 240, title: 'Cause tagged on solve', detail: 'Feeds weekly patterns', kind: 'added' },
];

const MAPPING: [string, string][] = [
  ['Gmail: a new email arrives', 'A ticket arriving in the billing inbox in Front starts the run'],
  ['AI step: classify the email', 'Not needed for routing. The customer already chose the category on the form'],
  ['Google Sheets: look up the known answer', 'Playbooks: queries that check the customer\'s billing data for a cause'],
  ['Gmail: reply to the customer', 'A draft reply in Front, which an agent reads and sends'],
  ['New bug: add a row and alert Slack', 'Billing error: a Slack alert and a Linear issue for Billing Engineering, with the handover note'],
  ['Known bug: reply with the known answer', 'Known cause: the drafted reply'],
];

// Two tests sort every cause: does the reply commit the company to money or
// policy, and can what it says be checked against live data when it is sent?
const GROUPS: { name: string; tone: Tone; rule: string; causes: string }[] = [
  {
    name: 'Never automated', tone: 'red',
    rule: 'The reply commits the company to money or policy, or admits an error.',
    causes: 'Refusing a refund, an open bank dispute, a double charge, a wrong invoice, anything that offers a credit or more time to pay.',
  },
  {
    name: 'A person sends', tone: 'amber',
    rule: 'The facts can be checked, but the customer is upset or the explanation needs judgement.',
    causes: 'Explaining a correct invoice (more than one project, usage over quota, add-ons, a charge after a downgrade), failed payments, tax, quota restrictions.',
  },
  {
    name: 'Could be automated later', tone: 'green',
    rule: 'The reply only states facts that can be checked at the moment of sending, and commits to nothing.',
    causes: 'A Free project paused for inactivity, "do you offer annual billing?", projects paused for an unpaid invoice.',
  },
];

const PHASES: { when: string; name: string; what: string; done: string }[] = [
  {
    when: 'Weeks 1 to 4', name: 'Learn',
    what: 'Work billing tickets by hand and tag each with its cause. Record the starting numbers: handling time per ticket, how many are settled in one reply, how many reopen. Find out what the billing command center already does. Build nothing.',
    done: 'A ranked list of real causes with their numbers, and a clear view of where the gap is.',
  },
  {
    when: 'Weeks 5 to 8', name: 'Blind notes',
    what: 'Run the playbooks for the three most common causes, but hide the note until the agent has recorded their own cause. Then compare. A second person settles each disagreement.',
    done: 'A playbook passes at 95% agreement over at least 50 tickets. One that misses is fixed and retested, or dropped.',
  },
  {
    when: 'Weeks 9 to 12', name: 'Drafts and handovers',
    what: 'For playbooks that passed, show the note on arrival and add a drafted reply. A person still sends every reply. Add the handover for billing errors, on terms agreed with Billing Engineering.',
    done: 'Handling time is down against the starting numbers, and the weekly sample finds no wrong reply sent.',
  },
];

export default function Plan() {
  return (
    <main className="page">
      <div className="prose">
        <h1>Rollout plan</h1>
        <p>
          The rest of this site is a demonstration. This page is how I would put the same idea to work inside a real
          support team: with the tools the team already has, without a new website, and without anything replying to a
          customer on its own.
        </p>

        <h2>Where it comes from</h2>
        <p>
          Last year I built a support automation in Zapier. A new email arrived, an AI step sorted it, a spreadsheet
          supplied the answer for known issues, and new bugs were logged and raised in Slack. It worked, and it taught
          me the shape of the problem. The <Link className="link" to="/playbooks">playbooks</Link> here are that same
          shape, moved from reading the message to reading the account.
        </p>

        <h2>How a ticket is routed today</h2>
        <p>
          The support form asks for a category and a severity. A comment in{' '}
          <a className="link" href="https://github.com/supabase/supabase/blob/master/apps/studio/components/interfaces/Support/Support.constants.ts" target="_blank" rel="noreferrer">Supabase's dashboard source</a>{' '}
          says the category is written to a field called Type on the ticket in Front. How Front routes from there is
          not public. I would expect sales enquiries to go to the growth team, billing and refund enquiries to billing
          support, and everything else to support engineers. That expectation is an assumption until someone on the
          team confirms it.
        </p>
      </div>

      <Flow label="How a support ticket is routed by its category" nodes={ROUTING} legend={false}
            edges={[['form', 'front'], ['front', 'growth'], ['front', 'billing'], ['front', 'engineers']]} />

      <div className="prose">
        <h2>What changes in the billing lane</h2>
        <p>
          Nothing changes for the customer, the form, or the other two lanes. When a billing ticket arrives, the
          playbooks check the organization's billing data and leave a private note on the ticket. What happens next
          depends on what the note found.
        </p>
      </div>

      <Flow label="What happens to a billing ticket under this plan" nodes={BILLING_LANE}
            edges={[['arrives', 'playbooks'], ['playbooks', 'note'], ['note', 'known'], ['note', 'error'], ['note', 'nomatch'],
                    ['known', 'tagged'], ['error', 'tagged'], ['nomatch', 'tagged']]} />

      <div className="prose">
        <h2>From my automation to this one</h2>
      </div>
      <div className="table-wrap" style={{ marginTop: 12, maxWidth: 900 }}>
        <table>
          <thead><tr><th>In my Zapier automation</th><th>Inside the team's tools</th></tr></thead>
          <tbody>
            {MAPPING.map(([mine, theirs]) => (
              <tr key={mine}><td style={{ width: '42%' }}>{mine}</td><td>{theirs}</td></tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="prose">
        <h2>Why a person sends every reply</h2>
        <p>My Zapier automation replied on its own. This one does not, for three reasons, and none of them is that automation is frightening.</p>
        <ul>
          <li><strong>The playbooks are unproven.</strong> They have only been tested on data I planted myself. Until they are measured on real tickets, nobody should trust them to send anything.</li>
          <li>
            <strong>At this volume, a human check is cheap.</strong>{' '}
            <a className="link" href="https://hex.tech/customers/supabase/" target="_blank" rel="noreferrer">Hex's case study</a>{' '}
            puts Supabase's billing queue at about 60 tickets a day. Reading and sending 60 drafts is roughly an hour of
            work, so automating the send would save very little. If the real volume is far higher, this sum changes.
          </li>
          <li><strong>Someone has to own the reply.</strong> A message about a customer's money should have a named person behind it who read it before it went.</li>
        </ul>
        <p>
          This has a cost, and it is worth saying plainly. A customer whose production is paused at two in the morning
          waits for a person, and that is the ticket where speed matters most. The note and the draft are ready the
          moment someone opens it, which shortens the reply but not the wait. That case is the first one I would bring
          to the team as a candidate for sending automatically.
        </p>

        <h2>Not every reply carries the same risk</h2>
        <p>
          "Your Free project paused and you owe nothing" and "we will not refund you" are different kinds of message.
          Two questions sort them: does the reply commit the company to money or policy, and can what it says be
          checked against live data at the moment it is sent?
        </p>
      </div>
      <div className="table-wrap" style={{ marginTop: 12, maxWidth: 900 }}>
        <table>
          <thead><tr><th>Group</th><th>Why</th><th>Causes</th></tr></thead>
          <tbody>
            {GROUPS.map((g) => (
              <tr key={g.name}>
                <td style={{ whiteSpace: 'nowrap' }}><Badge tone={g.tone}>{g.name}</Badge></td>
                <td style={{ width: '36%' }}>{g.rule}</td>
                <td>{g.causes}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="prose">
        <p>
          Nothing moves into the third group on my say. A cause would have to pass the checks below for months first,
          and the decision would be the team's.
        </p>

        <h2>The rules it runs under</h2>
        <ul>
          <li><strong>The account decides the cause.</strong> "My payment failed" has four different causes in the <Link className="link" to="/?view=payments">inbox</Link>, and the customer's words do not say which. The words and the form's category are used only to tell what the customer is asking for.</li>
          <li><strong>Read-only.</strong> The playbooks read billing data. They never issue a credit, extend a payment or change an account.</li>
          <li><strong>Checked again at the moment of sending.</strong> Billing data can be minutes old. A draft that says "unpaid" is rerun when the agent clicks send, because a person reading it cannot tell that the customer paid a minute ago.</li>
          <li><strong>No customer data leaves approved systems.</strong> If an AI step is used at all, it is one the company has already approved, and only for reading free text, never for deciding.</li>
          <li><strong>A ticket with no match says so.</strong> It is worked by hand, and if the same shape returns it becomes the next playbook.</li>
        </ul>

        <h2>The first ninety days</h2>
        <p>The thresholds are starting numbers I would propose. The team would set the real ones.</p>
      </div>
      <div className="table-wrap" style={{ marginTop: 12, maxWidth: 900 }}>
        <table>
          <thead><tr><th>When</th><th>Step</th><th>What happens</th><th>Done when</th></tr></thead>
          <tbody>
            {PHASES.map((p) => (
              <tr key={p.when}>
                <td style={{ whiteSpace: 'nowrap' }}>{p.when}</td>
                <td className="primary" style={{ whiteSpace: 'nowrap' }}>{p.name}</td>
                <td>{p.what}</td>
                <td>{p.done}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="prose">
        <p>
          The notes are hidden in the second step on purpose. If an agent sees the note before they investigate, they
          will tend to agree with it, and the comparison would only measure how persuasive the note is.
        </p>

        <h2>How I would know it is working</h2>
        <ul>
          <li><strong>Handling time per ticket, by cause,</strong> against the numbers recorded in the first four weeks.</li>
          <li><strong>Tickets settled in one reply,</strong> and how often a ticket reopens after a drafted reply against one written by hand.</li>
          <li><strong>A weekly sample read by someone else.</strong> Twenty sent drafts, chosen at random, checked against the account. The number that matters is how many were wrong.</li>
          <li><strong>Handovers the engineers agreed with.</strong> A billing error that turns out not to be one costs an engineer's time.</li>
        </ul>
        <p>
          Two things I would not claim. This does not shorten how long a ticket waits before someone opens it, which
          is most of the time to a first reply. And I would not treat "agents send most drafts unchanged" as success on
          its own, because it looks the same whether the drafts are good or people have stopped reading them.
        </p>

        <h2>When I would stop</h2>
        <ul>
          <li>A playbook that misses its threshold twice is dropped, and that cause goes back to being worked by hand.</li>
          <li>If handling time has not fallen after a month of drafts, the drafts are switched off and the notes stay.</li>
          <li>If the weekly sample finds a wrong reply about money that reached a customer, that cause returns to blind notes until the reason is found.</li>
        </ul>

        <h2>Who keeps it right</h2>
        <p>
          The playbooks are code that depends on prices and billing rules, and both change. Every change to a playbook
          would be reviewed by Billing Engineering, and the <Link className="link" to="/about">tests</Link> that pin
          the rules to worked examples would fail first when a price moves. A support specialist should not be the
          only person who can read or change the logic that explains a customer's bill.
        </p>

        <h2>What I do not know yet</h2>
        <ul>
          <li>How Front is set up: whether billing has its own inbox, and what rules already run.</li>
          <li>The real volume and mix of billing tickets. The figure above is from a vendor's case study.</li>
          <li>Where billing data can be queried, with what access, and how fresh it is.</li>
          <li>
            What the billing command center built by Supabase's billing engineers already automates. It already checks
            accounts and recommends actions, so the first question is not whether I can build this. It is what exists
            and where the gap is. The gap I would expect is the moment a ticket arrives. If the playbooks belong
            inside that tool and not beside it, that is the better outcome.
          </li>
        </ul>
      </div>
    </main>
  );
}

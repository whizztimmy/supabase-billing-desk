# Billing Desk

A billing support console and invoice explainer, built on Supabase Postgres,
for a billing system shaped like Supabase's own.

**Live: [supabase-billing-desk.vercel.app](https://supabase-billing-desk.vercel.app)**

I built it to answer one question about myself: can I do billing support for
technical customers, when I have not held that job? The honest way to answer
was to do the work. So this repository bills twenty invented organizations by
Supabase's published rules, lets things go wrong in their accounts the way
they go wrong for real customers, and then works the tickets.

Every company, person, card and ticket here is synthetic. The prices and
rules are not: they come from Supabase's documentation, and each row in the
price list links to the page it came from.

## What it does

**Inbox.** Twenty open billing tickets, sorted by when the first reply is
due. Each row shows two things side by side: what the customer says is wrong,
and what the account shows is wrong. They are often different.

**Ticket.** The diagnosis, the evidence from the account, the next step, a
drafted first reply, and the SQL that reached the conclusion. For a billing
error there is also an escalation note written so an engineer can act on it
without opening the ticket.

**Invoice.** An issued invoice line by line, each line explained in a
sentence, next to what the usage records say the line should be. A line that
differs is flagged, with the amount.

**Invoice explainer.** A public tool: describe a plan, some projects and a
month of usage, and it builds the invoice with every line explained. The link
carries the scenario, so an explained invoice can be shared.

**Patterns.** Which causes fill the queue over twelve weeks, which one is
growing, and new organizations spending far beyond anything they have paid.

**Playbooks.** The sixteen checks behind the diagnoses, with their SQL read
back from the database.

**Rollout plan.** How I would put this to work inside a real support team:
in the tools the team already uses, with drafts a person sends and nothing
replying on its own, over a first ninety days.

## How it works

**An invoice engine.** `quote_invoice()` takes a plan, a set of projects and a
month of usage, and returns the lines of the invoice with a sentence on each
one. It knows that plan fees are charged in advance and usage in arrears, that
compute credits offset compute and nothing else, that the spend cap exists
only on Pro and never covers add-ons, and that credits are used before the
card is charged.

**A way to reproduce a billing error.** `explain_invoice()` rebuilds an issued
invoice from the usage records and sets the two side by side. One seeded
invoice has lost its compute credits line; the reconciliation finds it and
says by how much.

**Playbooks.** A ticket rarely says what is wrong. "My payment failed" is an
expired card, or a bank blocking a US dollar charge from Singapore, or an
empty account, or a bank asking for 3D Secure, and each needs a different
reply. A playbook is one small query that checks the account for one cause.
`diagnose_ticket()` runs all sixteen and returns what it found. The cause
always comes from the account. Thirteen playbooks use nothing else; three
also look at the form's category or the wording, to know what the customer is
asking for, and a test pins that list. A ticket that matches no playbook says
so.

Everything that decides anything is SQL in Postgres. The browser reads
through Supabase's API with the public anon key. Row level security is on
for every table, every view runs with the caller's rights, and nothing has a
write policy, so the API cannot change anything.

## What is real and what is assumed

Real, from public sources: plan prices, compute and usage prices, quotas,
invoice line names, the spend cap's coverage, credits and refund rules,
invoice statuses and decline codes (Stripe's), the credit ledger's entry types
(Orb's), and the ticket categories and organization restriction states in
Supabase's dashboard source.

Assumed, because Supabase does not publish them: how many days pass before an
unpaid invoice pauses projects, and first-reply targets. Both live in the
`demo_settings` table, marked `assumed`, and the About page lists them.

Simplified: usage is billed as one monthly quantity where Supabase meters by
the hour, billing cycles are a fixed number of days, and the console is
read-only. I do not know how Supabase's internal tools work beyond what its
team has said in public, and nothing here claims to.

## The demo clock

The seed is written around one moment, 09:00 UTC on 20 November 2026. Left
there, the demo would age: a visitor in January would read "today is 20
November".

So the demo has its own clock, and it follows the real date. Each night
`advance_demo_clock()` moves that moment to 09:00 UTC today and moves every
date in the data forward by the same number of days. Nothing changes relative
to anything else: the urgent ticket is always 80 minutes old, the failed
payment always ten days old. A test moves the clock 107 days, across a year
end and a February, and checks that every diagnosis, total, age and trend
comes out identical.

In the console, times are shown in the viewer's own timezone, with the zone
printed beside them.

## Running it

Everything runs locally with no Supabase project. You need Node 20.6 or later.

```bash
npm install
npm test
```

`npm test` loads the migrations and the seed into [PGlite](https://pglite.dev),
Postgres running inside the Node process, and runs 105 assertions written in
SQL: the billing rules against worked examples, the seeded invoices, every
ticket's diagnosis, the access rules, and the demo clock.

To run the console:

```bash
npm install --prefix web
npm run dev --prefix web
```

With no `VITE_SUPABASE_URL` set, the dev server serves the same database from
PGlite at `/rest/v1`, and the Supabase client talks to it as it would to a
real project. Queries run as the `anon` role, so row level security applies
locally too. `scripts/local-api.mjs` is that stand-in.

## Putting it on Supabase and Vercel

1. Create a Supabase project. Put its session pooler connection string in
   `.env` with `node scripts/set-db-url.mjs`, then load the database:

   ```bash
   npm run db:setup
   ```

2. Import the repository at vercel.com/new, leaving Root Directory empty, and
   set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. No other key is
   needed, and the service role key must never be given to the site.

`api/keep-warm.js` reads from the database once a day through a Vercel Cron
Job, so a free project does not pause for inactivity. The demo clock is moved
inside the database by pg_cron, which `0005_demo_clock.sql` schedules.

## Layout

```
supabase/migrations/0001_catalog.sql         the price list, with sources
supabase/migrations/0002_accounts.sql        customers, usage, invoices, payments, tickets
supabase/migrations/0003_invoice_engine.sql  quote, rebuild and explain an invoice
supabase/migrations/0004_playbooks.sql       sixteen playbooks and the inbox
supabase/migrations/0005_demo_clock.sql      the clock that follows the real date
supabase/seed.sql                            the synthetic organizations and tickets
tests/                                       105 assertions, in SQL
scripts/test.mjs                             runs everything in PGlite
scripts/local-api.mjs                        the local stand-in for Supabase's API
web/                                         the console: Vite, React, TypeScript
api/keep-warm.js                             the daily read that keeps the project awake
```

## Status

| | |
|---|---|
| Database, invoice engine, playbooks | done, 105 tests passing |
| Console | done, checked in the browser against the local database, light and dark, desktop and phone |
| Hosted | on a Supabase project (Postgres 17) and Vercel since 21 November 2026. The hosted database returns the same results as the local one, and a write through the public API is refused |

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { Link, NavLink, Route, Routes, useLocation } from 'react-router-dom';
import { supabase, usingLocalDatabase } from './supabase';
import { useQuery } from './api';
import { dayTime } from './format';
import type { Setting } from './types';
import Inbox from './pages/Inbox';
import Ticket from './pages/Ticket';
import Invoice from './pages/Invoice';
import Explainer from './pages/Explainer';
import Patterns from './pages/Patterns';
import Playbooks from './pages/Playbooks';
import Plan from './pages/Plan';
import About from './pages/About';

// The demo has its own clock, stored in the database and moved to 09:00 UTC
// on the real day each night, along with every date in the data. Ages are
// measured against it, so "3 days overdue" means the same on every visit.
const DemoNow = createContext<string | null>(null);
export const useDemoNow = () => useContext(DemoNow);

type Theme = 'light' | 'dark';

// Dark is the default, as in the Supabase dashboard. A saved choice wins.
function initialTheme(): Theme {
  try {
    const saved = window.localStorage.getItem('billing-desk-theme');
    if (saved === 'light' || saved === 'dark') return saved;
  } catch {
    // Storage can be blocked; fall through to the default.
  }
  return 'dark';
}

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

const SECTIONS: { to: string; label: string; end?: boolean; icon: ReactNode }[] = [
  { to: '/', label: 'Inbox', end: true, icon: <><path d="M2 9.5 3.6 3.4A1 1 0 0 1 4.6 2.7h6.8a1 1 0 0 1 1 .7L14 9.5" /><path d="M2 9.5v3a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-3h-3.5l-1 1.5h-3l-1-1.5H2Z" /></> },
  { to: '/explain', label: 'Invoice explainer', icon: <><path d="M4 2h8v12l-2-1.2L8 14l-2-1.2L4 14V2Z" /><path d="M6.3 5.5h3.4M6.3 8h3.4" /></> },
  { to: '/patterns', label: 'Patterns', icon: <><path d="M2.5 13.5h11" /><path d="M4.5 11V8M8 11V4M11.5 11V6.5" /></> },
  { to: '/playbooks', label: 'Playbooks', icon: <><path d="M3 3.2A1.2 1.2 0 0 1 4.2 2H13v10H4.2A1.2 1.2 0 0 0 3 13.2V3.2Z" /><path d="M3 13.2A1.2 1.2 0 0 0 4.2 14H13v-2" /></> },
  { to: '/plan', label: 'Rollout plan', icon: <><circle cx="3.5" cy="4" r="1.5" /><circle cx="12.5" cy="12" r="1.5" /><path d="M5 4h4.5a2 2 0 0 1 2 2v0a2 2 0 0 1-2 2h-3a2 2 0 0 0-2 2v0a2 2 0 0 0 2 2H11" /></> },
  { to: '/about', label: 'About', icon: <><circle cx="8" cy="8" r="6" /><path d="M8 7.3v3.4M8 5.2v.1" /></> },
];

function sectionName(pathname: string): string {
  if (pathname.startsWith('/tickets/')) return 'Inbox';
  if (pathname.startsWith('/invoices/')) return 'Invoices';
  return SECTIONS.find((s) => (s.end ? pathname === s.to : pathname.startsWith(s.to)))?.label ?? 'Not found';
}

export default function App() {
  const [theme, setTheme] = useState<Theme>(initialTheme);
  const location = useLocation();
  const settings = useQuery<Setting[]>('settings', () => supabase.from('demo_settings').select('*'));
  // Stored as "2026-11-20 09:00:00+00"; browsers only agree on the ISO form.
  const stored = settings.data?.find((s) => s.key === 'demo_now')?.value;
  const demoNow = stored ? stored.replace(' ', 'T').replace(/\+00$/, 'Z') : null;

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      window.localStorage.setItem('billing-desk-theme', theme);
    } catch {
      // The choice still applies for this visit.
    }
  }, [theme]);

  return (
    <DemoNow.Provider value={demoNow}>
      <div className="shell">
        <aside className="sidebar">
          <Link to="/" className="wordmark">
            <span className="wordmark-mark" aria-hidden="true"><span /></span>
            Billing Desk
          </Link>
          <nav className="nav" aria-label="Main">
            {SECTIONS.map((s) => (
              <NavLink key={s.to} to={s.to} end={s.end}
                       className={({ isActive }) => (isActive || (s.to === '/' && /^\/(tickets|invoices)\//.test(location.pathname)) ? 'active' : '')}>
                <Icon>{s.icon}</Icon>
                {s.label}
              </NavLink>
            ))}
          </nav>
          <div className="sidebar-foot">
            Built by Timothy Adetunji. Not affiliated with Supabase.{' '}
            <a href="https://github.com/whizztimmy/supabase-billing-desk" target="_blank" rel="noreferrer">Source</a>
          </div>
        </aside>

        <div className="main">
          <header className="topbar">
            <div className="crumb">
              <span>Demo organization</span>
              <span className="slash">/</span>
              <span style={{ color: 'var(--text)' }}>{sectionName(location.pathname)}</span>
            </div>
            <div className="topbar-right">
              <Link to="/about" className="chip" title="Every customer, card and ticket is invented. Prices and rules are Supabase's published ones.">
                <span className="dot amber" aria-hidden="true" />Synthetic data
              </Link>
              {demoNow && (
                <span className="chip hide-narrow"
                      title="The demo's clock is set to 09:00 UTC today, shown here in your timezone. Every date in the data moves forward with it each night, so each ticket stays the same age.">
                  Demo time: {dayTime(demoNow)}
                </span>
              )}
              {usingLocalDatabase && <span className="chip hide-narrow">Local database</span>}
              <button type="button" className="btn" onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
                      aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`}>
                {theme === 'dark' ? 'Light' : 'Dark'}
              </button>
            </div>
          </header>

          <Routes>
            <Route path="/" element={<Inbox />} />
            <Route path="/tickets/:id" element={<Ticket />} />
            <Route path="/invoices/:id" element={<Invoice />} />
            <Route path="/explain" element={<Explainer />} />
            <Route path="/patterns" element={<Patterns />} />
            <Route path="/playbooks" element={<Playbooks />} />
            <Route path="/plan" element={<Plan />} />
            <Route path="/about" element={<About />} />
            <Route path="*" element={<main className="page"><h1>Page not found</h1><p className="muted">Go back to the <Link className="link" to="/">inbox</Link>.</p></main>} />
          </Routes>
        </div>
      </div>
    </DemoNow.Provider>
  );
}

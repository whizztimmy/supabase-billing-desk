import { useState, type ReactNode } from 'react';
import type { QueueTicket, Tone } from '../types';

export function Badge({ tone = 'gray', children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`badge ${tone === 'gray' ? '' : tone}`}>{children}</span>;
}

export function Status({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className="status">
      <span className={`dot ${tone === 'gray' ? '' : tone}`} aria-hidden="true" />
      {children}
    </span>
  );
}

export const severityTone: Record<QueueTicket['severity'], Tone> = {
  Urgent: 'red', High: 'amber', Normal: 'gray', Low: 'gray',
};

export const slaTone: Record<QueueTicket['sla_state'], Tone> = {
  overdue: 'red', 'due soon': 'amber', 'on track': 'green',
};

export function invoiceTone(status: string): Tone {
  if (status === 'paid') return 'green';
  if (status === 'open' || status === 'uncollectible') return 'red';
  return 'gray';
}

export function ErrorNote({ message }: { message: string }) {
  return <p className="error" role="alert">Could not load this: {message}</p>;
}

// Placeholder rows while a table loads, so the layout does not jump.
export function SkeletonRows({ rows = 6, columns }: { rows?: number; columns: number }) {
  return (
    <>
      {Array.from({ length: rows }, (_, r) => (
        <tr key={r}>
          {Array.from({ length: columns }, (_, c) => (
            <td key={c}><span className="skeleton" style={{ width: `${40 + ((r * 7 + c * 13) % 50)}%` }} /></td>
          ))}
        </tr>
      ))}
    </>
  );
}

export function SkeletonLines({ lines = 4 }: { lines?: number }) {
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      {Array.from({ length: lines }, (_, i) => (
        <span key={i} className="skeleton" style={{ width: `${90 - i * 14}%` }} />
      ))}
    </div>
  );
}

export function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard access can be refused; the text stays selectable on the page.
    }
  }
  return (
    <button type="button" className="btn" onClick={copy}>
      {copied ? 'Copied' : label}
    </button>
  );
}

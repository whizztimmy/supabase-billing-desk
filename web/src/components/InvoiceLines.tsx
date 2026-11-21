import { num, usd } from '../format';
import type { InvoiceLine } from '../types';

// One row per invoice line, with its plain-language explanation underneath.
// When `compare` is set, each line also shows what the usage records call for,
// and a line that differs is flagged.
export default function InvoiceLines({ lines, compare = false }: { lines: InvoiceLine[]; compare?: boolean }) {
  const total = lines.reduce((sum, l) => sum + Number(l.amount ?? 0), 0);
  const expected = lines.reduce((sum, l) => sum + Number(l.expected_amount ?? 0), 0);

  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Line</th>
            <th className="num hide-narrow">Used</th>
            <th className="num hide-narrow">Included</th>
            <th className="num">{compare ? 'On the invoice' : 'Amount'}</th>
            {compare && <th className="num">From usage records</th>}
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => {
            const wrong = compare && l.matches === false;
            return (
              <tr key={`${l.line_no}-${l.name}-${l.project ?? ''}`} className={wrong ? 'flag' : ''}>
                <td>
                  <div className="primary">
                    {l.name}{l.project && <span className="muted" style={{ fontWeight: 400 }}> · {l.project}</span>}
                  </div>
                  <div className="explain">{l.explanation}</div>
                </td>
                <td className="num hide-narrow">
                  {l.quantity !== null && l.kind !== 'plan' ? <>{num(l.quantity)} <span className="muted">{l.unit}</span></> : ''}
                </td>
                <td className="num hide-narrow">{l.included !== null ? num(l.included) : ''}</td>
                <td className="num">{l.amount === null ? <span className="muted">missing</span> : usd(l.amount)}</td>
                {compare && (
                  <td className="num">{l.expected_amount === null || l.expected_amount === undefined ? <span className="muted">none</span> : usd(l.expected_amount)}</td>
                )}
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr>
            <td>Total</td>
            <td className="hide-narrow" />
            <td className="hide-narrow" />
            <td className="num">{usd(total)}</td>
            {compare && <td className="num">{usd(expected)}</td>}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

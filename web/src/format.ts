const usdFormat = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const numberFormat = new Intl.NumberFormat('en-US', { maximumFractionDigits: 5 });

export const usd = (n: number | null | undefined) => (n === null || n === undefined ? '' : usdFormat.format(Number(n)));
export const num = (n: number | null | undefined) => (n === null || n === undefined ? '' : numberFormat.format(Number(n)));

const dayFormat = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
const timeFormat = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'UTC' });

export const day = (iso: string | null | undefined) => (iso ? dayFormat.format(new Date(iso)) : '');
export const dayTime = (iso: string | null | undefined) => (iso ? `${timeFormat.format(new Date(iso))} UTC` : '');

// 1.3 hours as "1h 18m", 42 hours as "1d 18h".
export function duration(hours: number): string {
  const minutes = Math.round(Math.abs(hours) * 60);
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 24 * 60) return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  return `${Math.floor(minutes / 1440)}d ${Math.floor((minutes % 1440) / 60)}h`;
}

export const hoursBetween = (from: string, to: string) => (new Date(to).getTime() - new Date(from).getTime()) / 36e5;

export const titleCase = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

// A card expiry stored as 2028-06-01, shown the way it is printed on the card.
export const monthYear = (iso: string | null | undefined) => (iso ? `${iso.slice(5, 7)}/${iso.slice(0, 4)}` : '');

const regionNames = new Intl.DisplayNames(['en'], { type: 'region' });

// "NG" as "Nigeria". Falls back to the code if the browser does not know it.
export function country(code: string | null | undefined): string {
  if (!code) return '';
  try {
    return regionNames.of(code) ?? code;
  } catch {
    return code;
  }
}

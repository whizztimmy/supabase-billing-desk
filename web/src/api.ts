import { useEffect, useState } from 'react';

type Response<T> = { data: T | null; error: { message: string } | null };

export type Query<T> = { data: T | null; error: string | null; loading: boolean };

// Runs one Supabase request and tracks its state. `key` identifies the
// request: when it changes, the request runs again and a late answer to the
// old one is dropped.
export function useQuery<T>(key: string, run: () => PromiseLike<Response<T>>, enabled = true): Query<T> {
  const [state, setState] = useState<Query<T>>({ data: null, error: null, loading: enabled });

  useEffect(() => {
    if (!enabled) return;
    let current = true;
    setState((s) => ({ ...s, loading: true, error: null }));
    Promise.resolve(run()).then(
      ({ data, error }) => {
        if (current) setState({ data: error ? null : data, error: error?.message ?? null, loading: false });
      },
      (e: unknown) => {
        if (current) setState({ data: null, error: e instanceof Error ? e.message : String(e), loading: false });
      },
    );
    return () => { current = false; };
    // `run` is recreated on every render; `key` is what identifies the request.
  }, [key, enabled]);

  return state;
}

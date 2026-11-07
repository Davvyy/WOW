import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import type { ConsoleApi } from './data/api';
import type { OpsInfo } from './data/types';
import { ErrorBox, Loading, Ms } from './components/ui';

interface Ctx { api: ConsoleApi; ops: OpsInfo; version: number; toast: (msg: string, icon?: string) => void }
const ConsoleContext = createContext<Ctx | null>(null);

export function ConsoleProvider({ api, children }: { api: ConsoleApi; children: ReactNode }) {
  const [version, setVersion] = useState(0);
  const [ops, setOps] = useState<OpsInfo | null>(null);
  const [opsErr, setOpsErr] = useState<Error | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [toastState, setToast] = useState<{ msg: string; icon: string } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => api.subscribe(() => setVersion((v) => v + 1)), [api]);
  useEffect(() => {
    let on = true;
    api.ops().then((o) => { if (on) { setOps(o); setOpsErr(null); } }, (e: Error) => { if (on) setOpsErr(e); });
    return () => { on = false; };
  }, [api, version, attempt]);

  const toast = useCallback((msg: string, icon = 'check_circle') => {
    setToast({ msg, icon });
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setToast(null), 2600);
  }, []);

  // 첫 요청이 느린 동안(운영자 확인) 빈 화면으로 두지 않는다
  if (!ops) return <main className="content">{opsErr ? <ErrorBox error={opsErr} retry={() => { setOpsErr(null); setAttempt((a) => a + 1); }} /> : <Loading />}</main>;
  return (
    <ConsoleContext.Provider value={{ api, ops, version, toast }}>
      {children}
      {toastState ? <div className="toast" role="status"><Ms name={toastState.icon} /><span>{toastState.msg}</span></div> : null}
    </ConsoleContext.Provider>
  );
}

export function useConsole(): Ctx {
  const c = useContext(ConsoleContext);
  if (!c) throw new Error('ConsoleProvider 밖에서 쓸 수 없어요');
  return c;
}

/** 데이터 불러오기. 데이터 버전이 바뀌면 다시 불러오고, 그동안 이전 값을 유지한다. */
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[]): { data?: T; error: Error | null; loading: boolean; reload: () => void } {
  const { version } = useConsole();
  const [state, setState] = useState<{ data?: T; error: Error | null; loading: boolean }>({ loading: true, error: null });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let on = true;
    setState((s) => ({ ...s, loading: true }));
    fn().then(
      (data) => { if (on) setState({ data, error: null, loading: false }); },
      (error: Error) => { if (on) setState((s) => ({ data: s.data, error, loading: false })); },
    );
    return () => { on = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [version, tick, ...deps]);
  return { ...state, reload: () => setTick((t) => t + 1) };
}

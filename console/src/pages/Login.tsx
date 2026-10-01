import { useEffect, useState, type ReactNode } from 'react';
import type { ConsoleApi } from '../data/api';
import { supabase } from '../data/supabaseClient';

/** Supabase 연결 시 운영자 이메일 로그인. 모의 데이터에서는 바로 통과한다. */
export function AuthGate({ api, children }: { api: ConsoleApi; children: ReactNode }) {
  const [state, setState] = useState<'loading' | 'in' | 'out'>(api.kind === 'mock' ? 'in' : 'loading');
  const [email, setEmail] = useState('');
  const [pw, setPw] = useState('');
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (api.kind === 'mock') return;
    const sb = supabase();
    sb.auth.getSession().then(({ data }) => setState(data.session ? 'in' : 'out'));
    const { data } = sb.auth.onAuthStateChange((_e, session) => setState(session ? 'in' : 'out'));
    return () => data.subscription.unsubscribe();
  }, [api]);

  if (state === 'in') return <>{children}</>;
  if (state === 'loading') return null;
  return (
    <main className="content" style={{ maxWidth: 420, marginTop: 80 }}>
      <form className="card" onSubmit={async (e) => {
        e.preventDefault(); setErr(null);
        const { error } = await supabase().auth.signInWithPassword({ email, password: pw });
        if (error) setErr('이메일 또는 비밀번호를 확인해 주세요');
      }}>
        <p className="title" style={{ fontSize: 18 }}>챌로리 운영자 콘솔</p>
        <div className="field"><label htmlFor="em">이메일</label><div className="input"><input id="em" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></div></div>
        <div className="field"><label htmlFor="pw">비밀번호</label><div className="input"><input id="pw" type="password" autoComplete="current-password" value={pw} onChange={(e) => setPw(e.target.value)} required /></div></div>
        {err ? <p className="cap" role="alert" style={{ color: 'var(--critical)' }}>{err}</p> : null}
        <button className="btn" type="submit">로그인</button>
        <p className="cap">운영자 계정만 들어올 수 있어요. 권한은 서버 RLS가 확인해요.</p>
      </form>
    </main>
  );
}

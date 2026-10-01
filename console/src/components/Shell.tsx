import { useEffect, useState } from 'react';
import { NavLink, Outlet, useMatch, useNavigate, useOutletContext, useParams } from 'react-router';
import { useConsole, useLoad } from '../context';
import type { Challenge } from '../data/types';
import { ddayInfo, STATUS } from '../lib/lifecycle';
import { Ms, ErrorBox, Loading } from './ui';

type ThemeMode = 'system' | 'light' | 'dark';

function applyTheme(mode: ThemeMode) {
  if (mode === 'system') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', mode);
  try { localStorage.setItem('challory-theme', mode); } catch { /* 저장소 접근 불가 */ }
}

function ReviewBar() {
  const { api } = useConsole();
  const [theme, setTheme] = useState<ThemeMode>(() => {
    try { return (localStorage.getItem('challory-theme') as ThemeMode) || 'system'; } catch { return 'system'; }
  });
  useEffect(() => { applyTheme(theme); }, [theme]);
  const m = api.mock;
  return (
    <div className="hbar" role="region" aria-label="검수 패널">
      <span className="mark">C</span>
      <span className="ttl">챌로리 운영자 콘솔 <small>{api.kind === 'mock' ? '모의 데이터' : 'Supabase 연결'}</small></span>
      {m ? (
        <>
          <span className="sec">상태 변형</span>
          <div className="variants" role="group" aria-label="모의 데이터 상태 변형">
            {m.scenarios.map((s) => (
              <button key={s.key} aria-pressed={m.current() === s.key} onClick={() => { try { localStorage.setItem('challory-mock-scenario', s.key); } catch { /* 무시 */ } m.setScenario(s.key); }}>{s.label}</button>
            ))}
          </div>
        </>
      ) : null}
      <span className="spacer" />
      <div className="ctrl" role="group" aria-label="테마">
        {([['system', 'contrast', '시스템'], ['light', 'light_mode', '라이트'], ['dark', 'dark_mode', '다크']] as const).map(([k, icon, label]) => (
          <button key={k} aria-pressed={theme === k} onClick={() => setTheme(k)}><Ms name={icon} cls="xs" />{label}</button>
        ))}
      </div>
    </div>
  );
}

function SideNav() {
  const { api, ops, version } = useConsole();
  const match = useMatch('/c/:cid/*');
  const cid = match?.params.cid;
  const { data: pend } = useLoad(() => (cid ? api.openReviewCount(cid) : Promise.resolve(0)), [cid]);
  const { data: ch } = useLoad(() => (cid ? api.getChallenge(cid) : Promise.resolve(null)), [cid, version]);
  const items = [
    { to: 'settings', id: 'OP1', icon: 'tune', name: '설정 · 규칙 · 초대코드' },
    { to: 'participants', id: 'OP2', icon: 'group', name: '참가자 · 동기화' },
    { to: 'reviews', id: 'OP3', icon: 'gavel', name: '검토 큐 · 판정' },
    { to: 'results', id: 'OP4', icon: 'emoji_events', name: '결과 · 공지 · CSV · 파기' },
  ];
  const n = pend ?? 0;
  return (
    <nav className="sidenav" aria-label="콘솔 메뉴">
      <div className="brand"><span className="logo">C</span><div><div className="t">챌로리 콘솔</div><div className="s">운영자 웹</div></div></div>
      <NavLink className="item" to="/" end aria-label="OP0 챌린지 목록">
        <Ms name="dashboard" /><span><span className="id">OP0</span><span className="nm">챌린지 목록</span></span><span />
      </NavLink>
      {cid && ch ? <div className="lbl">{ch.name}</div> : null}
      {cid ? items.map((it) => (
        <NavLink key={it.id} className="item sub" to={`/c/${cid}/${it.to}`}>
          <Ms name={it.icon} /><span><span className="id">{it.id}</span><span className="nm">{it.name}</span></span>
          {it.id === 'OP3' ? <span className={`badge ${n ? '' : 'zero'}`} aria-label={`미결 ${n}건`}>{n}</span> : <span />}
        </NavLink>
      )) : null}
      <div className="foot"><span className="av">{ops.operatorName.slice(0, 1)}</span><span>운영자 {ops.operatorName} · 감사 로그 ON</span></div>
    </nav>
  );
}

export function Shell() {
  return (
    <>
      <ReviewBar />
      <div className="app">
        <SideNav />
        <div className="main"><Outlet /></div>
      </div>
    </>
  );
}

export interface ChallengeOutlet { challenge: Challenge }

export function ChallengeLayout() {
  const { cid } = useParams();
  const { api, ops, version } = useConsole();
  const nav = useNavigate();
  const { data, error, reload } = useLoad(() => api.getChallenge(cid!), [cid, version]);
  if (error && !data) return <main className="content"><ErrorBox error={error} retry={reload} /><button className="btn quiet" onClick={() => nav('/')}>챌린지 목록으로</button></main>;
  if (!data) return <main className="content"><Loading /></main>;
  const st = STATUS[data.status];
  const d = ddayInfo(data, ops.today);
  return (
    <>
      <header className="topbar">
        <div className="cname">{data.name}<span className="code">{data.inviteCode}</span></div>
        <span className={`pill ${st.kind}`} role="status"><Ms name={st.icon} />{st.label}<small>{st.en}</small></span>
        <span className="dday"><Ms name="calendar_today" cls="sm" /><b>{d.head}</b><span>{d.sub}</span></span>
        <span className="grow" />
        <span className="sync"><Ms name="sync" cls="xs" />데이터 기준 {ops.syncedLabel} · 매시 정각 재계산</span>
      </header>
      <main className="content" id="view"><Outlet context={{ challenge: data } satisfies ChallengeOutlet} /></main>
    </>
  );
}

export function useChallenge(): Challenge {
  return useOutletContext<ChallengeOutlet>().challenge;
}

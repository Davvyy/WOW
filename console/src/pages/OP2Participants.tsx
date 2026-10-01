import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { Avatar, Banner, Chip, Drawer, ErrorBox, Fill4, Loading, Modal, Ms, PageHead, type Kind } from '../components/ui';
import { useChallenge } from '../components/Shell';
import { useConsole, useLoad } from '../context';
import type { DayRow, HealthAlert, Participant, ParticipantAction } from '../data/types';
import { fmt, mdDate } from '../lib/format';

type FilterKey = 'all' | 'unsynced' | 'flag' | 'record' | 'excluded';
type SortKey = 'nickname' | 'sync' | 'steps';

const FILTERS: { k: FilterKey; label: string; f: (p: Participant) => boolean }[] = [
  { k: 'all', label: '전체', f: () => true },
  { k: 'unsynced', label: '미동기화', f: (p) => p.state === 'unsynced' },
  { k: 'flag', label: '플래그', f: (p) => p.flagged },
  { k: 'record', label: '기록 모드', f: (p) => p.state === 'record' },
  { k: 'excluded', label: '제외', f: (p) => p.state === 'excluded' || p.state === 'kicked' },
];

const ACTION_TEXT: Record<Exclude<ParticipantAction, 'memo'>, { title: string; body: string; btn: string; toast: string; icon: string }> = {
  exclude: { title: '순위에서 제외할까요?', body: '순위에서 제외하면 이 참가자는 리더보드 명단에서 빠지고, 점수와 기록은 계속 볼 수 있어요. 당사자에게 사유는 보이지 않아요.', btn: '순위 제외', toast: '순위에서 제외했어요 · 감사 로그 기록', icon: 'block' },
  kick: { title: '강퇴할까요?', body: '강퇴하면 이 참가자는 순위에서 빠지고 재가입이 차단돼요. 당사자에게 사유는 보이지 않아요.', btn: '강퇴', toast: '강퇴했어요 · 재가입 차단 · 감사 로그 기록', icon: 'person_off' },
  block: { title: '재가입을 차단할까요?', body: '재가입을 차단하면 같은 계정으로 이 챌린지 초대코드를 다시 쓸 수 없어요. 당사자에게는 "참가할 수 없는 코드예요"로만 보여요.', btn: '재가입 차단', toast: '재가입을 차단했어요 · 감사 로그 기록', icon: 'no_accounts' },
};

function stateCell(p: Participant): { chip: React.ReactNode; sync: React.ReactNode } {
  const src = `${p.lastSyncedAt ?? '—'} · ${p.source}`;
  switch (p.state) {
    case 'excluded': return { chip: <Chip kind="critical" icon="block">순위 제외</Chip>, sync: src };
    case 'kicked': return { chip: <Chip kind="critical" icon="person_off">강퇴 · 재가입 차단</Chip>, sync: `마지막 ${p.lastSyncedAt ?? '—'}` };
    case 'unsynced': return { chip: <Chip kind="warn" icon="sync_problem">미동기화</Chip>, sync: <><span style={{ color: 'var(--warn)' }}>오늘 동기화 없음</span><span className="sub">마지막 {p.lastSyncedAt ?? '—'}</span></> };
    case 'review': return { chip: <Chip kind="review" icon="rule">검토 중</Chip>, sync: src };
    case 'record': return { chip: <Chip icon="edit_note">기록 모드</Chip>, sync: src };
    default: return { chip: <Chip kind="good" icon="check_circle">정상</Chip>, sync: src };
  }
}

function ActionMenu({ p, onPick }: { p: Participant; onPick: (a: ParticipantAction) => void }) {
  return (
    <div className="menu" role="menu" aria-label={`${p.nickname} 조치`}>
      <button role="menuitem" className="critical" onClick={() => onPick('exclude')}><Ms name="block" />순위 제외</button>
      <button role="menuitem" className="critical" onClick={() => onPick('kick')}><Ms name="person_off" />강퇴</button>
      <button role="menuitem" className="critical" onClick={() => onPick('block')}><Ms name="no_accounts" />재가입 차단</button>
      <button role="menuitem" onClick={() => onPick('memo')}><Ms name="sticky_note_2" />메모</button>
    </div>
  );
}

function MiniLedger({ name, days }: { name: string; days: DayRow[] }) {
  return (
    <>
      <div className="table-wrap">
        <table className="table">
          <caption className="sr">{name} 일별 A/I/S 미니 장부</caption>
          <thead><tr><th scope="col">날짜</th><th scope="col" className="num">걸음</th><th scope="col" className="num">A</th><th scope="col" className="num">I</th><th scope="col" className="num">S</th><th scope="col">상태</th></tr></thead>
          <tbody>
            {days.map((r) => (
              <tr key={r.date} className={r.check ? 'dim' : ''}>
                <td>{r.label}</td><td className="num">{fmt.int(r.steps)}</td><td className="num">{fmt.int(r.a)}</td><td className="num">{fmt.int(r.i)}</td>
                <td className="num">{fmt.k1(r.s)}{r.sBefore != null ? <span className="sub">← {fmt.k1(r.sBefore)}</span> : null}</td>
                <td>{r.check ? <Chip>점검</Chip> : r.provisional ? <Chip icon="schedule">잠정</Chip> : r.revised ? <Chip kind="warn" icon="history">정정</Chip> : r.underReview ? <Chip kind="review" icon="rule">검토 중</Chip> : r.floorApplied ? <Chip kind="warn">하한 적용</Chip> : <Chip kind="good" icon="check">확정</Chip>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="cap">A 활동 · I 섭취 · S 점수(모두 추정) · 점검 기간은 누적 미반영 · 하한 적용은 건강 안내와 분리</p>
    </>
  );
}

function ParticipantDrawer({ p, alerts, hasOpenReview, onClose, onAction }: { p: Participant; alerts: HealthAlert[]; hasOpenReview: string | null; onClose: () => void; onAction: (a: ParticipantAction, p: Participant) => void }) {
  const { api, toast, ops } = useConsole();
  const nav = useNavigate();
  const ch = useChallenge();
  const { data: days } = useLoad(() => api.participantDays(p.id), [p.id]);
  const [memo, setMemo] = useState(p.operatorNote);
  useEffect(() => { setMemo(p.operatorNote); }, [p.id, p.operatorNote]);
  const st = stateCell(p);
  const mine = alerts.filter((a) => a.participantId === p.id);
  const hasSession = Boolean(days?.length && p.watch);
  return (
    <Drawer label={`참가자 상세: ${p.nickname}`} onClose={onClose} head={
      <>
        <Avatar name={p.nickname} />
        <div className="who">
          <div className="nm">{p.nickname}{p.watch ? <Chip icon="watch">워치</Chip> : null}{st.chip}</div>
          <p className="cap">{p.sex === 'M' ? '남' : '여'}{p.birthYear ? ` · ${p.birthYear}년` : ''} · {p.heightCm} cm · {p.weightKg} kg · BMR 약 {fmt.int(p.bmr)} · 경고 {p.warningCount}/3</p>
        </div>
      </>
    }>
      {p.state === 'unsynced' ? (
        <Banner kind="warn" icon="sync_problem" action={<button className="btn sm secondary" onClick={() => toast('P4 연결 진단 안내를 보냈어요 · 당사자에게만', 'send')}>P4 진단 안내</button>}>
          <b>오늘 동기화 없음</b> · 마지막 {p.lastSyncedAt ?? '—'}<br /><span className="cap">Galaxy는 삼성헬스 → Health Connect 동기화 OFF가 흔한 원인이에요</span>
        </Banner>
      ) : null}
      <div className="card"><p className="title">연결 상태</p>
        <div className="kv"><span className="k">기기</span><span className="v">{p.device}</span></div>
        <div className="kv"><span className="k">출처 · 플랫폼</span><span className="v">{p.source} · {p.platform}</span></div>
        <div className="kv"><span className="k">마지막 동기화</span><span className="v">{p.lastSyncedAt ?? '—'}</span></div>
        <div className="kv"><span className="k">권한</span><span className="v">{p.state === 'unsynced' ? <Chip kind="warn" icon="warning">걸음 읽기 · 확인 필요</Chip> : <Chip kind="good" icon="check">걸음 · 세션 · 층수 읽기</Chip>}</span></div>
      </div>
      <div className="card"><p className="title">출처 목록</p>
        <div className="kv"><span className="k">걸음</span><span className="v">{p.source} (자동)</span></div>
        <div className="kv"><span className="k">세션</span><span className="v">{hasSession ? 'Apple Watch 운동' : '없음'}</span></div>
        <div className="kv"><span className="k">수동 입력</span><span className="v">없음 · 인정하지 않아요</span></div>
      </div>
      <div className="card">
        <div className="card-head"><p className="title">일별 A/I/S 미니 장부</p>
          {hasOpenReview ? <button className="btn sm secondary" onClick={() => nav(`/c/${ch.id}/reviews?review=${hasOpenReview}`)}><Ms name="gavel" />검토 보기</button> : null}</div>
        {days ? <MiniLedger name={p.nickname} days={days} /> : <Loading />}
      </div>
      <div className="card review-soft" aria-label="운영자 전용 비공개 섹션">
        <div className="card-head"><p className="title" style={{ color: 'var(--review)' }}><Ms name="visibility_off" cls="sm" />운영자만 열람</p><Chip kind="review">CSV 미포함</Chip></div>
        {p.recordModeReason ? <div className="kv"><span className="k">기록 모드 사유</span><span className="v" style={{ textAlign: 'right' }}>{p.recordModeReason}</span></div> : null}
        {mine.map((a) => <div className="kv" key={a.id}><span className="k">건강 알림</span><span className="v" style={{ textAlign: 'right' }}>{a.text}<span className="sub">{a.nudge}</span></span></div>)}
        {!p.recordModeReason && !mine.length ? <p className="cap">비공개 항목 없음</p> : null}
        <p className="cap">당사자·다른 참가자에게 보이지 않아요. 기록 모드 사유와 건강 신호는 판정과 섞지 않아요.</p>
      </div>
      <div className="card"><p className="title">메모</p>
        <textarea className="ta" aria-label="운영자 메모" rows={3} placeholder="운영자만 보는 메모 · 감사 로그에 남아요" value={memo} onChange={(e) => setMemo(e.target.value)} />
        <div className="btn-row" style={{ justifyContent: 'flex-end' }}><button className="btn sm secondary" onClick={() => onAction('memo', { ...p, operatorNote: memo })}><Ms name="save" />메모 저장</button></div>
      </div>
      <div className="btn-row">
        <button className="btn sm critical ghost" onClick={() => onAction('exclude', p)}><Ms name="block" />순위 제외</button>
        <button className="btn sm critical ghost" onClick={() => onAction('kick', p)}><Ms name="person_off" />강퇴</button>
        <button className="btn sm critical ghost" onClick={() => onAction('block', p)}><Ms name="no_accounts" />재가입 차단</button>
      </div>
      <p className="cap">데이터 기준 {ops.syncedLabel}</p>
    </Drawer>
  );
}

export function OP2Participants() {
  const ch = useChallenge();
  const { api, toast } = useConsole();
  const [sp, setSp] = useSearchParams();
  const nav = useNavigate();
  const filter = (sp.get('filter') as FilterKey) || 'all';
  const whoId = sp.get('who');
  const { data: people, error, reload } = useLoad(() => api.listParticipants(ch.id), [ch.id]);
  const { data: summary } = useLoad(() => api.summary(ch.id), [ch.id]);
  const { data: alerts } = useLoad(() => api.listHealthAlerts(ch.id), [ch.id]);
  const { data: reviews } = useLoad(() => api.listReviews(ch.id), [ch.id]);
  const [menu, setMenu] = useState<string | null>(null);
  const [action, setAction] = useState<{ type: Exclude<ParticipantAction, 'memo'>; p: Participant } | null>(null);
  const [actMemo, setActMemo] = useState('');
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 } | null>(null);
  const [healthOpen, setHealthOpen] = useState(false);

  useEffect(() => {
    if (!menu) return;
    const close = (e: MouseEvent) => { if (!(e.target as HTMLElement).closest('.menu-wrap')) setMenu(null); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setMenu(null); };
    document.addEventListener('click', close); document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('click', close); document.removeEventListener('keydown', esc); };
  }, [menu]);

  const flt = FILTERS.find((f) => f.k === filter) ?? FILTERS[0];
  const rows = useMemo(() => {
    const r = (people ?? []).filter(flt.f);
    if (!sort) return r;
    const val = (p: Participant) => sort.key === 'nickname' ? p.nickname : sort.key === 'steps' ? p.todaySteps : p.lastSyncedAt ?? '';
    return [...r].sort((a, b) => (val(a) > val(b) ? 1 : val(a) < val(b) ? -1 : 0) * sort.dir);
  }, [people, flt, sort]);
  const unsyncedN = (people ?? []).filter((p) => p.state === 'unsynced').length;
  const pend = summary?.openReviews ?? 0;
  const empty = !!people && people.length === 0;
  const drawerP = whoId ? people?.find((p) => p.id === whoId) : undefined;
  const openReviewIdOf = (pid: string) => reviews?.find((r) => r.participantId === pid && r.status !== 'decided')?.id ?? null;

  const setFilter = (k: FilterKey) => { const n = new URLSearchParams(sp); if (k === 'all') n.delete('filter'); else n.set('filter', k); setSp(n, { replace: true }); };
  const openDrawer = (id: string | null) => { const n = new URLSearchParams(sp); if (id) n.set('who', id); else n.delete('who'); setSp(n); };
  const sortBtn = (key: SortKey, label: string) => (
    <button className="sortable" onClick={() => setSort(sort?.key === key ? { key, dir: sort.dir === 1 ? -1 : 1 } : { key, dir: 1 })} aria-label={`${label} 정렬`}>{label} <Ms name="swap_vert" /></button>
  );

  async function runAction(type: ParticipantAction, p: Participant, memo: string) {
    try {
      await api.participantAction(p.id, type, memo);
      toast(type === 'memo' ? '메모를 저장했어요 · 감사 로그 기록' : ACTION_TEXT[type].toast);
    } catch (e) { toast((e as Error).message, 'error'); }
  }
  function pick(type: ParticipantAction, p: Participant) {
    setMenu(null);
    if (type === 'memo') { openDrawer(p.id); return; }
    setActMemo(''); setAction({ type, p });
  }

  const kpis = (
    <div className="grid kpi">
      <div className="card"><span className="k"><Ms name="group" cls="xs" />참가자</span><span className="v">{ch.joined}<small>/ {ch.capacity}</small></span>
        <span className="s">{empty ? `모집 중 · 초대코드 ${ch.inviteCode}` : <><Chip icon="watch">워치 {(people ?? []).filter((p) => p.watch).length}</Chip> <Chip>기록 모드 {(people ?? []).filter((p) => p.state === 'record').length}</Chip></>}</span></div>
      <div className="card"><span className="k"><Ms name="sync" cls="xs" />오늘 동기화율</span><span className="v">{summary?.todaySyncRate ?? 0}<small>%</small></span>
        <span className="s">{empty ? '—' : `미동기화 ${unsyncedN}명`}</span></div>
      <div className="card"><span className="k"><Ms name="restaurant" cls="xs" />미확정 끼니</span><span className="v">{summary?.unconfirmedMeals ?? 0}</span><span className="s">{empty ? '—' : '내일 09:00 자동 확정'}</span></div>
      <button className="card" style={{ textAlign: 'left', cursor: 'pointer' }} onClick={() => nav(`/c/${ch.id}/reviews`)} aria-label={`미결 검토 ${pend}건 · 검토 큐 열기`}>
        <span className="k"><Ms name="gavel" cls="xs" />미결 검토</span><span className="v" style={{ color: pend ? 'var(--critical)' : 'var(--good)' }}>{pend}<small>건</small></span>
        <span className="s">{pend ? '검토 큐 열기' : '최종 확정 가능'} <Ms name="chevron_right" cls="xs" /></span>
      </button>
    </div>
  );

  return (
    <>
      <PageHead id="OP2" title="참가자 · 동기화 현황" lead={'"걸음 0" 문의 즉답 · 조치(제외·강퇴·재가입 차단·메모) · 건강 신호 비공개 열람'} acts={<span className="cap"><Ms name="schedule" cls="xs" /> 매시 정각 재계산</span>} />
      {kpis}
      {error && !people ? <ErrorBox error={error} retry={reload} /> : null}
      {!people && !error ? <Loading /> : null}
      {empty ? (
        <div className="card"><div className="empty"><Ms name="group_add" /><p className="title">아직 참가자가 없어요</p><p className="body">초대코드를 공유해 주세요 · 시작 {mdDate(ch.startDate)}</p>
          <div className="btn-row"><NavBtn to={`/c/${ch.id}/settings`} icon="key">초대코드 보기</NavBtn></div></div></div>
      ) : people ? (
        <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
          <div className="card-head" style={{ padding: '14px 18px 0' }}>
            <div className="filter" role="group" aria-label="참가자 필터">
              {FILTERS.map((f) => <button key={f.k} aria-pressed={filter === f.k} onClick={() => setFilter(f.k)}>{f.label}<span className="n">{f.k === 'all' ? ch.joined : people.filter(f.f).length}</span></button>)}
            </div>
            <span className="cap">{filter === 'all' ? `${rows.length}/${ch.joined}명 표시` : `${rows.length}명`} · 내보내기는 OP4에서만</span>
          </div>
          {filter === 'unsynced' ? <div style={{ padding: '10px 18px 0' }}><Banner kind="warn" icon="sync_problem"><b>미동기화 {rows.length}명</b> · Health Connect 동기화 OFF가 흔한 원인이에요. 드로어에서 P4 진단 안내를 보낼 수 있어요.</Banner></div> : null}
          <div className="table-wrap" style={{ padding: '6px 18px 10px' }}>
            <table className="table" id="peopleTable">
              <caption className="sr">참가자 표</caption>
              <thead><tr>
                <th scope="col">{sortBtn('nickname', '닉네임')}</th><th scope="col">상태</th><th scope="col">{sortBtn('sync', '마지막 동기화')}</th><th scope="col">출처</th>
                <th scope="col" className="num">{sortBtn('steps', '오늘 걸음')}</th><th scope="col" className="num">끼니 확정</th><th scope="col" className="num">경고</th><th scope="col">조치</th>
              </tr></thead>
              <tbody>
                {rows.length ? rows.map((p) => {
                  const st = stateCell(p);
                  return (
                    <tr key={p.id}>
                      <td><button className="rowbtn" onClick={() => openDrawer(p.id)} aria-label={`${p.nickname} 상세 드로어 열기`}><Avatar name={p.nickname} />{p.nickname}{p.watch ? <Ms name="watch" cls="xs" /> : null}</button></td>
                      <td>{st.chip}</td>
                      <td>{st.sync}</td>
                      <td>{p.source}<span className="sub">{p.device} · {p.platform}</span></td>
                      <td className="num" style={p.todaySteps === 0 ? { color: 'var(--warn)' } : undefined}>{fmt.int(p.todaySteps)}</td>
                      <td className="num">{p.mealsToday}/3 <Fill4 n={p.mealsToday + (p.todaySteps > 0 ? 1 : 0)} /></td>
                      <td className="num" style={p.warningCount >= 2 ? { color: 'var(--warn)' } : undefined}>{p.warningCount}/3</td>
                      <td><div className="menu-wrap">
                        <button className="btn sm quiet" aria-haspopup="menu" aria-expanded={menu === p.id} aria-label={`${p.nickname} 조치 메뉴`} onClick={() => setMenu(menu === p.id ? null : p.id)}>조치 <Ms name="expand_more" /></button>
                        {menu === p.id ? <ActionMenu p={p} onPick={(a) => pick(a, p)} /> : null}
                      </div></td>
                    </tr>
                  );
                }) : <tr><td colSpan={8}><div className="empty" style={{ padding: 24 }}><Ms name="filter_alt_off" /><p className="body">해당하는 참가자가 없어요</p></div></td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      ) : null}

      <details className="priv" id="healthSec" aria-label="운영자 전용 비공개 섹션" open={healthOpen} onToggle={(e) => setHealthOpen((e.currentTarget as HTMLDetailsElement).open)}>
        <summary><Ms name="health_and_safety" />건강 알림 <Chip kind="review" icon="visibility_off">운영자만 열람 · CSV 미포함</Chip><span className="num" style={{ fontWeight: 700 }}>{alerts?.length ?? 0}건</span><span style={{ flex: 1 }} /><Ms name="expand_more" cls="chev" /></summary>
        <div className="inner">
          <p className="cap" style={{ color: 'var(--review)' }}>검토 큐가 아니에요 — 판정과 건강 배려를 섞지 않아요. 당사자에게는 점수와 무관한 중립 카드(N-07)로만 보여요. 섭취 3일 연속 적음(low_intake_3d) · 활동 3일 연속 높음(high_activity_3d) · 체중 급감(weight_drop).</p>
          <div className="table-wrap">
            <table className="table">
              <caption className="sr">건강 알림 목록</caption>
              <thead><tr><th scope="col">참가자</th><th scope="col">유형</th><th scope="col">내용</th><th scope="col">처리</th></tr></thead>
              <tbody>
                {(alerts ?? []).length ? (alerts ?? []).map((a) => (
                  <tr key={a.id}>
                    <td><button className="rowbtn" onClick={() => openDrawer(a.participantId)}><Avatar name={a.nickname} />{a.nickname}</button></td>
                    <td><code style={{ fontSize: 12 }}>{a.type}</code></td>
                    <td style={{ whiteSpace: 'normal' }}>{a.text}</td>
                    <td><Chip kind="review" icon="notifications">{a.nudge}</Chip></td>
                  </tr>
                )) : <tr><td colSpan={4} className="muted">건강 알림이 없어요</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      </details>

      {drawerP ? <ParticipantDrawer p={drawerP} alerts={alerts ?? []} hasOpenReview={openReviewIdOf(drawerP.id)} onClose={() => openDrawer(null)} onAction={(t, p) => (t === 'memo' ? runAction('memo', p, p.operatorNote) : pick(t, p))} /> : null}
      {action ? (
        <Modal id="mAction" onClose={() => setAction(null)}
          title={<><Ms name={ACTION_TEXT[action.type].icon} />{action.p.nickname} 님을 {ACTION_TEXT[action.type].title}</>}
          acts={<><button className="btn quiet" onClick={() => setAction(null)}>돌아가기</button>
            <button className="btn critical" onClick={async () => { const a = action; setAction(null); await runAction(a.type, a.p, actMemo); }}><Ms name={ACTION_TEXT[action.type].icon} />{ACTION_TEXT[action.type].btn}</button></>}>
          <p className="body">{ACTION_TEXT[action.type].body}</p>
          <div className="field"><label htmlFor="actMemo">사유 메모 (운영자만 · 감사 로그)</label><textarea className="ta" id="actMemo" rows={2} placeholder="예: 10.12 걸음 급증 소명 없이 반복" value={actMemo} onChange={(e) => setActMemo(e.target.value)} /></div>
        </Modal>
      ) : null}
    </>
  );
}

function NavBtn({ to, icon, children, kind }: { to: string; icon: string; children: React.ReactNode; kind?: Kind }) {
  const nav = useNavigate();
  return <button className={kind === 'neutral' ? 'btn quiet' : 'btn'} onClick={() => nav(to)}><Ms name={icon} />{children}</button>;
}

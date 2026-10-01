import { useNavigate } from 'react-router';
import { Chip, ErrorBox, Loading, Ms, PageHead } from '../components/ui';
import { useConsole, useLoad } from '../context';
import { ddayInfo, STATUS } from '../lib/lifecycle';
import { mdDate } from '../lib/format';

export function OP0Challenges() {
  const { api, ops } = useConsole();
  const nav = useNavigate();
  const { data, error, reload } = useLoad(() => api.listChallenges(), []);
  return (
    <main className="content">
      <PageHead id="OP0" title="챌린지 목록" lead={`운영자 ${ops.operatorName} · ${data ? `${data.length}개 챌린지` : ''}`}
        acts={<button className="btn secondary" disabled title="1회차는 챌린지 1개로 운영해요"><Ms name="add" />새 챌린지</button>} />
      {error && !data ? <ErrorBox error={error} retry={reload} /> : null}
      {!data && !error ? <Loading /> : null}
      {data ? (
        <div className="grid two">
          {data.map(({ challenge: c, openReviews, todaySyncRate, unconfirmedMeals }) => {
            const s = STATUS[c.status];
            const d = ddayInfo(c, ops.today);
            const started = !['draft', 'recruiting'].includes(c.status);
            return (
              <button key={c.id} className="card outline" style={{ textAlign: 'left', cursor: 'pointer', gap: 14 }} onClick={() => nav(`/c/${c.id}/${started ? 'participants' : 'settings'}`)} aria-label={`${c.name} 열기`}>
                <div className="card-head">
                  <p className="title" style={{ fontSize: 18 }}>{c.name}</p>
                  <span className={`pill ${s.kind}`}><Ms name={s.icon} />{s.label}<small>{s.en}</small></span>
                </div>
                <div className="chips">
                  <Chip icon="calendar_today">{d.head} · {mdDate(c.startDate)}~{mdDate(c.endDate)}</Chip>
                  <Chip icon="group">참가 {c.joined}/{c.capacity}</Chip>
                  <Chip kind={openReviews ? 'critical' : 'good'} icon="gavel">미결 {openReviews}건</Chip>
                  {todaySyncRate != null ? <Chip kind="good" icon="sync">오늘 동기화 {todaySyncRate}%</Chip> : null}
                </div>
                <div className="grid kpi" style={{ gap: 10 }}>
                  <div><span className="cap">정원</span><div className="num" style={{ fontSize: 22, fontWeight: 700 }}>{c.joined}<span className="cap">/{c.capacity}</span></div></div>
                  <div><span className="cap">동기화율</span><div className="num" style={{ fontSize: 22, fontWeight: 700 }}>{todaySyncRate != null ? `${todaySyncRate}%` : '—'}</div></div>
                  <div><span className="cap">미확정 끼니</span><div className="num" style={{ fontSize: 22, fontWeight: 700 }}>{unconfirmedMeals}</div></div>
                  <div><span className="cap">미결 검토</span><div className="num" style={{ fontSize: 22, fontWeight: 700 }}>{openReviews}</div></div>
                </div>
                <span className="link">열기 <Ms name="chevron_right" /></span>
              </button>
            );
          })}
          <div className="card">
            <p className="title">운영 메모</p>
            <p className="body muted">AI 분석 월 예산과 Edge Function 호출 수는 1회차에 Supabase Studio 대시보드에서 확인해요. 콘솔 OP1~OP4는 좌측 메뉴에서 열어요.</p>
          </div>
        </div>
      ) : null}
    </main>
  );
}

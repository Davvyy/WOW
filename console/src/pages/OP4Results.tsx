import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import { Avatar, Banner, Chip, ErrorBox, Fill4, Loading, Modal, Ms, PageHead } from '../components/ui';
import { useChallenge } from '../components/Shell';
import { useConsole, useLoad } from '../context';
import type { CsvFile, CsvType } from '../data/types';
import { CSV_LABEL } from '../lib/csv';
import { fmt, mdDate, mdTime } from '../lib/format';
import { objectionDaysLeft, objectionUntil } from '../lib/lifecycle';

const TITLE_MAX = 40;
const BODY_MAX = 500;
const CSV_META: Record<CsvType, { icon: string; hint: string }> = {
  ranking: { icon: 'leaderboard', hint: '순위·닉네임·누적·확정 끼니' },
  scores: { icon: 'table_chart', hint: '참가자×일 · A/I/D/S · is_counted' },
  meals: { icon: 'restaurant', hint: '끼니별 status · confirmed_kcal' },
  activity: { icon: 'directions_walk', hint: 'steps_net · sessions_net · floors · a_capped' },
};

export function OP4Results() {
  const ch = useChallenge();
  const { api, ops, toast } = useConsole();
  const nav = useNavigate();
  const { data: pend, error: pendErr, reload } = useLoad(() => api.openReviewCount(ch.id), [ch.id, ch.status]);
  const { data: ranking } = useLoad(() => api.finalRanking(ch.id), [ch.id, ch.status]);
  const { data: photos } = useLoad(() => api.photoCount(ch.id), [ch.id]);

  const [title, setTitle] = useState('최종 결과는 11.3 09:00에 확정돼요');
  const [body, setBody] = useState('마지막 날(11.2) 기록은 11.3 09:00에 확정되고, 운영자 확인 뒤 같은 날 발표돼요. 이의 기간은 11.10까지예요.');
  const [preview, setPreview] = useState(false);
  const [sent, setSent] = useState<number | null>(null);
  const [csv, setCsv] = useState<Partial<Record<CsvType, CsvFile & { url: string; at: string }>>>({});
  const [confirmModal, setConfirmModal] = useState(false);
  const [finalChk, setFinalChk] = useState(false);
  const [destroyChk, setDestroyChk] = useState(false);
  const [destroyModal, setDestroyModal] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => { setPreview(false); }, [title, body]);

  const closing = ch.status === 'closing';
  const published = ch.status === 'published';
  const archived = ch.status === 'archived';
  const purged = Boolean(ch.photosPurgedAt);
  const until = objectionUntil(ch);
  const timer = objectionDaysLeft(ch, ops.today);
  const n = pend ?? 0;
  const noticeLocked = archived || ch.status === 'cancelled' || ch.status === 'draft';

  async function publish() {
    setBusy(true);
    try {
      await api.transition(ch.id, 'published');
      setConfirmModal(false); setFinalChk(false);
      toast(`결과를 확정했어요 · ${ch.joined}명에게 발표 · 이의 기간 7일`, 'verified');
    } catch (e) {
      setConfirmModal(false);
      toast((e as Error).message, 'error'); // 서버가 미결 N건을 알려 주면 그대로 보여준다
      reload();
    }
    setBusy(false);
  }
  async function send() {
    try { const r = await api.sendAnnouncement(ch.id, { title: title.trim(), body: body.trim() }); setSent(r.recipients); toast(`${r.recipients}명에게 보냈어요 · N-03 · P5 배너·P12 공지 목록에 보관`, 'send'); }
    catch (e) { toast((e as Error).message, 'error'); }
  }
  async function makeCsv(t: CsvType) {
    try {
      const f = await api.exportCsv(ch.id, t);
      const url = URL.createObjectURL(new Blob([f.text], { type: 'text/csv;charset=utf-8' }));
      setCsv((m) => ({ ...m, [t]: { ...f, url, at: mdTime(new Date().toISOString()) } }));
      toast(`${CSV_LABEL[t]} CSV를 생성했어요 · 건강 신호 미포함`, 'download_done');
    } catch (e) { toast((e as Error).message, 'error'); }
  }
  async function purge() {
    setBusy(true);
    try { const r = await api.purgePhotos(ch.id); setDestroyModal(false); toast(`${fmt.int(r.count)}장 파기 완료 · 해시·확정값만 보존`, 'delete_forever'); }
    catch (e) { setDestroyModal(false); toast((e as Error).message, 'error'); }
    setBusy(false);
  }

  let banner: React.ReactNode;
  if (pendErr && pend == null) banner = <ErrorBox error={pendErr} retry={reload} />;
  else if (pend == null) banner = <Loading />;
  else if (closing && n > 0) banner = (
    <Banner lg kind="critical" icon="error" role="alert" action={
      <div className="btn-row" style={{ flex: 'none' }}>
        <button className="btn quiet" disabled aria-disabled="true" title={`미결 ${n}건 · 모두 판정하면 활성화돼요`}><Ms name="verified" />최종 확정</button>
        <button className="btn critical" onClick={() => nav(`/c/${ch.id}/reviews`)}><Ms name="gavel" />검토 큐 열기</button>
      </div>}>
      <b>미결 {n}건이 있어 최종 확정을 할 수 없어요</b><br /><span className="cap">모두 판정하면 확정 버튼이 열려요 · 서버도 미결이 있으면 확정을 막아요</span>
    </Banner>
  );
  else if (closing) banner = (
    <Banner lg kind="good" icon="task_alt" role="status" action={<button className="btn lg" onClick={() => setConfirmModal(true)}><Ms name="verified" />최종 확정</button>}>
      <b>미결 0건</b> · 최종 확정하면 결과가 발표되고 7일 이의 기간이 시작돼요
    </Banner>
  );
  else if (published) banner = (
    <Banner lg kind="brand" icon="verified" role="status" action={
      <div style={{ minWidth: 180, display: 'flex', flexDirection: 'column', gap: 4 }}>
        <span className="cap" style={{ color: 'inherit', textAlign: 'right' }}>이의 기간 {timer.elapsed}/7일 경과</span>
        <div className="gauge" aria-label={`이의 기간 7일 중 ${timer.elapsed}일 경과, ${timer.left}일 남음`}><i style={{ width: `${(timer.elapsed / 7 * 100).toFixed(0)}%` }} /></div>
      </div>}>
      <b>결과 확정 {ch.publishedAt ? mdTime(ch.publishedAt) : ''}</b> · 이의 기간 ~{until ? mdDate(until) : ''} · 이의 0건<br /><span className="cap">7일 중 {timer.left}일 남음 · 이의가 접수되면 OP3 큐(이의)로 들어와요</span>
    </Banner>
  );
  else if (archived) banner = (
    <Banner lg kind="neutral" icon="inventory_2" role="status">
      <b>종료{purged ? ` · ${fmt.int(photos ?? 0)}장 파기 완료 ${mdTime(ch.photosPurgedAt!)}` : ' · 사진 파기 전'}</b> · 열람 전용<br /><span className="cap">일별 점수는 익명으로 보존 후 삭제 · 감사 로그 종료+90일</span>
    </Banner>
  );
  else banner = <Banner lg kind="neutral" icon="schedule" role="status"><b>아직 집계 마감 전이에요</b><br /><span className="cap">종료일 다음 날 09:00 확정 배치가 끝나면 집계 마감(Closing)에서 최종 확정할 수 있어요</span></Banner>;

  return (
    <>
      <PageHead id="OP4" title="결과 · 공지 · CSV · 파기" lead={'최종 순위 확정("미결 0건" 조건) → 공지 발송 → CSV 4종 → 이의 기간 · 사진 파기'} />
      {banner}

      <div className="card">
        <div className="card-head"><p className="title"><Ms name="leaderboard" cls="sm" />최종 순위</p>
          <div className="chips">{ranking?.isFinal ? <Chip kind="good" icon="verified">확정 스냅샷{ranking.asOf ? ` ${mdTime(ranking.asOf)}` : ''}</Chip> : <Chip kind="warn" icon="lock_clock">잠정 · 집계 마감 · 정정 반영 중</Chip>}
            {ranking ? <Chip icon="visibility_off">{ranking.total}명{ranking.hiddenExcluded ? ` · 순위 제외 ${ranking.hiddenExcluded}명은 명단 미표시` : ''}</Chip> : null}</div></div>
        <div className="table-wrap">
          <table className="table">
            <caption className="sr">최종 순위 표</caption>
            <thead><tr><th scope="col" className="num" style={{ textAlign: 'left' }}>순위</th><th scope="col">닉네임</th><th scope="col" className="num">누적 점수(추정)</th><th scope="col" className="num">확정 끼니</th><th scope="col">반영률</th></tr></thead>
            <tbody>
              {(ranking?.rows ?? []).map((r) => (
                <tr key={r.rank + r.nickname}>
                  <td className="num" style={{ textAlign: 'left', fontSize: 16 }}>{r.rank}{r.rank <= 3 ? <Ms name="workspace_premium" cls="xs" /> : null}</td>
                  <td><Avatar name={r.nickname} /> {r.nickname}</td>
                  <td className="num" style={{ fontSize: 16 }}>약 {fmt.k1(r.score)}</td>
                  <td className="num">{r.confirmedMeals} / {r.mealsTotal}</td>
                  <td><Fill4 n={r.fill} /> <span className="cap">{Math.round(r.confirmedMeals / Math.max(1, r.mealsTotal) * 100)}%</span></td>
                </tr>
              ))}
              {ranking && ranking.rows.length === 0 ? <tr><td colSpan={5} className="muted">아직 순위가 없어요</td></tr> : null}
              {ranking && ranking.total > ranking.rows.length ? <tr className="dim"><td colSpan={5}><span className="cap">… {ranking.total}명 중 상위 {ranking.rows.length}명 표시 · 전체는 CSV &quot;최종 순위&quot;</span></td></tr> : null}
            </tbody>
          </table>
        </div>
      </div>

      <div className="grid two">
        <div className="card" id="noticeCard">
          <div className="card-head"><p className="title"><Ms name="campaign" cls="sm" />공지 작성</p>{sent != null ? <Chip kind="good" icon="check_circle">발송 완료 · {sent}명</Chip> : <Chip icon="group">발송 대상 전원 {ch.joined}명</Chip>}</div>
          <div className="field"><label htmlFor="nTitle">제목 <span className={`counter ${title.length > TITLE_MAX ? 'over' : ''}`}>{title.length} / {TITLE_MAX}</span></label><div className="input"><input id="nTitle" maxLength={TITLE_MAX} value={title} disabled={noticeLocked} onChange={(e) => { setTitle(e.target.value); setSent(null); }} /></div></div>
          <div className="field"><label htmlFor="nBody">본문 <span className={`counter ${body.length > BODY_MAX ? 'over' : ''}`}>{body.length} / {BODY_MAX}</span></label><textarea className="ta" id="nBody" maxLength={BODY_MAX} rows={4} value={body} disabled={noticeLocked} onChange={(e) => { setBody(e.target.value); setSent(null); }} /></div>
          {preview ? <div className="push" id="noticePreview" aria-live="polite"><div className="app brandmark" aria-hidden="true" /><div style={{ flex: 1, minWidth: 0 }}><div className="t"><span>{title}</span><small>N-03 · P5 배너 · P12 공지 목록 보관</small></div><div className="b">{body}</div></div></div> : null}
          <div className="btn-row">
            <button className="btn secondary" disabled={noticeLocked || !title.trim() || !body.trim()} onClick={() => setPreview(true)}><Ms name="preview" />미리보기</button>
            <button className="btn" disabled={!preview || sent != null || noticeLocked} onClick={send}><Ms name="send" />보내기</button>
            <span className="cap">미리보기 필수 · 전원 {ch.joined}명 · 공지·판정 알림은 참가자가 끌 수 없어요</span>
          </div>
        </div>

        <div className="stack">
          <div className="card">
            <div className="card-head"><p className="title"><Ms name="download" cls="sm" />CSV 4종</p><Chip kind="review" icon="visibility_off">건강 신호 미포함</Chip></div>
            <div className="grid csv">
              {(Object.keys(CSV_META) as CsvType[]).map((k) => {
                const g = csv[k];
                return (
                  <div className="card outline" style={{ gap: 8 }} key={k}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}><Ms name={CSV_META[k].icon} /><b>{CSV_LABEL[k]}</b></div>
                    {g ? <><a className="link" href={g.url} download={g.filename}><Ms name="download_done" />다운로드 · {fmt.int(g.rowCount)}행</a><span className="cap">{g.filename} · 생성 {g.at}</span></>
                      : <><button className="btn sm quiet" disabled={ch.status === 'draft'} onClick={() => makeCsv(k)}><Ms name="build" />생성</button><span className="cap">{CSV_META[k].hint}</span></>}
                  </div>
                );
              })}
            </div>
            <p className="cap">건강 알림 · 운영자 메모 · 기록 모드 사유 · 사진은 어떤 CSV에도 들어가지 않아요.</p>
          </div>

          <div className="card" id="destroyCard">
            <div className="card-head"><p className="title"><Ms name="delete_forever" cls="sm" />사진 원본 파기</p>
              {purged ? <Chip kind="good" icon="check_circle">{fmt.int(photos ?? 0)}장 파기 완료 {mdTime(ch.photosPurgedAt!)}</Chip> : <Chip icon="schedule">이의 기간 종료 후 활성{until ? ` · ~${mdDate(until)}` : ''}</Chip>}</div>
            <label className="checkrow"><input type="checkbox" checked={purged || destroyChk} disabled={!archived || purged} onChange={(e) => setDestroyChk(e.target.checked)} />
              <span>사진 원본 파기(해시·확정값만 보존)<span className="d">되돌릴 수 없어요 · {fmt.int(photos ?? 0)}장 · 비공개 버킷</span></span></label>
            <div className="btn-row"><button className="btn critical" disabled={!archived || purged || !destroyChk} onClick={() => setDestroyModal(true)}><Ms name="delete_forever" />파기 실행</button>
              <span className="cap">{purged ? '파기 완료 · 열람 전용' : archived ? '체크 후 파기 실행을 눌러 주세요' : published ? `이의 기간이 끝나는 ${until ? mdDate(until) : ''} 이후 체크할 수 있어요` : '결과 확정 → 7일 이의 기간 → 종료(Archived) 후 활성'}</span></div>
          </div>
        </div>
      </div>

      {confirmModal ? (
        <Modal id="mFinal" onClose={() => setConfirmModal(false)} title={<><Ms name="verified" />최종 확정할까요?</>}
          acts={<><button className="btn quiet" onClick={() => setConfirmModal(false)}>돌아가기</button><button className="btn" disabled={!finalChk || busy} onClick={publish}><Ms name="verified" />최종 확정</button></>}>
          <p className="body">미결 0건 · 최종 확정하면 결과가 발표되고 7일 이의 기간이 시작돼요.</p>
          <Banner kind="warn" icon="lock"><b>최종 확정 후에는 정정만 가능해요</b> · 순위 스냅샷이 저장되고 전원에게 발표돼요</Banner>
          <label className="checkrow"><input type="checkbox" checked={finalChk} onChange={(e) => setFinalChk(e.target.checked)} /><span>미결 0건과 순위 표를 확인했어요</span></label>
        </Modal>
      ) : null}
      {destroyModal ? (
        <Modal id="mPurge" onClose={() => setDestroyModal(false)} title={<><Ms name="delete_forever" />사진 원본을 파기할까요?</>}
          acts={<><button className="btn quiet" onClick={() => setDestroyModal(false)}>돌아가기</button><button className="btn critical" disabled={busy} onClick={purge}><Ms name="delete_forever" />파기 실행</button></>}>
          <p className="body">되돌릴 수 없어요. 사진 {fmt.int(photos ?? 0)}장의 원본이 삭제되고 해시와 확정값만 남아요.</p>
        </Modal>
      ) : null}
    </>
  );
}

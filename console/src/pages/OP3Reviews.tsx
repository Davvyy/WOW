import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { Avatar, Banner, Chip, ErrorBox, Loading, Ms, PageHead } from '../components/ui';
import { useChallenge } from '../components/Shell';
import { useConsole, useLoad } from '../context';
import type { ReasonTemplate, ReviewItem, Slot, Verdict, VerdictImpact } from '../data/types';
import { fmt, mdTime } from '../lib/format';
import { hoursLeft, slaLevel, slaText } from '../lib/sla';
import { composeNotification, REASON, REASON_KEYS, VERDICT, VERDICT_KEYS } from '../lib/verdictCopy';

const SLOT_LABEL: Record<Slot, string> = { breakfast: '아침', lunch: '점심', dinner: '저녁', snack: '간식' };
const V_ICON: Record<Verdict, string> = { approve: 'check_circle', warn: 'warning', void: 'history', exclude: 'visibility_off' };

function SlaChip({ r, now }: { r: ReviewItem; now: string }) {
  if (r.status === 'decided') return <Chip kind="good" icon="check_circle">판정 확정</Chip>;
  const h = hoursLeft(r.slaDueAt, now);
  const lv = slaLevel(h);
  return <Chip kind={lv === 'critical' ? 'critical' : lv === 'warn' ? 'warn' : 'neutral'} icon={lv === 'critical' ? 'alarm' : 'timer'}>{slaText(h)}</Chip>;
}
function StateChip({ r }: { r: ReviewItem }) {
  if (r.status === 'decided') return <Chip kind="good" icon="gavel">확정{r.verdict ? ` · ${VERDICT[r.verdict].label}` : ''}</Chip>;
  if (r.status === 'appealed') return <Chip kind="review" icon="mark_chat_read">소명 도착</Chip>;
  return <Chip icon="hourglass_top">검토 중 · 소명 대기</Chip>;
}

function Evidence({ r, now }: { r: ReviewItem; now: string }) {
  const ev = r.evidence;
  if (r.type === 'steps_spike' && ev.steps7) {
    const max = Math.max(1, ...ev.steps7.map((d) => d.steps));
    const base = ev.stepsBaseline ?? 0;
    const H = 84;
    const last = ev.steps7[ev.steps7.length - 1];
    return (
      <>
        <div className="card">
          <div className="card-head"><p className="title">걸음 7일 추이</p>{ev.stepsSource ? <Chip icon="watch">{ev.stepsSource}</Chip> : null}</div>
          <div className="bars baseline" role="img" aria-label={`걸음 7일: ${ev.steps7.map((d) => `${d.label} ${fmt.int(d.steps)}`).join(', ')} · 기준선 중앙값 ${fmt.int(base)}`}>
            {base ? <div className="line" style={{ bottom: `${(base / max * H + 22).toFixed(0)}px` }} aria-hidden="true"><span>기준선 {fmt.int(base)}</span></div> : null}
            {ev.steps7.map((d, i) => (
              <div key={d.label} className={`bar ${d.steps === max ? 'hi' : i < 3 ? 'base' : ''}`}><span className="v">{fmt.int(d.steps)}</span><i style={{ height: `${(d.steps / max * H).toFixed(0)}px` }} /><span className="d">{d.label}</span></div>
            ))}
          </div>
          {base && last ? <p className="cap">{r.dateLabel} {fmt.int(last.steps)}보 = 기준선 ×{(last.steps / base).toFixed(1)} → 플래그 조건(25,000 초과 또는 중앙값 ×2.5) · 첫 3일이 기준선</p> : null}
          <div className="kv"><span className="k">세션 기록</span><span className="v">{ev.sessionNote ?? '없음 · 걸음만 동기화'}</span></div>
          <div className="kv"><span className="k">출처</span><span className="v">{ev.stepsSource ?? '—'} · 수동 입력 없음</span></div>
        </div>
        <Appeal r={r} now={now} />
      </>
    );
  }
  if (r.type === 'dup_photo' || r.type === 'downward_edit') {
    return (
      <>
        {ev.photoPair ? (
          <div className="card">
            <div className="card-head"><p className="title">사진 중복 쌍</p><Chip kind="critical" icon="fingerprint">SHA-256 일치</Chip></div>
            <div className="photos">
              <figure className="photo" style={{ margin: 0 }} role="img" aria-label={`식사 사진 ${ev.photoPair.labelA}`}><span className="hash">{ev.photoPair.hash}</span><span className="tag">{ev.photoPair.labelA}</span></figure>
              <figure className="photo" style={{ margin: 0 }} role="img" aria-label={`식사 사진 ${ev.photoPair.labelB}`}><span className="hash">{ev.photoPair.hash}</span><span className="tag">{ev.photoPair.labelB}</span></figure>
            </div>
            <p className="cap">서명 URL 10분 · 열람은 감사 로그에 남아요 · 사진은 본인·운영자만 볼 수 있어요</p>
          </div>
        ) : null}
        {ev.ai ? <AiVs r={r} /> : null}
        <Appeal r={r} now={now} />
      </>
    );
  }
  return (
    <>
      <div className="card">
        <div className="card-head"><p className="title">신고 내용</p><Chip icon="visibility_off">신고자는 표시되지 않아요</Chip></div>
        <div className="quote">{r.reportText ?? '신고 내용이 없어요'}<p className="cap">접수 {r.reportAt ?? '—'} · 유형 기타 · 신고 1건</p></div>
      </div>
      {ev.photo ? (
        <div className="card"><p className="title">{r.dateLabel} {r.slot ? SLOT_LABEL[r.slot] : ''} 사진</p>
          <div className="photos">
            <figure className="photo" style={{ margin: 0, background: 'linear-gradient(135deg,#c96f3a,#8a3f1e)' }} role="img" aria-label={`식사 사진 ${r.dateLabel} ${r.slot ? SLOT_LABEL[r.slot] : ''}`}><span className="hash">{ev.photo.hash}</span><span className="tag">{ev.photo.label}</span></figure>
            <div className="box" style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 4 }}><span className="cap">AI 초안</span><span className="num" style={{ fontSize: 18, fontWeight: 700 }}>없음</span><span className="cap">국외 AI 미동의 → 검색으로 확정</span></div>
          </div>
        </div>
      ) : null}
      {ev.ai ? <AiVs r={r} /> : null}
    </>
  );
}

function AiVs({ r }: { r: ReviewItem }) {
  const ai = r.evidence.ai!;
  return (
    <div className="card"><p className="title">{ai.aiKcal != null ? `AI 초안 vs 확정 · ${r.dateLabel} ${r.slot ? SLOT_LABEL[r.slot] : ''}` : '확정값'}</p>
      <div className="ai-vs">
        <div className="box"><span className="k">{ai.aiKcal != null ? 'AI 초안' : '본인 확정(검색)'}</span><span className="v">{ai.aiKcal != null ? <>약 {fmt.int(ai.aiKcal)} <small>kcal</small></> : ai.confirmedKcal != null ? <>약 {fmt.int(ai.confirmedKcal)} <small>kcal</small></> : '—'}</span></div>
        <Ms name="arrow_forward" />
        <div className="box"><span className="k">{ai.aiKcal != null ? '본인 확정' : '무효 시 대체값'}</span><span className="v">{ai.aiKcal != null ? (ai.confirmedKcal != null ? <>약 {fmt.int(ai.confirmedKcal)} <small>kcal</small></> : '—') : ai.substituteKcal != null ? <>약 {fmt.int(ai.substituteKcal)} <small>kcal</small></> : '—'}</span></div>
      </div>
      {ai.title ? <p className="cap">{ai.title}{ai.aiKcal != null && ai.confirmedKcal != null ? ` · 하향 폭 ${Math.round((1 - ai.confirmedKcal / ai.aiKcal) * 100)}% (하향 수정 기준 50% 이상)` : ''}</p> : null}
    </div>
  );
}

function Appeal({ r, now }: { r: ReviewItem; now: string }) {
  return (
    <div className="card">
      <div className="card-head"><p className="title">소명</p>
        {r.appealText ? <Chip kind="review" icon="mark_chat_read">도착 {r.appealAt}</Chip> : <Chip icon="hourglass_top">소명 대기 · 남은 {Math.max(0, hoursLeft(r.slaDueAt, now))}h</Chip>}</div>
      {r.appealText ? <div className="quote">{r.appealText}<p className="cap">소명 1회 · 72h · 첨부 1장</p></div>
        : <div className="quote muted">아직 소명이 없어요. 기간이 지나면 기록으로만 확인해요.</div>}
    </div>
  );
}

function VerdictForm({ r, now }: { r: ReviewItem; now: string }) {
  const { api, toast } = useConsole();
  const decided = r.status === 'decided';
  const [verdict, setVerdict] = useState<Verdict | null>(null);
  const [tpl, setTpl] = useState<ReasonTemplate | ''>('');
  const [impact, setImpact] = useState<VerdictImpact | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<Error | null>(null);
  const [saved, setSaved] = useState<{ impact: VerdictImpact; verdict: Verdict; tpl: ReasonTemplate | null } | null>(null);

  useEffect(() => {
    setVerdict(null); setImpact(null); setErr(null); setSaved(null);
    setTpl(r.reasonTemplate ?? (r.type in REASON ? (r.type as ReasonTemplate) : ''));
  }, [r.id, r.reasonTemplate, r.type]);

  // 판정 선택 즉시 dry_run — 저장하지 않고 점수 영향만 계산한다.
  useEffect(() => {
    if (!verdict || decided) return;
    let on = true;
    setBusy(true); setErr(null);
    api.verdict(r.id, verdict, tpl || null, true).then(
      (i) => { if (on) { setImpact(i); setBusy(false); } },
      (e: Error) => { if (on) { setErr(e); setImpact(null); setBusy(false); } },
    );
    return () => { on = false; };
  }, [api, r.id, verdict, decided]); // eslint-disable-line react-hooks/exhaustive-deps

  const expired = hoursLeft(r.slaDueAt, now) < 0;
  const shownVerdict = decided ? r.verdict : verdict;
  const shownImpact = decided ? saved?.impact ?? null : impact;
  const shownTpl = decided ? r.reasonTemplate : (tpl || null);
  const msg = composeNotification({ reason: shownTpl, verdict: shownVerdict, impact: shownImpact, expired });
  const canConfirm = !decided && !!verdict && !!impact && !!tpl && !busy;

  async function confirm() {
    if (!verdict || !tpl || !impact) return;
    setBusy(true);
    try {
      const final = await api.verdict(r.id, verdict, tpl, false);
      setSaved({ impact: final, verdict, tpl });
      toast('판정을 저장했어요 · N-06 발송 · 감사 로그 기록', 'gavel');
    } catch (e) { toast((e as Error).message, 'error'); }
    setBusy(false);
  }

  const desc: Record<Verdict, string> = { approve: '점수 변동 없음', warn: `경고 ${r.warningCount}/3 → ${Math.min(3, r.warningCount + 1)}/3`, void: '대체 처리로 재계산', exclude: '경고 3회 → 순위 제외' };
  const dr = shownImpact && !decided ? shownImpact : null;
  const excludeToo = !!dr && (verdict === 'exclude' || (verdict === 'warn' && dr.warning_count >= 3));

  return (
    <div className="card" id="verdictForm">
      {decided ? <Banner kind="good" icon="check_circle"><b>판정을 저장했어요</b> · N-06 발송 · 감사 로그 기록<br /><span className="cap">{r.verdict ? VERDICT[r.verdict].label : ''} · {r.reasonTemplate ?? '-'} · {r.decidedAt ?? ''} · {r.decidedBy ?? ''}</span></Banner> : null}
      <p className="title">판정</p>
      <fieldset className="radios" style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
        <legend className="sr">판정</legend>
        {VERDICT_KEYS.map((k) => (
          <label className="radio" key={k}>
            <input type="radio" name="verdict" value={k} checked={(decided ? r.verdict : verdict) === k} disabled={decided} onChange={() => setVerdict(k)} />
            <span><span className="t"><Ms name={V_ICON[k]} cls="sm" />{VERDICT[k].label}</span><span className="d">{desc[k]}</span></span>
          </label>
        ))}
      </fieldset>
      <div className="field"><label htmlFor="tplSel">사유 템플릿 (reason_template)</label>
        <div className="input"><select id="tplSel" value={decided ? r.reasonTemplate ?? '' : tpl} disabled={decided} onChange={(e) => setTpl(e.target.value as ReasonTemplate | '')}>
          <option value="">선택해 주세요</option>
          {REASON_KEYS.map((k) => <option key={k} value={k}>{REASON[k]} ({k})</option>)}
        </select></div></div>

      <div className={`dry ${dr ? 'live' : ''}`} id="dryRun" aria-live="polite" aria-atomic="true">
        {!dr && !err ? <div className="row"><Ms name="preview" /> {busy ? '점수 영향을 계산하고 있어요' : decided ? '확정된 판정이에요' : '판정을 선택하면 점수 영향을 바로 미리 볼 수 있어요 (dry_run)'}</div> : null}
        {err ? <div className="row" role="alert" style={{ color: 'var(--critical)' }}><Ms name="error" /> {err.message}</div> : null}
        {dr && verdict ? (
          <>
            <div className="kv"><span className="cap">점수 영향 미리보기 · dry_run</span>{verdict === 'void' && dr.is_final ? <Chip kind="warn" icon="history">정정으로 기록돼요 · is_final 이후</Chip> : null}</div>
            <div className="big"><Ms name={V_ICON[verdict]} />
              {verdict === 'void' ? `S ${fmt.k1(dr.s_before)} → ${fmt.k1(dr.s_after)}` : verdict === 'exclude' ? '순위 제외 · 점수 변동 없음' : '점수 변동 없음'}
              {verdict === 'void' ? <small>{r.dateLabel} · {fmt.signed1(dr.s_after - dr.s_before)}점</small> : null}</div>
            <div className="row">
              {verdict === 'approve' ? <><span>경고 {r.warningCount}/3 유지</span><span>{r.status === 'appealed' ? '소명 확인 완료' : '기록으로 확인'}</span></> : null}
              {verdict === 'warn' ? <span>경고 {r.warningCount}/3 → {dr.warning_count}/3</span> : null}
              {verdict === 'exclude' ? <><span>경고 {r.warningCount}/3 → 3/3</span><span>리더보드 명단에서 빠져요 · 본인 점수·기록은 유지</span></> : null}
              {verdict === 'void' ? (<>
                {dr.is_final === false ? <span>{r.dateLabel}은 잠정 · 내일 09:00 확정 시 누적 반영</span> : <>
                  <span>누적 <b>{fmt.k1(dr.cumulative_before)}</b> → <b>{fmt.k1(dr.cumulative_after)}</b> ({fmt.signed1(dr.cumulative_after - dr.cumulative_before)})</span>
                  {dr.rank_before != null ? <span>순위 <b>{dr.rank_before}</b> → <b>{dr.rank_after}</b></span> : null}</>}
                {dr.detail ? <span>{dr.detail}</span> : null}
              </>) : null}
            </div>
            {excludeToo ? <Banner kind="review" icon="policy">이 판정으로 경고 3회 → 순위 제외가 함께 적용돼요</Banner> : null}
          </>
        ) : null}
      </div>

      <div className="push" id="pushPreview" aria-live="polite">
        <div className="app">C</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="t"><span>당사자에게만 보내요 · N-06</span><small>{r.nickname}</small></div>
          <div className="b">{msg ? `“${msg.text}”` : <span className="muted">판정과 사유 템플릿을 선택하면 알림 문구가 완성돼요 · 사유 문장 + 판정 문장 + 점수 영향 문장</span>}</div>
        </div>
      </div>
      <div className="btn-row">
        <button className="btn lg" id="confirmBtn" disabled={!canConfirm} onClick={confirm}><Ms name="gavel" />판정 확정</button>
        <span className="cap">{decided ? '확정된 판정은 정정으로만 바꿀 수 있어요' : '미리보기 확인 후 활성 · 당사자에게만 N-06 · 감사 로그'}</span>
      </div>
    </div>
  );
}

export function OP3Reviews() {
  const ch = useChallenge();
  const { api, ops } = useConsole();
  const nav = useNavigate();
  const [sp, setSp] = useSearchParams();
  const { data: list, error, reload } = useLoad(() => api.listReviews(ch.id), [ch.id]);
  const { data: audit } = useLoad(() => api.auditLog(ch.id), [ch.id]);
  const { data: doneCount } = useLoad(() => api.completedReviewCount(ch.id), [ch.id]);

  const sorted = useMemo(() => [...(list ?? [])].sort((a, b) => (a.status === 'decided' ? 1 : 0) - (b.status === 'decided' ? 1 : 0) || Date.parse(a.slaDueAt) - Date.parse(b.slaDueAt)), [list]);
  const open = sorted.filter((r) => r.status !== 'decided');
  const selId = sp.get('review') ?? open[0]?.id ?? sorted[0]?.id;
  const sel = sorted.find((r) => r.id === selId);
  const soon = open.filter((r) => { const h = hoursLeft(r.slaDueAt, ops.nowIso); return h >= 0 && h < 24; }).length;
  const over = open.filter((r) => hoursLeft(r.slaDueAt, ops.nowIso) < 0).length;
  const pick = (id: string) => { const n = new URLSearchParams(sp); n.set('review', id); setSp(n, { replace: true }); };

  if (error && !list) return <><PageHead id="OP3" title="검토 큐 · 판정" /><ErrorBox error={error} retry={reload} /></>;
  if (!list) return <><PageHead id="OP3" title="검토 큐 · 판정" /><Loading /></>;

  return (
    <>
      <PageHead id="OP3" title="검토 큐 · 판정" lead="플래그·신고·소명을 한 큐에서 증거와 함께 72h 안에 판정 · 문구는 판정 템플릿만" />
      <div className="grid kpi">
        <div className="card"><span className="k"><Ms name="gavel" cls="xs" />미결</span><span className="v" style={{ color: open.length ? 'var(--fg)' : 'var(--good)' }}>{open.length}<small>건</small></span>
          <span className="s">플래그 {open.filter((r) => r.type !== 'report').length} · 신고 {open.filter((r) => r.type === 'report').length} · 소명 도착 {open.filter((r) => r.status === 'appealed').length}</span></div>
        <div className="card"><span className="k"><Ms name="timer" cls="xs" />24h 이내</span><span className="v" style={{ color: soon ? 'var(--warn)' : 'var(--fg)' }}>{soon}<small>건</small></span><span className="s">SLA 72h · 임박은 텍스트로도 표시</span></div>
        <div className="card"><span className="k"><Ms name="alarm" cls="xs" />초과</span><span className="v" style={{ color: over ? 'var(--critical)' : 'var(--fg)' }}>{over}<small>건</small></span><span className="s">초과 시 &quot;설명 기간이 지나 기록으로만 확인했어요&quot;</span></div>
        <div className="card"><span className="k"><Ms name="task_alt" cls="xs" />완료</span><span className="v">{doneCount ?? 0}<small>건</small></span><span className="s">점검 기간 이후 누적</span></div>
      </div>

      {open.length === 0 ? (
        <div className="card"><div className="empty"><Ms name="task_alt" /><p className="title">미결 0건 · 최종 확정이 가능해요</p>
          <p className="body">모든 플래그·신고·소명을 처리했어요. OP4에서 최종 순위를 확정하면 결과가 발표되고 7일 이의 기간이 시작돼요.</p>
          <div className="btn-row"><button className="btn" onClick={() => nav(`/c/${ch.id}/results`)}><Ms name="emoji_events" />결과 확정으로 이동</button></div></div></div>
      ) : null}

      {sorted.length ? (
        <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
          <div className="table-wrap" style={{ padding: '4px 18px 8px' }}>
            <table className="table" id="queueTable">
              <caption className="sr">검토 큐 — SLA 잔여 오름차순</caption>
              <thead><tr><th scope="col">유형</th><th scope="col">대상</th><th scope="col">날짜</th><th scope="col">SLA 잔여</th><th scope="col">상태</th><th scope="col">ID</th><th scope="col"><span className="sr">열기</span></th></tr></thead>
              <tbody>
                {sorted.map((q) => (
                  <tr key={q.id} aria-selected={q.id === selId}>
                    <td><b>{q.label}</b></td>
                    <td><button className="rowbtn" onClick={() => pick(q.id)}><Avatar name={q.nickname} />{q.nickname}</button></td>
                    <td>{q.dateLabel}{q.slot ? ` ${SLOT_LABEL[q.slot]}` : ''}</td>
                    <td><SlaChip r={q} now={ops.nowIso} /></td>
                    <td><StateChip r={q} /></td>
                    <td className="num" style={{ fontWeight: 500, color: 'var(--fg-2)' }}>{q.shortId}</td>
                    <td><button className={`btn sm ${q.id === selId ? 'secondary' : 'quiet'}`} onClick={() => pick(q.id)} aria-label={`${q.shortId} 상세 보기`}>{q.id === selId ? '보고 있어요' : '열기'}</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ) : null}

      {sel ? (
        <>
          <div className="card-head" style={{ marginTop: 4 }}>
            <h2 className="h2"><Ms name="rule" />{sel.shortId} · {sel.label} · {sel.nickname} · {sel.dateLabel}{sel.slot ? ` ${SLOT_LABEL[sel.slot]}` : ''}</h2>
            <div className="chips"><SlaChip r={sel} now={ops.nowIso} /><StateChip r={sel} /><Chip kind={sel.warningCount >= 2 ? 'warn' : 'neutral'}>경고 {sel.warningCount}/3</Chip></div>
          </div>
          {sel.status !== 'decided' && hoursLeft(sel.slaDueAt, ops.nowIso) < 0 ? <Banner kind="critical" icon="alarm" role="alert"><b>SLA +{Math.abs(hoursLeft(sel.slaDueAt, ops.nowIso))}h 초과</b> · 소명 기간이 지났어요. 알림 문구에 &quot;설명 기간이 지나 기록으로만 확인했어요&quot;가 덧붙여져요.</Banner>
            : sel.status !== 'decided' && hoursLeft(sel.slaDueAt, ops.nowIso) < 24 ? <Banner kind="warn" icon="timer" role="status"><b>SLA 임박 · 남은 {hoursLeft(sel.slaDueAt, ops.nowIso)}h</b> · 72시간 안에 판정해 주세요.{sel.appealText ? ' 소명이 도착했어요.' : ''}</Banner> : null}
          <div className="grid two">
            <div className="stack" id="evidence"><Evidence r={sel} now={ops.nowIso} /></div>
            <VerdictForm key={sel.id} r={sel} now={ops.nowIso} />
          </div>
        </>
      ) : null}

      <div className="card">
        <div className="card-head"><p className="title"><Ms name="history" cls="sm" />감사 로그</p><Chip>append-only · 종료+90일 보존</Chip></div>
        <div className="log">{(audit ?? []).map((a, i) => <span key={i} style={{ display: 'contents' }}><span className="num">{a.at}</span><b>{a.by}</b><span>{a.text}</span></span>)}</div>
        {!(audit ?? []).length ? <p className="cap">기록이 없어요</p> : null}
      </div>
      <p className="cap">{mdTime(ops.nowIso)} 기준</p>
    </>
  );
}

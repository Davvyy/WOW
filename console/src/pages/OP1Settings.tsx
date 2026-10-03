import { useEffect, useMemo, useState } from 'react';
import { Banner, Chip, ErrorBox, Loading, Modal, Ms, PageHead } from '../components/ui';
import { useChallenge } from '../components/Shell';
import { useConsole, useLoad } from '../context';
import type { ChallengeRules, ChallengeStatus, SimResult } from '../data/types';
import { challengeBasicsError } from '../lib/challengeForm';
import { daysBetween, fmt, mdDate } from '../lib/format';
import { FLOW, isLocked, manualTransitions, STATUS } from '../lib/lifecycle';
import { parseMd, splitBold } from '../lib/markdown';
import { SAMPLES } from '../lib/samples';

const INVITE_BASE = (import.meta.env.VITE_INVITE_BASE as string | undefined) ?? 'https://challory.app/j/';
const MD_MAX = 2000;
const DEFAULT_MD = '## 운영자 추가 규칙\n- 회식 날(10.17)은 저녁 자동 확정 대신 대체값 적용을 요청할 수 있어요(운영자에게 메시지).\n- 상품은 상위 3명 + 반영률 100% 달성자 추첨 2명.';

function constCards(r: ChallengeRules) {
  return [
    { k: 'T 목표 순적자', v: fmt.int(r.t), s: 'kcal/일 → 100점 · 최대 150점' },
    { k: '활동 상한 C', v: fmt.int(r.c), s: 'kcal/일 (= 2T)' },
    { k: '섭취 하한 F', v: `max(${fmt.int(r.fMin)}, ${r.fRatio}×BMR)`, s: '운영자 조정 미결 · v1 기본값', long: true },
    { k: '대체값 M', v: `max(${fmt.int(r.mMin)}, ${r.mRatio}×BMR)`, s: '미기록 끼니 · 운영자 조정 미결', long: true },
    { k: '간식 임계', v: fmt.int(r.snackKcal), s: 'kcal 미만은 간식(슬롯 미충족)' },
    { k: '걸음 상한', v: fmt.int(r.stepsCap), s: '보/일 · 세션 창 밖 걸음' },
    { k: '층수 상한', v: fmt.int(r.floorsCap), s: '층/일 · 17.5초/층' },
    { k: '건너뜀', v: `${r.skipPerDay}/일 · ${r.skipPerWeek}/주`, s: '운영자 조정 미결 · v1 기본값' },
    { k: '점검 기간', v: `${r.checkDays}일`, s: '누적 미반영 · 플래그 기준선' },
  ];
}

function MdView({ md }: { md: string }) {
  const blocks = parseMd(md);
  if (!blocks.length) return <p className="cap">아직 추가 규칙이 없어요</p>;
  const inline = (t: string) => splitBold(t).map((p, i) => (p.bold ? <b key={i}>{p.text}</b> : <span key={i}>{p.text}</span>));
  return (
    <>
      {blocks.map((b, i) => b.kind === 'h' ? <h3 key={i}>{inline(b.text)}</h3>
        : b.kind === 'ul' ? <ul key={i}>{b.items.map((it, j) => <li key={j}>{inline(it)}</li>)}</ul>
        : <p key={i}>{inline(b.text)}</p>)}
    </>
  );
}

/** 참가자가 보는 규칙 화면(P11) 미리보기 — 상수는 서버가 돌려준 규칙·샘플 계산에서 읽는다. */
function P11Preview({ md, rules, mP, name, operator }: { md: string; rules: ChallengeRules; mP: number; name: string; operator: string }) {
  const M = fmt.int(mP);
  const cards: [string, string, string, string][] = [
    ['①', '먹은 걸 찍어요', `세 끼를 찍고 확정하면 끝. 안 찍은 끼니는 약 ${M} kcal로, 간식은 찍은 만큼 더해져요.`, `대체값 ${M} · 간식 ${rules.snackKcal} 미만`],
    ['②', '움직여요', `걸음·달리기·계단 자동 기록만 인정. 하루 활동 최대 약 ${fmt.int(rules.c)} kcal.`, `활동 상한 ${fmt.int(rules.c)} · 걸음 ${fmt.int(rules.stepsCap)}`],
    ['③', '점수는 이렇게', `(기초대사 + 활동) − 섭취 = 순적자. ${rules.t} kcal면 100점, 최대 150점.`, `T ${rules.t} · 최대 150점`],
    ['④', '공정하게', '폰이든 워치든 같은 공식. 이상 기록은 조용히 확인하고 설명 기회를 드려요.', '소명 1회 · 72시간'],
  ];
  return (
    <section className="pframe" aria-label="참가자 규칙 미리보기">
      <div className="statusbar" aria-hidden="true"><span>21:10</span><span className="icons"><span className="ms">signal_cellular_alt</span><span className="ms">wifi</span><span className="ms">battery_5_bar</span></span></div>
      <div className="appbar"><span>규칙</span><span className="meta">{name}</span></div>
      <div className="pscroll">
        {cards.map(([n, t, b, c]) => (
          <div className="rule" key={n}><div className="head"><span className="no">{n}</span><span className="t">{t}</span></div><span className="b">{b}</span><span className="c">{c}</span></div>
        ))}
        <div className="card">
          <p className="title">상수 <span className="cap">챌린지 시작 후 잠금</span></p>
          <div className="chips">
            {[`T ${rules.t}`, `활동 상한 ${fmt.int(rules.c)}`, `섭취 하한 max(${fmt.int(rules.fMin)}, ${rules.fRatio}×BMR)`, `대체값 max(${fmt.int(rules.mMin)}, ${rules.mRatio}×BMR)`, `간식 ${rules.snackKcal}`, `걸음 ${fmt.int(rules.stepsCap)}`, `층수 ${rules.floorsCap}`, `건너뜀 ${rules.skipPerDay}/일 · ${rules.skipPerWeek}/주`].map((t) => <Chip key={t}>{t}</Chip>)}
          </div>
        </div>
        <div className="card outline md"><MdView md={md} /><p className="cap">운영자 {operator} · 게시 즉시 반영</p></div>
        <p className="disclaimer">모든 수치는 추정이에요 · 의료 조언이 아니에요</p>
      </div>
    </section>
  );
}

function SimTable({ results }: { results: (SimResult | null)[] }) {
  return (
    <div className="table-wrap">
      <table className="table" id="simTable">
        <caption className="sr">샘플 3명 시뮬레이션 — 서버 계산 결과</caption>
        <thead><tr><th scope="col">샘플</th><th scope="col" className="num">BMR</th><th scope="col" className="num">활동 A (kcal)</th><th scope="col" className="num">섭취 I (kcal)</th><th scope="col" className="num">순적자 D (kcal)</th><th scope="col" className="num">점수 S</th><th scope="col">비고</th></tr></thead>
        <tbody>
          {SAMPLES.map((s, i) => {
            const r = results[i];
            if (!r) return <tr key={s.key}><td><b>{s.label}</b><span className="sub">{s.sub}</span></td><td colSpan={6} className="muted">계산 중이에요</td></tr>;
            const notes: { t: string; warn?: boolean }[] = [];
            if (r.intake.substitute_slots.length) notes.push({ t: `대체값 ${r.intake.substitute_slots.length}끼` });
            if (r.floor_applied) notes.push({ t: '하한 적용' });
            if (r.activity.a_capped) notes.push({ t: '활동 상한' });
            if (r.s_d === 0 && r.d_d < 0) notes.push({ t: '순적자 음수 → 0점', warn: true });
            if (r.intake.main_meal_count === 0) notes.push({ t: '확정 끼니 0 → 0점', warn: true });
            return (
              <tr key={s.key}>
                <td><b>{s.label}</b><span className="sub">{s.sub}</span></td>
                <td className="num">{fmt.int(r.bmr)}</td>
                <td className="num">약 {fmt.k1(r.activity.a_d)}</td>
                <td className="num">약 {fmt.k1(r.intake.i_d)}</td>
                <td className="num">약 {fmt.int(r.d_d)}</td>
                <td className="num" style={{ fontSize: 18, color: 'var(--brand)' }}>약 {fmt.k1(r.s_d)}</td>
                <td>{notes.length ? notes.map((n) => <span key={n.t}><Chip kind={n.warn ? 'warn' : 'neutral'}>{n.t}</Chip>{' '}</span>) : <Chip kind="good" icon="check">세 끼 확정</Chip>}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function OP1Settings() {
  const ch = useChallenge();
  const { api, ops, toast } = useConsole();
  const locked = isLocked(ch.status);
  const cancelled = ch.status === 'cancelled';
  const readOnly = locked || cancelled;
  const { data: rules, error: rulesErr, reload } = useLoad(() => api.getRules(ch.id), [ch.id, ch.status]);

  const [form, setForm] = useState({ name: ch.name, startDate: ch.startDate, endDate: ch.endDate, capacity: String(ch.capacity) });
  useEffect(() => { setForm({ name: ch.name, startDate: ch.startDate, endDate: ch.endDate, capacity: String(ch.capacity) }); }, [ch.name, ch.startDate, ch.endDate, ch.capacity]);
  const [md, setMd] = useState(ch.rulesMd);
  useEffect(() => { setMd(ch.rulesMd); }, [ch.id, ch.rulesMd]);
  const [kakao, setKakao] = useState(false);
  const [modal, setModal] = useState<ChallengeStatus | null>(null);
  const [formErr, setFormErr] = useState<string | null>(null);

  // 샘플 시뮬레이션 — 서버 RPC(모의 데이터는 TS 포트). 규칙이 바뀌면 다시 계산한다.
  const [sims, setSims] = useState<(SimResult | null)[]>([null, null, null]);
  const [simErr, setSimErr] = useState<Error | null>(null);
  const rulesKey = rules ? JSON.stringify(rules) : '';
  useEffect(() => {
    if (!rules) return;
    let on = true;
    Promise.all(SAMPLES.map((s) => api.simulate({ ...s.input, challenge_id: ch.id }))).then(
      (r) => { if (on) { setSims(r); setSimErr(null); } },
      (e: Error) => { if (on) setSimErr(e); },
    );
    return () => { on = false; };
  }, [api, ch.id, rulesKey, rules]);
  const mP = sims[0]?.m_p ?? 742.5;

  const days = useMemo(() => daysBetween(form.startDate, form.endDate) + 1, [form.startDate, form.endDate]);
  const link = `${INVITE_BASE}${ch.inviteCode}`;
  const draft = ch.status === 'draft';
  const trans = manualTransitions(ch.status, ch.joined);

  async function saveBasic() {
    const cap = Number(form.capacity);
    const err = challengeBasicsError({ name: form.name, startDate: form.startDate, endDate: form.endDate, capacity: cap }, { joined: ch.joined });
    if (err) { setFormErr(err); return; }
    setFormErr(null);
    try {
      await api.updateChallenge(ch.id, { name: form.name.trim(), startDate: form.startDate, endDate: form.endDate, capacity: cap });
      toast('기본 정보를 저장했어요 · 감사 로그 기록');
    } catch (e) { toast((e as Error).message, 'error'); }
  }
  async function saveMd() {
    try { await api.saveRulesMd(ch.id, md); toast('규칙을 게시했어요 · P11에 바로 반영 · 감사 로그 기록'); }
    catch (e) { toast((e as Error).message, 'error'); }
  }
  async function copy(text: string, msg: string) {
    try { await navigator.clipboard.writeText(text); toast(msg); } catch { toast(`${msg} (클립보드 권한이 없어 직접 복사해 주세요)`, 'content_copy'); }
  }
  async function doTransition(to: ChallengeStatus) {
    try {
      await api.transition(ch.id, to);
      setModal(null);
      toast(to === 'recruiting' ? '모집을 시작했어요 · 초대코드 활성화 · 감사 로그 기록' : to === 'cancelled' ? '챌린지를 취소했어요 · 참가자 공지(N-03) · 감사 로그 기록' : '초안으로 되돌렸어요 · 초대코드 비활성', 'campaign');
    } catch (e) { setModal(null); toast((e as Error).message, 'error'); }
  }

  const lockTxt = locked ? <span className="lock"><Ms name="lock" />🔒 잠금</span> : null;
  const ro = readOnly ? 'ro' : '';
  const kakaoText = `[${ch.name}] 함께 걸어요\n${mdDate(ch.startDate)}~${mdDate(ch.endDate)} · ${days}일 · 정원 ${ch.capacity}명\n세 끼 사진 + 걸음만 있으면 돼요. 폰이든 워치든 같은 공식이에요.\n코드 ${ch.inviteCode} 또는 링크로 참가: ${link}`;

  return (
    <>
      <PageHead id="OP1" title="챌린지 설정 · 규칙 · 초대코드" lead={readOnly ? (cancelled ? '취소된 챌린지예요 · 읽기 전용' : '시작 후 잠금 · 규칙 Markdown만 편집할 수 있어요') : '기간·정원·상수 → 규칙 Markdown → 샘플 시뮬레이션 → 초대코드 → 상태 전환'} />
      <div className="grid form-preview">
        <div className="stack">
          <div className="card" id="basicInfo">
            <div className="card-head">
              <p className="title"><Ms name="tune" cls="sm" />기본 정보</p>
              {readOnly ? <span className="lock"><Ms name="lock" />시작 후 잠금 · 읽기 전용</span> : <Chip>기간 7~30일 · 정원 30~100명</Chip>}
            </div>
            {locked ? <Banner kind="neutral" icon="lock">시작(점검 기간 진입) 후에는 기간·정원·상수가 바뀌지 않아요 🔒 <span className="cap">변경 요청은 운영 로그에 남겨요</span></Banner> : null}
            <div className="field"><label htmlFor="f-name">챌린지명 {lockTxt}</label><div className={`input ${ro}`}><input id="f-name" value={form.name} readOnly={readOnly} aria-readonly={readOnly} onChange={(e) => setForm({ ...form, name: e.target.value })} /></div></div>
            <div className="grid fields3">
              <div className="field"><label htmlFor="f-start">시작일 {lockTxt}</label><div className={`input ${ro}`}><input id="f-start" type="date" value={form.startDate} readOnly={readOnly} aria-readonly={readOnly} onChange={(e) => setForm({ ...form, startDate: e.target.value })} /></div></div>
              <div className="field"><label htmlFor="f-end">종료일 {lockTxt}</label><div className={`input ${ro}`}><input id="f-end" type="date" value={form.endDate} readOnly={readOnly} aria-readonly={readOnly} onChange={(e) => setForm({ ...form, endDate: e.target.value })} /></div></div>
              <div className="field"><label htmlFor="f-cap">정원 {lockTxt}</label><div className={`input ${ro}`}><input id="f-cap" className="num" inputMode="numeric" value={form.capacity} readOnly={readOnly} aria-readonly={readOnly} onChange={(e) => setForm({ ...form, capacity: e.target.value.replace(/\D/g, '') })} /><span className="unit">명{ch.joined ? ` · 참가 ${ch.joined}` : ''}</span></div></div>
            </div>
            <p className="cap">{days}일 · 점검 기간 {rules?.checkDays ?? 3}일(누적 미반영) · 확정 배치 매일 09:00</p>
            {formErr ? <p className="cap" role="alert" style={{ color: 'var(--critical)' }}>{formErr}</p> : null}
            {!readOnly ? <div className="btn-row" style={{ justifyContent: 'flex-end' }}><button className="btn sm secondary" onClick={saveBasic}><Ms name="save" />기본 정보 저장</button></div> : null}
          </div>

          <div className="card" id="constCard">
            <div className="card-head"><p className="title"><Ms name="functions" cls="sm" />상수</p><span className="lock"><Ms name="lock" />🔒 v1 조정 불가 · 시작 후 잠금</span></div>
            {rulesErr && !rules ? <ErrorBox error={rulesErr} retry={reload} /> : null}
            {rules ? (
              <div className="grid const">
                {constCards(rules).map((c) => (
                  <div className="card outline" style={{ gap: 2, padding: '10px 12px' }} aria-readonly="true" key={c.k}>
                    <span className="cap">{c.k}</span><span className="num" style={{ fontWeight: 700, fontSize: c.long ? 15 : 18 }}>{c.v}</span><span className="cap">{c.s}</span>
                  </div>
                ))}
              </div>
            ) : <Loading />}
            <div className="inline-note"><Ms name="info" /><span>T·C·상한은 v1 조정 불가, 대체값·섭취 하한·건너뜀은 운영자 조정이 미결이라 기본값으로 잠겨 있어요. 아래 샘플 시뮬레이션은 이 상수로 계산돼요.</span></div>
          </div>

          <div className="card" id="mdCard">
            <div className="card-head"><p className="title"><Ms name="article" cls="sm" />규칙 Markdown</p>{locked ? <Chip kind="brand" icon="edit">시작 후에도 편집 가능 · 게시 즉시 P11 반영</Chip> : <Chip>P11 &quot;운영자 추가 규칙&quot; 카드로 보여요</Chip>}</div>
            <textarea className="ta mono" aria-label="규칙 Markdown" rows={7} value={md} disabled={cancelled} onChange={(e) => setMd(e.target.value.slice(0, MD_MAX))} />
            <div className="kv"><span className="counter">{md.length.toLocaleString('ko-KR')} / 2,000</span>
              <div className="btn-row"><button className="btn sm quiet" disabled={cancelled} onClick={() => setMd(DEFAULT_MD)}>기본 문구로</button><button className="btn sm secondary" disabled={cancelled} onClick={saveMd}><Ms name="publish" />게시</button></div>
            </div>
          </div>
        </div>

        <div className="stack">
          <div className="card-head"><p className="title"><Ms name="smartphone" cls="sm" />P11 미리보기</p></div>
          <p className="cap" style={{ marginTop: -10 }}>참가자가 보는 규칙 화면과 같아요 · 390px · Markdown 입력 즉시 갱신</p>
          {rules ? <P11Preview md={md} rules={rules} mP={mP} name={ch.name} operator={ops.operatorName} /> : <Loading />}
        </div>
      </div>

      <div className="card" id="simCard">
        <div className="card-head"><p className="title"><Ms name="calculate" cls="sm" />샘플 3명 시뮬레이션</p>
          <div className="chips"><Chip kind="brand" icon="verified">골든 3건 · 28.8 / 72.1 / 0.0</Chip><Chip>{api.kind === 'mock' ? '모의 데이터 · TS 포트로 계산' : '서버 RPC score_simulate_from_inputs'}</Chip></div></div>
        {simErr ? <ErrorBox error={simErr} /> : <SimTable results={sims} />}
        <p className="disclaimer">모든 kcal·점수는 추정이에요 · 상수가 잠겨 있어 표는 항상 같은 값이에요</p>
      </div>

      <div className="card" id="inviteCard">
        <div className="card-head"><p className="title"><Ms name="key" cls="sm" />초대코드</p>
          {draft ? <Chip icon="schedule">모집을 시작하면 활성화돼요</Chip> : cancelled ? <Chip kind="critical" icon="cancel">취소됨 · 비활성</Chip> : <Chip kind="good" icon="group">참가 {ch.joined}/{ch.capacity}명 · 활성</Chip>}</div>
        <div style={{ display: 'flex', gap: 20, alignItems: 'center', flexWrap: 'wrap' }}>
          <div className={`codes ${draft || cancelled ? 'inactive' : ''}`} role="img" aria-label={`초대코드 ${ch.inviteCode}`}>{[...ch.inviteCode].map((c, i) => <span key={i}>{c}</span>)}</div>
          <div className="stack" style={{ gap: 8, flex: 1, minWidth: 240 }}>
            <p className="cap">초대 링크 <b className="num" style={{ color: 'var(--fg)' }}>{link}</b> · 카카오톡 공유 시 챌린지 요약 카드(P1)가 함께 보여요</p>
            <div className="btn-row">
              <button className="btn sm secondary" disabled={draft || cancelled} onClick={() => copy(link, '초대 링크를 복사했어요')}><Ms name="link" />초대 링크 복사</button>
              <button className="btn sm quiet" aria-expanded={kakao} onClick={() => setKakao(!kakao)}><Ms name="chat" />카카오톡 공유 문구</button>
            </div>
          </div>
        </div>
        {kakao ? (<>
          <textarea className="ta" aria-label="카카오톡 공유 문구" rows={4} readOnly value={kakaoText} />
          <div className="btn-row"><button className="btn sm quiet" onClick={() => copy(kakaoText, '공유 문구를 복사했어요')}><Ms name="content_copy" />문구 복사</button></div>
        </>) : null}
      </div>

      <div className="transbar" id="transBar" aria-label="상태 전환">
        <div className="grow">
          <div className="flow">
            {FLOW.map((s, i) => (
              <span key={s} style={{ display: 'contents' }}>
                {i > 0 ? <Ms name="chevron_right" /> : null}
                <span className={s === ch.status ? 'cur' : ''}>{s === ch.status ? <Ms name={STATUS[s].icon} /> : null}{STATUS[s].label}</span>
              </span>
            ))}
            {cancelled ? <span className="cur"><Ms name="cancel" />취소</span> : null}
          </div>
          <p className="cap">
            {ch.status === 'draft' ? '허용 전환: 초안 → 모집 중. 취소(참가자에게 공지)는 초안·모집 중에만 가능해요.'
              : ch.status === 'recruiting' ? `모집 중 · 시작일 ${mdDate(ch.startDate)} 00:00에 점검 기간으로 자동 전환되고 프로필·상수가 잠겨요.`
              : cancelled ? '취소된 챌린지는 바꿀 수 없어요.' : '진행 중에는 수동 전환이 없어요 · 배치가 자동으로 전환해요.'}
          </p>
        </div>
        <div className="btn-row">
          {trans.map((t) => <button key={t.to} className={t.danger ? 'btn critical ghost' : t.to === 'recruiting' ? 'btn' : 'btn quiet'} onClick={() => setModal(t.to)}><Ms name={STATUS[t.to].icon} />{t.label}</button>)}
          {!trans.length && !cancelled ? <span className="cap">다음 전환은 자동이에요</span> : null}
        </div>
      </div>

      {modal ? (
        <Modal id="mTrans" onClose={() => setModal(null)}
          title={<><Ms name={STATUS[modal].icon} />{modal === 'recruiting' ? '모집을 시작할까요?' : modal === 'cancelled' ? '챌린지를 취소할까요?' : '초안으로 되돌릴까요?'}</>}
          acts={<><button className="btn quiet" onClick={() => setModal(null)}>돌아가기</button><button className={modal === 'cancelled' ? 'btn critical' : 'btn'} onClick={() => doTransition(modal)}><Ms name={STATUS[modal].icon} />{modal === 'recruiting' ? '모집 시작' : modal === 'cancelled' ? '취소하기' : '초안으로'}</button></>}>
          {modal === 'recruiting' ? (<>
            <p className="body">모집을 시작하면 초대코드 <b className="num" style={{ letterSpacing: '.06em' }}>{ch.inviteCode}</b>가 활성화돼요. 기간·정원·상수는 시작일({mdDate(ch.startDate)}) 00:00에 잠겨요.</p>
            <ul className="cap" style={{ margin: 0, paddingLeft: 18 }}><li>초대 링크 {link}</li><li>참가자 0명이면 초안으로 되돌릴 수 있어요</li><li>감사 로그에 기록돼요</li></ul>
          </>) : modal === 'cancelled' ? (
            <p className="body">취소하면 참가자 {ch.joined}명에게 공지(N-03)가 가고 사진 원본은 바로 파기돼요. 되돌릴 수 없어요.</p>
          ) : <p className="body">참가자가 0명일 때만 초안으로 돌아갈 수 있고, 초대코드는 다시 비활성이 돼요.</p>}
        </Modal>
      ) : null}
    </>
  );
}


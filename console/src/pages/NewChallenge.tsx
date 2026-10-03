import { useState } from 'react';
import { useNavigate } from 'react-router';
import { Chip, Ms, PageHead } from '../components/ui';
import { useConsole } from '../context';
import { challengeBasicsError, newChallengeDefaults } from '../lib/challengeForm';
import { daysBetween, mdDate } from '../lib/format';

/** 새 챌린지 만들기(OP0): 초안으로 만들고 OP1 설정으로 이어 간다. 규칙 게시·모집 시작(초대코드 발급)은 OP1 에서. */
export function NewChallenge() {
  const { api, ops, toast } = useConsole();
  const nav = useNavigate();
  const [form, setForm] = useState(() => {
    const d = newChallengeDefaults(ops.today);
    return { ...d, capacity: String(d.capacity) };
  });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const days = form.startDate && form.endDate ? daysBetween(form.startDate, form.endDate) + 1 : 0;

  async function create() {
    const input = { ...form, capacity: Number(form.capacity) };
    const e = challengeBasicsError(input, { today: ops.today });
    if (e) { setErr(e); return; }
    setErr(null);
    setBusy(true);
    try {
      const c = await api.createChallenge(input);
      toast('새 챌린지를 초안으로 만들었어요 · 감사 로그 기록');
      nav(`/c/${c.id}/settings`);
    } catch (x) {
      setErr((x as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="content" style={{ maxWidth: 720 }}>
      <PageHead id="OP0" title="새 챌린지 만들기" lead="초안으로 만들어요 · 규칙 게시와 모집 시작(초대코드 발급)은 다음 화면(OP1)에서 해요" />
      <div className="card">
        <div className="card-head">
          <p className="title"><Ms name="add_circle" cls="sm" />기본 정보</p>
          <Chip>기간 7~30일 · 정원 30~100명</Chip>
        </div>
        <div className="field"><label htmlFor="n-name">챌린지명</label><div className="input"><input id="n-name" value={form.name} placeholder="예: 봄 걷기 챌린지" onChange={(e) => setForm({ ...form, name: e.target.value })} /></div></div>
        <div className="grid fields3">
          <div className="field"><label htmlFor="n-start">시작일</label><div className="input"><input id="n-start" type="date" min={ops.today} value={form.startDate} onChange={(e) => setForm({ ...form, startDate: e.target.value })} /></div></div>
          <div className="field"><label htmlFor="n-end">종료일</label><div className="input"><input id="n-end" type="date" min={form.startDate} value={form.endDate} onChange={(e) => setForm({ ...form, endDate: e.target.value })} /></div></div>
          <div className="field"><label htmlFor="n-cap">정원</label><div className="input"><input id="n-cap" className="num" inputMode="numeric" value={form.capacity} onChange={(e) => setForm({ ...form, capacity: e.target.value })} /></div></div>
        </div>
        <p className="cap">{days > 0 ? `${mdDate(form.startDate)}~${mdDate(form.endDate)} · ${days}일` : '기간을 정해 주세요'} · 규칙 상수는 기본값으로 시작해요(시작 후 잠금)</p>
        {err ? <p className="cap" role="alert" style={{ color: 'var(--critical)' }}>{err}</p> : null}
        <div className="btn-row" style={{ justifyContent: 'flex-end' }}>
          <button className="btn sm quiet" onClick={() => nav('/')}>취소</button>
          <button className="btn sm" onClick={create} disabled={busy}><Ms name="add" />만들기</button>
        </div>
      </div>
    </main>
  );
}

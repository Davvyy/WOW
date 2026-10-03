import { describe, expect, it } from 'vitest';
import { newChallengeDefaults } from '../../lib/challengeForm';
import { composeNotification } from '../../lib/verdictCopy';
import { createMockApi } from './provider';

describe('mock provider', () => {
  it('지수 10.12 저녁 사진 중복 무효 dry_run: 41.2→12.7, 누적 341.1→312.6, 순위 4→4', async () => {
    const api = createMockApi('running');
    const rvs = await api.listReviews('ch-autumn');
    const rv = rvs.find((r) => r.shortId === 'R-0415')!;
    const impact = await api.verdict(rv.id, 'void', 'dup_photo', true);
    expect(impact.s_before).toBe(41.2);
    expect(impact.s_after).toBe(12.7);
    expect(impact.cumulative_before).toBe(341.1);
    expect(impact.cumulative_after).toBe(312.6);
    expect(impact.rank_before).toBe(4);
    expect(impact.rank_after).toBe(4);
    expect(Math.round(impact.m_p!)).toBe(743);
    expect(composeNotification({ reason: 'dup_photo', verdict: 'void', impact })?.text)
      .toBe('같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5');
    // dry_run은 저장하지 않는다
    expect(await api.openReviewCount('ch-autumn')).toBe(3);
  });

  it('판정 확정 후 미결이 줄고, 미결이 있으면 최종 확정이 막힌다', async () => {
    const api = createMockApi('closing');
    await expect(api.transition('ch-autumn', 'published')).rejects.toThrow('미결 3건');
    for (const r of await api.listReviews('ch-autumn')) await api.verdict(r.id, 'approve', r.reasonTemplate, false);
    expect(await api.openReviewCount('ch-autumn')).toBe(0);
    await api.transition('ch-autumn', 'published');
    expect((await api.getChallenge('ch-autumn')).status).toBe('published');
  });
  it('새 챌린지: 초안으로 목록에 들어가고 규칙은 잠금 전, 잘못된 입력은 거절', async () => {
    const api = createMockApi('running');
    const { today } = await api.ops();
    const c = await api.createChallenge({ ...newChallengeDefaults(today), name: '  봄 걷기 챌린지  ' });
    expect(c).toMatchObject({ name: '봄 걷기 챌린지', status: 'draft', inviteCode: '', joined: 0 });
    expect((await api.listChallenges()).map((x) => x.challenge.id)).toContain(c.id);
    expect((await api.getChallenge(c.id)).name).toBe('봄 걷기 챌린지');
    expect((await api.getRules(c.id)).lockedAt).toBeNull();
    await expect(api.createChallenge({ ...newChallengeDefaults(today), name: 'x', capacity: 10 })).rejects.toThrow('정원은 30~100명');
  });
});

-- 건너뜀 하루 2회(D84)를 운영자가 만든 챌린지에도 맞춘다.
-- 20261025000900 은 월간 챌린지의 규칙 행만 바꿔서, 그 전에 만들어 둔 운영자 챌린지는 1회로 남고 그 뒤에 만든 챌린지는 2회가 됐다.
-- 아직 끝나지 않은 챌린지(초안·모집·점검·진행)만 바꾼다. 집계 마감 뒤 챌린지와 이미 확정된 날은 그대로.

update challenge_rules r set skip_per_day = 2
  from challenges c
  where c.id = r.challenge_id and r.skip_per_day = 1 and c.status in ('draft', 'recruiting', 'checking', 'running');

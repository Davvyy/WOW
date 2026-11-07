-- 걸음 급증 검토: 기준선 ×배율 규칙은 걸음이 steps_spike_min(기본 15,000)을 넘을 때만 건다.
-- 첫 3일에 폰을 거의 안 쓰면 기준선이 아주 낮아져(179보 → 448보만 넘어도 검토) 평범한 날이 모두 걸리던 문제. 절대 상한(25,000) 규칙은 그대로.
begin;
create function pg_temp.spike_on(p_steps int) returns boolean language plpgsql as $$
declare hani uuid := tests.pid('달려라하니');
begin
  delete from reviews where participant_id = hani and type = 'steps_spike';
  perform ingest_activity_batch(hani, jsonb_build_object('client_batch_id', gen_random_uuid(), 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', p_steps))), '2026-10-13 22:00+09');
  return exists (select 1 from reviews where participant_id = hani and type = 'steps_spike');
end $$;

do $$
declare hani uuid := tests.pid('달려라하니'); ch uuid;
begin
  select challenge_id into ch from participants where id = hani;
  insert into challenge_rules (challenge_id) values (ch) on conflict (challenge_id) do nothing;
  perform tests.eq((select steps_spike_min from challenge_rules where challenge_id = ch), 15000, '규칙 기본값 15,000');
  perform tests.eq((default_rules()).steps_spike_min, 15000, '규칙 행이 없을 때 기본값도 15,000');

  update participants set baseline_median_steps = 179 where id = hani;
  perform tests.ok(not pg_temp.spike_on(4226), '기준선 179, 4,226보: 평범한 날이라 검토 안 함');
  perform tests.ok(not pg_temp.spike_on(15000), '정확히 15,000보: 넘지 않았으니 검토 안 함');
  perform tests.ok(pg_temp.spike_on(15001), '15,001보이고 기준선의 2.5배 초과: 검토');

  update participants set baseline_median_steps = 8000 where id = hani;
  perform tests.ok(not pg_temp.spike_on(16000), '기준선 8,000, 16,000보: 2.5배 안 넘음');
  perform tests.ok(pg_temp.spike_on(25001), '25,000보 초과는 기준선과 상관없이 검토');

  update participants set baseline_median_steps = null where id = hani;
  perform tests.ok(not pg_temp.spike_on(20000), '기준선 없음, 20,000보: 검토 안 함');

  update participants set baseline_median_steps = 179 where id = hani;
  update challenge_rules set steps_spike_min = 10000 where challenge_id = ch;
  perform tests.ok(pg_temp.spike_on(11000), '규칙을 10,000으로 바꾸면 그 값을 따른다');
end $$;
rollback;

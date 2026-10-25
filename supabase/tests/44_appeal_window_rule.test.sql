-- 소명 기한은 챌린지 규칙(challenge_rules.appeal_window)을 따른다. 72시간 고정이 아니다.
-- 검토 열기(raise_flag)·신고(submit_report)가 기한(sla_due_at)과 N-05 문구를 규칙값으로 정하고, 소명 입력 권한도 같은 값을 쓴다.
begin;
do $$
declare hani uuid := tests.pid('달려라하니'); ch uuid; rv uuid; r reviews; body text;
begin
  select challenge_id into ch from participants where id = hani;
  insert into challenge_rules (challenge_id) values (ch) on conflict (challenge_id) do nothing;
  update challenge_rules set appeal_window = '24 hours' where challenge_id = ch;

  -- 22~08시에는 N-05 가 08:00 으로 미뤄지므로 낮 시각으로 연다
  rv := raise_flag(hani, '2026-10-13', 'steps_spike', '{"key":"appeal-window-test"}', '2026-10-13 12:00+09');
  select * into r from reviews where id = rv;
  perform tests.eq(r.sla_due_at - r.notified_at, interval '24 hours', '검토 기한 = 규칙 24시간');
  select n.body into body from notifications n where n.type = 'N-05' and n.payload ->> 'review_id' = rv::text;
  perform tests.ok(body like '%24시간 안에%', 'N-05 문구도 24시간');

  -- 기한 없이 만들어진 오래된 검토: 만든 지 30시간이면 24시간 규칙으로는 소명 불가(72시간 고정이면 가능했음)
  update reviews set sla_due_at = null, created_at = now() - interval '30 hours' where id = rv;
end $$;

select tests.login(tests.uid('달려라하니'));
set local role authenticated;
do $$
declare hani uuid := tests.pid('달려라하니'); rv uuid;
begin
  select id into rv from reviews where participant_id = hani and target ->> 'key' = 'appeal-window-test';
  perform tests.throws(format('insert into appeals (review_id, participant_id, text) values (%L, %L, %L)', rv, hani, '등산 다녀왔어요'),
    '42501', '규칙 기한(24시간)이 지나면 소명 불가');
end $$;
reset role;
rollback;

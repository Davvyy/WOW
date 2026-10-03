-- 챌린지 종류(D46)·개인 점검 기간(D48): check_start = max(시작일, 참가일 KST), 반영은 그 3일 뒤부터
begin;
do $$
declare ji uuid := tests.pid('지수'); ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  late uuid; later uuid; s daily_scores;
begin
  perform tests.eq((select kind::text from challenges where id = ch), 'operator', '기존 챌린지는 운영자 챌린지');
  perform tests.ok((select join_open from challenges where id = ch), '참가 마감 기본값 = 열림');
  perform tests.throws(format('insert into challenges (name, start_date, end_date, capacity, operator_id) values (''x'', ''2026-12-01'', ''2026-12-14'', null, %L)', op),
    '23514', '운영자 챌린지는 정원 필수');
  insert into challenges (name, kind, status, start_date, end_date, capacity, operator_id)
  values ('12월 챌린지', 'monthly', 'running', '2026-12-01', '2026-12-31', null, op);
  perform tests.throws(format('insert into challenges (name, kind, start_date, end_date, operator_id) values (''중복'', ''monthly'', ''2026-12-01'', ''2026-12-31'', %L)', op),
    '23505', '같은 달 월간 챌린지는 1개');
  perform tests.ok((select auto_continue from profiles limit 1), '자동 이어하기 기본값 = 켬');

  perform tests.eq((select check_start from participants where id = ji), date '2026-10-06', '시작 전 참가: check_start = 시작일');
  late := tests.new_participant(ch, '늦은참가', '2026-10-10 12:00+09');
  perform tests.eq((select check_start from participants where id = late), date '2026-10-10', '중간 참가: check_start = 참가일(KST)');
  s := compute_daily_score(late, '2026-10-12', 'provisional');
  perform tests.ok(not s.is_counted, '참가 3일째(10.12)는 점검 기간');
  s := compute_daily_score(late, '2026-10-13', 'provisional');
  perform tests.ok(s.is_counted, '참가 4일째(10.13)부터 반영');
  perform tests.eq((select count(*)::int from daily_scores where participant_id = ji and is_counted), 5, '기존 참가자 반영 일수 그대로(D4~D8)');

  later := tests.new_participant(ch, '오늘참가', '2026-10-13 08:00+09');
  perform run_provisional('2026-10-13 23:00+09');
  perform tests.eq((select count(*)::int from daily_scores where participant_id = later and local_date < '2026-10-13'), 0, '참가 전 날짜는 계산하지 않음');
  perform tests.ok(exists (select 1 from daily_scores where participant_id = later and local_date = '2026-10-13'), '참가 당일부터 계산');
  perform run_finalize('2026-10-14 09:00+09');
  perform tests.ok((select is_final from daily_scores where participant_id = later and local_date = '2026-10-13'), '참가 당일 확정');
end $$;
rollback;

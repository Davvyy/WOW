-- 월간 자동 생성(D46)·자동 이어하기(D51)
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  nov uuid; dec uuid; u uuid; v uuid; w uuid; pu uuid; pv uuid; pw uuid;
begin
  delete from app_settings where key = 'monthly_operator_id';
  perform tests.ok(ensure_monthly_challenge('2026-11-01 00:00+09') is null, '운영자 설정이 없으면 만들지 않음');
  insert into app_settings (key, value) values ('monthly_operator_id', to_jsonb(op));

  nov := ensure_monthly_challenge('2026-11-01 00:00+09');
  perform tests.eq((select name || '|' || kind || '|' || status || '|' || start_date || '|' || end_date || '|' || coalesce(capacity::text, '-')
    from challenges where id = nov), '11월 챌린지|monthly|running|2026-11-01|2026-11-30|-', '11월 챌린지: 1일~말일·진행 중·정원 없음');
  perform tests.ok((select locked_at is not null from challenge_rules where challenge_id = nov), '규칙은 만들 때 잠금');
  perform tests.eq(ensure_monthly_challenge('2026-11-15 12:00+09'), nov, '같은 달 다시 불러도 1개');

  -- 11월 참가자: u 유지·자동 켬, v 유지·자동 끔, w 나감
  pu := tests.new_participant(nov, '이어하기', '2026-11-01 09:00+09'); u := (select user_id from participants where id = pu);
  pv := tests.new_participant(nov, '안이어함', '2026-11-01 09:00+09'); v := (select user_id from participants where id = pv);
  pw := tests.new_participant(nov, '나간사람', '2026-11-01 09:00+09'); w := (select user_id from participants where id = pw);
  insert into profiles (user_id, sex, birth_year, height_cm, weight_kg, bmr_age, auto_continue) values
    (u, 'F', 1990, 160, 53, 36, true), (v, 'F', 1990, 160, 55, 36, false), (w, 'F', 1990, 160, 55, 36, true);
  update participants set status = 'left', rank_eligible = false, block_rejoin = true where challenge_id = nov and user_id = w;

  dec := ensure_monthly_challenge('2026-12-01 00:00+09');
  perform tests.eq((select name from challenges where id = dec), '12월 챌린지', '12월 챌린지 생성');
  perform tests.eq((select check_start || '|' || weight_locked || '|' || bmr_locked from participants where challenge_id = dec and user_id = u),
    '2026-12-01|53.0|' || bmr_kcal('F', 53, 160, 36), '자동 이어하기: 1일부터 점검, 최신 프로필 체중으로 BMR 다시 잠금');
  perform tests.ok(not exists (select 1 from participants where challenge_id = dec and user_id = v), '자동 이어하기를 끈 사람은 참가 안 함');
  perform tests.ok(not exists (select 1 from participants where challenge_id = dec and user_id = w), '나간 사람은 이어하지 않음');

  perform run_lifecycle('2027-01-01 00:00+09');
  perform tests.ok(exists (select 1 from challenges where kind = 'monthly' and start_date = '2027-01-01' and name = '1월 챌린지'),
    '00:00 생명주기 배치가 그 달 챌린지를 만든다');
end $$;
rollback;

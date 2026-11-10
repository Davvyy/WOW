-- 월간 자동 이어가기로 넘어갈 때 닉네임이 겹치면 번호를 붙인다(D81 중복 규칙을 다음 달에도 지킨다).
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  mar uuid; apr uuid; pu uuid; pv uuid; u uuid; v uuid; n1 text; n2 text;
begin
  delete from app_settings where key = 'monthly_operator_id';
  insert into app_settings (key, value) values ('monthly_operator_id', to_jsonb(op));
  mar := ensure_monthly_challenge('2027-03-01 00:00+09');
  pu := tests.new_participant(mar, '닉하나', '2027-03-01 09:00+09'); u := (select user_id from participants where id = pu);
  pv := tests.new_participant(mar, '닉둘', '2027-03-01 09:00+09'); v := (select user_id from participants where id = pv);
  insert into profiles (user_id, sex, birth_year, height_cm, weight_kg, bmr_age, auto_continue) values
    (u, 'F', 1990, 160, 53, 36, true), (v, 'F', 1990, 160, 55, 36, true);
  -- 중복 규칙이 생기기 전부터 겹쳐 있던 닉네임을 흉내 낸다(직접 고침)
  update participants set nickname = '같은이름' where id in (pu, pv);

  apr := ensure_monthly_challenge('2027-04-01 00:00+09');
  select nickname into n1 from participants where challenge_id = apr and user_id = u;
  select nickname into n2 from participants where challenge_id = apr and user_id = v;
  perform tests.ok(n1 is not null and n2 is not null, '두 사람 모두 다음 달로 넘어감');
  perform tests.ok(lower(n1) <> lower(n2), '겹치던 닉네임이 다음 달에는 겹치지 않음');
  perform tests.ok('같은이름' in (n1, n2) and '같은이름2' in (n1, n2), '한 사람은 그대로, 다른 사람은 번호 2');

  -- 12자 닉네임은 12자 안에서 번호를 붙인다
  update participants set nickname = '열두글자짜리닉네임이에요' where challenge_id = apr and user_id in (u, v);
  perform ensure_monthly_challenge('2027-05-01 00:00+09');
  perform tests.eq((select count(distinct lower(nickname))::int from participants p join challenges c on c.id = p.challenge_id
    where c.kind = 'monthly' and c.start_date = '2027-05-01' and p.user_id in (u, v)), 2, '12자 닉네임도 겹치지 않음');
  perform tests.ok((select max(char_length(nickname)) <= 12 from participants p join challenges c on c.id = p.challenge_id
    where c.kind = 'monthly' and c.start_date = '2027-05-01' and p.user_id in (u, v)), '번호를 붙여도 12자를 넘지 않음');
end $$;
rollback;

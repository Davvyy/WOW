-- 순위표 반영률(fill)을 홈과 같은 기준으로(D69): 끼니 칸은 대체값이 들어가지 않은 칸만 반영.
-- 칸을 채운 확정 기록(규칙 snack_kcal 이상, 지금 0 → 아무 기록이나)이나 한도 안의 건너뜀. 걸음은 활동 동기화.
begin;
do $$
declare
  ch uuid := (select id from challenges where invite_code = 'K7Q2MD');
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); r jsonb; ph uuid; m uuid; snap jsonb; fill int;
begin
  delete from reviews; -- 검토 중이면 '집계 중' 행(fill 0)이라 지운다

  -- 10.14: 아침 건너뜀(한도 안), 점심 커피 11 kcal 확정, 저녁 없음, 활동 없음 → 2칸
  perform skip_meal(uid, ji, '2026-10-14', 'breakfast', '2026-10-14 08:00+09');
  r := create_photo(uid, repeat('e1', 32), 400000, 1568, 1176, '2026-10-14 12:30+09', '2026-10-14 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('e1', 32), 400000, 1568, 1176, '2026-10-14 12:30+09');
  r := create_meal(uid, ph, false, '2026-10-14 12:30+09', p_slot => 'lunch'); m := (r ->> 'meal_id')::uuid;
  update meals set status = 'draft', ai_kcal = 11 where id = m;
  perform confirm_meal(uid, m, '[{"chosen_name":"아메리카노","serving_kcal":11,"eaten":true}]', (select version from meals where id = m),
    '2026-10-14 12:35+09');
  delete from daily_activity where participant_id = ji and local_date = '2026-10-14';

  perform build_leaderboard(ch, 'today', '2026-10-14', false, '2026-10-14 23:00+09');
  select rows into snap from leaderboard_snapshots where challenge_id = ch and scope = 'today' and local_date = '2026-10-14'
    order by as_of desc limit 1;
  select (e ->> 'fill')::int into fill from jsonb_array_elements(snap) e where e ->> 'participant_id' = ji::text;
  perform tests.eq(fill, 2, '한도 안 건너뜀 + 간식 수준 확정 기록 = 2칸(활동 없음)');

  -- 건너뜀이 한도를 넘어 대체값이 들어가면 반영으로 세지 않는다
  update daily_scores set breakdown = jsonb_set(breakdown, '{intake,substitute_slots}', '["breakfast"]')
    where participant_id = ji and local_date = '2026-10-14';
  perform build_leaderboard(ch, 'today', '2026-10-14', false, '2026-10-14 23:10+09');
  select rows into snap from leaderboard_snapshots where challenge_id = ch and scope = 'today' and local_date = '2026-10-14'
    order by as_of desc limit 1;
  select (e ->> 'fill')::int into fill from jsonb_array_elements(snap) e where e ->> 'participant_id' = ji::text;
  perform tests.eq(fill, 1, '대체값이 들어간 건너뜀 칸은 반영 아님');
end $$;
rollback;

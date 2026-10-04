-- 끼니 칸에 확정 기록이 하나라도 있으면 그 값으로 칸을 채운다(D59, snack_kcal 0). 대체값은 빈 칸에만.
begin;
do $$
declare
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); r jsonb; ph uuid; m uuid; b jsonb;
begin
  perform tests.eq((select snack_kcal from challenge_rules where challenge_id = (select challenge_id from participants where id = ji)),
    0::numeric, '기존 챌린지 규칙도 0');
  r := create_photo(uid, repeat('d1', 32), 400000, 1568, 1176, '2026-10-14 19:00+09', '2026-10-14 19:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('d1', 32), 400000, 1568, 1176, '2026-10-14 19:00+09');
  r := create_meal(uid, ph, false, '2026-10-14 19:00+09', p_slot => 'dinner'); m := (r ->> 'meal_id')::uuid;
  update meals set status = 'draft', ai_kcal = 11 where id = m;
  perform confirm_meal(uid, m, '[{"chosen_name":"아메리카노","serving_kcal":11,"eaten":true}]', (select version from meals where id = m),
    '2026-10-14 19:05+09');
  perform tests.eq((select slot::text from meals where id = m), 'dinner', '저녁 칸 그대로');
  b := (select breakdown from daily_scores where participant_id = ji and local_date = '2026-10-14');
  perform tests.eq(jsonb_typeof(b -> 'intake' -> 'substitute_slots'), 'array', '대체 칸 목록 위치 확인');
  perform tests.ok(not ((b -> 'intake' -> 'substitute_slots') ? 'dinner'), '커피만 있어도 저녁 대체값 없음');
  update challenge_rules set snack_kcal = 150 where challenge_id = (select challenge_id from participants where id = ji);
  perform recompute_day(ji, '2026-10-14');
  b := (select breakdown from daily_scores where participant_id = ji and local_date = '2026-10-14');
  perform tests.ok((b -> 'intake' -> 'substitute_slots') ? 'dinner', '대조: 옛 규칙(150)이면 저녁 대체값');
end $$;
rollback;

-- 끼니 칸(아침·점심·저녁)에 확정 기록이 하나라도 있으면 그 값으로 칸을 채운 것으로 본다(D59).
-- 대체값 M_p 는 기록이 하나도 없는(또는 분석 중인) 칸에만. 간식 칸은 그대로.
-- 전에는 간식 기준(snack_kcal 150) 미만 확정 기록은 칸을 채우지 않아, 커피만 올린 저녁에 대체값이 더해졌다.
-- 규칙 값으로 바꾼다: snack_kcal = 0 이면 intake_kcal 의 "v_kcal >= snack_kcal" 이 늘 참.

alter table challenge_rules alter column snack_kcal set default 0;
update challenge_rules set snack_kcal = 0 where snack_kcal <> 0;

-- 확정 전 날짜는 새 규칙으로 다시 계산한다(확정된 날짜는 그대로)
do $$
declare d record;
begin
  for d in select participant_id, local_date from daily_scores where not is_final
  loop
    perform recompute_day(d.participant_id, d.local_date);
  end loop;
end $$;

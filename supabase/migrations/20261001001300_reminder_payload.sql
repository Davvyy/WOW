-- N-02 조건부 리마인드(21:00 KST): 앱이 알림만 보고 할 일을 고르도록 payload 에 종류·끼니를 싣는다.
--   kind=confirm : 오늘 확정 대기 끼니(captured·draft·failed)가 있음 → slot(가장 이른 끼니), pending(건수)
--   kind=sync    : 오늘 활동 동기화 0건 → 앱이 받자마자 건강 데이터를 읽어 올림
-- 문장은 03 §8 예시 그대로: "점심 사진이 확정을 기다려요" / "앱을 열면 걸음이 동기화돼요"
create or replace function enqueue_reminders(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare d date := kst_date(p_now); x record; n int := 0; v_slot meal_slot; v_cnt int; v_label text;
begin
  for x in select pt.* from participants pt join challenges c on c.id = pt.challenge_id
    where c.status in ('checking', 'running') and d between c.start_date and c.end_date and pt.status in ('active', 'record_mode', 'excluded')
  loop
    select count(*)::int, min(m.slot) into v_cnt, v_slot from meals m
      where m.participant_id = x.id and m.local_date = d and m.status in ('captured', 'draft', 'failed') and m.slot is not null;
    if v_cnt > 0 then
      v_label := case v_slot when 'breakfast' then '아침' when 'lunch' then '점심' when 'dinner' then '저녁' else '간식' end;
      perform enqueue_notification(x.user_id, x.challenge_id, 'N-02', '확정 대기',
        case when v_cnt = 1 then format('%s 사진이 확정을 기다려요', v_label)
          else format('%s 외 %s끼 사진이 확정을 기다려요', v_label, v_cnt - 1) end,
        jsonb_build_object('local_date', d, 'kind', 'confirm', 'slot', v_slot, 'pending', v_cnt), p_now);
      n := n + 1;
    elsif not exists (select 1 from daily_activity a where a.participant_id = x.id and a.local_date = d) then
      perform enqueue_notification(x.user_id, x.challenge_id, 'N-02', '동기화', '앱을 열면 걸음이 동기화돼요',
        jsonb_build_object('local_date', d, 'kind', 'sync'), p_now);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

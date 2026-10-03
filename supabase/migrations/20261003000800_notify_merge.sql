-- 알림 묶음(docs/02 D53): 기록을 챌린지끼리 공유하므로 N-02·N-01 은 사용자당 1건. payload.challenge_ids = 최근 참가 순.

-- 21:00 N-02 조건부 리마인드(문장은 03 §8 그대로). 확정 대기는 대표 끼니(record_group_id = id)만 센다.
create or replace function enqueue_reminders(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare d date := kst_date(p_now); x record; n int := 0; v_slot meal_slot; v_cnt int; v_label text;
begin
  for x in
    select pt.user_id, array_agg(pt.id) as parts, array_agg(pt.challenge_id order by pt.joined_at desc) as chs
    from participants pt join challenges c on c.id = pt.challenge_id
    where c.status in ('checking', 'running') and d between c.start_date and c.end_date
      and pt.status in ('active', 'record_mode', 'excluded') and pt.user_id is not null
    group by pt.user_id
  loop
    select count(*)::int, min(m.slot) into v_cnt, v_slot from meals m
      where m.participant_id = any (x.parts) and m.record_group_id = m.id and m.local_date = d
        and m.status in ('captured', 'draft', 'failed') and m.slot is not null;
    if v_cnt > 0 then
      v_label := case v_slot when 'breakfast' then '아침' when 'lunch' then '점심' when 'dinner' then '저녁' else '간식' end;
      perform enqueue_notification(x.user_id, x.chs[1], 'N-02', '확정 대기',
        case when v_cnt = 1 then format('%s 사진이 확정을 기다려요', v_label)
          else format('%s 외 %s끼 사진이 확정을 기다려요', v_label, v_cnt - 1) end,
        jsonb_build_object('local_date', d, 'kind', 'confirm', 'slot', v_slot, 'pending', v_cnt, 'challenge_ids', to_jsonb(x.chs)), p_now);
      n := n + 1;
    elsif not exists (select 1 from daily_activity a where a.participant_id = any (x.parts) and a.local_date = d) then
      perform enqueue_notification(x.user_id, x.chs[1], 'N-02', '동기화', '앱을 열면 걸음이 동기화돼요',
        jsonb_build_object('local_date', d, 'kind', 'sync', 'challenge_ids', to_jsonb(x.chs)), p_now);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- 09:30 N-01 어제 확정 결과: 사용자당 1건, 챌린지별 점수(순위 대기 rank 0 은 순위 생략)
create or replace function enqueue_daily_results(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare d date := kst_date(p_now) - 1; u record; x record; n int := 0; v_rank int; v_parts text[]; v_chs uuid[]; v_single text;
begin
  for u in
    select distinct pt.user_id from daily_scores ds join participants pt on pt.id = ds.participant_id
      join challenges c on c.id = pt.challenge_id
    where ds.local_date = d and ds.is_final and c.status in ('checking', 'running', 'closing') and pt.user_id is not null
  loop
    v_parts := '{}'; v_chs := '{}'; v_single := null;
    for x in
      select ds.s_d, ds.participant_id, pt.rank_eligible, pt.challenge_id as ch, c.name
      from daily_scores ds join participants pt on pt.id = ds.participant_id join challenges c on c.id = pt.challenge_id
      where pt.user_id = u.user_id and ds.local_date = d and ds.is_final and c.status in ('checking', 'running', 'closing')
      order by pt.joined_at desc
    loop
      v_rank := null;
      select (r ->> 'rank')::int into v_rank from leaderboard_snapshots s, jsonb_array_elements(s.rows) r
        where s.challenge_id = x.ch and s.scope = 'cumulative' and s.is_final and s.local_date = d
          and r ->> 'participant_id' = x.participant_id::text
        order by s.as_of desc limit 1;
      v_single := case when x.rank_eligible and v_rank > 0 then format('어제 %s점, 누적 %s위', format_k1(x.s_d), v_rank)
        else format('어제 %s점', format_k1(x.s_d)) end;
      v_parts := v_parts || case when x.rank_eligible and v_rank > 0 then format('%s %s점·%s위', x.name, format_k1(x.s_d), v_rank)
        else format('%s %s점', x.name, format_k1(x.s_d)) end;
      v_chs := v_chs || x.ch;
    end loop;
    perform enqueue_notification(u.user_id, v_chs[1], 'N-01', '어제 결과',
      case when cardinality(v_parts) = 1 then v_single else '어제 ' || array_to_string(v_parts, ' · ') end,
      jsonb_build_object('local_date', d, 'challenge_ids', to_jsonb(v_chs)), p_now);
    n := n + 1;
  end loop;
  return n;
end $$;

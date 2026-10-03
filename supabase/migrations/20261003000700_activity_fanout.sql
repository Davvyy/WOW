-- 걸음·운동 기록 공유(docs/02 D52): 동기화 배치를 참가 중인 모든 챌린지에 넣는다.
-- 대표 참가에는 받은 client_batch_id 로, 다른 참가에는 파생 id(md5(client_batch_id:participant_id))로 넣어 참가마다 멱등을 지킨다.
alter function ingest_activity_batch(uuid, jsonb, timestamptz) rename to ingest_activity_one;

create function ingest_activity_batch(p_participant uuid, p_batch jsonb, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare v_res jsonb; v_user uuid; q participants; v_bid text := p_batch ->> 'client_batch_id';
begin
  v_res := ingest_activity_one(p_participant, p_batch, p_now);
  select user_id into v_user from participants where id = p_participant;
  if v_user is null then return v_res; end if;
  for q in select * from active_participations(v_user, array['checking', 'running', 'closing']::challenge_status[]) where id <> p_participant
  loop
    begin
      perform ingest_activity_one(q.id, jsonb_set(p_batch, '{client_batch_id}', to_jsonb(md5(v_bid || ':' || q.id)::uuid::text)), p_now);
    exception when others then
      raise notice 'activity copy to % skipped: %', q.id, sqlerrm;
    end;
  end loop;
  return v_res;
end $$;
revoke execute on function ingest_activity_batch(uuid, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function ingest_activity_batch(uuid, jsonb, timestamptz) to service_role;

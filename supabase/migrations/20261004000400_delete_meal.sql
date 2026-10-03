-- 끼니 기록 삭제(docs/02 D57, Edge meal-delete). 참가자가 확정 전 날짜의 자기 대표 끼니(record_group_id = id)를 지운다.
-- 복사본(기록 공유, D52)까지 같이 지우고(meal_items 는 cascade) 영향받은 참가자·날짜를 재계산한다.
-- 그 끼니에 대한 열린 검토는 승인으로 닫아 검토 대기열에 고아가 남지 않게 하고,
-- 다른 끼니가 쓰지 않는 사진은 purged_at 을 기록하고 경로를 돌려준다(Storage 객체는 Edge 가 지운다).
-- 확정 판단·판정 판단은 그룹 전체(대표 + 복사본)에 대해 본다: 한 챌린지에서라도 확정·판정된 기록이면 지우지 않는다.
create or replace function delete_meal(p_user uuid, p_meal uuid, p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare
  m meals;
  p participants;
  v_ids uuid[];
  v_days jsonb;
  v_challenges uuid[];
  v_deleted int;
  d record;
  c uuid;
  v_path text;
begin
  select * into m from meals where id = p_meal and record_group_id = id for update;
  if not found then raise exception '기록을 찾지 못했어요' using errcode = 'PT404'; end if; -- 복사본 id 도 여기서(참가자는 대표 끼니만 본다)
  select * into p from participants where id = m.participant_id;
  if p.user_id is distinct from p_user then raise exception '내 기록만 지울 수 있어요' using errcode = 'PT403'; end if;

  perform 1 from meals where record_group_id = p_meal for update;
  if exists (select 1 from meals g left join daily_scores ds on ds.participant_id = g.participant_id and ds.local_date = g.local_date
             where g.record_group_id = p_meal and (ds.is_final or g.locked_at is not null)) then
    raise exception '확정된 날짜의 기록은 지울 수 없어요' using errcode = 'PT422';
  end if;
  select array_agg(id), jsonb_agg(distinct jsonb_build_object('participant_id', participant_id, 'local_date', local_date)),
    array_agg(distinct challenge_id)
  into v_ids, v_days, v_challenges from meals where record_group_id = p_meal;
  if exists (select 1 from meals where id = any (v_ids) and status = 'void')
     or exists (select 1 from reviews where status = 'decided' and target ->> 'meal_id' = any (select unnest(v_ids)::text)) then
    raise exception '판정된 기록은 지울 수 없어요' using errcode = 'PT422';
  end if;

  -- 열린 검토 닫기(재계산 전에: under_review 가 풀리도록)
  update reviews set status = 'decided', verdict = 'approve', decided_at = p_now, reason_template = null
  where status in ('open', 'appealed') and target ->> 'meal_id' = any (select unnest(v_ids)::text);

  delete from meals where record_group_id = p_meal;
  get diagnostics v_deleted = row_count;

  for d in select (x ->> 'participant_id')::uuid as participant_id, (x ->> 'local_date')::date as local_date
           from jsonb_array_elements(v_days) x
  loop
    perform recompute_day(d.participant_id, d.local_date, 'user_edit', null, p_user); -- 참가 전 날짜는 null(D48)
  end loop;

  foreach c in array v_challenges loop
    perform write_audit(c, p_user, 'participant', 'meal_delete', jsonb_build_object('meal_id', m.id, 'local_date', m.local_date,
      'slot', m.slot, 'copies', v_deleted - 1));
  end loop;

  -- 사진: 남은 끼니가 쓰지 않으면 바로 파기
  if m.photo_id is not null and not exists (select 1 from meals where photo_id = m.photo_id) then
    update photos set purged_at = p_now where id = m.photo_id and purged_at is null returning storage_path into v_path;
  end if;

  return jsonb_build_object('meal_id', m.id, 'deleted', v_deleted, 'local_date', m.local_date, 'slot', m.slot, 'purge_path', v_path);
end $$;

revoke execute on function delete_meal(uuid, uuid, timestamptz) from public, anon, authenticated;
grant execute on function delete_meal(uuid, uuid, timestamptz) to service_role;

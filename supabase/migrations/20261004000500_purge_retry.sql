-- 후속 수정(docs/02 D56·D57):
-- 1) 확인 중(열린·소명 중 검토)인 끼니는 지우지 않는다. 지워서 검토를 닫아 버리는 길을 막는다(검토 자동 승인 제거).
-- 2) 사진 파기 재시도: purged_at 은 Storage 삭제 전에 기록되므로, Edge 가 삭제에 실패한 경로를 unmark_photos_purged 로 되돌린다.
--    다음 purge_due_photos 가 그 사진을 다시 고른다(파기 대상 챌린지의 purged_at is null 사진은 다시 본다).

-- ---------------------------------------------------------------- 끼니 기록 삭제
-- 원본(20261004000400_delete_meal.sql)에서: 열린 검토가 있으면 PT422, 검토 자동 승인 삭제.
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
  if exists (select 1 from reviews where status in ('open', 'appealed') and target ->> 'meal_id' = any (select unnest(v_ids)::text)) then
    raise exception '확인 중인 기록은 지울 수 없어요' using errcode = 'PT422';
  end if;

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

  -- 사진: 남은 끼니가 쓰지 않으면 바로 파기(Storage 삭제가 실패하면 Edge 가 unmark_photos_purged 로 되돌린다)
  if m.photo_id is not null and not exists (select 1 from meals where photo_id = m.photo_id) then
    update photos set purged_at = p_now where id = m.photo_id and purged_at is null returning storage_path into v_path;
  end if;

  return jsonb_build_object('meal_id', m.id, 'deleted', v_deleted, 'local_date', m.local_date, 'slot', m.slot, 'purge_path', v_path);
end $$;

-- ---------------------------------------------------------------- 파기 표시 되돌리기
-- Storage 삭제에 실패한 경로의 purged_at 을 지운다. 돌려주는 값은 되돌린 사진 수.
create or replace function unmark_photos_purged(p_paths text[]) returns int
  language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update photos set purged_at = null where storage_path = any (coalesce(p_paths, '{}')) and purged_at is not null;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function unmark_photos_purged(text[]) from public, anon, authenticated;
grant execute on function unmark_photos_purged(text[]) to service_role;

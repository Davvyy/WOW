-- 끼니 삭제 규칙 조정(docs/02 D57). 원본(20261004000500_purge_retry.sql)에서:
-- - 확인 중 거절은 다른 참가자 신고(report)가 열려 있거나 소명 중일 때만.
-- - 시스템 표시(late_upload·dup_photo·downward_edit·photo_mismatch 등 report 가 아닌 meal_id 대상 검토)는 막지 않고,
--   지울 때 '더 이상 해당 없음'으로 닫는다(decided·approve·decided_at, target 유지). 닫은 검토마다 감사 로그.
-- - 판정 거절은 그룹에 void 끼니가 있거나, 판정 끝난 검토의 verdict 가 void·warn·exclude 일 때만(approve 는 막지 않음).
create or replace function delete_meal(p_user uuid, p_meal uuid, p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare
  m meals;
  p participants;
  v_ids uuid[];
  v_keys text[];
  v_days jsonb;
  v_challenges uuid[];
  v_deleted int;
  d record;
  rv record;
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
  select array_agg(id), array_agg(id::text), jsonb_agg(distinct jsonb_build_object('participant_id', participant_id, 'local_date', local_date)),
    array_agg(distinct challenge_id)
  into v_ids, v_keys, v_days, v_challenges from meals where record_group_id = p_meal;
  if exists (select 1 from meals where id = any (v_ids) and status = 'void')
     or exists (select 1 from reviews where status = 'decided' and verdict in ('void', 'warn', 'exclude')
                and target ->> 'meal_id' = any (v_keys)) then
    raise exception '판정된 기록은 지울 수 없어요' using errcode = 'PT422';
  end if;
  if exists (select 1 from reviews where type = 'report' and status in ('open', 'appealed') and target ->> 'meal_id' = any (v_keys)) then
    raise exception '확인 중인 기록은 지울 수 없어요' using errcode = 'PT422';
  end if;

  -- 시스템 표시 닫기(재계산 전에: under_review 가 풀리도록)
  for rv in
    update reviews set status = 'decided', verdict = 'approve', decided_at = p_now
    where type <> 'report' and status in ('open', 'appealed') and target ->> 'meal_id' = any (v_keys)
    returning id, challenge_id, type, target ->> 'meal_id' as meal_id
  loop
    perform write_audit(rv.challenge_id, p_user, 'participant', 'review_closed_meal_deleted',
      jsonb_build_object('review_id', rv.id, 'type', rv.type, 'meal_id', rv.meal_id, 'group_id', m.id));
  end loop;

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

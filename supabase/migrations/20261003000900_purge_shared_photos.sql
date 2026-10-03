-- 사진 파기(API #31) — 기록 공유(docs/02 D52) 반영: 이 챌린지 사진과 이 챌린지 끼니(복사본 포함)가 쓰는 사진 중
-- 아직 끝나지 않은 다른 챌린지의 끼니가 쓰지 않는 것만 파기한다. 해시·메타는 남기고 원본 경로를 돌려준다(Storage 삭제는 Edge Function).
create or replace function purge_challenge_photos(p_challenge_id uuid) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare ch challenges; v_paths text[];
begin
  perform require_operator(p_challenge_id);
  select * into ch from challenges where id = p_challenge_id for update;
  if ch.status not in ('archived', 'cancelled') then raise exception '종료(Archived) 뒤에 파기할 수 있어요' using errcode = 'PT422'; end if;
  with target as (
    select ph.id from photos ph
    where ph.purged_at is null
      and (ph.challenge_id = p_challenge_id
        or exists (select 1 from meals m where m.photo_id = ph.id and m.challenge_id = p_challenge_id))
      and not exists (select 1 from meals m join challenges c on c.id = m.challenge_id
        where m.photo_id = ph.id and m.challenge_id <> p_challenge_id and c.status not in ('archived', 'cancelled'))
  ), u as (
    update photos set purged_at = now() from target t where photos.id = t.id returning photos.storage_path
  ) select coalesce(array_agg(storage_path), '{}') into v_paths from u;
  update challenges set photos_purged_at = now() where id = p_challenge_id;
  perform write_audit(p_challenge_id, auth.uid(), 'operator', 'purge_photos', jsonb_build_object('count', cardinality(v_paths)));
  return jsonb_build_object('count', cardinality(v_paths), 'paths', to_jsonb(v_paths), 'purged_at', now());
end $$;

-- 기록 공유(D52): 복사본 끼니가 쓰는 사진은 그 챌린지 운영자도 본다(판정 근거)
drop policy photos_read on photos;
create policy photos_read on photos for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id)
    or exists (select 1 from meals m where m.photo_id = photos.id and is_challenge_operator(m.challenge_id)));

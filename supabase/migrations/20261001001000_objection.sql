-- 결과 이의(05 API #34, 03 §7 "Published → Published: 이의 접수"): 발표 후 7일 안에 당사자 1회.
-- reviews(type=objection) + appeals(이의 본문)로 OP3 큐에 합류한다. 신고·플래그와 달리 '검토 중' 표시는 하지 않는다.
create or replace function submit_objection(p_text text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare p participants; ch challenges; v_id uuid; v_text text := trim(coalesce(p_text, ''));
begin
  select x.* into p from participants x join challenges c on c.id = x.challenge_id
  where x.user_id = auth.uid() and x.status not in ('kicked', 'left') and c.status = 'published'
  order by x.joined_at desc limit 1;
  if p.id is null then raise exception '결과가 발표된 챌린지가 없어요' using errcode = 'PT422'; end if;
  select * into ch from challenges where id = p.challenge_id;
  if now() > ch.published_at + interval '7 days' then raise exception '이의 기간이 지났어요' using errcode = 'PT422'; end if;
  if char_length(v_text) not between 5 and 1000 then raise exception '내용을 5~1,000자로 적어 주세요' using errcode = 'PT422'; end if;
  if exists (select 1 from reviews where participant_id = p.id and type = 'objection') then
    raise exception '이의는 1회만 남길 수 있어요' using errcode = 'PT409';
  end if;
  insert into reviews (challenge_id, participant_id, type, local_date, status, sla_due_at, notified_at, target)
  values (p.challenge_id, p.id, 'objection', ch.end_date, 'appealed', now() + interval '72 hours', now(), '{}')
  returning id into v_id;
  insert into appeals (review_id, participant_id, text) values (v_id, p.id, v_text);
  perform write_audit(p.challenge_id, auth.uid(), 'participant', 'objection', jsonb_build_object('review_id', v_id));
  return jsonb_build_object('review_id', v_id);
end $$;
revoke execute on function submit_objection(text) from public, anon;
grant execute on function submit_objection(text) to authenticated, service_role;

-- 참가자 앱 세션(05 API #33): 내 챌린지 요약 + 규칙 상수 + 내 참가 정보(잠긴 프로필·BMR) + 최근 공지(N-03)를 한 번에.
-- 참가 인원은 참가자 RLS 로는 셀 수 없으므로 security definer 로 계산한다(본인이 참가한 챌린지만).
create or replace function my_challenge_summary() returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'today', kst_date(),
    'challenge', jsonb_build_object('id', c.id, 'name', c.name, 'status', c.status, 'start_date', c.start_date, 'end_date', c.end_date,
      'capacity', c.capacity, 'invite_code', c.invite_code, 'rules_md', c.rules_md, 'published_at', c.published_at),
    'joined', (select count(*) from participants x where x.challenge_id = c.id and x.status not in ('kicked', 'left')),
    'rules', to_jsonb(r) - 'challenge_id' - 'created_at' - 'updated_at',
    'participant', jsonb_build_object('id', p.id, 'nickname', p.nickname, 'sex', p.sex, 'birth_year', p.birth_year, 'age', p.age,
      'height_cm', p.height_cm, 'weight_locked', p.weight_locked, 'bmr_locked', p.bmr_locked, 'status', p.status,
      'rank_eligible', p.rank_eligible, 'leaderboard_visible', p.leaderboard_visible, 'grade_badge_public', p.grade_badge_public,
      'warning_count', p.warning_count, 'last_synced_at', p.last_synced_at, 'last_sync_source', p.last_sync_source),
    'notice', (select jsonb_build_object('title', n.title, 'body', n.body, 'created_at', n.created_at) from notifications n
      where n.user_id = p.user_id and n.challenge_id = c.id and n.type = 'N-03' order by n.created_at desc limit 1))
  from participants p
  join challenges c on c.id = p.challenge_id
  left join challenge_rules r on r.challenge_id = c.id
  where p.user_id = auth.uid() and p.status not in ('kicked', 'left')
  order by p.joined_at desc
  limit 1
$$;
revoke execute on function my_challenge_summary() from public, anon;
grant execute on function my_challenge_summary() to authenticated, service_role;

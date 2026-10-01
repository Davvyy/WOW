-- 참가자 쓰기: 응원(1일 1회) · 소명(1회·72h) · 결과 이의(발표 후 7일·1회)
begin;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare me uuid := tests.pid('지수'); rv uuid; r jsonb;
begin
  -- 소명: 본인 open 검토에 1회
  rv := (select id from reviews where participant_id = me and status = 'open' limit 1);
  perform tests.ok(rv is not null, '소명 대상 open 검토(R-0415)');
  insert into appeals (review_id, participant_id, text) values (rv, me, '10.10 저녁과 같은 접시를 다시 찍었어요.');
  perform tests.eq((select status::text from reviews where id = rv), 'appealed', '소명 → appealed');
  perform tests.eq((select text from appeals where review_id = rv), '10.10 저녁과 같은 접시를 다시 찍었어요.', '소명 본문 본인 조회');
  -- 이의: 아직 발표 전
  perform tests.throws('select submit_objection(''10.12 점수가 다른 것 같아요'')', 'PT422', '이의: 발표 전 불가', '%발표된 챌린지가 없어요%');
end $$;
reset role;
update challenges set status = 'published', published_at = now() - interval '1 day' where invite_code = 'K7Q2MD';
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare r jsonb;
begin
  perform tests.throws('select submit_objection(''짧음'')', 'PT422', '이의: 5자 미만 거부');
  r := submit_objection('10.12 저녁은 다른 날 사진이에요. 다시 확인 부탁드려요.');
  perform tests.ok((select type = 'objection' and status = 'appealed' from reviews where id = (r ->> 'review_id')::uuid), '이의 → OP3 큐(objection, appealed)');
  perform tests.ok(exists (select 1 from appeals where review_id = (r ->> 'review_id')::uuid), '이의 본문 저장');
  perform tests.throws('select submit_objection(''한 번 더 이의를 남겨요'')', 'PT409', '이의: 1회만');
end $$;
reset role;
do $$
declare ch uuid := (select id from challenges where invite_code = 'K7Q2MD'); snap jsonb;
begin
  update reviews set status = 'decided' where type <> 'objection'; -- 다른 검토는 끝난 상태로
  perform build_leaderboard(ch, 'cumulative', '2026-11-02', true, '2027-01-01 00:00+09'); -- 시드 스냅샷(10.13)보다 뒤
  select rows into snap from leaderboard_snapshots where challenge_id = ch order by as_of desc limit 1;
  perform tests.ok(exists (select 1 from jsonb_array_elements(snap) e where e ->> 'nickname' = '지수'), '이의는 검토 중이 아님(최종 순위에 이름 유지)');
end $$;
update challenges set published_at = now() - interval '8 days' where invite_code = 'K7Q2MD';
select tests.login(tests.uid('밤산책'));
set local role authenticated;
do $$ begin
  perform tests.throws('select submit_objection(''기간이 지난 뒤 이의'')', 'PT422', '이의: 7일 지나면 불가', '%기간이 지났어요%');
end $$;
reset role;
rollback;

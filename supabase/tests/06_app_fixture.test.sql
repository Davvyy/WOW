-- 앱(Dart) 매핑 테스트용 픽스처: 시드 DB의 지수 장부·정정 이력·리더보드 스냅샷을 PostgREST 응답과 같은 JSON 으로 만든다.
-- 10.12 저녁 무효 판정(R-0415)을 적용한 상태와 적용 전(검토 중) 스냅샷을 함께 담고, 판정은 되돌린다.
-- run.sh 가 tests.app_fixture() 결과를 app/test/fixtures/server_ledger.json 으로 저장한다.
create or replace function tests.app_fixture() returns jsonb language plpgsql as $$
declare
  ji uuid := tests.pid('지수');
  ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  before_cum jsonb; out jsonb;
begin
  before_cum := (select rows from leaderboard_snapshots where challenge_id = ch and scope = 'cumulative' order by as_of desc limit 1);
  begin
    perform apply_verdict((select id from reviews where target ->> 'code' = 'R-0415'), 'void', false, null, null, '2026-10-13 21:31+09');
    perform build_leaderboard(ch, 'today', '2026-10-13', false, '2026-10-13 22:00+09');
    perform build_leaderboard(ch, 'cumulative', '2026-10-13', false, '2026-10-13 22:00+09');
    out := jsonb_build_object(
      'participant_id', ji,
      'nickname', '지수',
      'start_date', (select start_date from challenges where id = ch),
      'daily_scores', (select jsonb_agg(jsonb_build_object('id', id, 'local_date', local_date, 'bmr', bmr, 'a_d', a_d, 'i_d', i_d, 'f_p', f_p,
          'd_d', d_d, 's_d', s_d, 'is_counted', is_counted, 'is_final', is_final, 'under_review', under_review, 'breakdown', breakdown) order by local_date)
        from daily_scores where participant_id = ji),
      'revisions', (select coalesce(jsonb_agg(jsonb_build_object('daily_score_id', daily_score_id, 'prev_s_d', prev_s_d, 'new_s_d', new_s_d,
          'reason', reason, 'review_id', review_id) order by created_at), '[]') from score_revisions where participant_id = ji),
      'reviews', (select jsonb_agg(jsonb_build_object('id', id, 'type', type)) from reviews where participant_id = ji),
      'snapshot_today', (select rows from leaderboard_snapshots where challenge_id = ch and scope = 'today' order by as_of desc limit 1),
      'snapshot_cumulative', (select rows from leaderboard_snapshots where challenge_id = ch and scope = 'cumulative' order by as_of desc limit 1),
      'snapshot_cumulative_under_review', before_cum,
      'expect', jsonb_build_object('cumulative', participant_cumulative(ji)));
    raise exception using errcode = 'P0D02', message = 'rollback';
  exception when sqlstate 'P0D02' then null;
  end;
  return out;
end $$;

do $$
declare f jsonb := tests.app_fixture();
begin
  perform tests.eq((f #>> '{expect,cumulative}')::numeric, 312.6, '픽스처: 판정 후 누적 312.6');
  perform tests.eq(jsonb_array_length(f -> 'daily_scores'), 8, '픽스처: 지수 8일');
  perform tests.eq(participant_cumulative(tests.pid('지수')), 341.1, '픽스처 생성 뒤 판정은 되돌려짐');
end $$;

-- 앱 세션 요약 RPC: 본인 챌린지·규칙 상수·잠긴 프로필·참가 인원·최근 공지
begin;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare s jsonb := my_challenge_summary();
begin
  perform tests.eq(s #>> '{challenge,name}', '가을 걷기 챌린지', '요약: 챌린지 이름');
  perform tests.eq(s #>> '{challenge,start_date}', '2026-10-06', '요약: 시작일');
  perform tests.eq((s ->> 'joined')::int, 12, '요약: 참가 인원(참가자 RLS 와 무관하게 전체)');
  perform tests.eq((s #>> '{participant,bmr_locked}')::int, 1650, '요약: 잠긴 BMR');
  perform tests.eq((s #>> '{rules,t}')::numeric, 500::numeric, '요약: 규칙 T');
  perform tests.eq(s #>> '{rules,dinner_end}', '22:00:00', '요약: 끼니 경계');
  perform tests.ok(not (s -> 'challenge' ? 'operator_id'), '요약: 운영자 id 미포함');
  perform tests.ok(s ->> 'rules_md' is null and s #>> '{challenge,rules_md}' like '%운영자 추가 규칙%', '요약: 운영자 규칙 Markdown');
end $$;
reset role;
reset role;
rollback;

begin;
do $$ begin
  perform enqueue_notification(tests.uid('지수'), (select challenge_id from participants where id = tests.pid('지수')), 'N-03',
    '최종 결과는 11.3 09:00에 확정돼요', '마지막 날 기록은 11.3 09:00에 확정돼요', '{}');
end $$;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$ begin
  perform tests.eq(my_challenge_summary() #>> '{notice,title}', '최종 결과는 11.3 09:00에 확정돼요', '요약: 최근 공지');
end $$;
reset role;
select tests.login('00000000-0000-4000-a000-0000000000ff');
set local role authenticated;
do $$ begin
  perform tests.ok(my_challenge_summary() is null, '참가하지 않은 사용자 → null');
end $$;
reset role;
rollback;

-- pg_cron 스케줄 (docs/05 §7). cron 은 UTC → KST = UTC+9.
-- pg_cron 이 없는 환경(로컬 순수 Postgres 테스트)에서는 건너뛴다. Supabase 에서는 Dashboard > Database > Extensions 에서 pg_cron 활성화.
-- notify 는 Edge Function(notify)을 pg_net 으로 호출하거나, 외부 스케줄러가 /functions/v1/notify 를 부른다(supabase/README.md).
do $do$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron not available — schedules skipped';
    return;
  end if;
  execute 'create extension if not exists pg_cron';
  -- 매시 정각 잠정 재계산 + 스냅샷
  execute $c$select cron.schedule('challory-provisional', '0 * * * *', 'select public.run_provisional()')$c$;
  -- 09:00 KST 확정 (= 00:00 UTC)
  execute $c$select cron.schedule('challory-finalize', '0 0 * * *', 'select public.run_finalize()')$c$;
  -- 09:10 KST 건강 신호
  execute $c$select cron.schedule('challory-health-check', '10 0 * * *', 'select public.run_health_check()')$c$;
  -- 09:30 KST N-01 어제 결과
  execute $c$select cron.schedule('challory-n01', '30 0 * * *', 'select public.enqueue_daily_results()')$c$;
  -- 21:00 KST N-02 조건부 리마인드
  execute $c$select cron.schedule('challory-n02', '0 12 * * *', 'select public.enqueue_reminders()')$c$;
  -- 00:00 KST 생명주기
  execute $c$select cron.schedule('challory-lifecycle', '0 15 * * *', 'select public.run_lifecycle()')$c$;
  -- 멱등 키 7일 후 삭제
  execute $c$select cron.schedule('challory-idempotency-gc', '20 18 * * *', $q$delete from public.idempotency_keys where created_at < now() - interval '7 days'$q$)$c$;
end $do$;

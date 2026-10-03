-- 감사 로그 append-only 트리거가 FK 연쇄(on delete set null)로 challenge_id·actor_id 만 null 이 되는 수정은 허용한다(docs/02 D54).
-- 감사 로그가 있는 챌린지(콘솔에서 만든 챌린지 전부)를 지울 수 없던 문제. 로그 내용은 그대로 남는다.
create or replace function audit_logs_append_only() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE'
     and (new.challenge_id is null or new.challenge_id = old.challenge_id)
     and (new.actor_id is null or new.actor_id = old.actor_id)
     and (new.challenge_id, new.actor_id) is distinct from (old.challenge_id, old.actor_id)
     and (new.id, new.actor_role, new.action, new.target, new.before, new.after, new.created_at)
       is not distinct from (old.id, old.actor_role, old.action, old.target, old.before, old.after, old.created_at) then
    return new;
  end if;
  raise exception 'audit_logs is append-only';
end $$;

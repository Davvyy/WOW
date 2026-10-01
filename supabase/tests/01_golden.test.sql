-- 점수 엔진 골든 테스트 (docs/04 §6·§9, 02 §5). 허용 오차 ±0.05.
-- 입력은 golden_cases.json 하나를 SQL·Dart가 함께 읽는다.
-- run.sh 가 golden_cases.json 을 /tmp/challory_golden_cases.json 으로 복사해 둔다.
\set cases `cat /tmp/challory_golden_cases.json`
select set_config('tests.cases', :'cases', false) \gset

create schema if not exists tests;

create or replace function tests.flatten(o jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object('bmr', o -> 'bmr', 'm_p', o -> 'm_p', 'f_p', o -> 'f_p', 'd_d', o -> 'd_d', 's_d', o -> 's_d',
    'floor_applied', o -> 'floor_applied')
    || (o -> 'activity') - 'session_mets'
    || jsonb_build_object('i_d', o #> '{intake,i_d}', 'main_meal_count', o #> '{intake,main_meal_count}',
       'snack_count', o #> '{intake,snack_count}', 'skip_over', o #> '{intake,skip_over}')
$$;

create or replace function tests.golden_dump(p_cases jsonb) returns jsonb language sql stable as $$
  select jsonb_object_agg(c ->> 'id', tests.flatten(score_simulate_from_inputs(c -> 'input')))
  from jsonb_array_elements(p_cases -> 'cases') c
$$;

do $$
declare
  c jsonb; e record; got jsonb; v jsonb; n int := 0; bad text := '';
begin
  for c in select * from jsonb_array_elements(current_setting('tests.cases')::jsonb -> 'cases')
  loop
    got := tests.flatten(score_simulate_from_inputs(c -> 'input'));
    for e in select * from jsonb_each(c -> 'expect')
    loop
      v := got -> e.key;
      if jsonb_typeof(e.value) = 'number' then
        if v is null or abs((v #>> '{}')::numeric - (e.value #>> '{}')::numeric) > 0.05 then
          bad := bad || format(E'\n  %s.%s expected %s got %s', c ->> 'id', e.key, e.value, v);
        end if;
      elsif v is distinct from e.value then
        bad := bad || format(E'\n  %s.%s expected %s got %s', c ->> 'id', e.key, e.value, v);
      end if;
      n := n + 1;
    end loop;
  end loop;
  if bad <> '' then raise exception 'golden mismatch:%', bad; end if;
  raise notice 'golden: % assertions passed', n;
end $$;

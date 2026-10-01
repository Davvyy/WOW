#!/usr/bin/env bash
# 로컬 Postgres 16 에 새 DB를 만들어 마이그레이션 → 시드 → 테스트를 순서대로 돌린다.
# 사용: PGHOST/PGUSER 등 표준 환경변수 또는 기본값(로컬 소켓, postgres 사용자).
#   supabase/tests/run.sh            # 전체
#   KEEP_DB=1 supabase/tests/run.sh  # 끝나고 DB 남김
# Supabase CLI 가 있으면 `supabase test db` 로 tests/*.test.sql(pgTAP 아님, 같은 SQL 단언)도 돌릴 수 있다.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DB="${TEST_DB:-challory_test}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")
if [ "$(id -u)" = "0" ] && [ -z "${PGUSER:-}" ]; then PSQL=(su postgres -c); fi

run() { # run <sql-file>
  if [ "${PSQL[0]}" = "su" ]; then
    su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f '$1'"
  else
    psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$1"
  fi
}
runc() { # runc <sql>
  if [ "${PSQL[0]}" = "su" ]; then
    su postgres -c "psql -X -q -At -v ON_ERROR_STOP=1 -d $DB -c \"$1\""
  else
    psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "$1"
  fi
}
admin() {
  if [ "${PSQL[0]}" = "su" ]; then su postgres -c "psql -X -q -d postgres -c \"$1\""; else psql -X -q -d postgres -c "$1"; fi
}

admin "drop database if exists $DB" >/dev/null && admin "create database $DB" >/dev/null || { echo "[FAIL] create database"; exit 1; }
chmod -R a+rX "$ROOT" 2>/dev/null

ok=1
run "$HERE/local_bootstrap.sql" || ok=0
for f in "$ROOT"/migrations/*.sql; do
  [ $ok = 1 ] || break
  run "$f" || { echo "[FAIL] migration $(basename "$f")"; ok=0; }
done
[ $ok = 1 ] && { run "$ROOT/seed.sql" || { echo "[FAIL] seed"; ok=0; }; }
cp "$HERE/golden_cases.json" /tmp/challory_golden_cases.json && chmod a+r /tmp/challory_golden_cases.json
if [ $ok = 1 ]; then
  for t in "$HERE"/*.test.sql; do
    if run "$t"; then echo "[OK] $(basename "$t")"; else echo "[FAIL] $(basename "$t")"; ok=0; fi
  done
fi
# Dart 엔진 비교용 SQL 결과 덤프
if [ $ok = 1 ]; then
  runc "select jsonb_pretty(jsonb_build_object('_doc', 'score_simulate_from_inputs 실행 결과(supabase/tests/run.sh 가 생성). app/test/engine/golden_test.dart 가 Dart 결과와 비교한다.', 'results', tests.golden_dump(pg_read_file('/tmp/challory_golden_cases.json')::jsonb)))" > "$HERE/golden_sql_results.json" \
    && echo "[OK] golden_sql_results.json" || { echo "[FAIL] golden dump"; ok=0; }
fi
[ -z "${KEEP_DB:-}" ] && admin "drop database if exists $DB" >/dev/null
if [ $ok = 1 ]; then echo "[OK] all"; exit 0; else echo "[FAIL] see above"; exit 1; fi

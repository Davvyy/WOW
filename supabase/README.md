# 챌로리 Supabase 백엔드

설계 기준: `docs/05-데이터-모델-및-아키텍처.md`(ERD·API·배치), `docs/04-칼로리-엔진-및-순위-규칙.md`(산식), `prototype/data.js`(참조 엔진).

```
supabase/
├── migrations/
│   ├── 20261001000100_schema.sql        enum·테이블·인덱스(05 §3)
│   ├── 20261001000200_engine.sql        점수 엔진: activity_kcal · intake_kcal · score_simulate · score_simulate_from_inputs
│   ├── 20261001000300_batch.sql         compute_daily_score(단일 경로) · 매시 잠정 · 09:00 확정 · 리더보드 스냅샷
│   │                                    동기화 배치(ingest_activity_batch) · 식사 확정(confirm_meal) · 건너뜀 · 판정(apply_verdict)
│   │                                    생명주기 · 건강 신호 · 알림 큐
│   ├── 20261001000400_rls.sql           RLS·권한·뷰·공개 RPC(get_invite·join_challenge·food_search·map_food_candidates)
│   ├── 20261001000500_cron.sql          pg_cron 스케줄(없으면 건너뜀)
│   └── 20261001000600_operator_rpc.sql  운영자 콘솔 RPC(전환·공지·CSV·사진 파기·감사 로그) + Storage 버킷
├── functions/                           Edge Functions(Deno)
│   ├── _shared/                         AI 어댑터(Gemini·Claude·모의) · 분석 파이프라인 · 멱등성 · 배치 검증 · 푸시 · CSV
│   ├── analyze-meal/  sync-activity/  meal-confirm/  meal-skip/  verdict/  notify/  announce/  export/  purge-photos/
│   └── deno.json                        deno task check / deno task test
├── seed/generate_seed.mjs               seed.sql 생성기(프로토타입 예시 → 원천 값만)
├── seed.sql                             생성 파일(직접 수정 금지)
└── tests/
    ├── run.sh                           로컬 Postgres 16 으로 마이그레이션 → 시드 → 테스트
    ├── golden_cases.json                골든 케이스(SQL·Dart·프로토타입 공용 입력)
    ├── golden_sql_results.json          SQL 실행 결과(앱 Dart 테스트가 필드별로 비교)
    ├── proto_check.mjs                  프로토타입 엔진으로 같은 케이스 검증
    └── 00~04_*.test.sql                 헬퍼 · 골든 · 배치/판정/동기화 · RLS · 음식 매핑
```

## 점수 엔진 — SQL 함수 하나로

화면(P5 잠정·P11 시뮬레이터·OP1 샘플)과 배치(매시 잠정·09:00 확정·판정 정정)가 모두 같은 경로를 탄다.

```
score_simulate_from_inputs(jsonb)          ← P11·OP1 RPC (05 API #16)
compute_daily_score(participant, date, mode) ← 배치·동기화·확정·판정
        └→ activity_kcal → intake_kcal → score_simulate
```

- 반올림은 세 구현(SQL·Dart·프로토타입) 공통 `r1(x) = floor(x·10 + 0.5)/10`, BMR `round10`.
- 골든: 폰만 70 kg 남 **28.8** · 워치 58 kg 여 **72.1** · 1끼 600만 확정 **0.0** · 커피 100 추가 **8.8** · 10.12 저녁 무효 **41.2 → 12.7** · 건너뜀 초과 **120.3** 외 14건(`tests/golden_cases.json`).
- 확정 배치 재생으로 만든 시드에서 지수 누적 **341.1**(판정 전) → R-0415 무효 판정 후 **312.6**.

## 로컬 테스트 (Supabase CLI·Docker 없이)

순수 Postgres 16 에 `tests/local_bootstrap.sql`(auth 스키마·역할 스텁)을 깔고 마이그레이션을 그대로 적용한다.

```bash
# Postgres 16 이 떠 있어야 함 (예: pg_ctlcluster 16 main start)
supabase/tests/run.sh                 # [OK]/[FAIL] 출력, 끝에 [OK] all
KEEP_DB=1 supabase/tests/run.sh       # 테스트 DB(challory_test)를 남겨 직접 조회
node supabase/tests/proto_check.mjs   # 프로토타입 엔진으로 같은 골든 검증
```

`run.sh` 는 마지막에 `tests/golden_sql_results.json` 을 다시 만든다. 앱의 `flutter test test/engine` 이 이 파일과 Dart 결과를 필드별(오차 1e-9)로 비교한다. 엔진을 고치면 `run.sh` → `flutter test` 순서로 돌린다.

Edge Functions:

```bash
cd supabase/functions
deno task check   # 타입체크
deno task test    # 단위 테스트(모의 어댑터, 네트워크·키 불필요)
```

## Supabase 프로젝트에 배포

```bash
supabase link --project-ref <ref>
supabase db push                      # migrations/ 적용
psql "$DATABASE_URL" -f supabase/seed.sql   # (선택) 프로토타입 예시 데이터
supabase functions deploy analyze-meal sync-activity meal-confirm meal-skip verdict notify announce export purge-photos
supabase secrets set INTERNAL_SECRET=... CRON_SECRET=... \
  AI_ENGINE=gemini VERTEX_PROJECT=... VERTEX_LOCATION=asia-northeast3 VERTEX_ACCESS_TOKEN=...   # 또는 GEMINI_API_KEY
  # 스왑: AI_ENGINE=claude ANTHROPIC_API_KEY=...
  # 푸시: FCM_PROJECT_ID=... FCM_ACCESS_TOKEN=...
```

- pg_cron: Dashboard › Database › Extensions 에서 켠 뒤 `20261001000500_cron.sql` 을 다시 실행하면 스케줄이 등록된다(KST = UTC+9: 매시 잠정, 00:00 UTC = 09:00 KST 확정, 09:10 건강 신호, 09:30 N-01, 21:00 N-02, 00:00 KST 생명주기).
- 알림 발송 워커 `notify` 는 pg_net 또는 외부 스케줄러가 1~5분마다 `x-cron-secret` 헤더로 호출한다.
- 키가 없으면 `analyze-meal` 은 모의 어댑터(프로토타입 점심 초안 6항목)를, `notify` 는 로그 발송을 쓴다.
- 음식 DB: 시드의 `food_db_cache` 30건은 **예시 값**이다. 실제 식약처 음식 표준데이터(15100070)는 CSV를 내려받아 `food_db_cache(food_code, name_kr, category, serving_g, kcal, ...)` 로 적재하고 동의어 100개를 `food_synonyms` 에 넣는다.

## 권한 모델

| 호출자 | 할 수 있는 것 |
|---|---|
| 참가자(authenticated) | 본인 행 읽기, 표시 설정·체중·응원(1일 1회)·소명(1회·72h) 쓰기, `score_simulate_from_inputs`·`food_search`·`join_challenge` |
| 운영자(challenges.operator_id) | 자기 챌린지 전체 읽기(건강 알림·메모·신고 내용·기록 모드 사유 포함), 참가자 상태·재가입 차단, 규칙(잠금 전), `apply_verdict_rpc`·`transition_challenge_rpc`·`announce_challenge`·`export_rows`·`purge_challenge_photos`·`log_operator_action` |
| service_role(Edge Function·pg_cron) | `ingest_activity_batch`·`confirm_meal`·`skip_meal`·`run_*` 배치·`claim_due_notifications` |
| 익명 | `get_invite(code)` |

PostgREST 오류: 함수가 SQLSTATE `PTnnn` 을 던지면 HTTP `nnn`(403·404·409·412·422)으로 나간다.

## 검증하지 못한 것

- Supabase CLI·Docker 이미지를 받을 수 없는 네트워크라 **실제 Supabase(Auth·Storage·PostgREST·pg_cron·pg_net)** 위에서는 돌려 보지 않았다. 로컬은 auth 스텁 + 순수 Postgres 16.
- Gemini·Claude·FCM 실호출(키 없음). 어댑터는 요청 형식을 가짜 fetch 로만 검증했다.
- 미구현 Edge Function: `photos/upload-url`(서명 PUT URL·서버 재검증), `meals`(끼니 생성·지연 업로드 규칙), `meals/manual`, `reports`, `appeals`(현재는 RLS 직접 insert), `objections`, `account` 삭제. SQL 쪽 `confirm_meal`·`skip_meal`·`join_challenge` 는 있다.

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
│   ├── 20261001000600_operator_rpc.sql  운영자 콘솔 RPC(전환·공지·CSV·사진 파기·감사 로그) + Storage 버킷
│   ├── 20261001000700_participant_writes.sql  사진 생성·재검증 · 끼니 생성(슬롯·지연 업로드·중복 해시) · 직접 입력 · 신고 · 계정 삭제
│   ├── 20261001000800~1100              식사 항목 후보 · 내 챌린지 요약 · 결과 이의 · 최근 음식
│   ├── 20261001001200_push_devices.sql  푸시 기기 등록(register_device) · 알림 한 건 즉시 집기(claim_notification)
│   └── 20261001001300_reminder_payload.sql  N-02 리마인드 payload(kind=confirm·sync, slot, pending)·끼니 이름 문장
├── functions/                           Edge Functions(Deno)
│   ├── _shared/                         AI 어댑터(Gemini·Claude·모의) · 분석 파이프라인 · 멱등성 · 배치 검증 · 푸시 · CSV
│   ├── photo-upload-url/  meals/  meal-manual/  meal-confirm/  meal-skip/  analyze-meal/  sync-activity/  reports/  account/
│   ├── verdict/  notify/  announce/  export/  purge-photos/
│   └── deno.json                        deno task check / deno task test
├── seed/generate_seed.mjs               seed.sql 생성기(프로토타입 예시 → 원천 값만)
├── seed.sql                             생성 파일(직접 수정 금지)
└── tests/
    ├── run.sh                           로컬 Postgres 16 으로 마이그레이션 → 시드 → 테스트
    ├── golden_cases.json                골든 케이스(SQL·Dart·프로토타입 공용 입력)
    ├── golden_sql_results.json          SQL 실행 결과(앱 Dart 테스트가 필드별로 비교)
    ├── proto_check.mjs                  프로토타입 엔진으로 같은 케이스 검증
    └── 00~09_*.test.sql                 헬퍼 · 골든 · 배치/판정/동기화 · RLS · 음식 매핑 · 참가자 쓰기 경로 · 앱 픽스처 · 요약 · 응원/소명/이의 · 푸시
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
supabase db query --linked -f supabase/seed.sql   # (선택) 프로토타입 예시 데이터(psql 없이 Management API 로). psql 이 있으면 psql "$DATABASE_URL" -f 도 같음
supabase functions deploy --use-api photo-upload-url meals meal-manual meal-confirm meal-skip analyze-meal sync-activity reports account \
  verdict notify announce export purge-photos   # --use-api: Docker 없이 서버에서 번들
supabase secrets set INTERNAL_SECRET=... CRON_SECRET=... \
  AI_ENGINE=gemini VERTEX_PROJECT=... VERTEX_LOCATION=asia-northeast3 VERTEX_ACCESS_TOKEN=...   # 또는 GEMINI_API_KEY
  # 스왑: AI_ENGINE=claude ANTHROPIC_API_KEY=...
  # 푸시: supabase secrets set FCM_SERVICE_ACCOUNT="$(cat <Firebase 서비스 계정 키>.json)"   (또는 Dashboard › Edge Functions › Secrets 에 JSON 전체를 붙여 넣기)
```

- `config.toml`: 함수별 `verify_jwt`·import map(`functions/deno.json`)·진입점, 로컬 Storage 버킷(`meal-photos`, JPEG 5 MiB), Auth 복귀 딥링크를 담는다. `notify` 만 `verify_jwt = false`(pg_cron·외부 스케줄러가 JWT 없이 `x-cron-secret` 으로 부름, 함수가 CRON_SECRET 으로 막음)이고 나머지는 Bearer JWT 필수. `project_id` 는 로컬 구분용 이름이라 원격 프로젝트는 `supabase link --project-ref` 로 고른다. Auth 제공자(카카오·Apple) 설정은 이 파일이 아니라 Dashboard 에서 한다(아래 "로그인(Auth) 설정").
- Windows: 위 명령은 PowerShell 이 아니라 **Git Bash** 에서 돌린다(`\` 줄 잇기·`$VAR`·`ls -d` 가 bash 문법). Supabase CLI 는 `scoop install supabase` 또는 `npx supabase@2` 로 쓰고, `--use-api` 를 붙이면 Docker Desktop 없이 배포된다. 저장소는 줄바꿈 변환 없이 받는 것이 안전하다(`git config --global core.autocrlf input`, SQL·셸 스크립트가 CRLF 로 바뀌지 않게).

- pg_cron: Dashboard › Database › Extensions 에서 켠 뒤 `20261001000500_cron.sql` 을 다시 실행하면 스케줄이 등록된다(KST = UTC+9: 매시 잠정, 00:00 UTC = 09:00 KST 확정, 09:10 건강 신호, 09:30 N-01, 21:00 N-02, 00:00 KST 생명주기).
- 알림 발송 워커 `notify` 는 pg_net 또는 외부 스케줄러가 1~5분마다 `x-cron-secret` 헤더로 호출한다. transactional 알림은 워커를 기다리지 않는다: 분석 완료(N-04)는 `analyze-meal` 이, 판정 결과(N-06)는 `verdict`(확정 호출, 재전송 제외)가 큐에 넣은 직후 `claim_notification` 으로 그 건을 집어 바로 보낸다(`_shared/supabase.ts` `sendPendingNow`, 같은 no_push·하루 4건 규칙, 실패하면 워커가 이어서 보냄). 검토 안내(N-05, scheduled)도 `reports`·`sync-activity` 가 같은 방식으로 바로 보내되, 22~08시 생성분은 예약 시각(08:00)이 아니므로 집히지 않고 워커가 08:00 에 보낸다.
- 푸시 data 는 `type`·`id`(알림) + payload(N-01: `local_date`, N-02: `local_date`·`kind`(confirm·sync)·`slot`·`pending`, N-04: `meal_id`·`slot`, N-05: `review_id`, N-06: `review_id`·`verdict`)를 문자열로 싣는다. 앱은 N-04 를 받으면 그 끼니를 다시 읽고(눌렀으면 P7), N-05·N-06 을 받으면 장부·검토·순위를 다시 읽고(눌렀으면 P10), N-01 을 받으면 확정된 장부·순위를 다시 읽는다(눌렀으면 P5).
- 키가 없으면 `analyze-meal` 은 모의 어댑터(프로토타입 점심 초안 6항목)를, `notify` 는 로그 발송을 쓴다.
- 푸시는 `FCM_SERVICE_ACCOUNT`(Firebase 콘솔 › 프로젝트 설정 › 서비스 계정 › 새 비공개 키 생성으로 받은 JSON 전체)로 보낸다. 함수가 이 키로 서명한 JWT 를 Google 토큰 엔드포인트에 보내 FCM 액세스 토큰을 받고, 만료 1분 전까지 인스턴스 안에서 재사용한다(`_shared/push.ts`). 정적 액세스 토큰은 1시간 뒤 만료되므로 쓰지 않는다. JSON 이 깨졌거나 필드가 빠지면 오류 로그를 남기고 로그 발송으로 대신한다.
- Gemini 기본 모델은 `gemini-3.5-flash-lite` 이고 `GEMINI_MODEL` 시크릿으로 바꾼다. 2.5 모델은 예전에 쓰던 사용자에게만 열려 새 키로는 404 가 난다. `analyze-meal` 은 호출 1회 8초·최대 2회라 응답이 빠른 모델이어야 한다. 무료 등급은 보낸 사진이 Google 제품 개선에 쓰이므로 실제 참가자를 받기 전 유료 등급으로 바꾼다.
- 음식 DB: 시드의 `food_db_cache` 29건은 **예시 값**(가짜 코드 `D000001` 형식)이다. 실제 데이터는 공공데이터포털 「전국통합식품영양성분정보(음식)표준데이터」(15100070)의 파일 데이터 CSV 를 받아 `node supabase/seed/load_food_db.mjs <CSV> > food_db.sql` → `npx --yes supabase@2 db query --linked -f food_db.sql` 로 넣는다. 일반 음식만(프랜차이즈·간편조리세트 제외) 이름당 1건, 1인분 값(기준량당 × 식품중량), `이름_세부` 형식 이름의 동의어(`김밥_참치` → 참치김밥)를 함께 넣고 예시 음식은 지운다(규칙은 스크립트 머리말·docs/02 D42, 테스트 `node --test supabase/seed/load_food_db_test.mjs`). 다시 돌려도 값만 갱신된다. 2026-10-01 등록 파일 기준 음식 1,927건·동의어 710개.

## 식사 사진 흐름 (05 §6)

```
앱: 촬영 → 긴 변 ≤1,568 px 리사이즈·EXIF 제거·SHA-256
 1. POST photo-upload-url {sha256, bytes, width, height, client_captured_at}  → photo_id, 서명 업로드 URL
 2. PUT  (서명 URL) 이미지
 3. POST meals {photo_id, queued}   → 객체를 서버가 다시 읽어 해시·크기·해상도 재검증(불일치 422 + photo_mismatch)
                                     → 서버 KST 슬롯 태그(04:00/10:30/15:00/22:00) · 지연 업로드 규칙 · 중복 해시 dup_photo
                                     → 국외 AI 동의자만 analyze-meal 백그라운드 호출, 즉시 201 반환
 4. analyze-meal → 초안(draft) + N-04  →  5. POST meal-confirm (If-Match: version)
사진 없이: POST meal-manual {slot, items}  (하루 3건 이상 manual_input_burst)
```

지연 업로드(queued=true, 단말 촬영 시각 기준): 30분 이내 → 서버 시각 / 단말 날짜가 이미 확정 → 끼니 미인정(사진·해시만) / 30분~12시간 → 단말 시각 + late_upload / 12시간 초과 → 서버 시각 + late_upload.

신고(`reports`)는 신고자를 운영자 전용 `review_reporters` 에만 남기고, 대상에게는 N-05 만 보낸다(하루 3건). 계정 삭제(`account`, 확인 문구 "삭제")는 기록을 즉시 지우고 일별 점수만 익명(`탈퇴 참가자`)으로 Archived 까지 남긴다.

## 로그인(Auth) 설정

앱은 Kakao·Apple ID 토큰을 `grant_type=id_token` 으로 넘기거나(네이티브), 브라우저 OAuth 로 로그인한다(app/README.md "로그인·참가").

- Dashboard > Authentication > Providers: **Kakao**(REST API 키·Client Secret), **Apple**(Services ID·키) 활성화
- Kakao 의 **REST API Key** 칸에는 `<REST API 키>,<네이티브 앱 키>` 처럼 쉼표로 두 키를 넣는다(공백 없이, REST 키가 앞). 앱이 카카오 SDK 로 받은 ID 토큰은 `aud` 가 네이티브 앱 키라서, REST 키만 있으면 `Unacceptable audience in id_token` 으로 거절된다. Auth 는 이 값을 목록으로 읽어 ID 토큰 `aud` 와 대조하고(`internal/api/token_oidc.go`), 브라우저 OAuth 는 첫 번째 값을 쓴다(`internal/api/provider/kakao.go`).
- Authentication > URL Configuration > Redirect URLs: `app.challory://login-callback`
- 로그인만으로는 `public.users` 행이 생기지 않는다. 참가 RPC `join_challenge` 가 users·profiles·consents·participants 를 한 번에 만든다.

## 권한 모델

| 호출자 | 할 수 있는 것 |
|---|---|
| 참가자(authenticated) | 본인 행 읽기, 표시 설정·체중·응원(1일 1회)·소명(1회·72h, 신고 검토 포함) 쓰기, 본인 기기 행 삭제(로그아웃), `score_simulate_from_inputs`·`food_search`·`join_challenge`·`register_device` |
| 운영자(challenges.operator_id) | 자기 챌린지 전체 읽기(건강 알림·메모·신고 내용·기록 모드 사유 포함), 참가자 상태·재가입 차단, 규칙(잠금 전), `apply_verdict_rpc`·`transition_challenge_rpc`·`announce_challenge`·`export_rows`·`purge_challenge_photos`·`log_operator_action` |
| service_role(Edge Function·pg_cron) | `create_photo`·`verify_photo`·`create_meal`·`create_manual_meal`·`confirm_meal`·`skip_meal`·`submit_report`·`delete_account`·`ingest_activity_batch`·`run_*` 배치·`claim_due_notifications`·`claim_notification` |
| 익명 | `get_invite(code)` |

PostgREST 오류: 함수가 SQLSTATE `PTnnn` 을 던지면 HTTP `nnn`(403·404·409·412·422)으로 나간다.

## 검증하지 못한 것

- Supabase CLI·Docker 이미지를 받을 수 없는 네트워크라 **실제 Supabase(Auth·Storage·PostgREST·pg_cron·pg_net)** 위에서는 돌려 보지 않았다. 로컬은 auth 스텁 + 순수 Postgres 16.
- Gemini·Claude·FCM 실호출(키 없음). 어댑터는 요청 형식을 가짜 fetch 로만 검증했다.
- 미구현 Edge Function: `objections`(결과 이의), `appeals`(현재는 RLS 직접 insert), `invite/{code}` 웹 랜딩. 참가는 RPC `join_challenge` 로 직접.
- 서명 업로드 URL 유효 시간은 Supabase Storage 고정값(2시간)이라 05 §8 의 10분과 다르다. 대신 업로드 후 `meals` 가 객체를 다시 읽어 해시·크기·해상도를 재검증한다.
- 탈퇴 사용자 auth 행의 30일 내 하드 삭제 배치(`deleted_users_due()` 목록 → 관리 API 삭제)는 스케줄러에 아직 연결하지 않았다.

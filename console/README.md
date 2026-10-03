# 챌로리(Challory) 운영자 웹 콘솔

다이어트 챌린지 앱 챌로리의 운영자 콘솔(OP0~OP4)이에요. Refine(`@refinedev/core`) + Vite + React + TypeScript로 만들었고,
화면과 문구는 `prototype/console.html`, `docs/06-화면-설계.md` §4~§6을 기준으로 맞췄어요.
Ant Design 같은 UI 키트 없이 프로토타입의 CSS 토큰(`src/styles.css`, 라이트·다크)을 그대로 써요.

| 화면 | 경로 | 내용 |
|---|---|---|
| OP0 | `/` | 챌린지 카드(상태·D-day·참가자·미결·오늘 동기화율) |
| OP0 새 챌린지 | `/new` | 이름·기간(7~30일)·정원(30~100명)으로 초안 생성(RPC `create_challenge`, 기본 규칙 행 포함) → OP1 로 이동. 초대코드는 OP1 모집 시작 때 발급 |
| OP1 | `/c/:id/settings` | 기본 정보, 상수 카드(읽기 전용·잠금), 규칙 Markdown + P11 미리보기, 샘플 3명 시뮬레이션(서버 RPC), 초대코드·링크, 상태 전환 |
| OP2 | `/c/:id/participants` | 요약 카드, 필터(미동기화·플래그·기록 모드·제외)·정렬 표, 참가자 드로어, 제외·강퇴·재가입 차단·메모, 건강 알림(운영자만 열람) |
| OP3 | `/c/:id/reviews` | 통합 검토 큐(SLA 72h·임박·초과), 증거 패널, 판정 4단계 + 점수 영향 미리보기(dry_run) → 확정, 알림 미리보기, 감사 로그 |
| OP4 | `/c/:id/results` | 최종 순위, "미결 N건" 차단 배너, 최종 확정 모달, 공지(N-03), CSV 4종, 이의 기간 타이머, 사진 파기 |

## 실행

```bash
cd console
npm i
npm run dev        # http://localhost:5173
npm run build      # tsc -b + vite build
npm test           # vitest
```

### 환경 변수 (`.env.example` 참고)

| 변수 | 설명 |
|---|---|
| `VITE_SUPABASE_URL` | 비워 두면 **모의(mock) 모드**로 실행해요. 값이 있으면 Supabase에 연결하고 이메일 로그인 화면이 떠요. |
| `VITE_SUPABASE_ANON_KEY` | Supabase anon 키 |
| `VITE_INVITE_BASE` | 초대 링크 앞부분(기본 `https://challory.app/j/`) |

### 모의 모드

`VITE_SUPABASE_URL`이 없으면 `src/data/mock/`의 메모리 데이터로 돌아가요. 백엔드가 없어도 모든 화면을 눌러 볼 수 있어요.

- 시드: 가을 걷기 챌린지 10.6~11.2, 42/60명, 오늘 10.13(D+8), 지수·밤산책·달려라하니, 검토 큐 3건(R-0412 걸음 급증·소명 도착, R-0415 사진 중복, R-0417 신고) 등 `prototype/data.js`·`console.html` 예시와 같아요.
- 상단 검수 바의 "상태 변형" 버튼(또는 `?scenario=closing` 쿼리)으로 상태를 바꿔요: 초안 · 모집 중(0명/42명) · 진행 중 · SLA 임박 · 집계 마감(미결 3) · SLA 초과 · 집계 마감(미결 0) · 결과 확정 · 종료(파기 전/완료). 바꾸면 시드가 새로 만들어져요.
- 판정 확정·조치·공지·전환 등은 메모리에서만 바뀌고 새로고침하면 초기화돼요.
- 점수 계산은 `src/data/mock/engine.ts`(prototype `ENGINE`의 TS 포트, **모의 전용**)가 해요. Supabase 모드에서는 이 파일을 쓰지 않고 서버 RPC `score_simulate_from_inputs`·`apply_verdict`를 호출해요.

## 구조

```
src/
  data/api.ts                 ConsoleApi 인터페이스(화면은 이것만 안다)
  data/index.ts               VITE_SUPABASE_URL 유무로 provider 선택
  data/supabaseProvider.ts    Supabase(테이블·RPC·Edge Function) 구현
  data/mock/                  모의 provider·시드·점수 엔진 포트
  data/refineProvider.ts      <Refine> dataProvider(Supabase 모드는 @refinedev/supabase)
  lib/verdictCopy.ts          판정 통지 문구 템플릿(사유+판정+점수 영향) — 판정 문구는 여기서만 만든다
  lib/{lifecycle,sla,csv,...} 상태 8종·전환 규칙, SLA, CSV 열 허용 목록 등
  pages/OP0~OP4, Login        화면
  components/                 Shell(내비·상단 바·검수 바), 공용 UI
```

## 테스트 (`npm test`)

- `lib/verdictCopy.test.ts`: 사유·판정·점수 영향 문장 조합. 예) 지수 10.12 저녁 무효 →
  `같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5`
- `lib/forbiddenWords.test.ts`: `src/**/*.{ts,tsx}`의 문자열 리터럴·템플릿·JSX 텍스트에 금지 어휘(실패·부정·조작·거짓·적발·꼴찌)가 없는지 TypeScript AST로 검사
- `data/mock/engine.test.ts`: 모의 시뮬레이션 골든값 28.8 / 72.1 / 0.0
- `data/mock/provider.test.ts`: 판정 dry_run(41.2→12.7, 누적 341.1→312.6, 순위 4→4), 미결이 있으면 최종 확정 차단
- `lib/csv.test.ts`: CSV 열 허용 목록에 건강 알림·운영자 메모·기록 모드 사유가 없음
- `lib/sla.test.ts`, `lib/lifecycle.test.ts`
- `App.smoke.test.tsx`: jsdom에서 OP0~OP4를 모의 데이터로 렌더링해 주요 문구·판정 흐름 확인

## 실제로 연결된 것 / 모의인 것

| 영역 | Supabase 모드 | 모의 모드 |
|---|---|---|
| 챌린지·규칙·참가자·검토·점수 읽기 | 테이블 직접 조회 | 메모리 시드 |
| 샘플 시뮬레이션 | RPC `score_simulate_from_inputs` | TS 포트(모의 전용) |
| 판정 미리보기·확정 | RPC `apply_verdict_rpc`(dry_run / 확정, `p_reason_template`; 운영자 검사·N-06·감사 로그는 서버가 처리, actor = 본인 고정) | TS 포트 |
| 상태 전환 | RPC `transition_challenge_rpc`(미결이 있으면 서버가 422 "미결 N건") | 같은 규칙을 메모리에서 |
| 미결 건수 | RPC `challenge_open_review_count` | 메모리 |
| 공지 | Edge Function `announce` → RPC `announce_challenge`(N-03) | 메모리 |
| CSV | Edge Function `export?type=` → RPC `export_rows`(서버 허용 열) → 실패 시 클라이언트 생성(허용 열만) | 클라이언트 생성 |
| 사진 파기 | Edge Function `purge-photos` → RPC `purge_challenge_photos`(Archived만) + Storage 삭제 | 메모리 |
| 감사 로그(화면 조치) | RPC `log_operator_action`(audit_logs 직접 insert 불가) | 메모리 |

## 열린 이슈 / supabase/ 계약과 다른 점

`supabase/migrations/*.sql`(스키마·엔진·배치)을 읽고 맞췄어요. 아래는 확인이 필요하거나 다르게 해석한 부분이에요.

1. Edge Function `announce`·`export`·`purge-photos`·`verdict`는 `supabase/functions/`에 있어요. 콘솔은 판정에 `apply_verdict_rpc`를 직접 부르고(같은 SQL), `verdict` 함수는 멱등 키가 필요한 외부 호출용이에요.
2. **`apply_verdict` 반환**: `substitution`은 식별자가 아니라 구절("대체값 743", "AI 추정값 복원", "평소 걸음 기준", "해당 출처 제외")이에요. 콘솔은 이 구절을 그대로 쓰고, 없으면 `m_p`를 올림해 "대체값 N"을 만들어요(서버 `ceil(m_p)`와 같고, 문서의 "정수 반올림"과 .5에서 같은 값). 무효 문구의 누적 차액은 서버 `verdict_message`와 같이 `cumulative_after − cumulative_before`예요. 서버가 돌려주는 `message`는 쓰지 않고 콘솔이 `verdictCopy.ts`로 같은 문장을 조립해요(두 곳의 문자열이 같아야 해요). 순위(4→4)는 계약에 없어 서버 모드에서는 표시하지 않아요.
3. **문장부호**: 요청서 예시는 마침표가 없고 "743로"였지만, 06 문서·프로토타입·서버(`josa_ro`) 모두 문장 사이에 ". "를 넣고 "743으로"라서 그쪽을 따랐어요.
4. **테이블 모양 차이**: `participants`에는 `record_mode_reason`·`operator_note`·기기·출처 컬럼이 없어요. 운영자 메모는 `participant_notes`, 기록 모드 사유는 `profiles.record_mode_reason`(enum), 출처는 `last_sync_source`, 플랫폼은 `devices`에서 읽어요. 기기 모델명은 어디에도 없어 "iPhone/Android"까지만 보여 줘요. 상태는 `participant_status`(active/record_mode/excluded/kicked/left)이고 `left`는 목록에서 숨겨요.
5. **리더보드**: `leaderboard_scope`는 `today`/`cumulative`뿐이라 최종 순위는 `scope=cumulative, is_final=true` 스냅샷으로 읽어요. 스냅샷 `rows`에 확정 끼니 수가 없어 `daily_scores.main_meal_count` 합으로 계산해요.
6. **검토 큐**: `reviews`에 슬롯 컬럼이 없어 `target.meal_id → meals`에서 가져와요. 신고 내용은 `review_reporters.reason`(신고자 id는 조회하지 않아요). 유형은 스키마의 `review_type` 12종을 모두 처리하지만 증거 패널은 걸음 급증·사진 중복·신고(식사 사진)를 중심으로 만들었어요.
7. RLS는 `supabase/migrations/*_rls.sql`에 있고 `supabase/tests/03_rls.test.sql`이 검증해요: 운영자는 자기 챌린지의 `profiles`(기록 모드 사유)·`participant_notes`·`review_reporters`·`health_alerts`를 읽고, `participants`는 상태·재가입 차단만, `participant_notes`는 읽기·쓰기가 돼요. `audit_logs`는 직접 insert가 막혀 있어 `log_operator_action` RPC로 남겨요.
8. **사진은 자리표시자예요.** 서명 URL(10분)·열람 로그를 아직 연결하지 않아서 증거 패널의 사진은 해시와 라벨만 있는 프로토타입식 자리표시자예요.
9. Supabase 경로(조회·RPC 호출)는 실제 DB에 대해 실행해 보지 못했어요(타입 검사·빌드까지만 확인). 로컬 Supabase가 준비되면 OP1~OP4를 한 번씩 눌러 보며 컬럼명을 확인해 주세요.
10. 브라우저가 없는 환경이라 화면 모양(1280~1024px 레이아웃)은 눈으로 확인하지 못했고, 프로토타입 CSS를 그대로 옮기고 jsdom 스모크 테스트로 동작만 확인했어요. 1100px 이하에서는 프로토타입처럼 좌측 메뉴가 아이콘만 남고, OP1 2열은 1열로 접혀요.
11. Refine은 `<Refine>`(라우터·데이터 provider) 수준으로만 쓰고, 화면의 도메인 호출은 `ConsoleApi`를 거쳐요. `@refinedev/supabase` 데이터 provider는 연결해 뒀지만 리소스 CRUD 훅은 아직 쓰지 않아요.
12. 번들이 500 kB를 넘는다는 Vite 경고가 있어요(코드 분할 미적용).
13. 새 챌린지는 RPC `create_challenge` 로만 만들도록 화면을 붙였지만, 운영자의 `challenges` 직접 insert 권한(RLS `challenges_insert`)은 아직 남아 있어요. 모의 데이터에서는 새로 만든 챌린지도 다른 예시 챌린지처럼 수정·전환이 막혀 있어요(가을 걷기 챌린지만 가능).

# 챌로리(Challory) 참가자 앱

다이어트 챌린지 앱 "챌로리"의 참가자용 Flutter 앱입니다. 화면 명세는 `docs/06-화면-설계.md`, 클릭 프로토타입은 `prototype/index.html`, 점수 산식은 `docs/04-칼로리-엔진-및-순위-규칙.md`를 따릅니다. 서버 쓰기 경로(사진 업로드·끼니 생성·확정·건너뜀·직접 입력·신고·계정 삭제·활동 동기화)는 `ChalloryApi` 로 Edge Functions 에 연결돼 있고, `SUPABASE_URL` 이 없으면 같은 흐름을 모의 구현이 대신합니다. 리더보드·장부·로그인은 아직 모의입니다(아래 "서버 연결"·"모의/미구현").

## 실행

Flutter SDK 3.47 / Dart 3.13 기준입니다.

```bash
cd app
flutter pub get
flutter run                      # 모의 데이터 모드 (서버 없이 동작)
```

서버(Supabase)에 연결하려면 빌드 시점 상수로 주입합니다.

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon key> \
  --dart-define=KAKAO_NATIVE_APP_KEY=<카카오 네이티브 앱 키>   # 선택
```

| 상수 | 설명 |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | 둘 다 있으면 `Supabase.initialize` 후 `SupabaseChalloryApi`(Edge Functions) 와 P11 RPC `score_simulate_from_inputs` 를 씁니다. 없으면 `MockChalloryApi`·로컬 엔진. |
| `KAKAO_NATIVE_APP_KEY` | 있으면 카카오 SDK(카카오톡 앱·카카오계정)로 로그인해 ID 토큰을 Supabase 에 넘깁니다. 없으면 카카오도 브라우저 OAuth. Android 는 같은 dart-define 을 매니페스트 스킴 `kakao{키}` 에도 씁니다. iOS 는 `ios/Flutter/Kakao.xcconfig`(예시 `Kakao.xcconfig.example`)에 같은 키를 넣어야 합니다. |
| `MOCK_HEALTH=true` | 실기기에서도 건강 데이터를 모의 값으로 강제합니다. |
| `SCREEN_LIST=true` | 릴리스 빌드에서도 검수용 화면 목록(`/debug`)을 켭니다. 디버그 빌드에서는 항상 켜져 있습니다. |

### 화면 둘러보기

디버그 빌드의 P1 하단 "화면 목록 (검수용)" 링크(또는 `/debug` 경로)에서 P1~P12와 주요 상태 변형으로 바로 이동할 수 있고, 모의 상태(끼니·활동·챌린지 생명주기)를 바꿔 변형을 볼 수 있습니다.

| 경로 | 화면 |
|---|---|
| `/p1` `/p2` `/p3` `/p4` | 시작·초대코드 / 프로필·안전 체크 / 동의 / 건강 데이터 연결 (`/p4?state=zero\|denied\|ok\|unsupported`) |
| `/home` (= `/p5`) | 홈 — 탭 셸 |
| `/rank` (= `/p9`) | 리더보드 — 탭 셸 |
| `/activity` (= `/p8`) | 활동 상세 — 탭 셸 |
| `/rules` (= `/p11`) | 규칙·시뮬레이터 — 탭 셸 |
| `/p6?slot=lunch` | 식사 촬영 |
| `/p7/lunch` (`?search=1`) | 식사 확인·편집 |
| `/p10` (`?v=review\|verdict-void\|…`, `?day=7`) | 점수 장부·소명 |
| `/p12` (`?v=push-off\|disconnected\|notices\|delete\|weight-read`) | 설정 |

탭 바는 프로토타입과 같은 `홈 · 순위 · [촬영 FAB] · 활동 · 규칙`이고, 설정(P12)은 홈의 톱니, 점수 장부(P10)는 '점수 계산 보기'로 들어갑니다(docs/06 §2).

## 테스트

```bash
flutter analyze
flutter test
```

- `test/engine/` 엔진 골든 테스트(엔진 담당 영역, 수정하지 않음)
- `test/widget/screens_test.dart` P5·P7·P9·P11 위젯 스모크: 모의 데이터가 엔진 값(BMR 1,650 · 오늘 28.8점 · 누적 312.6)과 일치, P7에서 김을 해제하면 850 → 780이고 '확정'하면 P5가 엔진으로 28.8을 다시 계산, P11 기본 입력에서 28.8 표시 등
- `test/services/` 동기화 배치 JSON(docs/05 §5)·KST 윈도·시뮬레이터 입출력 변환
- `test/forbidden_words_test.dart` `lib/**/*.dart`에서 금지 어휘(실패·부정·조작·거짓·적발·꼴찌) 검사. 엔진 폴더(`lib/core/engine/`)는 담당 영역이라 제외합니다.

### 서버 응답 픽스처

`test/fixtures/server_ledger.json` 은 `supabase/tests/run.sh` 가 시드 DB에서 만든 실제 서버 응답(지수 장부·정정 이력·리더보드 스냅샷, 10.12 무효 판정 적용)입니다. `test/services/server_mapping_test.dart`·`test/widget/remote_mode_test.dart` 가 이 파일로 서버 모드 매핑과 화면을 검증합니다. 서버 함수를 바꾸면 `run.sh` → `flutter test` 순서로 돌립니다.

## 구조

```
lib/
  main.dart, app.dart, router.dart     진입점 · go_router(P1~P12, 탭 셸, /debug)
  core/
    engine/                            점수 엔진(다른 담당 영역, 읽기 전용으로 사용)
    theme/                             토큰(ThemeExtension, 라이트/다크) · 폰트
    format.dart, config.dart           숫자 포맷 · 실행 설정(dart-define)
  data/
    models.dart                        MealRecord, MealItem, LedgerRow …
    mock/mock_data.dart                prototype/data.js 포팅(모든 값은 엔진으로 계산)
  services/
    score_simulator.dart               ScoreSimulator 인터페이스 + 로컬/Supabase RPC 구현
    api/                               ChalloryApi(서버 호출 계약) · Supabase 구현 · 모의 구현 · P7 항목↔서버 변환
    photo/                             사진 전처리(리사이즈·EXIF 제거·SHA-256) · 업로드 파이프라인·재시도 큐
    health/                            HealthSource, 패키지 구현, 모의 구현, 동기화 배치
  state/app_state.dart                 Riverpod 단순 Provider(끼니·활동·날짜·생명주기)
  ui/screens/                          p1_start … p12_settings, debug_screens
  ui/widgets/                          공용 위젯(링, 카드, 칩, 버튼, 슬롯 카드)
```

원칙

- BMR·M·F·A·I·D·S 숫자는 하드코딩하지 않고 `ChalloryEngine`으로 계산합니다. 규칙 상수(T·상한·하한·대체값 등) 표기는 `EngineRules`에서 읽습니다.
- 순위에 들어가는 값은 서버가 계산합니다. 앱의 점수는 P5·P7·P11 미리보기용입니다.
- 모든 kcal·점수는 "약"·"추정"으로 표기하고 하단 면책 1줄을 둡니다.

## 건강 데이터(`lib/services/health/`)

- `HealthSource` : 일 집계만 돌려줍니다(`steps_total`, `steps_manual`, `floors`, 세션, 출처). KST 기준 D·D−1·D−2 3일 윈도.
- `HealthPackageSource` : `health` 13.x. 걸음은 `getTotalStepsInInterval` 집계 쿼리로 읽고, 수동 입력은 제외합니다. iOS는 `steps_manual`을 분리해 보내고, Android(Health Connect)는 집계로 수동분을 분리할 수 없어 수동 제외 집계 + `has_manual_source` 플래그를 보냅니다. 플랫폼 활동 칼로리는 `platformActiveKcal` 참고값으로만 보관하며 점수·순위에 쓰지 않습니다.
- `MockHealthSource` : 실기기가 아니면(데스크톱·테스트) 자동 사용.
- `buildSyncBatch(...)` : docs/05 §5 배치 JSON(`client_batch_id`, `tz`, `days[...]`). P5·P8 새로고침 때 `sync-activity` 로 올립니다(`client_batch_id` = Idempotency-Key).
- 갤러리/`image_picker` 사용 없음, 걸음 수동 입력 UI 없음.

## 플랫폼 설정

### Android
- `MainActivity`는 `FlutterFragmentActivity`(Android 14 Health Connect 권한 화면 필요), `minSdk 26`.
- 권한: `READ_STEPS`, `READ_DISTANCE`, `READ_FLOORS_CLIMBED`, `READ_EXERCISE`, `READ_ACTIVE_CALORIES_BURNED`, `READ_HEALTH_DATA_IN_BACKGROUND`, `READ_WEIGHT`, `CAMERA`, `INTERNET`.
- Health Connect 권한 사용 목적 화면: `ACTION_SHOW_PERMISSIONS_RATIONALE` intent-filter(Android 13 이하)와 `ViewPermissionUsageActivity` activity-alias(Android 14+). 스토어 제출 시 해당 화면이 개인정보 처리방침을 보여 주도록 연결해야 합니다.
- 체중(`READ_WEIGHT`)은 P12 "건강 앱에서 읽기"를 처음 누를 때 따로 요청합니다.

### iOS
- `Info.plist`: `NSHealthShareUsageDescription`(읽기 전용 설명), `NSHealthUpdateUsageDescription`(쓰지 않음을 명시), `NSCameraUsageDescription`(한국어).
- `Runner/Runner.entitlements`에 HealthKit(`com.apple.developer.healthkit`)을 넣고 Xcode 프로젝트에 연결했습니다. 서명 팀 설정은 직접 해야 합니다.

## 폰트와 라이선스

| 서체 | 용도 | 출처 | 라이선스 |
|---|---|---|---|
| Pretendard (Regular/Medium/SemiBold/Bold, OTF) | 본문 | npm `pretendard` 1.3.9 | SIL OFL 1.1 — `assets/fonts/OFL-Pretendard.txt` |
| Barlow Semi Condensed (500/600/700, TTF) | 링 kcal·점수·순위 등 숫자 | npm `@expo-google-fonts/barlow-semi-condensed` 0.4.1 | SIL OFL 1.1 — `assets/fonts/OFL-BarlowSemiCondensed.txt` |

두 서체 모두 앱에 번들했고 라이선스 전문을 `assets/fonts/`에 함께 두었습니다. 프로토타입은 IBM Plex Sans KR을 대신 쓰지만 docs/06 §5.2의 지정(Pretendard)을 따랐습니다. Pretendard OTF가 약 1.5 MB × 4라 앱 용량이 늘어나므로, 필요하면 가변 폰트나 서브셋으로 줄일 수 있습니다. 아이콘은 Flutter 기본 번들의 Material Icons(`*_rounded`)를 씁니다(프로토타입의 Material Symbols Rounded와 모양이 약간 다릅니다).

## 로그인·참가 (`lib/services/auth/`, P1~P3)

```
P1 초대코드 6자리 → get_invite(로그인 전, 익명) → 챌린지 카드
   카카오 / Apple 로그인 → 이미 참가 중이면 홈, 아니면 P2(닉네임은 로그인 이름으로 미리 채움)
P2 닉네임·성별·생년·키·체중·안전 체크·건강 정보 동의 → P3 약관·국외 AI 동의
   → join_challenge(자격 게이트 · 기록 모드 · BMR 잠금은 서버 판정) → P4 건강 연결
```

| 제공자 | iOS | Android |
|---|---|---|
| 카카오 | 카카오 SDK → ID 토큰 → `signInWithIdToken(kakao)` (앱 키 없으면 브라우저 OAuth) | 같음 |
| Apple | Sign in with Apple(네이티브) → ID 토큰 → `signInWithIdToken(apple)` | 브라우저 OAuth |

- ID 토큰 경로는 nonce 를 씁니다: 제공자에게는 SHA-256 해시, Supabase 에는 원본(재사용 공격 방지).
- 브라우저 OAuth 는 딥링크 `app.challory://login-callback` 으로 돌아옵니다(Android intent-filter·iOS URL 스킴 등록됨).
- 서버 모드에서는 라우터가 로그인 전 화면 접근을 막습니다(P1·규칙 미리 보기만 공개). 로그아웃·계정 삭제 뒤에는 P1 로 돌아갑니다. 모의 모드는 가드 없이 모든 화면을 엽니다(검수용).
- 사전 준비(코드 밖): Supabase Dashboard > Authentication > Providers 에서 Kakao·Apple 켜기, Redirect URLs 에 `app.challory://login-callback` 추가, 카카오 디벨로퍼스에서 OpenID Connect 활성화(ID 토큰), Apple Developer 에서 Sign in with Apple 기능·Services ID(Android 브라우저 경로용).

### 현재 세션(`lib/state/session.dart`)

화면은 `curChallenge`·`curMe`·`engine`(현재 챌린지 규칙으로 만든 엔진)·`meM`/`meF` 접근자로 챌린지·내 정보·규칙을 읽습니다. 서버 모드는 `sessionProvider` 가 `my_challenge_summary` 결과로 이 값을 바꾸고, 탭 셸(AppShell)이 그 Provider 를 지켜보므로 값이 바뀌면 아래 화면이 다시 그려집니다. 모의 모드는 프로토타입 예시 값(`ChallengeSession.mock`)입니다. 프로토타입 예시 계산은 `mockEngine`(기본 규칙)을 씁니다.

## 서버 연결 (`lib/services/api/`)

| 화면·동작 | 호출 | 비고 |
|---|---|---|
| P6 촬영 | `photo-upload-url` → 서명 URL PUT → `meals` | 기기에서 긴 변 ≤1,568 px·EXIF 제거·SHA-256(`photo_prep.dart`, isolate). 업로드는 기다리지 않고 홈으로(3초 복귀). 슬롯은 서버가 서버 시각으로 정하고 앱은 응답 슬롯으로 옮김 |
| 분석 완료 | `meals` 행 조회(PostgREST, 본인 RLS) | 1.5초 간격 최대 10회 확인 → 초안 항목(후보 칩 kcal·국물 여부 포함) 반영. N-04 푸시 수신 처리는 남은 일 |
| P7 확정 | `meal-confirm` (If-Match: version, Idempotency-Key) | 화면은 바로 반영, 서버가 거절하면 되돌리고 안내(412: "다른 기기에서 먼저 바뀌었어요") |
| P7 직접 입력·검색(사진 없음) | `meal-manual` | 빈 슬롯·분석 없음 끼니 |
| P7 건너뜀 | `meal-skip` | 한도 초과면 "대체값으로 계산돼요" 안내 |
| P5 시작·당겨서 새로고침 | `meals` 조회 · `sync-activity` · 재시도 큐 | 서버 모드는 빈 슬롯에서 시작해 오늘 끼니를 서버에서 채움 |
| 앱 시작(로그인 후) | RPC `my_challenge_summary` | 챌린지 이름·기간·정원·참가 인원·D+n·상태(생명주기), 잠긴 프로필·BMR, 규칙 상수(T·C·M·F·상한·건너뜀·점검 일수), 끼니 경계·확정 시각·수정·소명 시간, 운영자 추가 규칙(Markdown), 최근 공지. 받기 전에는 탭 화면 대신 로딩·오류·"참가 중인 챌린지가 없어요" |
| P12 공지 · P5 공지 배너 | `notifications`(type N-03, 본인 행, 예약 시각이 지난 것) 최신순 50건 | 목록을 열면 안 읽은 공지를 읽음 처리(`read_at`, 본인 행·이 컬럼만 수정 가능). P5 배너는 최신 1건, 누르면 전문 + 읽음 |
| P9 순위 | `leaderboard_snapshots` 최신 오늘·누적 + 내 `daily_scores` | 스냅샷의 '집계 중' 행은 이름·점수 없음. 내가 검토 중이면 내 점수로 순위를 계산해 그 자리에 내 행(검토 중 · 소명하기). 순위 제외(기록 모드·비공개)는 순위 '—'. 당겨서 새로고침 |
| P9 신고 | `reports` | 스냅샷 행의 participant_id 로 보냄 |
| P9 응원 하트 | `cheers` insert(RLS: 본인·같은 챌린지·오늘 KST) | 보내는 사람 기준 하루 1회(UNIQUE). 이미 보냈으면 "내일 다시 응원할 수 있어요". 화면 진입 때 오늘 보낸 응원을 읽어 하트 상태 표시 |
| P10 검토 카드·소명 | `reviews`(본인) + `appeals` insert(RLS: open·72h·1회) | 사유 문장·기한(SLA)·보낸 설명을 서버 값으로. 판정이 나면 서버 통지 문장(사유+판정+점수 영향)을 배너로 |
| P10 결과 이의 | RPC `submit_objection`(발표 후 7일·1회) | 결과 발표(Published) 단계에서만 카드 노출 |
| P10 장부 · P5 지난 날 · P8 7일 그래프 · P9 주간 피드백 | `daily_scores`(+`score_revisions`·`reviews` 유형) | 서버 분해값(BMR·A·I·F·D·S·대체값 슬롯·하한)을 그대로 표시, 정정 이력은 "판정 41.2→12.7점"처럼. 확정·건너뜀 뒤 다시 읽음 |
| P12 계정 삭제 | `account` (확인 문구 "삭제") → 로그아웃 | |

- 모든 쓰기 호출에 `Idempotency-Key`(UUID). 오프라인·5xx 는 `MealUploader.pending` 큐에 넣고 같은 키로 재시도하며, 재시도는 `queued=true` 로 보내 서버가 촬영 시각 기준 지연 업로드 규칙을 적용합니다. 큐는 메모리에만 있어 앱을 종료하면 사라집니다.
- 모의 모드(`MockChalloryApi`)는 같은 호출 순서·응답 모양을 흉내 냅니다: 서버 시각 슬롯, 2초 뒤 초안, 확정마다 버전 증가.

## 모의/미구현

모의로 동작하는 것
- 모든 화면 데이터(챌린지·내 정보·끼니·장부·리더보드·최종 결과): `lib/data/mock/mock_data.dart`.
- 모의 모드의 로그인: 버튼을 누르면 로그인된 것으로 봅니다(`MockAuthService`). 초대코드는 `K7Q2MD` 유효, `FULL00` 마감, `BLOCK0` 참가 단계에서 거절.
- 모의 모드의 AI 초안(2초 뒤 `draft`)과 식약처 DB 검색(P7) 목록. 서버 모드에서도 P7 검색 시트는 아직 모의 목록입니다(`food_search` RPC 연결은 남은 일).

알려진 공백
- 서버 연동 남은 것: 실기기에서 카카오·Apple 로그인 확인(제공자 설정 필요), P7 음식 검색, 재시도 큐 디스크 보관, N-04 푸시로 초안 갱신.
- 푸시 알림(FCM)과 OS 알림 권한 요청: P6 프리퍼미션 카드는 화면만 있고 실제 권한 요청은 없습니다.
- "설정 열기"·"삼성헬스 열기"·약관 링크처럼 외부 앱/URL을 여는 동작(`url_launcher`, `permission_handler` 미포함).
- 볼륨 키 촬영(네이티브 구현), 백그라운드 동기화(WorkManager, `HKObserverQuery`), 딥링크·클립보드 초대코드 감지(P1 배너는 모의).
- 건강 데이터 패키지 구현은 컴파일·단위 수준만 확인했고 실기기(삼성헬스 → Health Connect, Apple 건강)에서의 값은 검증하지 못했습니다. Android SDK·Xcode가 없는 환경이라 Android·iOS 빌드는 이 저장소에서 실행해 보지 못했습니다.
- 과거 날짜(P5 날짜 스와이프)는 열람 전용이며 48시간 정정 편집은 오늘 끼니에만 연결돼 있습니다.
- 접근성은 시맨틱 라벨·44dp 터치 영역·모션 감소를 반영했지만 TalkBack/VoiceOver 점검은 하지 않았습니다.

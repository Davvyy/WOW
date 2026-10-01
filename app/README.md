# 챌로리(Challory) 참가자 앱

다이어트 챌린지 앱 "챌로리"의 참가자용 Flutter 앱입니다. 화면 명세는 `docs/06-화면-설계.md`, 클릭 프로토타입은 `prototype/index.html`, 점수 산식은 `docs/04-칼로리-엔진-및-순위-규칙.md`를 따릅니다. 현재는 **모의 데이터로 끝까지 동작하는 UI 단계**이며, 서버 연동은 점수 시뮬레이터 RPC 한 곳만 연결돼 있습니다(아래 "모의/미구현" 참고).

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
  --dart-define=SUPABASE_ANON_KEY=<anon key>
```

| 상수 | 설명 |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | 둘 다 있으면 `Supabase.initialize` 후 P11 시뮬레이터가 RPC `score_simulate_from_inputs`(`{p: <json>}`)를 호출합니다. 호출이 안 되면 로컬 엔진으로 계산합니다. 없으면 로컬 엔진만 씁니다. |
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
- `buildSyncBatch(...)` : docs/05 §5 배치 JSON(`client_batch_id`, `tz`, `days[...]`). 서버 업로드 호출은 아직 없습니다.
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

## 모의/미구현

모의로 동작하는 것
- 모든 화면 데이터(챌린지·내 정보·끼니·장부·리더보드·최종 결과): `lib/data/mock/mock_data.dart`. 초대코드는 `K7Q2MD` 유효, `FULL00` 마감, `BLOCK0` 참가 불가, 그 외 오류.
- 로그인(카카오/Apple)은 버튼만 있고 인증은 하지 않습니다.
- 촬영 후 AI 초안(2초 뒤 `draft`)과 식약처 DB 검색(P7)은 모의 목록입니다.
- 응원·신고·소명·이의 전송은 화면 안에서만 동작하고 서버로 보내지 않습니다.

알려진 공백
- Supabase 연동은 P11 시뮬레이터 RPC만. 인증(Kakao/Apple), 끼니·사진 업로드(리사이즈·EXIF 제거·SHA-256·서명 URL), 리더보드·장부 조회, 동기화 배치 업로드, 오프라인 큐·재시도가 남아 있습니다.
- 푸시 알림(FCM)과 OS 알림 권한 요청: P6 프리퍼미션 카드는 화면만 있고 실제 권한 요청은 없습니다.
- "설정 열기"·"삼성헬스 열기"·약관 링크처럼 외부 앱/URL을 여는 동작(`url_launcher`, `permission_handler` 미포함).
- 볼륨 키 촬영(네이티브 구현), 백그라운드 동기화(WorkManager, `HKObserverQuery`), 딥링크·클립보드 초대코드 감지(P1 배너는 모의).
- 건강 데이터 패키지 구현은 컴파일·단위 수준만 확인했고 실기기(삼성헬스 → Health Connect, Apple 건강)에서의 값은 검증하지 못했습니다. Android SDK·Xcode가 없는 환경이라 Android·iOS 빌드는 이 저장소에서 실행해 보지 못했습니다.
- 과거 날짜(P5 날짜 스와이프)는 열람 전용이며 48시간 정정 편집은 오늘 끼니에만 연결돼 있습니다.
- 접근성은 시맨틱 라벨·44dp 터치 영역·모션 감소를 반영했지만 TalkBack/VoiceOver 점검은 하지 않았습니다.

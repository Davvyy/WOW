import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';
import '../core/engine/engine.dart';
import '../data/mock/mock_data.dart';
import '../data/models.dart';
import '../services/health/health_models.dart';
import '../services/health/health_package_source.dart';
import '../services/health/health_source.dart';
import '../services/health/mock_health_source.dart';
import '../services/api/challory_api.dart';
import '../services/api/meal_wire.dart';
import '../services/api/mock_api.dart';
import '../services/api/supabase_api.dart';
import '../services/auth/auth_service.dart';
import '../services/photo/meal_uploader.dart';
import '../services/photo/photo_prep.dart';
import '../services/score_simulator.dart';
import 'session.dart';

/// 서버 호출 계층. SUPABASE_URL 이 있으면 Edge Functions, 없으면 같은 흐름의 모의 구현.
final apiProvider = Provider<ChalloryApi>((_) {
  if (AppConfig.hasSupabase) {
    try {
      return SupabaseChalloryApi(Supabase.instance.client);
    } catch (_) {}
  }
  return MockChalloryApi();
});

/// 로그인. 서버 모드는 Supabase Auth(Kakao·Apple), 모의 모드는 버튼만 누르면 로그인된 것으로 본다.
final authServiceProvider = Provider<AuthService>((_) {
  if (AppConfig.hasSupabase) {
    try {
      return SupabaseAuthService(Supabase.instance.client);
    } catch (_) {}
  }
  return MockAuthService();
});

/// 온보딩(P1 코드 → 로그인 → P2 프로필·건강 동의 → P3 약관·국외 AI 동의 → 참가) 입력을 모아 두는 초안
class OnboardingDraft {
  const OnboardingDraft({this.code = '', this.invite, this.nickname = '', this.sex = Sex.m, this.birthYear, this.heightCm, this.weightKg,
      this.pregnancy = false, this.eatingDisorder = false, this.sensitiveHealth = false, this.join});
  final String code;
  final InviteSummary? invite;
  final String nickname;
  final Sex sex;
  final int? birthYear;
  final double? heightCm;
  final double? weightKg;
  final bool pregnancy;
  final bool eatingDisorder;
  final bool sensitiveHealth;
  final JoinResult? join;

  bool get profileReady => nickname.trim().length >= 2 && birthYear != null && heightCm != null && weightKg != null && sensitiveHealth;

  OnboardingDraft copyWith({String? code, InviteSummary? invite, String? nickname, Sex? sex, int? birthYear, double? heightCm, double? weightKg,
          bool? pregnancy, bool? eatingDisorder, bool? sensitiveHealth, JoinResult? join}) =>
      OnboardingDraft(
        code: code ?? this.code,
        invite: invite ?? this.invite,
        nickname: nickname ?? this.nickname,
        sex: sex ?? this.sex,
        birthYear: birthYear ?? this.birthYear,
        heightCm: heightCm ?? this.heightCm,
        weightKg: weightKg ?? this.weightKg,
        pregnancy: pregnancy ?? this.pregnancy,
        eatingDisorder: eatingDisorder ?? this.eatingDisorder,
        sensitiveHealth: sensitiveHealth ?? this.sensitiveHealth,
        join: join ?? this.join,
      );
}

class OnboardingNotifier extends Notifier<OnboardingDraft> {
  @override
  OnboardingDraft build() => const OnboardingDraft();

  void setInvite(String code, InviteSummary? invite, {String? nickname}) =>
      state = OnboardingDraft(code: code, invite: invite, nickname: nickname ?? state.nickname);

  void setProfile({required String nickname, required Sex sex, required int birthYear, required double heightCm, required double weightKg,
          required bool pregnancy, required bool eatingDisorder, required bool sensitiveHealth}) =>
      state = state.copyWith(nickname: nickname.trim(), sex: sex, birthYear: birthYear, heightCm: heightCm, weightKg: weightKg,
          pregnancy: pregnancy, eatingDisorder: eatingDisorder, sensitiveHealth: sensitiveHealth);

  /// P3 마지막 단계: 서버 join_challenge. 자격·기록 모드 판정은 서버가 한다. 성공 시 null, 아니면 안내 문구.
  Future<String?> join({required bool terms, required bool overseasAi}) async {
    final d = state;
    final api = ref.read(apiProvider);
    if (!d.profileReady) {
      if (!api.isRemote) return null; // 모의 모드에서 화면 목록으로 바로 P3 를 연 경우(검수용)
      return '기본 정보를 먼저 입력해 주세요';
    }
    try {
      final r = await api.joinChallenge(JoinRequest(
            code: d.code, nickname: d.nickname, sex: d.sex, birthYear: d.birthYear!, heightCm: d.heightCm!, weightKg: d.weightKg!,
            pregnancy: d.pregnancy, eatingDisorder: d.eatingDisorder, terms: terms, sensitiveHealth: d.sensitiveHealth, overseasAi: overseasAi));
      if (ref.mounted) {
        state = state.copyWith(join: r);
        ref.invalidate(sessionProvider); // 새 참가 정보로 세션 다시 읽기
      }
      return null;
    } catch (e) {
      return apiErrorText(e);
    }
  }
}

final onboardingProvider = NotifierProvider<OnboardingNotifier, OnboardingDraft>(OnboardingNotifier.new);

/// 리더보드(최신 스냅샷)·내 점수 장부. 서버 모드는 PostgREST, 모의 모드는 프로토타입 값.
final leaderboardProvider = FutureProvider<Leaderboard>((ref) => ref.watch(apiProvider).fetchLeaderboard());
final ledgerProvider = FutureProvider<List<LedgerRow>>((ref) => ref.watch(apiProvider).fetchLedger());

/// 화면용: 값이 아직 없으면 모의 모드는 프로토타입 값으로 바로 그리고, 서버 모드는 null(로딩·오류 표시)
Leaderboard? watchLeaderboard(WidgetRef ref) =>
    ref.watch(leaderboardProvider).value ?? (ref.read(apiProvider).isRemote ? null : mockLeaderboard);
List<LedgerRow>? watchLedger(WidgetRef ref) => ref.watch(ledgerProvider).value ?? (ref.read(apiProvider).isRemote ? null : mockLedger);

/// 공지 목록(N-03). 열면 [markAllRead] 로 읽음 처리(서버 read_at).
class NoticesNotifier extends AsyncNotifier<List<Notice>> {
  @override
  Future<List<Notice>> build() {
    ref.watch(authChangesProvider);
    return ref.watch(apiProvider).fetchNotices();
  }

  int get unread => (state.value ?? const []).where((n) => !n.read).length;

  Future<void> markRead(Iterable<String> ids) async {
    final list = state.value;
    if (list == null) return;
    final targets = {for (final n in list) if (!n.read && ids.contains(n.id)) n.id};
    if (targets.isEmpty) return;
    state = AsyncData([for (final n in list) targets.contains(n.id) ? n.markRead() : n]); // 화면 먼저
    try {
      await ref.read(apiProvider).markNoticesRead(targets.toList());
    } on ApiException {
      // 읽음 표시는 다음에 다시 시도해도 되는 부가 정보 — 화면 상태는 유지
    }
  }

  Future<void> markAllRead() => markRead([for (final n in state.value ?? const <Notice>[]) n.id]);
}

final noticesProvider = AsyncNotifierProvider<NoticesNotifier, List<Notice>>(NoticesNotifier.new);

/// 최종 결과(Published): 서버는 발표 때 만든 확정 누적 스냅샷(transition_challenge), 모의는 프로토타입 최종 순위
List<LeaderRow> watchFinalRows(WidgetRef ref) =>
    ref.read(apiProvider).isRemote ? (watchLeaderboard(ref)?.cumulative ?? const []) : mockFinal;

/// 최종 결과의 내 행(순위 제외면 null)
LeaderRow? myFinalRow(List<LeaderRow> rows) => rows.where((r) => r.me).firstOrNull;

/// 서버 장부 한 줄 → 화면용 결과(분해값은 서버 값 그대로, M_p 는 BMR 로 계산)
SimulateResult resultFromLedgerRow(LedgerRow r) => SimulateResult(
      bmr: r.bmr,
      bmrRaw: null,
      activity: ActivityResult(stepsOut: r.steps, stepsNetKcal: 0, sessionsNetKcal: 0, floorsKcal: 0, aRaw: r.a, aD: r.a, aCapped: false, sessionMets: const []),
      intake: IntakeResult(iD: r.i, mP: engine.m(r.bmr), mainMealCount: 0, snackCount: 0, substituteSlots: r.substituted, draftSlots: const [],
          pendingSlots: const [], skipsToday: 0, skipOver: false),
      score: ScoreResult(fP: r.f, floorApplied: r.floorApplied, dD: r.dd, sD: r.s, ratio: r.dd / engine.rules.t),
    );

/// 장부 확정분으로 계산한 주간 피드백(06 P9: 하드코딩 금지)
WeeklyFeedback? weeklyFrom(List<LedgerRow> ledger) {
  final rows = ledger.where((x) => !x.check && !x.provisional).toList();
  if (rows.isEmpty) return null;
  final avg = round1(rows.fold(0.0, (a, x) => a + x.s) / rows.length);
  return WeeklyFeedback(rows.length, avg, rows.where((x) => !x.substituted.contains(MealSlot.dinner)).length / rows.length);
}

final mealUploaderProvider = Provider<MealUploader>((ref) => MealUploader(ref.watch(apiProvider), prepare: preparePhoto));

String todayKst() => kstDateString(toKstWall(DateTime.now()));

/// 서버 오류를 화면 문구로(수치심 없는 카피, 06 §6)
String apiErrorText(Object e) {
  if (e is ApiException) {
    switch (e.status) {
      case 0:
        return '연결이 불안정해요. 연결되면 다시 보낼게요';
      case 412:
        return '다른 기기에서 먼저 바뀌었어요. 새로 불러온 뒤 다시 확정해 주세요';
      case 429:
        return e.message.isNotEmpty ? e.message : '잠시 뒤에 다시 해 주세요';
      default:
        return e.message.isNotEmpty ? e.message : '요청을 처리하지 못했어요';
    }
  }
  return '요청을 처리하지 못했어요';
}

final healthSourceProvider = Provider<HealthSource>((_) => createHealthSource());

final scoreSimulatorProvider = Provider<ScoreSimulator>((_) {
  if (AppConfig.hasSupabase) {
    try {
      return SupabaseScoreSimulator(Supabase.instance.client);
    } catch (_) {
      // Supabase.initialize 전이면 로컬 계산
    }
  }
  return const LocalScoreSimulator();
});

/// 챌린지 생명주기(03 §7). 서버 모드는 challenges.status 에서, 모의 모드는 진행 중(검수 화면에서 바꿀 수 있음).
enum ChallengePhase { recruiting, active, closing, published }

ChallengePhase phaseOfStatus(String status) => switch (status) {
      'draft' || 'recruiting' => ChallengePhase.recruiting,
      'closing' => ChallengePhase.closing,
      'published' || 'archived' => ChallengePhase.published,
      _ => ChallengePhase.active, // checking · running (cancelled 은 참가자에게 보이지 않음)
    };

/// 로그인 상태 변화(로그인·로그아웃마다 세션을 다시 읽는다)
final authChangesProvider = StreamProvider<bool>((ref) => ref.watch(authServiceProvider).changes);

/// 현재 챌린지 세션. 서버 모드는 my_challenge_summary, 모의 모드는 프로토타입 값.
/// 값을 받으면 [applySession] 으로 curChallenge·curMe·engine 접근자를 바꾼다.
final sessionProvider = FutureProvider<ChallengeSession?>((ref) async {
  ref.watch(authChangesProvider);
  final api = ref.watch(apiProvider);
  if (!api.isRemote) {
    applySession(ChallengeSession.mock);
    return ChallengeSession.mock;
  }
  if (!ref.read(authServiceProvider).isSignedIn) {
    resetSession();
    return null;
  }
  final s = await api.fetchSession();
  if (s != null) applySession(s);
  return s;
});

class PhaseNotifier extends Notifier<ChallengePhase> {
  @override
  ChallengePhase build() {
    final s = ref.watch(sessionProvider).value;
    return s == null ? ChallengePhase.active : phaseOfStatus(s.status);
  }
  void set(ChallengePhase p) => state = p;
}

final phaseProvider = NotifierProvider<PhaseNotifier, ChallengePhase>(PhaseNotifier.new);

// ---------- 활동 ----------
class ActivityNotifier extends Notifier<TodayActivity> {
  @override
  TodayActivity build() => mockTodayActivity;

  void set(TodayActivity a) => state = a;

  /// 3일 재조회(앱 실행·포그라운드 복귀·당겨서 새로고침). 모의 원천은 덮어쓰지 않는다.
  Future<void> refresh() async {
    final src = ref.read(healthSourceProvider);
    if (src is MockHealthSource) return;
    final days = await src.fetchDays();
    if (!ref.mounted || days.isEmpty) return;
    // 서버 업로드(05 API #6): 보내지 못해도 화면 값은 갱신하고 다음 새로고침 때 다시 보낸다
    try {
      await ref.read(apiProvider).syncActivity(buildSyncBatch(days));
    } on ApiException catch (_) {}
    if (!ref.mounted) return;
    final d = days.first;
    final wall = toKstWall(DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    state = TodayActivity(
      stepsTotal: d.stepsVerified,
      stepsRecorded: d.stepsTotal,
      stepsManual: d.stepsManual ?? 0,
      floors: d.floors,
      sessions: [
        for (final s in d.sessions)
          SessionInput(
            type: switch (s.type) {
              'running' => SessionType.running,
              'stair' => SessionType.stair,
              _ => SessionType.walking,
            },
            minutes: s.end.difference(s.start).inSeconds / 60,
            distanceM: s.distanceM,
            stepsInRange: s.stepsInRange,
            manual: s.method == RecordMethod.manual,
          ),
      ],
      platformActiveKcal: d.platformActiveKcal,
      hasManualSource: d.hasManualSource,
      source: src.platformLabel == 'Apple 건강' ? 'Apple 건강' : '삼성헬스',
      syncTime: '${two(wall.hour)}:${two(wall.minute)}',
    );
  }
}

final activityProvider = NotifierProvider<ActivityNotifier, TodayActivity>(ActivityNotifier.new);

// ---------- 끼니 ----------
class SkipsNotifier extends Notifier<int> {
  @override
  int build() => 1; // 이번 주 이미 1회 사용(남은 2회)
  void set(int v) => state = v;
}

final skipsUsedProvider = NotifierProvider<SkipsNotifier, int>(SkipsNotifier.new);

class MealsNotifier extends Notifier<List<MealRecord>> {
  MealsNotifier([List<MealRecord>? initial]) : _initial = initial;
  final List<MealRecord>? _initial;

  @override
  List<MealRecord> build() {
    if (_initial != null) return _initial;
    // 서버 연결 시 빈 슬롯으로 시작하고 loadToday() 로 채운다. 모의 모드는 프로토타입 시드.
    if (ref.read(apiProvider).isRemote) return [for (final s in MealSlot.values) MealRecord(slot: s)];
    return buildTodayMeals();
  }

  /// 오늘(KST) 본인 끼니를 서버에서 읽어 슬롯별로 반영. 한 슬롯에 여러 끼니면 마지막 것을 보여준다.
  Future<String?> loadToday() async {
    final api = ref.read(apiProvider);
    if (!api.isRemote) return null;
    try {
      final rows = await api.fetchMealsOn(todayKst());
      if (!ref.mounted) return null;
      final next = [for (final s in MealSlot.values) MealRecord(slot: s)];
      for (final m in rows) {
        final slot = m.slot;
        if (slot == null) continue;
        final items = [for (var i = 0; i < m.items.length; i++) mealItemFromServer(m.items[i], i)];
        final t = m.capturedAt == null ? '' : toKstWall(m.capturedAt!);
        String two(int v) => v.toString().padLeft(2, '0');
        next[slot.index] = MealRecord(
          slot: slot,
          status: m.status,
          kcal: m.confirmedKcal ?? 0,
          aiKcal: m.aiKcal,
          items: items,
          title: items.map((i) => i.name).take(2).join(' · '),
          time: t is DateTime ? '${two(t.hour)}:${two(t.minute)}' : '',
          serverId: m.id,
          version: m.version,
          noAnalysis: m.engine == 'none',
          lateUpload: m.lateUpload,
          corrected: m.status == MealStatus.corrected,
        );
      }
      state = next;
      for (final r in next) {
        if (r.status == MealStatus.captured && !r.noAnalysis && r.serverId != null) _pollDraft(r.slot, r.serverId!);
      }
      return null;
    } catch (e) {
      return apiErrorText(e);
    }
  }

  MealRecord of(MealSlot slot) => state.firstWhere((m) => m.slot == slot);

  void _put(MealRecord m) => state = [for (final x in state) x.slot == m.slot ? m : x];

  void reset(List<MealRecord> meals) => state = meals;

  /// 확정(P7). 이미 확정된 끼니를 고치면 corrected(정정).
  /// 화면은 바로 바꾸고(낙관적), 서버 끼니면 meal-confirm(If-Match: version), 사진 없는 확정이면 meal-manual 을 부른다.
  /// 서버가 거절하면 이전 상태로 되돌리고 오류 문구를 돌려준다(성공 시 null).
  Future<String?> confirm(MealSlot slot, List<MealItem> items, double total, {double? aiKcal}) async {
    final prev = of(slot);
    final wasConfirmed = prev.status == MealStatus.confirmed || prev.status == MealStatus.auto || prev.status == MealStatus.corrected;
    final names = items.where((i) => i.checked).map((i) => i.name).take(2).join(' · ');
    _put(prev.copyWith(
      status: wasConfirmed ? MealStatus.corrected : MealStatus.confirmed,
      kcal: total,
      aiKcal: aiKcal ?? prev.aiKcal,
      items: items,
      title: names.isEmpty ? prev.title : names,
      corrected: wasConfirmed,
      noAnalysis: false,
    ));
    final api = ref.read(apiProvider);
    final wire = [for (final it in items) mealItemToWire(it)];
    try {
      final ConfirmResult r;
      if (prev.serverId != null) {
        r = await api.confirmMeal(prev.serverId!, prev.version, wire, idempotencyKey: newUuidV4());
      } else if (api.isRemote || prev.status == MealStatus.empty || prev.noAnalysis || prev.status == MealStatus.skipped) {
        r = await api.createManualMeal(slot, wire, localDate: todayKst(), idempotencyKey: newUuidV4());
      } else {
        return null; // 모의 시드 끼니(서버 행 없음)
      }
      if (!ref.mounted) return null;
      _put(of(slot).copyWith(serverId: r.mealId, version: r.version, kcal: r.confirmedKcal));
      if (api.isRemote) ref.invalidate(ledgerProvider); // 서버가 잠정 점수를 다시 계산함
      return null;
    } catch (e) {
      if (ref.mounted) _put(prev);
      return apiErrorText(e);
    }
  }

  /// 직접 검색·입력으로 확정(초안 없음 경로)
  Future<String?> confirmManual(MealSlot slot, List<MealItem> items, double total) => confirm(slot, items, total);

  Future<String?> skip(MealSlot slot) async {
    final prev = of(slot);
    _put(prev.copyWith(status: MealStatus.skipped, kcal: 0, items: const [], title: ''));
    try {
      final api = ref.read(apiProvider);
      final r = await api.skipMeal(todayKst(), slot, idempotencyKey: newUuidV4());
      if (api.isRemote && ref.mounted) ref.invalidate(ledgerProvider);
      if (r.overLimit && ref.mounted) return '이번 주 건너뜀 한도를 넘어 대체값으로 계산돼요';
      return null;
    } catch (e) {
      if (ref.mounted) _put(prev);
      return apiErrorText(e);
    }
  }

  /// P6 촬영 직후: 분석 중(captured) → AI 초안(draft). 국외 AI 미동의면 분석 없이 저장.
  /// [photo] 가 있으면 업로드 파이프라인(리사이즈·EXIF 제거·SHA-256 → 서버 끼니 생성)을 탄다.
  /// 슬롯은 서버가 서버 시각으로 정하므로 응답 슬롯으로 옮긴다.
  Future<String?> capture(MealSlot slot, String time, {bool aiConsent = true, Uint8List? photo, DateTime? capturedAt}) async {
    final base = of(slot).copyWith(time: time, items: const [], kcal: 0, corrected: false);
    _put(base.copyWith(status: MealStatus.captured, noAnalysis: !aiConsent, pendingUpload: photo != null));
    if (photo == null) {
      if (!aiConsent || ref.read(apiProvider).isRemote) return null;
      // 사진 없는 모의 경로(테스트·카메라 없는 환경): 2초 뒤 모의 초안
      Future.delayed(const Duration(seconds: 2), () {
        if (!ref.mounted) return;
        final cur = of(slot);
        if (cur.status != MealStatus.captured || cur.noAnalysis) return;
        final items = mockDraftItems(slot);
        _put(cur.copyWith(status: MealStatus.draft, items: items, aiKcal: mockAiTotal(slot), title: items.map((i) => i.name).take(2).join(' · ')));
      });
      return null;
    }
    try {
      final meal = await ref.read(mealUploaderProvider).submitRaw(photo, capturedAt ?? DateTime.now(), localTag: slot.name);
      if (!ref.mounted) return null;
      if (meal == null) return '연결이 불안정해요. 연결되면 사진을 다시 보낼게요'; // 재시도 큐
      return _applyCreated(slot, meal, aiConsent);
    } catch (e) {
      if (ref.mounted) _put(of(slot).copyWith(status: MealStatus.empty, pendingUpload: false));
      return apiErrorText(e);
    }
  }

  String? _applyCreated(MealSlot localSlot, CreatedMeal meal, bool aiConsent) {
    final cur = of(localSlot);
    if (meal.slot != localSlot) _put(of(localSlot).copyWith(status: MealStatus.empty, pendingUpload: false, time: ''));
    _put(of(meal.slot).copyWith(status: MealStatus.captured, time: cur.time, serverId: meal.mealId, version: 1,
        noAnalysis: !meal.analyze, lateUpload: meal.lateUpload, pendingUpload: false, items: const [], kcal: 0));
    if (meal.analyze) _pollDraft(meal.slot, meal.mealId);
    if (!meal.counted) return '이미 확정된 날의 사진이라 기록으로만 남아요';
    if (meal.dupPhoto) return '같은 사진이 이미 있어 확인 중이에요';
    return null;
  }

  /// 분석 완료(N-04)를 기다리는 대신 짧게 확인(최대 약 15초). 푸시가 오면 [refreshMeal] 로도 갱신된다.
  Future<void> _pollDraft(MealSlot slot, String mealId, {int tries = 10}) async {
    for (var i = 0; i < tries; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!ref.mounted) return;
      if (await refreshMeal(slot, mealId)) return;
    }
  }

  /// 서버 끼니를 다시 읽어 초안·확정 상태를 반영. 분석이 끝났으면 true.
  Future<bool> refreshMeal(MealSlot slot, String mealId) async {
    final ServerMeal? m;
    try {
      m = await ref.read(apiProvider).fetchMeal(mealId);
    } on ApiException {
      return false;
    }
    if (m == null || !ref.mounted) return false;
    final cur = of(slot);
    if (cur.serverId != mealId) return true; // 그새 다른 끼니로 바뀜
    if (m.status == MealStatus.draft) {
      final items = [for (var i = 0; i < m.items.length; i++) mealItemFromServer(m.items[i], i)];
      _put(cur.copyWith(status: MealStatus.draft, items: items, aiKcal: m.aiKcal, version: m.version,
          title: items.map((i) => i.name).take(2).join(' · ')));
      return true;
    }
    if (m.status == MealStatus.failed) {
      _put(cur.copyWith(status: MealStatus.failed, version: m.version, noAnalysis: true));
      return true;
    }
    return m.status != MealStatus.captured;
  }

  /// 오프라인 큐 재시도(앱 복귀·당겨서 새로고침)
  Future<void> retryPendingUploads() async {
    final done = await ref.read(mealUploaderProvider).retryPending();
    if (!ref.mounted) return;
    for (final (tag, meal) in done) {
      final slot = tag == null ? meal.slot : MealSlot.values.byName(tag);
      _applyCreated(slot, meal, true);
    }
  }

  /// 촬영 직후 "지금 확정" 경로: 분석을 기다리지 않고 바로 초안 상태로
  void captureNow(MealSlot slot, String time) {
    final items = mockDraftItems(slot);
    _put(of(slot).copyWith(
      status: MealStatus.draft,
      time: time,
      items: items,
      aiKcal: mockAiTotal(slot),
      title: items.map((i) => i.name).take(2).join(' · '),
      noAnalysis: false,
    ));
  }
}

final mealsProvider = NotifierProvider<MealsNotifier, List<MealRecord>>(MealsNotifier.new);

// ---------- 오늘 계산(엔진) ----------
final todayResultProvider = Provider<SimulateResult>((ref) {
  final meals = ref.watch(mealsProvider);
  final act = ref.watch(activityProvider);
  final skips = ref.watch(skipsUsedProvider);
  ref.watch(sessionProvider); // 규칙·잠긴 BMR 이 바뀌면 다시 계산
  return engine.simulate(SimulateInput(
    bmr: curMe.bmr, // 서버가 잠근 BMR(시작 후 프로필 변경 없음)
    weightKg: curMe.weightKg,
    stepsTotal: act.stepsTotal,
    sessions: act.sessions,
    floors: act.floors,
    meals: [for (final m in meals) m.toInput()],
    skipsUsedThisWeek: skips,
  ));
});

// ---------- 날짜 선택(1~8, 8=오늘) ----------
class DayNotifier extends Notifier<int> {
  @override
  int build() => curChallenge.dayIndex;
  void set(int d) => state = d.clamp(1, curChallenge.dayIndex);
}

final selectedDayProvider = NotifierProvider<DayNotifier, int>(DayNotifier.new);

// ---------- 응원(하루 1회) ----------
class HeartNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void send(String name) => state = name;
}

final heartedTodayProvider = NotifierProvider<HeartNotifier, String?>(HeartNotifier.new);

/// 첫 촬영 뒤 알림 프리퍼미션 카드를 이미 보여줬는지
class NotifAskNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void done() => state = true;
}

final notifAskedProvider = NotifierProvider<NotifAskNotifier, bool>(NotifAskNotifier.new);

/// 국외 AI 분석 동의(P3 선택, P12 철회)
class AiConsentNotifier extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool v) => state = v;
}

final aiConsentProvider = NotifierProvider<AiConsentNotifier, bool>(AiConsentNotifier.new);

/// P12 "순위에 내 행 보이기" (끄면 내 행만 보인다)
class RankVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool v) => state = v;
}

final rankVisibleProvider = NotifierProvider<RankVisibleNotifier, bool>(RankVisibleNotifier.new);

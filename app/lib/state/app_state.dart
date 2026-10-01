import 'dart:async';

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
import '../services/score_simulator.dart';

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

/// 챌린지 생명주기(03 §7). 기본은 진행 중.
enum ChallengePhase { recruiting, active, closing, published }

class PhaseNotifier extends Notifier<ChallengePhase> {
  @override
  ChallengePhase build() => ChallengePhase.active;
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
  List<MealRecord> build() => _initial ?? buildTodayMeals();

  MealRecord of(MealSlot slot) => state.firstWhere((m) => m.slot == slot);

  void _put(MealRecord m) => state = [for (final x in state) x.slot == m.slot ? m : x];

  void reset(List<MealRecord> meals) => state = meals;

  /// 확정(P7). 이미 확정된 끼니를 고치면 corrected(정정).
  void confirm(MealSlot slot, List<MealItem> items, double total, {double? aiKcal}) {
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
  }

  /// 직접 검색·입력으로 확정(초안 없음 경로)
  void confirmManual(MealSlot slot, List<MealItem> items, double total) => confirm(slot, items, total);

  void skip(MealSlot slot) => _put(of(slot).copyWith(status: MealStatus.skipped, kcal: 0, items: const [], title: ''));

  /// P6 촬영 직후: 분석 중(captured) → 잠시 뒤 AI 초안(draft). 국외 AI 미동의면 분석 없이 저장.
  void capture(MealSlot slot, String time, {bool aiConsent = true}) {
    final base = of(slot).copyWith(time: time, items: const [], kcal: 0, corrected: false);
    if (!aiConsent) {
      _put(base.copyWith(status: MealStatus.captured, noAnalysis: true));
      return;
    }
    _put(base.copyWith(status: MealStatus.captured, noAnalysis: false));
    Future.delayed(const Duration(seconds: 2), () {
      if (!ref.mounted) return;
      final cur = of(slot);
      if (cur.status != MealStatus.captured || cur.noAnalysis) return;
      final items = mockDraftItems(slot);
      _put(cur.copyWith(status: MealStatus.draft, items: items, aiKcal: mockAiTotal(slot), title: items.map((i) => i.name).take(2).join(' · ')));
    });
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
  return engine.simulate(SimulateInput(
    profile: mockMe.profile,
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
  int build() => mockChallenge.dayIndex;
  void set(int d) => state = d.clamp(1, mockChallenge.dayIndex);
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

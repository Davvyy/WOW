import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine/engine.dart';
import '../data/models.dart';
import 'app_state.dart';
import 'session.dart';

/// 반영률 4칸(표시 전용, D69): 아침·점심·저녁 + 걸음. 서버 순위표 fill 과 같은 기준.
/// 끼니 칸은 대체값이 들어가지 않은 칸만 반영: 칸을 채운 확정 기록([snackKcal] 이상)이 있거나, 한도 안의 건너뜀.
/// 한도를 넘은 건너뜀은 대체값이 들어가므로 반영으로 세지 않는다. 걸음 칸은 걸음이 있으면 반영.
List<bool> coverageCells({required List<MealRecord> meals, required IntakeResult intake, required int steps, required double snackKcal}) {
  bool filled(MealSlot s) => mealsIn(meals, s).any((m) => isCountedStatus(m.status) && m.kcal >= snackKcal);
  bool validSkip(MealSlot s) =>
      mealsIn(meals, s).any((m) => m.status == MealStatus.skipped) &&
      !intake.substituteSlots.contains(s) &&
      !intake.substituteValues.containsKey(s);
  return [for (final s in mainSlots) filled(s) || validSkip(s), steps > 0];
}

int coverageCount(List<bool> cells) => cells.where((x) => x).length;

/// 오늘 반영률(홈 오늘 화면·순위표 '오늘' 내 줄이 같이 쓴다)
final todayCoverageProvider = Provider<List<bool>>((ref) {
  final sim = ref.watch(todayResultProvider);
  return coverageCells(
    meals: ref.watch(mealsProvider),
    intake: sim.intake,
    steps: ref.watch(activityProvider).stepsTotal,
    snackKcal: engine.rules.snackKcal,
  );
});

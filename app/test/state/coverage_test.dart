// 반영률 4칸(D69): 홈과 순위표 내 줄이 같은 계산을 쓴다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/state/coverage.dart';
import 'package:flutter_test/flutter_test.dart';

IntakeResult _intake({List<MealSlot> substitute = const []}) => IntakeResult(
    iD: 0, mP: 819, mainMealCount: 1, snackCount: 0, substituteSlots: substitute, draftSlots: const [], pendingSlots: const [], skipsToday: 0, skipOver: false);

void main() {
  const lunch = MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 11);
  const skipBreakfast = MealRecord(slot: MealSlot.breakfast, status: MealStatus.skipped);

  test('한도 안 건너뜀 + 확정 기록(간식 기준 0) + 걸음 → 3칸', () {
    final cells = coverageCells(meals: const [skipBreakfast, lunch], intake: _intake(substitute: [MealSlot.dinner]), steps: 100, snackKcal: 0);
    expect(cells, [true, true, false, true]);
    expect(coverageCount(cells), 3);
  });

  test('대체값이 들어간 건너뜀은 반영 아님 · 걸음 0 은 반영 아님', () {
    final cells = coverageCells(meals: const [skipBreakfast, lunch], intake: _intake(substitute: [MealSlot.breakfast, MealSlot.dinner]), steps: 0, snackKcal: 0);
    expect(cells, [false, true, false, false]);
  });

  test('간식 기준 이상이어야 칸을 채움(규칙 값 사용)', () {
    final cells = coverageCells(meals: const [lunch], intake: _intake(), steps: 0, snackKcal: 150);
    expect(cells[1], isFalse);
  });
}

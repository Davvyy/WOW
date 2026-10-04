// 빈 끼니 칸 대체값 = max(M_p, 전날 같은 칸 등록 kcal)(docs/02 D61).
// supabase/tests/29_prev_day_substitute.test.sql 과 같은 경우를 엔진에서 확인한다. BMR 1650 → M_p 742.5.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/engine/json_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = ChalloryEngine();
  const bmr = 1650;
  const mP = 742.5;

  group('전날 같은 칸 대체값', () {
    test('전날 점심 900 → 오늘 빈 점심 900', () {
      final r = engine.intake(bmr: bmr, meals: const [], prevSlots: const {MealSlot.lunch: 900});
      expect(r.substituteValues[MealSlot.lunch], 900);
      expect(r.substituteValues[MealSlot.breakfast], mP);
      expect(r.iD, closeTo(mP * 2 + 900, 1e-9));
      expect(r.mP, mP);
    });

    test('전날 점심 200(M_p 미만) → M_p', () {
      final r = engine.intake(bmr: bmr, meals: const [], prevSlots: const {MealSlot.lunch: 200});
      expect(r.substituteValues[MealSlot.lunch], mP);
      expect(r.iD, closeTo(mP * 3, 1e-9));
    });

    test('전날 기록 없음 → M_p (지금과 같음)', () {
      final r = engine.intake(bmr: bmr, meals: const []);
      expect(r.substituteValues, {MealSlot.breakfast: mP, MealSlot.lunch: mP, MealSlot.dinner: mP});
      expect(r.iD, closeTo(mP * 3, 1e-9));
    });

    test('분석 중 칸·한도 초과 건너뜀도 같은 값, 한도 안 건너뜀은 0', () {
      final pending = engine.intake(
          bmr: bmr, meals: const [MealInput(slot: MealSlot.lunch, status: MealStatus.captured)], prevSlots: const {MealSlot.lunch: 900});
      expect(pending.pendingSlots, [MealSlot.lunch]);
      expect(pending.iD, closeTo(mP * 2 + 900, 1e-9));

      final skips = engine.intake(bmr: bmr, meals: const [
        MealInput(slot: MealSlot.breakfast, status: MealStatus.skipped),
        MealInput(slot: MealSlot.lunch, status: MealStatus.skipped),
      ], prevSlots: const {MealSlot.breakfast: 1000, MealSlot.lunch: 900});
      expect(skips.skipOver, isTrue);
      expect(skips.substituteValues.containsKey(MealSlot.breakfast), isFalse);
      expect(skips.iD, closeTo(900 + mP, 1e-9));
    });

    test('초안 잠정값과 간식은 그대로', () {
      final r = engine.intake(bmr: bmr, meals: const [
        MealInput(slot: MealSlot.breakfast, status: MealStatus.draft, aiKcal: 400),
        MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 500),
        MealInput(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: 600),
      ], prevSlots: const {MealSlot.breakfast: 1000, MealSlot.snack: 5000});
      expect(r.draftSlots.single.value, mP); // max(M_p, 1.3×400) — 전날 값과 무관
      expect(r.substituteValues, isEmpty);
      expect(r.iD, closeTo(mP + 1100, 1e-9));
    });

    test('simulate 와 JSON 입력(prev_slots)이 그대로 넘긴다', () {
      final s = engine.simulate(simulateInputFromJson({
        'bmr': bmr,
        'weight_kg': 70,
        'meals': const [],
        'prev_slots': {'lunch': 900, 'dinner': 200, 'snack': 5000},
      }));
      expect(s.intake.iD, closeTo(2385, 1e-9));
      final none = engine.simulate(simulateInputFromJson({'bmr': bmr, 'weight_kg': 70}));
      expect(none.intake.iD, closeTo(2227.5, 1e-9));
    });

    test('JSON prev_slots 의 null 값은 0(→ M_p)으로 읽는다', () {
      final input = simulateInputFromJson({
        'bmr': bmr,
        'weight_kg': 70,
        'prev_slots': {'lunch': null, 'dinner': 900},
      });
      expect(input.prevSlots, {MealSlot.lunch: 0.0, MealSlot.dinner: 900.0});
      final s = engine.simulate(input);
      expect(s.intake.substituteValues[MealSlot.lunch], mP);
      expect(s.intake.iD, closeTo(mP * 2 + 900, 1e-9));
    });
  });

  group('전날 장부 행 → 칸별 kcal', () {
    test('확정·자동·정정만, 간식 제외, 칸별 합', () {
      final prev = prevSlotKcal(const [
        MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 500),
        MealInput(slot: MealSlot.lunch, status: MealStatus.corrected, kcal: 400),
        MealInput(slot: MealSlot.breakfast, status: MealStatus.auto, kcal: 300),
        MealInput(slot: MealSlot.dinner, status: MealStatus.draft, aiKcal: 900),
        MealInput(slot: MealSlot.dinner, status: MealStatus.voided, kcal: 900),
        MealInput(slot: MealSlot.snack, status: MealStatus.confirmed, kcal: 1000),
      ]);
      expect(prev, {MealSlot.lunch: 900, MealSlot.breakfast: 300});
    });
  });
}

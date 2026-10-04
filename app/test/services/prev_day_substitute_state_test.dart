// 오늘 잠정 점수는 어제 장부 행의 칸별 등록 kcal 로 빈 칸 대체값 max(M_p, 전날 같은 칸)을 계산한다(D61).
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

LedgerRow _row(int d, List<MealInput> meals) => LedgerRow(
      d: d,
      date: '',
      steps: 0,
      bmr: 0,
      a: 0,
      i: 0,
      dd: 0,
      s: 0,
      f: 0,
      floorApplied: false,
      substituted: const [],
      check: false,
      provisional: false,
      note: '',
      history: '',
      health: false,
      meals: meals,
    );

/// 어제 장부 행만 정해 둔다(행이 없으면 빈 장부)
class _LedgerApi extends MockChalloryApi {
  _LedgerApi(this.yesterday);
  final List<MealInput>? yesterday;
  @override
  Future<List<LedgerRow>> fetchLedger() async => [if (yesterday != null) _row(curChallenge.dayIndex - 1, yesterday!)];
}

Future<IntakeResult> _todayIntake(List<MealInput>? yesterday) async {
  final c = ProviderContainer(overrides: [
    apiProvider.overrideWithValue(_LedgerApi(yesterday)),
    mealsProvider.overrideWith(() => MealsNotifier(const [])),
  ]);
  addTearDown(c.dispose);
  await c.read(sessionProvider.future);
  await c.read(ledgerProvider.future);
  return c.read(todayResultProvider).intake;
}

void main() {
  test('어제 점심 900 → 오늘 빈 점심 900, 다른 칸 M_p', () async {
    final inn = await _todayIntake(const [
      MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 900),
      MealInput(slot: MealSlot.snack, status: MealStatus.confirmed, kcal: 1000),
    ]);
    expect(inn.mP, lessThan(900));
    expect(inn.substituteFor(MealSlot.lunch), 900);
    expect(inn.substituteFor(MealSlot.dinner), inn.mP);
    expect(inn.iD, closeTo(round1(inn.mP * 2 + 900), 1e-9));
  });

  test('어제 점심 200 → M_p', () async {
    final inn = await _todayIntake(const [MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 200)]);
    expect(inn.substituteFor(MealSlot.lunch), inn.mP);
    expect(inn.iD, closeTo(round1(inn.mP * 3), 1e-9));
  });

  test('어제 장부 행 없음 → M_p', () async {
    final inn = await _todayIntake(null);
    expect(inn.substituteValues.values.toSet(), {inn.mP});
  });

  test('서버 장부 행의 substitute_values 를 읽는다', () {
    final row = ledgerRowFromServer({
      'local_date': '2026-10-15',
      'i_d': 2385,
      'f_p': 1320,
      'breakdown': {
        'intake': {
          'substitute_slots': ['breakfast', 'lunch', 'dinner'],
          'substitute_values': {'breakfast': 742.5, 'lunch': 900, 'dinner': 742.5},
        },
      },
    }, DateTime(2026, 10, 6));
    expect(row.substituteValues, {MealSlot.breakfast: 742.5, MealSlot.lunch: 900, MealSlot.dinner: 742.5});
    expect(resultFromLedgerRow(row).intake.substituteFor(MealSlot.lunch), 900);
  });
}

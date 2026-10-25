// 사진 없는 기록(전수 점검 #15): '사진 없이 기록'·검색·직접 입력으로 만든 끼니는 사진 자리·'인앱 촬영 · 서버 시각'·
// '사진은 저장됐고' 문구를 보이지 않는다. 사진이 있는 끼니는 그대로.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

const _tag = '인앱 촬영 · 서버 시각';

Map<String, dynamic> _row({String? photoId, String status = 'confirmed'}) => {
      'id': 'm-1', 'slot': 'lunch', 'status': status, 'version': 2, 'engine': 'gemini', 'ai_kcal': null, 'confirmed_kcal': 520,
      'captured_at': '2026-10-13T03:20:00Z', 'late_upload': false, 'photo_id': photoId,
      'meal_items': [
        {'chosen_name': '김치볶음밥', 'name_candidates': ['김치볶음밥'], 'candidate_kcal': [520], 'count': 1, 'portion_multiplier': 1,
          'has_broth': false, 'needs_check': false, 'eaten': true},
      ],
    };

Future<void> _openServerLunch(WidgetTester tester, Map<String, dynamic> row) async {
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-1'), overrides: [
    apiProvider.overrideWithValue(MockChalloryApi()),
    mealsProvider.overrideWith(() => MealsNotifier([
          for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
          ...mealRecordsFromServer([ServerMeal.fromJson(row)]),
        ])),
  ]);
}

void main() {
  test('서버 끼니: photo_id 가 없으면 사진 없는 기록, 있으면 사진 기록, 열을 안 받았으면 모름', () {
    expect(ServerMeal.fromJson(_row()).hasPhoto, isFalse);
    expect(ServerMeal.fromJson(_row(photoId: 'ph-1')).hasPhoto, isTrue);
    expect(ServerMeal.fromJson({..._row()}..remove('photo_id')).hasPhoto, isNull);
    expect(mealRecordsFromServer([ServerMeal.fromJson(_row())]).single.photoless, isTrue);
    expect(mealRecordsFromServer([ServerMeal.fromJson(_row(photoId: 'ph-1'))]).single.photoless, isFalse);
  });

  testWidgets('카메라의 "사진 없이 기록": 사진 자리·촬영 표시·"사진은 저장됐고" 없이 검색 안내', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.lunch, search: true));
    expect(find.text('점심 확인'), findsOneWidget);
    expect(find.text(_tag), findsNothing);
    expect(find.bySemanticsLabel('점심 사진'), findsNothing);
    expect(find.textContaining('사진은 저장됐고', findRichText: true), findsNothing);
    expect(find.textContaining('음식을 찾지 못했어요', findRichText: true), findsNothing, reason: '분석한 적이 없다');
    expect(find.textContaining('사진 없이 기록해요.', findRichText: true), findsOneWidget);
    expect(find.text('음식 이름 검색 · 최근 음식'), findsOneWidget);
  });

  testWidgets('검색으로 확정한 끼니(photo_id 없음)를 다시 열면 사진 자리가 없다', (tester) async {
    await _openServerLunch(tester, _row());
    expect(find.text('김치볶음밥'), findsWidgets);
    expect(find.text(_tag), findsNothing);
    expect(find.bySemanticsLabel('점심 사진'), findsNothing);
  });

  testWidgets('사진이 있는 끼니는 사진 자리와 촬영 표시를 그대로 보인다', (tester) async {
    await _openServerLunch(tester, _row(photoId: 'ph-1'));
    expect(find.text(_tag), findsOneWidget);
  });

  testWidgets('목록에 없는 끼니를 확정하면(검색·직접 입력) 사진 없는 기록으로 남는다', (tester) async {
    final c = await pumpApp(tester);
    const item = MealItem(id: 'u0', candidates: ['바나나'], candKcal: [90], portion: '1인분', kind: ItemKind.count, confidence: Confidence.manual);
    await c.read(mealsProvider.notifier).confirm(MealSlot.snack, const [item], 90, key: 'local-new');
    final snack = c.read(mealsProvider).where((m) => m.matches('local-new')).single;
    expect(snack.photoless, isTrue);
    expect(c.read(mealsProvider).where((m) => m.slot == MealSlot.lunch).every((m) => !m.photoless), isTrue, reason: '사진 기록은 그대로');
  });
}

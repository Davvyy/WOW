// 지난 날 홈: 끼니마다 한 줄, 누르면 그 날짜의 P7. 서버 규칙(확정 전 · 확정 뒤 48시간 · 그 뒤)대로 확정·지우기를 연다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/past_meals.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:challory/ui/widgets/meal_slot_card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 지난 날(D+7 = 10.12)
const _past = '2026-10-12';

ServerMealItem _item(String name, double kcal) => ServerMealItem(
    candidates: [name], candidateKcal: [kcal], candidateFoodCodes: const [null], count: 1, portionMultiplier: 1,
    hasBroth: false, needsCheck: false, aiKcal: kcal);

/// 10.12 아침 둘: 확정 420(07:40) · AI 초안 300(10:10)
List<ServerMeal> _twoBreakfasts() => [
      ServerMeal(id: 'b-1', status: MealStatus.confirmed, version: 2, confirmedKcal: 420, aiKcal: 420, slot: MealSlot.breakfast,
          capturedAt: DateTime.utc(2026, 10, 11, 22, 40), items: [_item('계란토스트', 420)]),
      ServerMeal(id: 'b-2', status: MealStatus.draft, version: 1, aiKcal: 300, slot: MealSlot.breakfast,
          capturedAt: DateTime.utc(2026, 10, 12, 1, 10), items: [_item('요거트 볼', 300)]),
    ];

/// 서버 모드: 10.12 끼니·장부 응답을 정해 두고, 확정·지우기 요청을 남긴다
class _PastApi extends MockChalloryApi {
  _PastApi({required this.isFinal, this.finalizedAt});
  final bool isFinal;
  final DateTime? finalizedAt;
  List<ServerMeal> meals = _twoBreakfasts();
  int ledgerReads = 0;
  final confirmed = <String>[];
  ApiException? deleteError;
  ApiException? confirmError;
  ApiException? ledgerError;
  ApiException? mealsError;
  int mealReads = 0;

  @override
  bool get isRemote => true;

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async {
    if (localDate != _past) return const [];
    mealReads++;
    if (mealsError != null) throw mealsError!;
    return List.of(meals);
  }

  @override
  Future<List<LedgerRow>> fetchLedger() async {
    ledgerReads++;
    if (ledgerError != null) throw ledgerError!;
    return [
      ledgerRowFromServer({
        'id': 'ds-7',
        'local_date': _past,
        'bmr': 1650,
        'a_d': 300,
        'i_d': 1500,
        'f_p': 1200,
        'd_d': 400,
        's_d': 30,
        'is_counted': true,
        'is_final': isFinal,
        'finalized_at': finalizedAt?.toUtc().toIso8601String(),
        'breakdown': const <String, dynamic>{},
      }, mockChallenge.start),
    ];
  }

  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    calls.add('meal-confirm');
    if (confirmError != null) throw confirmError!;
    confirmed.add(mealId);
    final kcal = wireTotal(items);
    meals = [
      for (final m in meals)
        m.id == mealId
            ? ServerMeal(id: m.id, status: isFinal ? MealStatus.corrected : MealStatus.confirmed, version: version + 1, confirmedKcal: kcal,
                aiKcal: m.aiKcal, slot: m.slot, capturedAt: m.capturedAt, items: m.items)
            : m,
    ];
    return ConfirmResult(mealId: mealId, confirmedKcal: kcal, version: version + 1, status: isFinal ? 'corrected' : 'confirmed');
  }

  @override
  Future<void> deleteMeal(String mealId, {required String idempotencyKey}) async {
    calls.add('meal-delete');
    final e = deleteError;
    if (e != null && e.status != 404) throw e;
    meals = [for (final m in meals) if (m.id != mealId) m];
    deletedMeals.add(mealId);
    if (e != null) throw e; // 404: 이미 지워짐
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, _PastApi api, {String location = R.home}) async {
  addTearDown(resetSession);
  return pumpApp(tester, location: location, overrides: [
    apiProvider.overrideWithValue(api),
    authServiceProvider.overrideWithValue(MockAuthService(true)),
  ]);
}

/// 홈에서 D+7(10.12)을 고른다
Future<void> _pickPastDay(WidgetTester tester, ProviderContainer c) async {
  c.read(selectedDayProvider.notifier).set(7);
  await tester.pumpAndSettle();
}

Finder _rowsOf(MealSlot s) => find.byWidgetPredicate((w) => w is MealRow && w.meal.slot == s);

Finder _cta(String prefix) => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith(prefix));

void main() {
  testWidgets('지난 날 아침 2건이면 2줄 · 추가 없음 · 두 번째를 누르면 그 끼니의 P7', (tester) async {
    final api = _PastApi(isFinal: false);
    final c = await _pump(tester, api);
    await _pickPastDay(tester, c);
    expect(find.text('D+7/28'), findsOneWidget);
    expect(_rowsOf(MealSlot.breakfast), findsNWidgets(2));
    expect(find.text('계란토스트'), findsOneWidget);
    expect(find.bySemanticsLabel('아침 추가'), findsNothing, reason: '지난 날에는 새로 찍지 않는다');
    // 기록 없는 점심은 빈 칸(누를 수 없음)
    final lunch = tester.widget<MealSlotCard>(find.byWidgetPredicate((w) => w is MealSlotCard && w.meal.slot == MealSlot.lunch));
    expect(lunch.onTap, isNull);

    await tester.tap(_rowsOf(MealSlot.breakfast).at(1));
    await tester.pumpAndSettle();
    expect(find.text('아침 확인'), findsOneWidget);
    expect(find.textContaining('아침 · 10:10'), findsOneWidget);
    expect(find.text('요거트 볼'), findsWidgets);
    expect(_cta('확정 · 약 300 kcal'), findsOneWidget);
    expect(find.textContaining('건너뜀'), findsNothing, reason: '건너뜀은 오늘만');
  });

  testWidgets('확정 전 지난 날: P7 확정은 서버로 보내고 장부를 다시 읽는다', (tester) async {
    final api = _PastApi(isFinal: false);
    final c = await _pump(tester, api, location: R.meal(MealSlot.breakfast, meal: 'b-2', date: _past));
    expect(find.text('요거트 볼'), findsWidgets);
    expect(find.byTooltip('기록 지우기'), findsOneWidget, reason: '확정 전이면 지울 수 있다');
    final reads = api.ledgerReads;
    await tester.tap(_cta('확정 · 약 300 kcal'));
    await tester.pumpAndSettle();
    expect(api.confirmed, ['b-2']);
    expect(api.ledgerReads, greaterThan(reads), reason: '점수가 바뀌어 장부를 다시 읽는다');
    expect(find.text('아침을 확정했어요'), findsOneWidget);
    final b2 = c.read(pastMealsProvider(_past)).value!.firstWhere((m) => m.serverId == 'b-2');
    expect(b2.status, MealStatus.confirmed);
    expect(b2.kcal, 300);
    expect(c.read(mealsProvider).where((m) => m.serverId == 'b-2'), isEmpty, reason: '오늘 목록에는 넣지 않는다');
  });

  testWidgets('확정 뒤 47시간: 수정 저장은 되고 지우기는 없다(정정)', (tester) async {
    final api = _PastApi(isFinal: true, finalizedAt: DateTime.now().subtract(const Duration(hours: 47)));
    final c = await _pump(tester, api, location: R.meal(MealSlot.breakfast, meal: 'b-1', date: _past));
    expect(find.text('계란토스트'), findsWidgets);
    expect(find.byTooltip('기록 지우기'), findsNothing);
    expect(find.text('수정 기한(확정 후 48시간)이 지나 볼 수만 있어요'), findsNothing);
    await tester.tap(_cta('수정 저장 · 약 420 kcal'));
    await tester.pumpAndSettle();
    expect(api.confirmed, ['b-1']);
    final b1 = c.read(pastMealsProvider(_past)).value!.firstWhere((m) => m.serverId == 'b-1');
    expect(b1.status, MealStatus.corrected);
  });

  testWidgets('확정 뒤 49시간: 확정 버튼 없이 보기만, 서버 호출 없음', (tester) async {
    final api = _PastApi(isFinal: true, finalizedAt: DateTime.now().subtract(const Duration(hours: 49)));
    await _pump(tester, api, location: R.meal(MealSlot.breakfast, meal: 'b-2', date: _past));
    expect(find.text('요거트 볼'), findsWidgets);
    expect(find.textContaining('약 300'), findsWidgets);
    expect(find.text('수정 기한(확정 후 48시간)이 지나 볼 수만 있어요'), findsOneWidget);
    expect(_cta('확정'), findsNothing);
    expect(_cta('수정 저장'), findsNothing);
    expect(find.byTooltip('기록 지우기'), findsNothing);
    expect(api.calls.where((x) => x == 'meal-confirm' || x == 'meal-delete'), isEmpty);
  });

  testWidgets('확정 전 지난 날 지우기: 그 줄이 빠진다', (tester) async {
    final api = _PastApi(isFinal: false);
    final c = await _pump(tester, api);
    await _pickPastDay(tester, c);
    await tester.tap(_rowsOf(MealSlot.breakfast).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('기록 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    expect(api.deletedMeals, ['b-2']);
    expect(find.text('기록을 지웠어요'), findsOneWidget);
    expect(find.text('D+7/28'), findsOneWidget, reason: '고른 날짜 그대로 홈');
    expect(_rowsOf(MealSlot.breakfast), findsOneWidget);
  });

  testWidgets('지우기가 404 면 이미 지워진 것으로 본다', (tester) async {
    final api = _PastApi(isFinal: false)..deleteError = const ApiException(404, 'not found');
    final c = await _pump(tester, api);
    await _pickPastDay(tester, c);
    await tester.tap(_rowsOf(MealSlot.breakfast).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('기록 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    expect(find.text('기록을 지웠어요'), findsOneWidget);
    expect(_rowsOf(MealSlot.breakfast), findsOneWidget);
    expect([for (final m in c.read(pastMealsProvider(_past)).value!) m.serverId], ['b-1']);
  });

  testWidgets('지우기를 서버가 거절하면 되돌리고 문구를 그대로 보여 준다 · 연결 오류는 다시 지워 달라고', (tester) async {
    final api = _PastApi(isFinal: false)..deleteError = const ApiException(422, '확정된 날짜의 기록은 지울 수 없어요');
    final c = await _pump(tester, api);
    await _pickPastDay(tester, c);
    final n = c.read(pastMealsProvider(_past).notifier);
    expect(await n.delete('b-2'), '확정된 날짜의 기록은 지울 수 없어요');
    expect([for (final m in c.read(pastMealsProvider(_past)).value!) m.serverId], ['b-1', 'b-2']);
    api.deleteError = const ApiException(0, 'offline');
    expect(await n.delete('b-1'), '연결이 불안정해요. 잠시 뒤 다시 지워 주세요');
    expect([for (final m in c.read(pastMealsProvider(_past)).value!) m.serverId], ['b-1', 'b-2']);
    await tester.pumpAndSettle();
  });

  testWidgets('날짜와 함께 없는 끼니 키로 열면 홈으로 돌아가 안내', (tester) async {
    await _pump(tester, _PastApi(isFinal: false), location: R.meal(MealSlot.lunch, meal: 'gone-1', date: _past));
    expect(find.text('기록을 찾지 못했어요'), findsOneWidget);
    expect(find.text('점심 확인'), findsNothing);
  });

  testWidgets('모의 모드 지난 날은 지금처럼 장부 요약(누를 수 없음)', (tester) async {
    final c = await pumpApp(tester);
    c.read(selectedDayProvider.notifier).set(7);
    await tester.pumpAndSettle();
    expect(find.byType(MealRow), findsNothing);
    final cards = tester.widgetList<MealSlotCard>(find.byType(MealSlotCard));
    expect(cards, hasLength(4));
    expect(cards.every((w) => w.onTap == null), isTrue);
  });

  _fixRound1();
}

ServerMeal _noItems(String id, MealStatus status) =>
    ServerMeal(id: id, status: status, version: 1, slot: MealSlot.lunch, capturedAt: DateTime.utc(2026, 10, 12, 3, 30));

ServerMeal _auto() => ServerMeal(id: 'b-1', status: MealStatus.auto, version: 2, confirmedKcal: 546, aiKcal: 420, slot: MealSlot.breakfast,
    capturedAt: DateTime.utc(2026, 10, 11, 22, 40), items: [_item('계란토스트', 420)]);

const _ledgerErrorNote = '점수 정보를 불러오지 못했어요. 당겨서 새로고침해 주세요';

void _fixRound1() {
  testWidgets('확정을 서버가 거절(412)하면 되돌리고 그 날짜 끼니와 장부를 다시 읽는다', (tester) async {
    final api = _PastApi(isFinal: false);
    final c = await _pump(tester, api);
    await _pickPastDay(tester, c);
    final n = c.read(pastMealsProvider(_past).notifier);
    final items = n.byKey('b-2')!.items;
    // 그새 다른 기기에서 바뀜(version 3)
    api.meals = [api.meals.first, ServerMeal(id: 'b-2', status: MealStatus.draft, version: 3, aiKcal: 300, slot: MealSlot.breakfast,
        capturedAt: DateTime.utc(2026, 10, 12, 1, 10), items: [_item('요거트 볼', 300)])];
    api.confirmError = const ApiException(412, 'version mismatch');
    final ledger = api.ledgerReads, meals = api.mealReads;
    expect(await n.confirm('b-2', items, 300, finalDay: false), apiErrorText(const ApiException(412, '')));
    await tester.pumpAndSettle();
    expect(api.mealReads, greaterThan(meals));
    expect(api.ledgerReads, greaterThan(ledger));
    final b2 = c.read(pastMealsProvider(_past)).value!.firstWhere((m) => m.serverId == 'b-2');
    expect(b2.version, 3, reason: '다음 확정은 새 버전으로');
    expect(b2.status, MealStatus.draft);
  });

  testWidgets('지우기를 서버가 거절(422)하면 그 날짜 끼니와 장부를 다시 읽는다', (tester) async {
    final api = _PastApi(isFinal: false)..deleteError = const ApiException(422, '확정된 날짜의 기록은 지울 수 없어요');
    final c = await _pump(tester, api);
    await _pickPastDay(tester, c);
    final ledger = api.ledgerReads, meals = api.mealReads;
    expect(await c.read(pastMealsProvider(_past).notifier).delete('b-2'), '확정된 날짜의 기록은 지울 수 없어요');
    await tester.pumpAndSettle();
    expect(api.mealReads, greaterThan(meals));
    expect(api.ledgerReads, greaterThan(ledger));
    expect(_rowsOf(MealSlot.breakfast), findsNWidgets(2));
  });

  testWidgets('장부를 못 읽으면 P7 은 버튼 없이 안내만(보기만 안내는 없음)', (tester) async {
    final api = _PastApi(isFinal: false)..ledgerError = const ApiException(500, 'boom');
    await _pump(tester, api, location: R.meal(MealSlot.breakfast, meal: 'b-2', date: _past));
    expect(find.text('요거트 볼'), findsWidgets);
    expect(find.text(_ledgerErrorNote), findsOneWidget);
    expect(_cta('확정'), findsNothing);
    expect(find.byTooltip('기록 지우기'), findsNothing);
    expect(find.textContaining('볼 수만 있어요'), findsNothing);
  });

  testWidgets("항목 없는 끼니: '확정된 음식 항목이 없어요'는 보기만일 때만", (tester) async {
    final api = _PastApi(isFinal: false)..ledgerError = const ApiException(500, 'boom');
    api.meals = [...api.meals, _noItems('l-1', MealStatus.failed)];
    await _pump(tester, api, location: R.meal(MealSlot.lunch, meal: 'l-1', search: true, date: _past));
    expect(find.text(_ledgerErrorNote), findsOneWidget);
    expect(find.text('확정된 음식 항목이 없어요'), findsNothing);
  });

  testWidgets("항목 없는 끼니 + 기한 지남: '확정된 음식 항목이 없어요'", (tester) async {
    final api = _PastApi(isFinal: true, finalizedAt: DateTime.now().subtract(const Duration(hours: 49)));
    api.meals = [...api.meals, _noItems('l-1', MealStatus.failed)];
    await _pump(tester, api, location: R.meal(MealSlot.lunch, meal: 'l-1', search: true, date: _past));
    expect(find.text('확정된 음식 항목이 없어요'), findsOneWidget);
  });

  testWidgets('자동 확정 끼니: 기한이 지나면 고쳐 저장하라는 문구를 빼고, 기한 안이면 남긴다', (tester) async {
    final closed = _PastApi(isFinal: true, finalizedAt: DateTime.now().subtract(const Duration(hours: 49)))..meals = [_auto()];
    await _pump(tester, closed, location: R.meal(MealSlot.breakfast, meal: 'b-1', date: _past));
    expect(find.textContaining('09:00까지 확정하지 않아'), findsOneWidget);
    expect(find.textContaining('아래 항목을 고쳐 저장하면'), findsNothing);
  });

  testWidgets('자동 확정 끼니: 기한 안이면 고쳐 저장 문구가 있다', (tester) async {
    final open = _PastApi(isFinal: true, finalizedAt: DateTime.now().subtract(const Duration(hours: 47)))..meals = [_auto()];
    await _pump(tester, open, location: R.meal(MealSlot.breakfast, meal: 'b-1', date: _past));
    expect(find.textContaining('아래 항목을 고쳐 저장하면'), findsOneWidget);
  });

  testWidgets('그 날짜 끼니를 못 읽으면 서버 문구로 안내하고 홈으로', (tester) async {
    final api = _PastApi(isFinal: false)..mealsError = const ApiException(500, '잠시 뒤에 다시 열어 주세요');
    await _pump(tester, api, location: R.meal(MealSlot.breakfast, meal: 'b-2', date: _past));
    expect(find.text('잠시 뒤에 다시 열어 주세요'), findsOneWidget);
    expect(find.text('기록을 찾지 못했어요'), findsNothing);
    expect(find.text('아침 확인'), findsNothing);
  });
}

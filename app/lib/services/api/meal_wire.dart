import '../../core/engine/engine.dart';
import '../../data/models.dart';
import 'challory_api.dart';

/// 먹은 양 배수 범위(서버 meal_items.portion_multiplier 0.1~3.0, D60)
const minPortionTenths = 1;
const maxPortionTenths = 30;

/// 배수 → 0.1 단위 정수(1.2 → 12). 범위 밖은 0.1~3.0 으로 맞춘다.
int portionTenths(double mult) => (mult * 10).round().clamp(minPortionTenths, maxPortionTenths);

/// P7 항목 → 서버 confirm_meal 항목 형식.
/// 서버 kcal = serving_kcal × portion_multiplier × count × (broth_off ? 0.6 : 1) — 앱 [MealItem.rawKcal] 과 같은 값이 되게 보낸다.
Map<String, dynamic> mealItemToWire(MealItem it) {
  // 개수 항목은 개수 × 1개 크기 배수, 그 밖(밥·국·반찬)은 먹은 양 배수만. 배수는 0.1 단위로(D60)
  final count = it.kind == ItemKind.count ? it.count : 1;
  final mult = portionTenths(it.mult) / 10;
  final code = it.foodCodes.length > it.cand ? it.foodCodes[it.cand] : null;
  return {
    'chosen_name': it.name,
    'food_code': ?code,
    'serving_kcal': it.candKcal[it.cand],
    'name_candidates': it.candidates,
    // 다시 열었을 때 후보 칩·국물 토글이 그대로 나오게 서버가 함께 저장한다
    'candidate_kcal': it.candKcal,
    if (it.foodCodes.length == it.candidates.length) 'candidate_food_codes': it.foodCodes,
    'has_broth': it.kind == ItemKind.soup,
    'count': count,
    'portion_multiplier': mult,
    'broth_off': it.kind == ItemKind.soup && it.brothOff,
    'eaten': it.checked,
    'input_type': switch (it.confidence) { Confidence.manual => 'manual', _ => it.fromSearch ? 'search' : 'ai' },
  };
}

/// 서버 초안 항목 → P7 편집 항목. 개수와 배수를 모두 살려 서버와 같은 kcal 로 연다.
MealItem mealItemFromServer(ServerMealItem s, int index) {
  final name = s.candidates[s.chosen];
  // 가공식품(상품, D63)은 이름이 밥으로 끝나도 밥(공기)이 아니라 상품 단위로 연다
  final product = s.unitLabel;
  final riceOrSoup = s.hasBroth || (product == null && name.endsWith('밥'));
  // 밥·국이 개수 2 이상이면 개수를 먹은 양 배수로 접는다(2 × 1.5 → 3.0공기).
  // 3.0 을 넘어 줄이면 kcal 이 바뀌는 행과 그 밖의 개수 2 이상 행(옛 반찬 젓가락 수 포함)은 개수 항목.
  final foldedTenths = (s.portionMultiplier * s.count * 10).round();
  final ItemKind kind;
  if (riceOrSoup && (s.count <= 1 || foldedTenths <= maxPortionTenths)) {
    kind = s.hasBroth ? ItemKind.soup : ItemKind.rice;
  } else {
    kind = s.count > 1 ? ItemKind.count : ItemKind.side;
  }
  final folded = kind != ItemKind.count && s.count > 1;
  final count = kind == ItemKind.count ? s.count : 1;
  return MealItem(
    id: 's$index',
    candidates: s.candidates,
    candKcal: [for (final k in s.candidateKcal) k.round()],
    foodCodes: s.candidateFoodCodes,
    portion: product ?? (kind == ItemKind.rice ? '1공기' : (kind == ItemKind.count ? '개' : '1인분')),
    unitLabels: [for (var i = 0; i < s.candidates.length; i++) i == s.chosen ? product : null],
    kind: kind,
    baseCount: count,
    count: count,
    mult: (folded ? foldedTenths.clamp(minPortionTenths, maxPortionTenths) : portionTenths(s.portionMultiplier)) / 10,
    confidence: s.needsCheck ? Confidence.check : Confidence.sure,
    cand: s.chosen,
    checked: s.eaten,
    brothOff: kind == ItemKind.soup && s.brothOff,
  );
}

String slotWire(MealSlot s) => s.name;

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
  final isCount = it.kind == ItemKind.count;
  // 개수 항목은 개수로, 그 밖(밥·국·반찬)은 먹은 양 배수(0.1 단위)로
  final count = isCount ? it.count : 1;
  final mult = isCount ? 1.0 : portionTenths(it.mult) / 10;
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

/// 서버 초안 항목 → P7 편집 항목
MealItem mealItemFromServer(ServerMealItem s, int index) {
  final name = s.candidates[s.chosen];
  // 개수가 2 이상인 행은 개수 항목(옛 반찬 행은 젓가락 수를 개수로 저장했다)
  final kind = s.hasBroth
      ? ItemKind.soup
      : (name.endsWith('밥') ? ItemKind.rice : (s.count > 1 ? ItemKind.count : ItemKind.side));
  return MealItem(
    id: 's$index',
    candidates: s.candidates,
    candKcal: [for (final k in s.candidateKcal) k.round()],
    foodCodes: s.candidateFoodCodes,
    portion: kind == ItemKind.rice ? '1공기' : (kind == ItemKind.count ? '개' : '1인분'),
    kind: kind,
    baseCount: s.count,
    count: s.count,
    mult: kind == ItemKind.count ? 1 : portionTenths(s.portionMultiplier) / 10,
    confidence: s.needsCheck ? Confidence.check : Confidence.sure,
    cand: s.chosen,
    checked: s.eaten,
    brothOff: kind == ItemKind.soup && s.brothOff,
  );
}

String slotWire(MealSlot s) => s.name;

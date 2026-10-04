import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine/engine.dart' show MealStatus;
import '../data/models.dart';
import '../services/api/challory_api.dart';
import '../services/api/meal_wire.dart';
import '../services/health/health_models.dart' show kstDateString;
import '../services/health/health_source.dart' show newUuidV4;
import 'app_state.dart';
import 'session.dart';

/// 지난 날 끼니를 어디까지 고칠 수 있는지(서버 규칙과 같음).
/// [full] 확정 전: 확정·지우기 · [correctOnly] 확정 뒤 수정 기한 안: 정정(확정)만 · [readOnly] 기한이 지남: 보기만.
enum PastEditMode { full, correctOnly, readOnly }

/// 수정 기한 기본값(challenge_rules.edit_window). 서버 규칙 값은 [currentEditWindow].
const kEditWindow = Duration(hours: 48);

/// 지금 챌린지의 수정 기한(서버 규칙 값, 없으면 48시간)
Duration get currentEditWindow => Duration(hours: currentSession.editWindowHours);

/// 확정 전이면 [PastEditMode.full], 확정 뒤 [finalizedAt] + [editWindow] 까지는 정정만, 그 뒤로는 보기만.
/// 확정됐는데 확정 시각을 모르면 짐작하지 않고 보기만.
PastEditMode pastEditMode({required bool isFinal, required DateTime? finalizedAt, required DateTime now, Duration editWindow = kEditWindow}) {
  if (!isFinal) return PastEditMode.full;
  if (finalizedAt == null) return PastEditMode.readOnly;
  return now.isAfter(finalizedAt.add(editWindow)) ? PastEditMode.readOnly : PastEditMode.correctOnly;
}

/// 장부의 [localDate] 행으로 판정한다. 장부를 아직 못 받았으면 null(버튼을 숨기고 기다린다).
/// 그 날짜 행이 없으면 아직 점수가 확정되지 않은 날이다(확정하면 서버가 행을 남긴다).
PastEditMode? pastEditModeOn(List<LedgerRow>? ledger, String localDate, {DateTime? now}) {
  if (ledger == null) return null;
  final row = ledger.where((r) => r.localDate == localDate).firstOrNull;
  if (row == null) return PastEditMode.full;
  return pastEditMode(isFinal: !row.provisional, finalizedAt: row.finalizedAt, now: now ?? DateTime.now(), editWindow: currentEditWindow);
}

/// 챌린지 [start] 기준 [day]일째(1~)의 날짜(YYYY-MM-DD). 날짜 필드만으로 UTC 에서 계산해
/// 기기 시간대의 서머타임(하루가 23·25시간)과 무관하다.
String localDateOfDay(DateTime start, int day) => kstDateString(DateTime.utc(start.year, start.month, start.day + day - 1));

/// [localDate](YYYY-MM-DD)가 챌린지 [start] 기준 며칠째(1~)인지. 날짜가 아니면 null.
int? dayOfLocalDate(DateTime start, String localDate) {
  final d = DateTime.tryParse(localDate);
  if (d == null) return null;
  return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(start.year, start.month, start.day)).inDays + 1;
}

/// 지난 날(YYYY-MM-DD, KST) 본인 끼니. 오늘 목록([mealsProvider])과 따로 둔다(오늘 엔진 입력에 섞이지 않게).
/// 서버 모드만 읽는다. 모의 모드는 빈 목록(홈은 지금처럼 장부 요약을 보여 준다).
/// 확정·지우기는 화면을 먼저 바꾸고 서버가 거절하면 되돌린다([MealsNotifier] 와 같은 규칙).
class PastMealsNotifier extends AsyncNotifier<List<MealRecord>> {
  PastMealsNotifier(this.localDate);
  final String localDate;

  @override
  Future<List<MealRecord>> build() async {
    final api = ref.watch(apiProvider);
    if (!api.isRemote) return const [];
    return mealRecordsFromServer(await api.fetchMealsOn(localDate));
  }

  List<MealRecord> get _list => state.value ?? const [];

  /// [key](로컬 키 또는 서버 id)의 끼니. 없으면 null.
  MealRecord? byKey(String key) => _list.where((m) => m.matches(key)).firstOrNull;

  void _set(List<MealRecord> list) => state = AsyncData(list);
  void _put(MealRecord m) => _set([for (final x in _list) x.localKey == m.localKey ? m : x]);

  /// 서버에서 이 날짜 끼니를 다시 읽는다(못 읽으면 지금 목록을 그대로 둔다)
  Future<void> _reload() async {
    try {
      final rows = await ref.read(apiProvider).fetchMealsOn(localDate);
      if (ref.mounted) _set(mealRecordsFromServer(rows));
    } catch (_) {}
  }

  /// 확정·정정(P7). [finalDay] 면(확정된 날짜의 수정) 정정(corrected)으로 둔다. 이미 확정된 끼니를 고쳐도 정정.
  /// 서버가 거절하면 이전 상태로 되돌리고 서버 문구를 돌려준다(성공 시 null). 성공하든 거절되든 장부와 이 날짜 끼니를 다시 읽는다.
  Future<String?> confirm(String key, List<MealItem> items, double total, {required bool finalDay, double? aiKcal}) async {
    final prev = byKey(key);
    if (prev == null) return '기록을 찾지 못했어요';
    final id = prev.serverId;
    if (id == null) return '아직 서버에 올라가지 않은 기록이에요';
    final corrected = finalDay || isCountedStatus(prev.status);
    final names = items.where((i) => i.checked).map((i) => i.name).take(2).join(' · ');
    _put(prev.copyWith(
      slot: slotAfterConfirm(prev.slot, total, snackKcal: engine.rules.snackKcal),
      status: corrected ? MealStatus.corrected : MealStatus.confirmed,
      kcal: total,
      aiKcal: aiKcal ?? prev.aiKcal,
      items: items,
      title: names.isEmpty ? prev.title : names,
      corrected: corrected,
      noAnalysis: false,
    ));
    final link = ref.keepAlive(); // 응답 전에 홈이 다른 날짜로 바뀌어도 결과를 반영한다
    try {
      final r = await ref.read(apiProvider).confirmMeal(id, prev.version, [for (final it in items) mealItemToWire(it)], idempotencyKey: newUuidV4());
      if (!ref.mounted) return null;
      final cur = byKey(key);
      if (cur != null) _put(cur.copyWith(version: r.version, kcal: r.confirmedKcal, slot: r.slot));
      ref.invalidate(ledgerProvider); // 서버가 그날 점수를 다시 계산함
      unawaited(_reload());
      return null;
    } catch (e) {
      if (ref.mounted) {
        if (byKey(key) != null) _put(prev);
        _refreshAfterRefusal();
      }
      return apiErrorText(e);
    } finally {
      link.close();
    }
  }

  /// 지우기(P7, 확정 전 날짜만). 화면에서 먼저 빼고 서버 meal-delete 를 부른다.
  /// 404 는 이미 지워진 것으로 본다. 서버가 거절하면 제자리에 되돌리고 안내 문구를 돌려준다.
  Future<String?> delete(String key) async {
    final list = _list;
    final i = list.indexWhere((m) => m.matches(key));
    if (i < 0) return null;
    final prev = list[i];
    final id = prev.serverId;
    if (id == null) return '아직 서버에 올라가지 않은 기록이에요';
    _set([...list]..removeAt(i));
    void deleted() {
      ref.invalidate(ledgerProvider);
      unawaited(forgetMealPhoto(ref, id));
      unawaited(_reload());
    }

    final link = ref.keepAlive();
    try {
      await ref.read(apiProvider).deleteMeal(id, idempotencyKey: newUuidV4());
      if (ref.mounted) deleted();
      return null;
    } on ApiException catch (e) {
      if (e.status == 404) {
        if (ref.mounted) deleted();
        return null;
      }
      _restore(i, prev);
      _refreshAfterRefusal();
      return e.status == 0 ? '연결이 불안정해요. 잠시 뒤 다시 지워 주세요' : apiErrorText(e);
    } catch (e) {
      _restore(i, prev);
      _refreshAfterRefusal();
      return apiErrorText(e);
    } finally {
      link.close();
    }
  }

  /// 서버가 거절함: 버전·확정 여부가 바뀌었을 수 있으니 장부와 이 날짜 끼니를 다시 읽는다(다음 시도는 새 값으로)
  void _refreshAfterRefusal() {
    if (!ref.mounted) return;
    ref.invalidate(ledgerProvider);
    unawaited(_reload());
  }

  void _restore(int i, MealRecord prev) {
    if (!ref.mounted) return;
    final list = _list;
    if (list.any((m) => m.localKey == prev.localKey || m.serverId == prev.serverId)) return;
    _set([...list]..insert(i.clamp(0, list.length), prev));
  }
}

/// 지난 날 끼니(날짜별). 그 날짜를 보는 화면이 없으면 버린다(다시 열면 새로 읽음).
final pastMealsProvider = AsyncNotifierProvider.autoDispose.family<PastMealsNotifier, List<MealRecord>, String>(PastMealsNotifier.new);

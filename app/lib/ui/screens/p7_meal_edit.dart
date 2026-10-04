import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../../state/past_meals.dart';
import '../../services/health/health_source.dart' show newUuidV4;
import '../../services/share/meal_share.dart';
import '../widgets/common.dart';
import '../widgets/meal_share_card.dart';
import '../../state/session.dart';


/// P7 식사 확인·편집. 후보 칩(이름과 kcal이 함께 바뀜) · 분량(반 공기/1공기/곱빼기) · 국물 −40% ·
/// 개수 스테퍼 · 먹은 것만 체크 · 실시간 합계. '확정'은 모의 상태를 갱신하고 P5가 엔진으로 다시 계산한다.
class MealEditScreen extends ConsumerStatefulWidget {
  const MealEditScreen({super.key, required this.slot, this.mealKey, this.searchOnly = false, this.date});
  final MealSlot slot;

  /// 연 끼니의 키(로컬 키 또는 서버 id). 없거나 못 찾으면 [slot] 에 새로 기록한다.
  final String? mealKey;
  final bool searchOnly;

  /// 지난 날(YYYY-MM-DD)의 끼니를 열 때 그 날짜. 끼니는 [pastMealsProvider] 에서 읽고,
  /// 확정·지우기는 서버 규칙([pastEditMode])대로만 연다. 건너뜀·공유는 오늘만. null 이면 오늘.
  final String? date;

  @override
  ConsumerState<MealEditScreen> createState() => _MealEditScreenState();
}

class _MealEditScreenState extends ConsumerState<MealEditScreen> {
  late List<MealItem> _items;
  late double _aiTotal;
  late MealRecord _origin;

  /// 이 화면이 다루는 끼니의 키(새 기록이면 확정할 때 이 키로 더해진다)
  late String _key;

  /// `meal=` 키로 열었는데 그 끼니가 목록에 없음 → 홈으로 돌아간다
  late bool _missing;

  /// 연 끼니를 찾아 화면 값을 채웠는지(지난 날은 그 날짜 끼니를 읽은 뒤에 채운다)
  bool _inited = false;

  /// AI 분석을 기다리는 중('지금 확정' 직후 · 분석 중 끼니를 연 경우). 초안이 오면 그 항목으로 바꾼다.
  late bool _waiting;

  /// 분석이 음식을 찾지 못함 → 검색으로 확정
  bool _searchFallback = false;

  /// 이 폰에 보관된 사진(공유용 7일 보관본). 없으면 색 배경
  Uint8List? _photo;

  /// 사진 칸 비율([photoBoxAspect])
  double _photoAspect = 4 / 3;

  @override
  void initState() {
    super.initState();
    if (widget.date == null) {
      final key = widget.mealKey;
      _init(key == null ? null : ref.read(mealsProvider.notifier).byKey(key));
    }
  }

  /// 연 끼니로 화면 값을 채운다. 오늘은 initState 에서, 지난 날은 그 날짜 끼니를 읽은 첫 build 에서.
  /// [loadError] 가 있으면(그 날짜 끼니를 못 읽음) '기록을 찾지 못했어요' 대신 그 문구로 알린다.
  void _init(MealRecord? found, {String? loadError}) {
    _inited = true;
    final key = widget.mealKey;
    final past = widget.date != null;
    _origin = found ?? MealRecord(slot: widget.slot, localKey: 'local-${newUuidV4()}');
    _key = _origin.key;
    // 연 끼니가 없음(그새 지워짐 등): 예시 항목을 띄우지 않고 홈으로 돌아가 알린다. 키 없이 연 새 기록은 그대로.
    // 지난 날은 새로 기록하지 않으므로 키가 없어도 홈으로.
    _missing = (key != null || past) && found == null;
    if (_missing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showToast(context, loadError ?? '기록을 찾지 못했어요');
        context.go(R.home);
      });
    }
    // 지난 날은 분석을 기다리지 않는다: 항목이 없으면 검색으로
    final analyzing = !_missing && !widget.searchOnly && _origin.status == MealStatus.captured && !_origin.noAnalysis && !_origin.pendingUpload;
    _waiting = analyzing && !past;
    if (widget.searchOnly || _waiting || _missing) {
      _items = const [];
      _aiTotal = 0;
    } else {
      _setDraft(_origin);
      if (past && _items.isEmpty) _searchFallback = true;
    }
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    final id = _origin.serverId;
    if (id == null) return;
    final bytes = await ref.read(sharePhotoStoreProvider).get(id);
    if (mounted && bytes != null) {
      setState(() {
        _photo = bytes;
        _photoAspect = photoBoxAspect(bytes);
      });
    }
  }

  void _setDraft(MealRecord m) {
    // 지난 날 서버 끼니는 예시 항목으로 채우지 않는다
    _items = m.items.isNotEmpty || widget.date != null ? m.items : mockDraftItems(widget.slot);
    _aiTotal = m.aiKcal ?? _items.fold(0.0, (a, i) => a + i.rawKcal);
  }

  /// 기다리는 동안 끼니가 초안·분석 불가로 바뀌면 화면을 바꾼다
  void _onMealChanged(MealRecord next) {
    if (!_waiting) return;
    if (next.status == MealStatus.draft) {
      setState(() {
        _waiting = false;
        _origin = next;
        _setDraft(next);
      });
    } else if (next.status == MealStatus.failed || next.noAnalysis) {
      setState(() {
        _waiting = false;
        _origin = next;
        _searchFallback = true;
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  double get _total => _items.fold(0.0, (a, i) => a + i.kcal);

  void _update(int index, MealItem Function(MealItem) f) => setState(() => _items = [for (var i = 0; i < _items.length; i++) i == index ? f(_items[i]) : _items[i]]);

  void _addFood(String name, int kcal) {
    setState(() => _items = [
          ..._items,
          MealItem(id: 'u${_items.length}_$name', candidates: [name], candKcal: [kcal], portion: '1인분', kind: ItemKind.count, confidence: Confidence.manual),
        ]);
  }

  /// 음식 검색(식약처 DB) · 최근 음식 시트. 고른 음식은 1인분 kcal·food_code 로 항목에 들어간다(확정 시 input_type=search).
  Future<void> _openSearch({int? replaceIndex}) async {
    final picked = await showChSheet<Object>(context, builder: (_) => const _FoodSearchSheet());
    if (!mounted || picked == null) return;
    if (picked == _FoodSearchSheet.manual) {
      await _manualEntry();
      return;
    }
    final hit = picked as FoodHit;
    MealItem item(String id) => MealItem(
          id: id,
          candidates: [hit.name],
          candKcal: [hit.kcal],
          foodCodes: [hit.foodCode],
          portion: '1인분',
          kind: ItemKind.count,
          confidence: Confidence.sure,
          fromSearch: true,
        );
    if (replaceIndex != null) {
      _update(replaceIndex, (it) => item(it.id));
    } else {
      setState(() => _items = [..._items, item('s${_items.length}_${hit.name}')]);
    }
  }

  Future<void> _manualEntry() async {
    final name = TextEditingController();
    final kcal = TextEditingController();
    final ok = await showChDialog<bool>(
      context,
      title: '직접 입력',
      body: Column(children: spaced([
        ChInput(controller: name, numeric: false, label: '음식 이름', hint: '예: 엄마표 김밥'),
        ChInput(controller: kcal, label: 'kcal (추정)', unit: 'kcal', hint: '350', maxLength: 5),
      ], gap: 10)),
      actions: [
        Builder(builder: (ctx) => ChButton('취소', kind: BtnKind.quiet, onPressed: () => Navigator.of(ctx).pop(false))),
        Builder(builder: (ctx) => ChButton('추가', onPressed: () => Navigator.of(ctx).pop(true))),
      ],
    );
    final k = int.tryParse(kcal.text);
    if (ok == true && name.text.trim().isNotEmpty && k != null && k > 0) _addFood(name.text.trim(), k);
    name.dispose();
    kcal.dispose();
  }

  Future<void> _confirm() async {
    final total = _total;
    if (total <= 0) return;
    final auto = _origin.status == MealStatus.auto;
    if (!widget.searchOnly && !auto && _aiTotal > 0 && total < 0.5 * _aiTotal) {
      final go = await showChDialog<bool>(
        context,
        title: 'AI 추정보다 50% 넘게 낮아요',
        body: Txt('AI 초안 약 ${fmtInt(_aiTotal)} kcal → 현재 약 ${fmtInt(total)} kcal(${fmtPct(total / _aiTotal)}). 그대로 확정할까요? 운영자가 확인할 수 있어요.'),
        actions: [
          Builder(builder: (ctx) => ChButton('다시 볼게요', kind: BtnKind.quiet, onPressed: () => Navigator.of(ctx).pop(false))),
          Builder(builder: (ctx) => ChButton('그대로 확정', onPressed: () => Navigator.of(ctx).pop(true))),
        ],
      );
      if (go != true) return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final key = _key;
    final aiKcal = _aiTotal > 0 ? _aiTotal : null;
    final MealSlot slot;
    final Future<String?> pending;
    final date = widget.date;
    if (date != null) {
      // 지난 날: 확정된 날짜면 정정으로
      final past = ref.read(pastMealsProvider(date).notifier);
      slot = past.byKey(key)?.slot ?? widget.slot;
      final finalDay = _pastMode() != PastEditMode.full;
      pending = past.confirm(key, _items, total, finalDay: finalDay, aiKcal: aiKcal);
    } else {
      final meals = ref.read(mealsProvider.notifier);
      slot = meals.byKey(key)?.slot ?? widget.slot; // 서버가 슬롯을 옮겼으면 그 슬롯
      pending = meals.confirm(slot, _items, total, key: key, aiKcal: aiKcal);
    }
    final snack = slot != MealSlot.snack && total < engine.rules.snackKcal;
    // 화면은 바로 홈으로(낙관적 반영), 서버 확정(meal-confirm / meal-manual)이 안 되면 되돌리고 알린다
    _goHome();
    if (snack) {
      messenger.showSnackBar(const SnackBar(content: Text('150 kcal 미만이라 간식으로 옮겼어요')));
    }
    final err = await pending;
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text('${slotLabel[slot]}을 확정했어요'),
      duration: const Duration(seconds: 6),
      persist: false,
      // 공유 카드는 오늘 끼니만(카드에 오늘 날짜가 찍힌다)
      action: date != null
          ? null
          : SnackBarAction(label: '공유', onPressed: () {
              final ctx = rootNavigatorKey.currentContext;
              if (ctx != null) showMealShareSheet(ctx, key);
            }),
    ));
  }

  /// 지난 날 끼니를 어디까지 고칠 수 있는지(장부를 아직 못 받았으면 null). 오늘이면 null.
  PastEditMode? _pastMode({bool watch = false}) {
    final date = widget.date;
    if (date == null) return null;
    final ledger = watch ? ref.watch(ledgerProvider).value : ref.read(ledgerProvider).value;
    return pastEditModeOn(ledger, date);
  }

  /// 홈으로. 지난 날 끼니였으면 홈도 그 날짜를 보여 준다(바뀐 목록이 바로 보이게).
  void _goHome() {
    final date = widget.date;
    final day = date == null ? null : dayOfLocalDate(curChallenge.start, date);
    if (day != null) ref.read(selectedDayProvider.notifier).set(day);
    context.go(R.home);
  }

  /// 이 끼니 지우기: 확인 창 → 서버 meal-delete → 홈으로 돌아가 안내. 서버가 거절하면 목록에 되돌리고 그 문구를 보여 준다.
  Future<void> _delete() async {
    final ok = await showChDialog<bool>(
      context,
      title: '이 기록을 지울까요?',
      body: const Txt('사진과 음식 기록이 지워지고 점수가 다시 계산돼요. 되돌릴 수 없어요.'),
      actions: [
        Builder(builder: (ctx) => ChButton('취소', kind: BtnKind.quiet, onPressed: () => Navigator.of(ctx).pop(false))),
        Builder(builder: (ctx) => ChButton('지우기', kind: BtnKind.critical, onPressed: () => Navigator.of(ctx).pop(true))),
      ],
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final date = widget.date;
    final pending = date == null ? ref.read(mealsProvider.notifier).delete(_key) : ref.read(pastMealsProvider(date).notifier).delete(_key);
    _goHome();
    final err = await pending;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(err ?? '기록을 지웠어요'), duration: const Duration(milliseconds: 2200)));
  }

  Future<void> _skip() async {
    final messenger = ScaffoldMessenger.of(context);
    final pending = ref.read(mealsProvider.notifier).skip(widget.slot);
    context.go(R.home);
    final err = await pending;
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final slot = widget.slot;
    final label = slotLabel[slot]!;
    final date = widget.date;
    final isPast = date != null;
    final List<MealRecord> meals;
    if (date != null) {
      // 지난 날: 그 날짜 끼니를 읽은 뒤에 화면 값을 채운다(못 읽으면 없는 끼니로 보고 홈으로)
      final past = ref.watch(pastMealsProvider(date));
      if (!_inited) {
        if (past.hasValue) {
          final key = widget.mealKey;
          _init(key == null ? null : past.value!.where((m) => m.matches(key)).firstOrNull);
        } else if (past.hasError) {
          _init(null, loadError: apiErrorText(past.error!));
        } else {
          return ChScaffold(title: '$label 확인', backFallback: R.home, children: const [
            Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: CircularProgressIndicator())),
          ]);
        }
      }
      meals = past.value ?? const [];
    } else {
      meals = ref.watch(mealsProvider);
      ref.listen<MealRecord?>(mealsProvider.select((l) => l.where((x) => x.matches(_key)).firstOrNull), (_, next) {
        if (next != null) _onMealChanged(next);
      });
    }
    // 지난 날 끼니를 고칠 수 있는지(오늘이면 null). 장부를 받기 전에는 버튼을 숨기고 기다린다.
    final pastMode = _pastMode(watch: true);
    final canEdit = !isPast || pastMode == PastEditMode.full || pastMode == PastEditMode.correctOnly;
    final readOnlyNote = pastMode == PastEditMode.readOnly;
    // 장부를 못 읽음: 고칠 수 있는지 몰라 버튼을 숨기고 새로고침을 안내한다
    final ledgerError = isPast && pastMode == null && ref.watch(ledgerProvider).hasError;
    // 지금 목록의 이 끼니(새 기록이면 아직 없음)
    final live = meals.where((x) => x.matches(_key)).firstOrNull;
    final skipsUsed = ref.watch(skipsUsedProvider);
    final skipsToday = meals.where((m) => m.status == MealStatus.skipped && m.slot != slot).length;
    final remaining = engine.rules.skipPerWeek - skipsUsed - skipsToday;
    final skipLimit = remaining <= 0 || skipsToday >= engine.rules.skipPerDay;
    // 건너뜀은 끼니를 채운 기록이 없을 때만(비었거나 간식 수준 기록뿐인 슬롯)
    final canSkip = canSkipSlot(meals, slot, snackKcal: engine.rules.snackKcal);
    final total = _total;
    final isSnackLevel = total > 0 && total < engine.rules.snackKcal;
    final auto = _origin.status == MealStatus.auto;
    final m = fmtM(meM);
    // 간식은 대체값이 없어 1.3×AI 그대로 자동 확정(D55). 끼니는 max(M_p, 1.3×AI).
    final isSnackSlot = slot == MealSlot.snack;
    final autoVal = isSnackSlot ? engine.rules.autoConfirm * _aiTotal : engine.autoConfirmValue(curMe.bmr, _aiTotal);
    final autoRule = isSnackSlot ? '1.3×AI' : 'max($m, 1.3×AI)';
    final autoRuleAi = isSnackSlot ? '1.3×AI ${fmtInt(_aiTotal)}' : 'max($m, 1.3×AI ${fmtInt(_aiTotal)})';
    final sure = _items.where((i) => i.confidence == Confidence.sure).length;
    final check = _items.where((i) => i.confidence == Confidence.check).length;
    final unchecked = _items.where((i) => !i.checked).length;
    final searchMode = (widget.searchOnly || _searchFallback) && _items.isEmpty;

    // 사진이 있으면 잘리지 않게 제 비율(세로 4:5 ~ 가로 16:9)로, 없으면 150 높이 띠
    Widget photoBox() => Container(
          height: _photo == null ? 150 : null,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          alignment: Alignment.bottomLeft,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            image: _photo == null ? null : DecorationImage(image: MemoryImage(_photo!), fit: BoxFit.cover),
            gradient: _photo != null
                ? null
                : const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFB3552D), Color(0xFF7A3417), Color(0xFF3B1A0D)]),
          ),
          child: Semantics(
            label: '$label 사진',
            child: Row(children: [
              _Tag('$label${_origin.time.isEmpty ? '' : ' · ${_origin.time}'}'),
              const Spacer(),
              const _Tag('인앱 촬영 · 서버 시각', icon: Icons.photo_camera_rounded),
            ]),
          ),
        );
    // 사진이 있으면 잘리지 않게 제 비율(세로 4:5 ~ 가로 16:9)로, 없으면 150 높이 띠
    Widget photo() => _photo == null ? photoBox() : AspectRatio(aspectRatio: _photoAspect, child: photoBox());

    // 없는 끼니: 첫 프레임 뒤 홈으로 돌아가므로 빈 화면만(확정 버튼 없음)
    if (_missing) return ChScaffold(title: '$label 확인', backFallback: R.home, children: const []);

    if (_waiting) {
      return ChScaffold(
        title: '$label 확인',
        backFallback: R.home,
        gap: 10,
        children: [
          photo(),
          InfoBanner(
            tone: Tone.brand,
            icon: Icons.hourglass_top_rounded,
            child: boldThen(context, 'AI가 음식을 보고 있어요.', ' 보통 몇 초 걸려요. 끝나면 항목이 여기에 나와요.'),
          ),
          const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Center(child: CircularProgressIndicator())),
          ChButton('검색으로 기록', kind: BtnKind.secondary, icon: Icons.search_rounded, onPressed: () => setState(() {
                _waiting = false;
                _searchFallback = true;
              })),
          ChButton('홈에서 기다리기', kind: BtnKind.quiet, onPressed: () => context.go(R.home)),
          const InlineNote(Icons.notifications_rounded, '홈으로 가도 분석은 계속돼요. 끝나면 알려드려요.'),
        ],
      );
    }

    final children = <Widget>[
      photo(),
      if (readOnlyNote) InlineNote(Icons.lock_rounded, '수정 기한(확정 후 ${currentEditWindow.inHours}시간)이 지나 볼 수만 있어요'),
      if (ledgerError) const InlineNote(Icons.info_rounded, '점수 정보를 불러오지 못했어요. 당겨서 새로고침해 주세요'),
      if (searchMode && readOnlyNote)
        const InlineNote(Icons.info_rounded, '확정된 음식 항목이 없어요')
      else if (searchMode && canEdit) ...[
        InfoBanner(
          tone: Tone.warn,
          icon: Icons.search_rounded,
          child: boldThen(context, '음식을 찾지 못했어요.', ' 이름으로 검색해 주세요. 사진은 저장됐고, 확정하기 전까지는 $m kcal로 잠정 계산돼요.', color: c.warn),
        ),
        ChButton('음식 이름 검색 · 최근 음식', kind: BtnKind.secondary, icon: Icons.search_rounded, onPressed: _openSearch),
        ChButton('직접 입력 (이름·kcal)', kind: BtnKind.quiet, icon: Icons.edit_rounded, onPressed: _manualEntry),
      ] else ...[
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              const Txt.cap('현재'),
              const Spacer(),
              Semantics(
                liveRegion: true,
                label: '현재 약 ${fmtInt(total)} kcal',
                child: ExcludeSemantics(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: total),
                    duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 200),
                    builder: (_, v, _) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Txt('약 ', size: 15, color: c.fg2),
                      NumText(fmtInt(v), size: 27, weight: FontWeight.w700, unit: 'kcal'),
                    ]),
                  ),
                ),
              ),
            ]),
            Align(
              alignment: Alignment.centerRight,
              child: Txt.cap('AI 초안 약 ${fmtInt(_aiTotal)} · $sure개 확실 · $check개 확인 필요${unchecked > 0 ? ' · $unchecked개 먹지 않음' : ''}'),
            ),
          ]),
        ),
        if (auto)
          InfoBanner(
            tone: Tone.warn,
            icon: Icons.schedule_rounded,
            child: boldThen(context, '자동 확정 ${fmtInt(autoVal)} kcal', ' · 09:00까지 확정하지 않아 $autoRuleAi으로 계산됐어요.${readOnlyNote ? '' : ' 아래 항목을 고쳐 저장하면 확정값으로 바뀌어요(48시간 안).'}', color: c.warn),
          ),
        if (isSnackLevel)
          InfoBanner(
            tone: Tone.neutral,
            icon: Icons.cookie_rounded,
            child: boldThen(context, '150 kcal 미만은 간식이에요.', '${slot == MealSlot.snack ? ' 섭취에 더해져요.' : ' 확정하면 간식 칸으로 옮겨요(섭취에는 더해져요).'}${!isPast && canSkip && !skipLimit ? ' 이 끼니를 먹지 않았다면 건너뜀을 눌러 주세요.' : ''}', color: c.fg2),
          ),
        for (var i = 0; i < _items.length; i++)
          // 보기만 하는 지난 날 끼니는 항목을 바꿀 수 없다
          IgnorePointer(
            ignoring: !canEdit,
            child: _ItemCard(item: _items[i], onChange: (f) => _update(i, f), onSearch: () => _openSearch(replaceIndex: i), onRemove: () => setState(() => _items = [..._items]..removeAt(i))),
          ),
        if (canEdit) ...[
          ChButton('항목 추가 — 검색 · 최근 음식 · 직접 입력', kind: BtnKind.secondary, icon: Icons.add_rounded, onPressed: _openSearch),
          const InlineNote(Icons.check_box_rounded, '먹은 것만 체크해 두세요. 체크를 풀면 그 항목은 계산에서 빠져요. 이름을 바꾸면 kcal도 함께 바뀌어요.'),
        ],
        if (!isPast || pastMode == PastEditMode.full)
          InlineNote(Icons.schedule_rounded, '09:00까지 확정하지 않으면 $autoRule kcal로 자동 확정돼요. 그 뒤 48시간 안에는 고칠 수 있어요.'),
        const Disclaimer('모든 kcal은 추정이에요 · 확정값만 순위에 반영돼요'),
      ],
    ];
    // 지우기는 서버에 있는 끼니만, 지난 날은 확정 전 날짜만(확정된 날짜는 서버가 거절)
    final canDelete = live?.serverId != null && (!isPast || pastMode == PastEditMode.full);

    return ChScaffold(
      title: slot == MealSlot.snack ? '간식 확인' : '$label 확인',
      backFallback: R.home,
      // 지난 날: 당겨서 장부(고칠 수 있는지)와 그 날짜 끼니를 다시 읽는다
      onRefresh: date == null
          ? null
          : () async {
              ref.invalidate(ledgerProvider);
              ref.invalidate(pastMealsProvider(date));
              await ref.read(ledgerProvider.future).then((_) {}, onError: (_) {});
            },
      actions: [
        // 공유 카드는 오늘 끼니만(카드에 오늘 날짜가 찍힌다)
        if (!isPast && live != null && canShareMeal(live))
          IconButton(onPressed: () => showMealShareSheet(context, _key), tooltip: '공유', icon: Icon(Icons.ios_share_rounded, color: c.fg), constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
        // 서버에 있는 끼니만 지울 수 있다(사진·항목을 서버가 지우고 점수를 다시 계산)
        if (canDelete)
          IconButton(onPressed: _delete, tooltip: '기록 지우기', icon: Icon(Icons.delete_rounded, color: c.fg), constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
      ],
      gap: 10,
      cta: !canEdit
          ? null
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 체크를 모두 풀면 확정할 수 없다(0 kcal 확정 방지) — 왜 버튼이 꺼졌는지 알린다
              if (!searchMode && _items.isNotEmpty && total <= 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Icon(Icons.info_rounded, size: 14, color: c.warn),
                    const SizedBox(width: 4),
                    Expanded(child: Txt.cap('체크한 음식이 없어요. 먹은 것을 체크해 주세요.${canDelete ? ' 먹지 않았다면 위의 휴지통으로 기록을 지워 주세요.' : ''}', color: c.warn)),
                  ]),
                ),
              // 건너뜀은 오늘만
              if (!isPast && skipLimit && !searchMode)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [Icon(Icons.info_rounded, size: 14, color: c.warn), const SizedBox(width: 4), Expanded(child: Txt.cap('이번 주 건너뜀 ${engine.rules.skipPerWeek}회를 모두 썼어요. 안 먹은 끼니는 $m kcal로 계산돼요.', color: c.warn))])),
              Row(children: [
                if (!isPast) ...[
                  ChButton(skipLimit ? '건너뜀' : '건너뜀 (남은 $remaining회)', kind: BtnKind.quiet, expand: false, onPressed: skipLimit || !canSkip ? null : _skip),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: ChButton(
                    // 자동 확정·확정된 날짜의 끼니는 고쳐 저장(정정)
                    '${auto || pastMode == PastEditMode.correctOnly ? '수정 저장' : '확정'}${searchMode ? '' : ' · 약 ${fmtInt(total)} kcal'}',
                    icon: Icons.check_rounded,
                    onPressed: total > 0 ? _confirm : null,
                  ),
                ),
              ]),
            ]),
      children: children,
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: const Color(0x73000000), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 4)],
          Txt(text, size: 11, weight: FontWeight.w600, color: Colors.white),
        ]),
      );
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.onChange, required this.onSearch, required this.onRemove});
  final MealItem item;
  final void Function(MealItem Function(MealItem)) onChange;
  final VoidCallback onSearch;
  final VoidCallback onRemove;

  String _assume() {
    final it = item;
    switch (it.kind) {
      case ItemKind.rice:
        final label = it.mult == 0.5 ? '반 공기' : (it.mult == 1.5 ? '곱빼기' : '1공기');
        return '$label · 약 ${fmtInt((it.grams ?? 0) * it.mult)} g';
      case ItemKind.count:
        final unit = it.portion == '조각' ? '조각' : it.portion.replaceFirst(RegExp('^1'), '');
        return '${it.count}$unit${it.grams != null ? ' · 약 ${fmtInt(it.grams! * it.count)} g' : ''}';
      case ItemKind.soup:
        return '1인분 · 약 ${fmtInt(it.grams ?? 0)} g${it.brothOff ? ' · 국물 안 먹음 −40%' : ''}';
      case ItemKind.side:
        return '${it.portion} · 약 ${fmtInt(it.grams ?? 0)} g';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final it = item;
    final off = !it.checked;
    final conf = switch (it.confidence) {
      Confidence.sure => const ChChip('확실', tone: Tone.good, icon: Icons.check_rounded),
      Confidence.check => const ChChip('확인 필요', tone: Tone.warn, icon: Icons.priority_high_rounded),
      Confidence.manual => const ChChip('직접 입력', icon: Icons.edit_rounded),
    };
    Widget stepper(String dec, String inc, String value, VoidCallback? onDec, VoidCallback? onInc) => Container(
          decoration: BoxDecoration(border: Border.all(color: c.borderStrong), borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(onPressed: onDec, tooltip: dec, icon: const Icon(Icons.remove_rounded, size: 18), constraints: const BoxConstraints(minWidth: 44, minHeight: 40), padding: EdgeInsets.zero),
            SizedBox(width: 32, child: Center(child: Semantics(liveRegion: true, child: NumText(value, size: 16, weight: FontWeight.w700)))),
            IconButton(onPressed: onInc, tooltip: inc, icon: const Icon(Icons.add_rounded, size: 18), constraints: const BoxConstraints(minWidth: 44, minHeight: 40), padding: EdgeInsets.zero),
          ]),
        );
    Widget row(String text, Widget trailing) => Row(children: [Expanded(child: Txt.cap(text, color: c.fg2)), trailing]);

    final candMult = it.kind == ItemKind.count ? it.count : 1;
    return ChCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ChCheck(value: it.checked, onChanged: (v) => onChange((i) => i.copyWith(checked: v)), label: '${it.name} 먹었어요'),
          const SizedBox(width: 2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Txt(it.name, size: 16, weight: FontWeight.w700, color: off ? c.fg2 : c.fg, strike: off),
                  conf,
                ]),
                Txt.cap('가정 분량 · ${_assume()}'),
              ]),
            ),
          ),
          Padding(padding: const EdgeInsets.only(top: 10), child: NumText(fmtInt(it.rawKcal), size: 21, weight: FontWeight.w700, color: off ? c.fg2 : c.fg, unit: 'kcal')),
        ]),
        Opacity(
          opacity: off ? 0.5 : 1,
          child: IgnorePointer(
            ignoring: off,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
              Semantics(
                container: true,
                label: '음식 후보',
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var ci = 0; ci < it.candidates.length; ci++)
                    Semantics(
                      inMutuallyExclusiveGroup: true,
                      checked: ci == it.cand,
                      button: true,
                      label: '${it.candidates[ci]} ${it.candKcal[ci] * candMult} kcal',
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => onChange((i) => i.copyWith(cand: ci)),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 36),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: ci == it.cand ? c.brandSoft : c.bg,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: ci == it.cand ? c.brand : c.border, width: ci == it.cand ? 2 : 1),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Txt(it.candidates[ci], size: 12, weight: ci == it.cand ? FontWeight.w600 : FontWeight.w400, color: ci == it.cand ? c.brand : c.fg),
                            const SizedBox(width: 4),
                            NumText('${it.candKcal[ci] * candMult}', size: 13, color: c.fg2),
                          ]),
                        ),
                      ),
                    ),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onSearch,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.border)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.search_rounded, size: 14, color: c.fg), const SizedBox(width: 2), const Txt('검색', size: 12)]),
                    ),
                  ),
                ]),
              ),
              if (it.kind == ItemKind.rice)
                ChSeg<double>(
                  small: true,
                  label: '분량',
                  items: const [(0.5, '반 공기'), (1.0, '1공기'), (1.5, '곱빼기')],
                  value: it.mult,
                  onChanged: (v) => onChange((i) => i.copyWith(mult: v)),
                ),
              if (it.kind == ItemKind.soup)
                row('국물 안 먹음 (−40%)', ChSwitch(value: it.brothOff, onChanged: (v) => onChange((i) => i.copyWith(brothOff: v)), label: '국물 안 먹음')),
              if (it.kind == ItemKind.count)
                row('개수', stepper('하나 빼기', '하나 더하기', '${it.count}', it.count > 1 ? () => onChange((i) => i.copyWith(count: i.count - 1)) : null, it.count < 9 ? () => onChange((i) => i.copyWith(count: i.count + 1)) : null)),
              if (it.kind == ItemKind.side)
                row('반찬 1젓가락 ≈ 10~15 g', stepper('덜 먹음', '더 먹음', it.mult == it.mult.roundToDouble() ? '${it.mult.round()}' : '${it.mult}', it.mult > 0.5 ? () => onChange((i) => i.copyWith(mult: i.mult - 0.5)) : null, it.mult < 3 ? () => onChange((i) => i.copyWith(mult: i.mult + 1 > 3 ? 3 : i.mult + 1)) : null)),
              if (it.confidence == Confidence.manual)
                Align(alignment: Alignment.centerRight, child: ChLink('항목 삭제', trailing: false, onTap: onRemove)),
            ], gap: 10)),
          ),
        ),
      ], gap: 10)),
    );
  }
}

/// 검색 시트: 입력이 비면 최근 음식, 입력하면 250 ms 뒤 서버 검색(food_search).
class _FoodSearchSheet extends ConsumerStatefulWidget {
  const _FoodSearchSheet();

  /// "직접 입력" 선택 표시
  static const manual = Object();

  @override
  ConsumerState<_FoodSearchSheet> createState() => _FoodSearchSheetState();
}

class _FoodSearchSheetState extends ConsumerState<_FoodSearchSheet> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<FoodHit> _hits = const [];
  bool _loading = true;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _load(v.trim()));
    setState(() {});
  }

  Future<void> _load(String q) async {
    final seq = ++_seq; // 늦게 온 이전 응답은 버린다
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      final hits = q.isEmpty ? await api.recentFoods() : await api.searchFoods(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _hits = const [];
        _loading = false;
        _error = apiErrorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final q = _q.text.trim();
    final label = _loading
        ? (q.isEmpty ? '최근 음식을 불러오고 있어요' : '검색하고 있어요')
        : _error ?? (q.isEmpty ? (_hits.isEmpty ? '최근 30일 동안 확정한 음식이 없어요' : '최근 음식') : (_hits.isEmpty ? '찾는 음식이 없어요 · 직접 입력해 주세요' : '검색 결과 ${_hits.length}건'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
      const Txt.title('음식 검색'),
      ChInput(controller: _q, numeric: false, hint: '음식 이름 검색 (식약처 DB)', leading: Icon(Icons.search_rounded, size: 20, color: c.fg2), onChanged: _onChanged),
      Semantics(liveRegion: true, child: Txt.cap(label, weight: FontWeight.w600, color: _error != null ? c.critical : null)),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final h in _hits)
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => Navigator.of(context).pop(h),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.border)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(h.recent ? Icons.history_rounded : Icons.restaurant_rounded, size: 14, color: c.fg2),
                const SizedBox(width: 4),
                Txt('${h.name} ', size: 13),
                NumText('${h.kcal}', size: 14, color: c.fg2),
              ]),
            ),
          ),
      ]),
      const Txt.cap('kcal 은 1인분 추정치예요. 고른 뒤 분량·개수를 바꿀 수 있어요.'),
      ChButton('직접 입력 (이름·kcal)', kind: BtnKind.secondary, icon: Icons.edit_rounded, onPressed: () => Navigator.of(context).pop(_FoodSearchSheet.manual)),
    ], gap: 12));
  }
}

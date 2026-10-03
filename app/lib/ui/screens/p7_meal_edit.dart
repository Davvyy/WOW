import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../../services/share/meal_share.dart';
import '../widgets/common.dart';
import '../widgets/meal_share_card.dart';
import '../../state/session.dart';


/// P7 식사 확인·편집. 후보 칩(이름과 kcal이 함께 바뀜) · 분량(반 공기/1공기/곱빼기) · 국물 −40% ·
/// 개수 스테퍼 · 먹은 것만 체크 · 실시간 합계. '확정'은 모의 상태를 갱신하고 P5가 엔진으로 다시 계산한다.
class MealEditScreen extends ConsumerStatefulWidget {
  const MealEditScreen({super.key, required this.slot, this.searchOnly = false});
  final MealSlot slot;
  final bool searchOnly;

  @override
  ConsumerState<MealEditScreen> createState() => _MealEditScreenState();
}

class _MealEditScreenState extends ConsumerState<MealEditScreen> {
  late List<MealItem> _items;
  late double _aiTotal;
  late MealRecord _origin;

  @override
  void initState() {
    super.initState();
    _origin = ref.read(mealsProvider.notifier).of(widget.slot);
    if (widget.searchOnly) {
      _items = const [];
      _aiTotal = 0;
    } else {
      _items = _origin.items.isNotEmpty ? _origin.items : mockDraftItems(widget.slot);
      _aiTotal = _origin.aiKcal ?? _items.fold(0.0, (a, i) => a + i.rawKcal);
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
    final snack = widget.slot != MealSlot.snack && total < engine.rules.snackKcal;
    // 화면은 바로 홈으로(낙관적 반영), 서버 확정(meal-confirm / meal-manual)이 안 되면 되돌리고 알린다
    final pending = ref.read(mealsProvider.notifier).confirm(widget.slot, _items, total, aiKcal: _aiTotal > 0 ? _aiTotal : null);
    context.go(R.home);
    if (snack) {
      messenger.showSnackBar(const SnackBar(content: Text('150 kcal 미만은 간식으로 기록돼요 · 끼니 슬롯은 채우지 않아요')));
    }
    final err = await pending;
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final slot = widget.slot;
    messenger.showSnackBar(SnackBar(
      content: Text('${slotLabel[slot]}을 확정했어요'),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: '공유', onPressed: () {
        final ctx = rootNavigatorKey.currentContext;
        if (ctx != null) showMealShareSheet(ctx, slot);
      }),
    ));
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
    final meals = ref.watch(mealsProvider);
    final skipsUsed = ref.watch(skipsUsedProvider);
    final skipsToday = meals.where((m) => m.status == MealStatus.skipped && m.slot != slot).length;
    final remaining = engine.rules.skipPerWeek - skipsUsed - skipsToday;
    final skipLimit = remaining <= 0 || skipsToday >= engine.rules.skipPerDay;
    final total = _total;
    final isSnackLevel = total > 0 && total < engine.rules.snackKcal;
    final auto = _origin.status == MealStatus.auto;
    final m = fmtM(meM);
    final autoVal = engine.autoConfirmValue(curMe.bmr, _aiTotal);
    final sure = _items.where((i) => i.confidence == Confidence.sure).length;
    final check = _items.where((i) => i.confidence == Confidence.check).length;
    final unchecked = _items.where((i) => !i.checked).length;
    final searchMode = widget.searchOnly && _items.isEmpty;

    Widget photo() => Container(
          height: 150,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          alignment: Alignment.bottomLeft,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFB3552D), Color(0xFF7A3417), Color(0xFF3B1A0D)]),
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

    final children = <Widget>[
      photo(),
      if (searchMode) ...[
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
            child: boldThen(context, '자동 확정 ${fmtInt(autoVal)} kcal', ' · 09:00까지 확정하지 않아 max($m, 1.3×AI ${fmtInt(_aiTotal)})으로 계산됐어요. 아래 항목을 고쳐 저장하면 확정값으로 바뀌어요(48시간 안).', color: c.warn),
          ),
        if (isSnackLevel)
          InfoBanner(
            tone: Tone.neutral,
            icon: Icons.cookie_rounded,
            child: boldThen(context, '150 kcal 미만은 간식이에요.', ' 섭취에는 더해지지만 끼니 슬롯은 채우지 않아요.', color: c.fg2),
          ),
        for (var i = 0; i < _items.length; i++) _ItemCard(item: _items[i], onChange: (f) => _update(i, f), onSearch: () => _openSearch(replaceIndex: i), onRemove: () => setState(() => _items = [..._items]..removeAt(i))),
        ChButton('항목 추가 — 검색 · 최근 음식 · 직접 입력', kind: BtnKind.secondary, icon: Icons.add_rounded, onPressed: _openSearch),
        const InlineNote(Icons.check_box_rounded, '먹은 것만 체크해 두세요. 체크를 풀면 그 항목은 계산에서 빠져요. 이름을 바꾸면 kcal도 함께 바뀌어요.'),
        InlineNote(Icons.schedule_rounded, '09:00까지 확정하지 않으면 max($m, 1.3×AI) kcal로 자동 확정돼요. 그 뒤 48시간 안에는 고칠 수 있어요.'),
        const Disclaimer('모든 kcal은 추정이에요 · 확정값만 순위에 반영돼요'),
      ],
    ];

    return ChScaffold(
      title: slot == MealSlot.snack ? '간식 확인' : '$label 확인',
      backFallback: R.home,
      actions: [
        if (canShareMeal(_origin))
          IconButton(onPressed: () => showMealShareSheet(context, widget.slot), tooltip: '공유', icon: Icon(Icons.ios_share_rounded, color: c.fg), constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
        IconButton(onPressed: () => showToast(context, '사진 삭제는 서버 연동 후 지원돼요'), tooltip: '사진 삭제', icon: Icon(Icons.delete_rounded, color: c.fg), constraints: const BoxConstraints(minWidth: 48, minHeight: 48))],
      gap: 10,
      cta: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (skipLimit && !searchMode)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [Icon(Icons.info_rounded, size: 14, color: c.warn), const SizedBox(width: 4), Expanded(child: Txt.cap('이번 주 건너뜀 ${engine.rules.skipPerWeek}회를 모두 썼어요. 안 먹은 끼니는 $m kcal로 계산돼요.', color: c.warn))])),
        Row(children: [
          ChButton(skipLimit ? '건너뜀' : '건너뜀 (남은 $remaining회)', kind: BtnKind.quiet, expand: false, onPressed: skipLimit || slot == MealSlot.snack ? null : _skip),
          const SizedBox(width: 8),
          Expanded(
            child: ChButton(
              '${auto ? '수정 저장' : '확정'}${searchMode ? '' : ' · 약 ${fmtInt(total)} kcal'}',
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

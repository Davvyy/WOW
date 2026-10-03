import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../services/health/health_models.dart' show toKstWall;
import '../../services/share/meal_share.dart';
import '../../state/app_state.dart';
import 'common.dart';

/// 식사 공유 카드(4:5). 밖으로 나가는 이미지라 앱 테마(다크 모드)와 무관하게 밝은 색으로 고정한다.
/// [size] × [pixelRatio] = 1080×1350 px.
class MealShareCard extends StatelessWidget {
  const MealShareCard({super.key, required this.data});
  final MealShareData data;

  static const size = Size(360, 450);
  static const pixelRatio = 3.0;

  @override
  Widget build(BuildContext context) {
    const c = ChalloryColors.light;
    final photo = data.photo;
    Widget line(ShareLine l) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.body(c, size: 15))),
            const SizedBox(width: 8),
            Text.rich(TextSpan(children: [
              TextSpan(text: fmtInt(l.kcal), style: T.num(c.fg, size: 16)),
              TextSpan(text: ' kcal', style: T.body(c, size: 11, w: FontWeight.w500, color: c.fg2)),
            ])),
          ]),
        );

    return SizedBox.fromSize(
      size: size,
      child: ColoredBox(
        color: c.bg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (photo != null)
            SizedBox(height: 190, child: Image.memory(photo, fit: BoxFit.cover, gaplessPlayback: true))
          else
            Container(
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              color: c.brandSoft,
              child: Row(children: [Icon(Icons.restaurant_rounded, color: c.brand, size: 30)]),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(data.title, style: T.body(c, size: 17, w: FontWeight.w600)),
                const SizedBox(height: 6),
                ...data.lines.map(line),
                if (data.moreCount > 0) Text('외 ${data.moreCount}개', style: T.body(c, size: 13, color: c.fg2)),
                const Spacer(),
                Divider(height: 14, color: c.border),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('합계', style: T.body(c, size: 15, w: FontWeight.w600)),
                  const Spacer(),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '약 ', style: T.body(c, size: 15, w: FontWeight.w500, color: c.fg2)),
                    TextSpan(text: fmtInt(data.total), style: T.num(c.fg, size: 34, w: FontWeight.w700)),
                    TextSpan(text: ' kcal', style: T.body(c, size: 15, w: FontWeight.w500, color: c.fg2)),
                  ])),
                ]),
              ]),
            ),
          ),
          Container(
            height: 48,
            color: c.brand,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              Image.asset('assets/icon/app_icon_monochrome.png', width: 34, height: 34, color: c.onBrand),
              Text('챌로리', style: T.body(c, size: 16, w: FontWeight.w700, color: c.onBrand)),
              const Spacer(),
              Text('kcal은 추정치예요', style: T.body(c, size: 12, color: c.onBrand.withValues(alpha: 0.8))),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 공유 미리보기 시트. [mealKey] 끼니(로컬 키 또는 서버 id)로 카드를 만들고, '공유하기'를 누르면 PNG 로 그려 폰 공유 창에 넘긴다.
/// 확정 직후 홈 스낵바에서도 열 수 있도록 끼니 대신 키를 받는다(P7 화면이 이미 닫혀 있어도 됨). 그 끼니가 없으면 열지 않는다.
Future<void> showMealShareSheet(BuildContext context, String mealKey) async {
  final meal = ProviderScope.containerOf(context, listen: false).read(mealsProvider.notifier).byKey(mealKey);
  if (meal == null) return;
  await showChSheet<void>(context, builder: (_) => _MealShareSheet(meal: meal));
}

class _MealShareSheet extends ConsumerStatefulWidget {
  const _MealShareSheet({required this.meal});
  final MealRecord meal;

  @override
  ConsumerState<_MealShareSheet> createState() => _MealShareSheetState();
}

class _MealShareSheetState extends ConsumerState<_MealShareSheet> {
  final _boundary = GlobalKey();
  late final MealRecord _meal = widget.meal;
  late final DateTime _day = toKstWall(DateTime.now());
  MealShareData? _data;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = _meal.serverId;
    final photo = id == null ? null : await ref.read(sharePhotoStoreProvider).get(id);
    if (mounted) setState(() => _data = MealShareData.fromRecord(_meal, day: _day, photo: photo));
  }

  Future<void> _share() async {
    final data = _data;
    final boundary = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (data == null || boundary == null) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      final image = await boundary.toImage(pixelRatio: MealShareCard.pixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) throw StateError('png');
      final day = '${_day.year}${_day.month.toString().padLeft(2, '0')}${_day.day.toString().padLeft(2, '0')}';
      await ref.read(mealSharerProvider).shareImage(bytes.buffer.asUint8List(),
          fileName: 'challory_${day}_${_meal.slot.name}.png', text: data.caption);
      if (mounted) nav.pop();
    } catch (_) {
      if (mounted) showToast(context, '공유 창을 열지 못했어요 · 잠시 후 다시 해 주세요');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Txt.title('식사 공유'),
      const SizedBox(height: 12),
      Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MealShareCard.size.width),
          child: AspectRatio(
            aspectRatio: MealShareCard.size.width / MealShareCard.size.height,
            child: FittedBox(
            child: data == null
                ? SizedBox.fromSize(size: MealShareCard.size, child: const Center(child: CircularProgressIndicator()))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RepaintBoundary(key: _boundary, child: MealShareCard(data: data)),
                  ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      const Txt.cap('닉네임·점수는 들어가지 않아요 · 사진은 이 폰에만 7일 보관돼요', align: TextAlign.center),
      const SizedBox(height: 12),
      ChButton('공유하기', icon: Icons.ios_share_rounded, onPressed: data == null || _busy ? null : _share),
    ]);
  }
}

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import 'common.dart';
import '../../state/session.dart';

/// 끼니 1건의 상태별 표시(썸네일 56 · 설명 · 상태 배지 · 오른쪽 kcal). 슬롯 카드와 끼니 행이 함께 쓴다.
/// 05 meals.status 매핑: 분석 중=captured · 확정 대기=captured(noAnalysis)/failed · 초안=draft ·
/// 확정=confirmed/corrected · 자동 확정=auto · 건너뜀=skipped · void는 정정 이력으로만.
class _MealLook {
  _MealLook._(this.thumb, this.desc, this.badge, this.right);
  final Widget thumb;
  final String desc;
  final Widget? badge;
  final Widget? right;

  static List<Color> _gradient(MealSlot s) => switch (s) {
        MealSlot.breakfast => const [Color(0xFFD6A84A), Color(0xFF946A1C)],
        MealSlot.lunch => const [Color(0xFFC96F3A), Color(0xFF8A3F1E)],
        MealSlot.dinner => const [Color(0xFF5C9A5A), Color(0xFF2E5F2E)],
        MealSlot.snack => const [Color(0xFF7A5A4A), Color(0xFF3F2A22)],
      };

  /// [photo]: 이 폰에 보관된 실제 사진(없으면 아이콘 썸네일). 사진 기반 상태(분석 중~확정)에서만 쓴다.
  factory _MealLook.of(BuildContext context, MealRecord m, Uint8List? photo) {
    final c = context.c;
    final subM = fmtM(meM);

    Widget thumbEmpty(IconData icon) => Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: c.borderStrong, width: 1.5)),
          child: Icon(icon, color: c.fg2, size: 26),
        );
    // [status] 가 true 면 아이콘이 상태(분석 중·업로드 대기)를 뜻하므로 사진 위에도 작게 남긴다.
    final decodePx = (56 * MediaQuery.devicePixelRatioOf(context) * 1.5).ceil();
    Widget thumbFood(IconData icon, {bool status = false}) {
      final p = photo;
      if (p == null) {
        return Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _gradient(m.slot))),
          child: Icon(icon, color: Colors.white, size: 26),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 56,
          height: 56,
          child: Stack(fit: StackFit.expand, children: [
            // 56px 타일에 원본(긴 변 1568px)을 통째로 디코딩하지 않는다: 타일의 1.5배 안에서만 디코딩
            Image(
              image: ResizeImage(MemoryImage(p), width: decodePx, height: decodePx, policy: ResizeImagePolicy.fit),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
            if (status)
              Positioned(
                right: 3,
                bottom: 3,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 12),
                ),
              ),
          ]),
        ),
      );
    }

    Widget thumb;
    String desc;
    Widget? right;
    Widget? badge;
    final isSnack = m.slot == MealSlot.snack;
    Widget kcalRight(String v, String unit, {bool muted = false}) => Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          NumText(v, size: muted ? 16 : 19, weight: FontWeight.w700, color: muted ? c.fg2 : c.fg),
          Txt(unit, size: 9, weight: FontWeight.w500, color: c.fg2),
        ]);

    switch (m.status) {
      case MealStatus.empty:
      case MealStatus.voided:
        thumb = thumbEmpty(m.status == MealStatus.voided ? Icons.history_rounded : (isSnack ? Icons.add_rounded : Icons.photo_camera_rounded));
        desc = isSnack ? '간식은 찍은 만큼 더해지고, 끼니 슬롯은 채우지 않아요' : '아직 기록 없음 · 미기록 시 $subM kcal로 계산돼요';
        right = isSnack ? null : kcalRight(subM, '대체값', muted: true);
      case MealStatus.captured:
      case MealStatus.failed:
        if (m.pendingUpload) {
          // 연결이 없어 아직 서버에 못 올린 사진(앱 전용 폴더에 보관, 연결되면 이어서 보냄)
          thumb = thumbFood(Icons.cloud_upload_rounded, status: true);
          desc = '연결되면 사진을 보낼게요 · 확정 전까지는 $subM kcal로 잠정 계산돼요';
          badge = const ChChip('업로드 대기', tone: Tone.warn, icon: Icons.cloud_upload_rounded);
          right = isSnack ? null : kcalRight(subM, '대체값', muted: true);
        } else if (m.noAnalysis || m.status == MealStatus.failed) {
          thumb = thumbFood(Icons.image_rounded);
          desc = m.noAnalysis ? 'AI 분석 없이 저장됐어요 · 검색으로 확정해 주세요' : '사진은 저장됐어요 · 음식을 찾지 못해 검색으로 확정이 필요해요';
          badge = const ChChip('확정 대기', tone: Tone.warn, icon: Icons.edit_rounded);
          right = isSnack ? null : kcalRight(subM, '대체값', muted: true);
        } else {
          thumb = thumbFood(Icons.hourglass_top_rounded, status: true);
          desc = '분석 중… 끝나면 알려드려요';
          badge = const ChChip('분석 중', icon: Icons.hourglass_top_rounded);
          right = Container(width: 44, height: 14, decoration: BoxDecoration(color: c.border, borderRadius: BorderRadius.circular(8)));
        }
      case MealStatus.draft:
        final ai = m.aiKcal ?? 0;
        thumb = thumbFood(Icons.image_rounded);
        badge = const ChChip('확인 필요', tone: Tone.warn, icon: Icons.priority_high_rounded);
        if (isSnack) {
          desc = 'AI 초안 약 ${fmtInt(ai)} kcal · 확정하면 반영돼요';
        } else {
          final prov = engine.autoConfirmValue(curMe.bmr, ai);
          desc = 'AI 초안 약 ${fmtInt(ai)} kcal · ${fmtInt(prov)} kcal로 잠정 계산 중';
          right = kcalRight(fmtInt(prov), '잠정');
        }
      case MealStatus.auto:
        thumb = thumbFood(Icons.image_rounded);
        desc = '${m.title} · 09:00 자동 확정';
        badge = const ChChip('자동 확정', tone: Tone.warn, icon: Icons.schedule_rounded);
        right = kcalRight(fmtInt(m.kcal), 'kcal');
      case MealStatus.skipped:
        thumb = thumbEmpty(Icons.block_rounded);
        desc = '이 끼니는 먹지 않았어요 (건너뜀)';
        right = kcalRight('0', 'kcal', muted: true);
      case MealStatus.confirmed:
      case MealStatus.corrected:
        thumb = thumbFood(Icons.restaurant_rounded);
        desc = m.title.isEmpty ? '확정 기록' : m.title;
        final snackLevel = !isSnack && m.kcal < engine.rules.snackKcal;
        badge = Row(mainAxisSize: MainAxisSize.min, children: [
          if (isSnack || snackLevel) const ChChip('간식', icon: Icons.cookie_rounded) else const ChChip('확정', tone: Tone.good, icon: Icons.check_rounded),
          if (m.corrected || m.status == MealStatus.corrected) ...[const SizedBox(width: 4), const ChChip('정정', tone: Tone.warn, icon: Icons.history_rounded)],
        ]);
        right = kcalRight(fmtInt(m.kcal), 'kcal');
    }
    return _MealLook._(thumb, desc, badge, right);
  }
}

/// 식사 카드(슬롯) — docs/06 §5.4. 썸네일 56 · 끼니명 · kcal · 상태 배지.
/// 기록이 없는 슬롯과 지난 날 장부 요약(모의 모드 등, 슬롯당 한 줄)에 쓴다. 기록이 있는 슬롯은 [MealSlotGroupCard].
class MealSlotCard extends StatelessWidget {
  const MealSlotCard({super.key, required this.meal, this.onTap, this.photo});
  final MealRecord meal;

  /// 이 폰에 보관된 실제 사진(없으면 아이콘 썸네일). 사진 기반 상태(분석 중~확정)에서만 쓴다.
  final Uint8List? photo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = meal;
    final label = slotLabel[m.slot]!;
    final look = _MealLook.of(context, m, photo);

    return Semantics(
      button: onTap != null,
      label: '$label ${look.desc}',
      excludeSemantics: true,
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              look.thumb,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Txt(label, weight: FontWeight.w600),
                    if (m.time.isNotEmpty) Txt(m.time, size: 13, color: c.fg2),
                    ?look.badge,
                  ]),
                  const SizedBox(height: 2),
                  Txt.cap(look.desc, maxLines: 2),
                ]),
              ),
              if (look.right != null) ...[const SizedBox(width: 8), look.right!],
            ]),
          ),
        ),
      ),
    );
  }
}

/// 슬롯 카드 안의 끼니 한 줄: 썸네일 56 · 음식 이름(없으면 상태 문구) · 시각·상태 배지 · kcal. 누르면 그 끼니(P7).
class MealRow extends StatelessWidget {
  const MealRow({super.key, required this.meal, this.onTap, this.photo});
  final MealRecord meal;
  final Uint8List? photo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = meal;
    final look = _MealLook.of(context, m, photo);
    return Semantics(
      button: onTap != null,
      label: '${slotLabel[m.slot]}${m.time.isEmpty ? '' : ' ${m.time}'} ${look.desc}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              look.thumb,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Txt(look.desc, weight: FontWeight.w600, maxLines: 2),
                  const SizedBox(height: 2),
                  Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (m.time.isNotEmpty) Txt(m.time, size: 13, color: c.fg2),
                    ?look.badge,
                  ]),
                ]),
              ),
              if (look.right != null) ...[const SizedBox(width: 8), look.right!],
            ]),
          ),
        ),
      ),
    );
  }
}

/// 기록이 있는 슬롯 카드(오늘·지난 날): 머리글(아침 · 반영 kcal 합계) + 끼니마다 한 줄([MealRow]) + '추가'(같은 슬롯으로 촬영).
class MealSlotGroupCard extends StatelessWidget {
  const MealSlotGroupCard({super.key, required this.slot, required this.meals, required this.onTapMeal, this.onAdd, this.photoOf, this.canOpen});
  final MealSlot slot;

  /// 이 슬롯의 끼니(촬영 시각 순, 1건 이상)
  final List<MealRecord> meals;
  final void Function(MealRecord meal) onTapMeal;

  /// '추가'(같은 슬롯으로 촬영). null 이면 줄을 그리지 않는다(지난 날).
  final VoidCallback? onAdd;

  /// 누를 수 있는 끼니인지(null 이면 모두). false 인 줄은 누를 수 없다.
  final bool Function(MealRecord meal)? canOpen;

  /// 끼니의 보관 사진(없으면 null → 아이콘 썸네일)
  final Uint8List? Function(MealRecord meal)? photoOf;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final label = slotLabel[slot]!;
    final counted = meals.where((m) => isCountedStatus(m.status));
    final total = counted.fold<double>(0, (a, m) => a + m.kcal);
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            header: true,
            label: counted.isEmpty ? label : '$label ${fmtInt(total)} kcal',
            excludeSemantics: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Txt(label, weight: FontWeight.w600),
              if (counted.isNotEmpty) ...[
                Txt(' · ', color: c.fg2),
                NumText(fmtInt(total), size: 15, weight: FontWeight.w700, unit: 'kcal'),
              ],
            ]),
          ),
          const SizedBox(height: 4),
          for (final m in meals) MealRow(meal: m, photo: photoOf?.call(m), onTap: canOpen?.call(m) == false ? null : () => onTapMeal(m)),
          if (onAdd != null)
            Semantics(
              button: true,
              label: '$label 추가',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onAdd,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(children: [
                    Icon(Icons.add_rounded, size: 20, color: c.brand),
                    const SizedBox(width: 6),
                    Txt('추가', weight: FontWeight.w600, color: c.brand),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

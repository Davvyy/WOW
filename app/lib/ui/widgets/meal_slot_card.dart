import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import 'common.dart';
import '../../state/session.dart';

/// 식사 카드(슬롯) — docs/06 §5.4. 썸네일 56 · 끼니명 · kcal · 상태 배지.
/// 05 meals.status 매핑: 분석 중=captured · 확정 대기=captured(noAnalysis)/failed · 초안=draft ·
/// 확정=confirmed/corrected · 자동 확정=auto · 건너뜀=skipped · void는 정정 이력으로만.
class MealSlotCard extends StatelessWidget {
  const MealSlotCard({super.key, required this.meal, this.onTap, this.photo});
  final MealRecord meal;

  /// 이 폰에 보관된 실제 사진(없으면 아이콘 썸네일). 사진 기반 상태(분석 중~확정)에서만 쓴다.
  final Uint8List? photo;
  final VoidCallback? onTap;

  static List<Color> _gradient(MealSlot s) => switch (s) {
        MealSlot.breakfast => const [Color(0xFFD6A84A), Color(0xFF946A1C)],
        MealSlot.lunch => const [Color(0xFFC96F3A), Color(0xFF8A3F1E)],
        MealSlot.dinner => const [Color(0xFF5C9A5A), Color(0xFF2E5F2E)],
        MealSlot.snack => const [Color(0xFF7A5A4A), Color(0xFF3F2A22)],
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = meal;
    final label = slotLabel[m.slot]!;
    final subM = fmtM(meM);

    Widget thumbEmpty(IconData icon) => Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: c.borderStrong, width: 1.5)),
          child: Icon(icon, color: c.fg2, size: 26),
        );
    // [status] 가 true 면 아이콘이 상태(분석 중·업로드 대기)를 뜻하므로 사진 위에도 작게 남긴다.
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
            Image.memory(p, fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true),
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

    return Semantics(
      button: onTap != null,
      label: '$label $desc',
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
              thumb,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Txt(label, weight: FontWeight.w600),
                    if (m.time.isNotEmpty) Txt(m.time, size: 13, color: c.fg2),
                    ?badge,
                  ]),
                  const SizedBox(height: 2),
                  Txt.cap(desc, maxLines: 2),
                ]),
              ),
              if (right != null) ...[const SizedBox(width: 8), right],
            ]),
          ),
        ),
      ),
    );
  }
}

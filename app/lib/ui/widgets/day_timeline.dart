import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'common.dart';

/// 홈 '오늘 기록' 줄의 상태 점. 색과 함께 줄 글자(상태 문구)로도 알린다.
/// counted = 반영(확정·자동 확정·정정, 채운 teal) · substitute = 대체값이 들어간 칸(빈 칸·확정 대기·한도 초과 건너뜀, amber 테두리) ·
/// skipped = 건너뜀(채운 회색) · draft = AI 초안(teal 테두리) · analysing = 분석 중(회색 테두리).
enum RowDot { counted, substitute, skipped, draft, analysing }

/// 끼니 1건(또는 빈 칸)의 줄 표시. 05 meals.status 매핑: 분석 중=captured · 확정 대기=captured(noAnalysis)/failed ·
/// 초안=draft · 확정=confirmed/corrected · 자동 확정=auto · 건너뜀=skipped · void 는 빈 칸처럼 대체값.
class RowLook {
  const RowLook._(this.dot, this.title, this.status, this.kcal, {this.kcalUnit = 'kcal', this.kcalMuted = false, this.usesPhoto = true});

  final RowDot dot;
  final String title;

  /// 시각 뒤에 붙는 상태 문구(없으면 '')
  final String status;

  /// 오른쪽 kcal(없으면 null)
  final String? kcal;
  final String kcalUnit;
  final bool kcalMuted;

  /// 사진 썸네일을 보여 줄 상태인지(빈 칸·건너뜀은 아니다)
  final bool usesPhoto;

  /// [substitute] 는 이 칸의 대체값 max(M_p, 전날 같은 칸)(D61). [overLimitSkip] 은 한도를 넘어 대체값이 들어간 건너뜀.
  /// [today] 가 false 면(지난 날) 빈 간식 칸을 '기록 없음'으로.
  factory RowLook.of(MealRecord m, {double? substitute, bool overLimitSkip = false, bool today = true}) {
    final subM = fmtM(substitute ?? meM);
    final isSnack = m.slot == MealSlot.snack;
    RowLook subRow(RowDot dot, String title, String status) =>
        RowLook._(dot, title, status, isSnack ? null : subM, kcalUnit: '대체', kcalMuted: true);
    switch (m.status) {
      case MealStatus.empty:
        if (isSnack) return RowLook._(RowDot.analysing, today ? '찍은 만큼 더해져요' : '기록 없음', '', null, usesPhoto: false);
        return RowLook._(RowDot.substitute, '기록 없음 · 대체 $subM', '', null, usesPhoto: false);
      case MealStatus.voided:
        return RowLook._(RowDot.substitute, isSnack ? '기록 없음' : '기록 없음 · 대체 $subM', '무효', null, usesPhoto: false);
      case MealStatus.captured:
      case MealStatus.failed:
        if (m.pendingUpload) return subRow(RowDot.substitute, m.title.isEmpty ? '업로드 대기' : m.title, '업로드 대기 · 연결되면 보낼게요');
        if (m.noAnalysis || m.status == MealStatus.failed) {
          return subRow(RowDot.substitute, m.title.isEmpty ? '확정 대기' : m.title, '확정 대기 · 검색으로 확정해 주세요');
        }
        return const RowLook._(RowDot.analysing, '분석 중…', '끝나면 알려드려요', null);
      case MealStatus.draft:
        final ai = m.aiKcal ?? 0;
        final title = m.title.isEmpty ? 'AI 초안' : m.title;
        if (isSnack) return RowLook._(RowDot.draft, title, '확인 필요 · AI 약 ${fmtInt(ai)} kcal', null);
        return RowLook._(RowDot.draft, title, '확인 필요 · AI 약 ${fmtInt(ai)} kcal', fmtInt(engine.autoConfirmValue(curMe.bmr, ai)), kcalUnit: '잠정');
      case MealStatus.auto:
        return RowLook._(RowDot.counted, m.title.isEmpty ? '자동 확정 기록' : m.title, '자동 확정', fmtInt(m.kcal));
      case MealStatus.skipped:
        return overLimitSkip
            ? RowLook._(RowDot.substitute, '건너뜀', '한도 초과 · 대체 $subM', subM, kcalUnit: '대체', kcalMuted: true, usesPhoto: false)
            : const RowLook._(RowDot.skipped, '건너뜀', '먹지 않았어요', '0', kcalMuted: true, usesPhoto: false);
      case MealStatus.confirmed:
      case MealStatus.corrected:
        final snackLevel = isSnack || m.kcal < engine.rules.snackKcal;
        final corrected = m.corrected || m.status == MealStatus.corrected;
        return RowLook._(RowDot.counted, m.title.isEmpty ? '확정 기록' : m.title, '${snackLevel ? '간식' : '확정'}${corrected ? ' · 정정' : ''}', fmtInt(m.kcal));
    }
  }
}

/// '오늘 기록' 한 줄: 상태 점 · 슬롯 이름 · (보관 사진 32) · 제목 + 시각·상태 · 오른쪽 kcal · (끝 버튼).
/// 빈 칸은 [meal] 의 status 가 empty. 누르면 [onTap](P7 또는 촬영), 끝 버튼([trailing])은 줄과 따로 누른다.
class DayTimelineRow extends StatelessWidget {
  const DayTimelineRow({super.key, required this.meal, this.photo, this.onTap, this.substitute, this.overLimitSkip = false, this.today = true,
    this.trailing, this.actionHint = '열기'});
  final MealRecord meal;

  /// 줄을 눌렀을 때 하는 일(읽기 이름 끝에 붙는다)
  final String actionHint;

  /// 이 폰에 보관된 실제 사진(없으면 썸네일 없음)
  final Uint8List? photo;
  final VoidCallback? onTap;
  final double? substitute;
  final bool overLimitSkip;
  final bool today;

  /// 줄 끝 버튼('찍기'·'+ 추가') 또는 정렬용 빈 칸
  final Widget? trailing;

  static const thumbSize = 32.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = meal;
    final label = slotLabel[m.slot]!;
    final look = RowLook.of(m, substitute: substitute, overLimitSkip: overLimitSkip, today: today);
    final sub = [if (m.time.isNotEmpty && m.status != MealStatus.empty) m.time, if (look.status.isNotEmpty) look.status].join(' · ');
    final p = look.usesPhoto ? photo : null;
    final kcalSem = look.kcal == null ? '' : ' ${look.kcalUnit == 'kcal' ? '' : '${look.kcalUnit} '}${look.kcal} kcal';
    final semantics = '$label ${look.title}$kcalSem${look.status.isEmpty ? '' : ' ${look.status}'}${onTap != null ? ', $actionHint' : ''}';

    final main = Semantics(
      button: onTap != null,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              _Dot(look.dot),
              const SizedBox(width: 10),
              Txt(label, weight: FontWeight.w600, color: c.fg),
              const SizedBox(width: 12),
              if (p != null) ...[_Thumb(p), const SizedBox(width: 10)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Txt(look.title, weight: m.status == MealStatus.empty ? FontWeight.w400 : FontWeight.w600,
                      color: m.status == MealStatus.empty ? c.fg2 : c.fg, maxLines: 1),
                  if (sub.isNotEmpty) Txt.cap(sub, maxLines: 1),
                ]),
              ),
              if (look.kcal != null) ...[
                const SizedBox(width: 8),
                NumText(look.kcal!, size: 17, weight: FontWeight.w700, color: look.kcalMuted ? c.fg2 : c.fg, unit: look.kcalUnit),
              ],
            ]),
          ),
        ),
      ),
    );
    if (trailing == null) return main;
    return Row(children: [Expanded(child: main), trailing!]);
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.kind);
  final RowDot kind;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (Color? fill, Color? ring) = switch (kind) {
      RowDot.counted => (c.brand, null),
      RowDot.substitute => (null, c.warn),
      RowDot.skipped => (c.fg2, null),
      RowDot.draft => (null, c.brand),
      RowDot.analysing => (null, c.borderStrong),
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: fill, border: ring == null ? null : Border.all(color: ring, width: 2)),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.photo);
  final Uint8List photo;
  @override
  Widget build(BuildContext context) {
    const s = DayTimelineRow.thumbSize;
    // 32px 타일에 원본(긴 변 1568px)을 통째로 디코딩하지 않는다: 타일의 1.5배 안에서만 디코딩
    final px = (s * MediaQuery.devicePixelRatioOf(context) * 1.5).ceil();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: s,
        height: s,
        child: Image(
          image: ResizeImage(MemoryImage(photo), width: px, height: px, policy: ResizeImagePolicy.fit),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

/// 줄 끝의 작은 버튼('찍기'·'+ 추가'). 누르는 영역은 48dp 이상.
class RowAction extends StatelessWidget {
  const RowAction({super.key, required this.label, required this.icon, required this.onTap, required this.semanticsLabel, this.iconOnly = false});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String semanticsLabel;

  /// 아이콘만(기록이 있는 칸의 '+'). 정렬 폭 [width] 와 같다.
  final bool iconOnly;

  static const width = 48.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: width, minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: iconOnly
                ? Icon(icon, size: 22, color: c.brand)
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: c.brandSoft, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 16, color: c.brand),
                      const SizedBox(width: 4),
                      Txt(label, size: 13, weight: FontWeight.w600, color: c.brand),
                    ]),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 목록 머리글: 왼쪽 '오늘 기록'(지난 날 'M.D 기록'), 오른쪽 반영률 4칸 + '반영 n/4'.
class TimelineHeader extends StatelessWidget {
  const TimelineHeader({super.key, required this.title, required this.cells, required this.semanticsDetail});
  final String title;
  final List<bool> cells;

  /// 칸별 읽기 문구(아침 확정, 점심 건너뜀 …)
  final String semanticsDetail;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final n = cells.where((x) => x).length;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(children: [
        Expanded(child: Semantics(header: true, child: Txt.title(title))),
        Semantics(
          label: '반영 $n/${cells.length} · $semanticsDetail',
          excludeSemantics: true,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Fill4(cells: cells, small: true),
            const SizedBox(width: 6),
            Txt('반영 $n/${cells.length}', size: 13, weight: FontWeight.w600, color: c.fg2),
          ]),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';

export '../../core/theme/theme.dart';

enum Tone { neutral, good, warn, critical, review, brand }

(Color bg, Color fg) toneColors(ChalloryColors c, Tone t) => switch (t) {
      Tone.neutral => (c.surface, c.fg2),
      Tone.good => (c.goodSoft, c.good),
      Tone.warn => (c.warnSoft, c.warn),
      Tone.critical => (c.criticalSoft, c.critical),
      Tone.review => (c.reviewSoft, c.review),
      Tone.brand => (c.brandSoft, c.brand),
    };

/// 세로 간격을 끼워 넣은 자식 목록
List<Widget> spaced(List<Widget> children, {double gap = 12}) => [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ];

bool reduceMotion(BuildContext context) => MediaQuery.of(context).disableAnimations;

// ---------------------------------------------------------------- 텍스트

class Txt extends StatelessWidget {
  const Txt(this.text, {super.key, this.size = 15, this.weight = FontWeight.w400, this.color, this.align, this.maxLines, this.strike = false, this.height});
  final String text;
  final double size;
  final FontWeight weight;
  final Color? color;
  final TextAlign? align;
  final int? maxLines;
  final bool strike;
  final double? height;

  /// caption 13/18
  const Txt.cap(this.text, {super.key, this.color, this.align, this.maxLines, this.weight = FontWeight.w400, this.strike = false})
      : size = 13,
        height = null;

  /// title 17/24 600
  const Txt.title(this.text, {super.key, this.color, this.align, this.maxLines})
      : size = 17,
        weight = FontWeight.w600,
        strike = false,
        height = null;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    var s = T.body(c, size: size, w: weight, color: color ?? (size == 13 ? c.fg2 : c.fg));
    if (height != null) s = s.copyWith(height: height);
    if (strike) s = s.copyWith(decoration: TextDecoration.lineThrough);
    return Text(text, style: s, textAlign: align, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
  }
}

/// 숫자 서체(Barlow Semi Condensed) 텍스트. 단위는 [unit] 으로 작게 붙인다.
class NumText extends StatelessWidget {
  const NumText(this.value, {super.key, this.size = 17, this.weight = FontWeight.w600, this.color, this.unit, this.align});
  final String value;
  final double size;
  final FontWeight weight;
  final Color? color;
  final String? unit;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final col = color ?? c.fg;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: value, style: T.num(col, size: size, w: weight)),
        if (unit != null)
          TextSpan(text: ' $unit', style: T.body(c, size: size * 0.55 < 11 ? 11 : size * 0.55, w: FontWeight.w500, color: c.fg2)),
      ]),
      textAlign: align,
    );
  }
}

// ---------------------------------------------------------------- 카드·칩·배너

class ChCard extends StatelessWidget {
  const ChCard({super.key, required this.child, this.color, this.outline = false, this.onTap, this.padding, this.semanticsLabel, this.dashed = false});
  final Widget child;
  final Color? color;
  final bool outline;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final String? semanticsLabel;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final deco = BoxDecoration(
      color: outline ? c.bg : (color ?? c.surface),
      borderRadius: BorderRadius.circular(12),
      border: outline ? Border.all(color: c.border) : null,
    );
    final content = Container(
      width: double.infinity,
      decoration: deco,
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: child,
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: content),
    );
  }
}

class ChChip extends StatelessWidget {
  const ChChip(this.text, {super.key, this.tone = Tone.neutral, this.icon});
  final String text;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg) = toneColors(c, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: tone == Tone.neutral ? Border.all(color: c.border) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
        Flexible(child: Text(text, style: T.body(c, size: 11, w: FontWeight.w500, color: fg).copyWith(height: 1.45))),
      ]),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.tone, required this.icon, required this.child, this.action, this.onClose});
  final Tone tone;
  final IconData icon;
  final Widget child;
  final Widget? action;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg) = toneColors(c, tone);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: DefaultTextStyle(style: T.body(c, size: 13, color: fg), child: child),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              tooltip: '닫기',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: fg),
            ),
        ]),
      ),
    );
  }
}

/// 굵은 글씨 + 보통 글씨 한 문단(배너 본문용)
Widget boldThen(BuildContext context, String bold, String rest, {Color? color}) {
  final c = context.c;
  final col = color ?? c.fg;
  return Text.rich(TextSpan(children: [
    TextSpan(text: bold, style: T.body(c, size: 13, w: FontWeight.w600, color: col)),
    TextSpan(text: rest, style: T.body(c, size: 13, color: col)),
  ]));
}

class Kv extends StatelessWidget {
  const Kv(this.k, this.v, {super.key});
  final Widget k;
  final Widget v;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Flexible(child: k), const SizedBox(width: 12), v]);
}

class Disclaimer extends StatelessWidget {
  const Disclaimer(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Center(child: Txt(text, size: 11, color: context.c.fg2, align: TextAlign.center)),
      );
}

class InlineNote extends StatelessWidget {
  const InlineNote(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: c.fg2)),
      const SizedBox(width: 8),
      Expanded(child: Txt.cap(text)),
    ]);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Txt(text, size: 11, weight: FontWeight.w600, color: context.c.fg2),
      );
}

// ---------------------------------------------------------------- 버튼·입력

enum BtnKind { primary, secondary, ghost, quiet, critical, kakao, apple }

class ChButton extends StatelessWidget {
  const ChButton(this.label, {super.key, this.onPressed, this.kind = BtnKind.primary, this.icon, this.small = false, this.expand = true, this.semanticsLabel});
  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final IconData? icon;
  final bool small;
  final bool expand;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg, border) = switch (kind) {
      BtnKind.primary => (c.brand, c.onBrand, null),
      BtnKind.secondary => (c.brandSoft, c.brand, null),
      BtnKind.ghost => (Colors.transparent, c.brand, c.borderStrong),
      BtnKind.quiet => (c.surface, c.fg, null),
      BtnKind.critical => (c.critical, c.onCritical, null),
      BtnKind.kakao => (c.kakao, c.onKakao, null),
      BtnKind.apple => (c.apple, c.onApple, null),
    };
    final enabled = onPressed != null;
    final h = small ? 36.0 : 48.0;
    final child = Row(
      mainAxisSize: expand && !small ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: small ? 16 : 20, color: fg), const SizedBox(width: 6)],
        Flexible(child: Text(label, textAlign: TextAlign.center, style: T.body(c, size: small ? 13 : 15, w: FontWeight.w600, color: fg))),
      ],
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: small ? 44 : 48),
          child: Center(
            widthFactor: small ? 1 : null,
            child: Material(
              color: bg,
              shape: StadiumBorder(side: border == null ? BorderSide.none : BorderSide(color: border)),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onPressed,
                child: Container(
                  height: h,
                  padding: EdgeInsets.symmetric(horizontal: small ? 14 : 18),
                  constraints: BoxConstraints(minWidth: small ? 0 : 0),
                  alignment: Alignment.center,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChLink extends StatelessWidget {
  const ChLink(this.label, {super.key, required this.onTap, this.trailing = true});
  final String label;
  final VoidCallback onTap;
  final bool trailing;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: T.body(c, w: FontWeight.w600, color: c.brand)),
          if (trailing) Icon(Icons.chevron_right_rounded, size: 18, color: c.brand),
        ]),
      ),
    );
  }
}

class ChCheck extends StatelessWidget {
  const ChCheck({super.key, required this.value, required this.onChanged, required this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      checked: value,
      label: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: value ? c.brand : c.bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: value ? c.brand : c.borderStrong, width: 2),
              ),
              child: value ? Icon(Icons.check_rounded, size: 18, color: c.onBrand) : null,
            ),
          ),
        ),
      ),
    );
  }
}

class ChSwitch extends StatelessWidget {
  const ChSwitch({super.key, required this.value, required this.onChanged, required this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      toggled: value,
      label: label,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: SizedBox(
          width: 52,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 150),
              width: 44,
              height: 26,
              padding: const EdgeInsets.all(3),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(color: value ? c.brand : c.borderStrong, borderRadius: BorderRadius.circular(999)),
              child: Container(width: 20, height: 20, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 필 모양 세그먼트(라디오 역할)
class ChSeg<V> extends StatelessWidget {
  const ChSeg({super.key, required this.items, required this.value, required this.onChanged, this.small = false, this.label});
  final List<(V, String)> items;
  final V value;
  final ValueChanged<V>? onChanged;
  final bool small;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      container: true,
      label: label,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(999)),
        child: Row(children: [
          for (final (v, text) in items)
            Expanded(
              child: Semantics(
                inMutuallyExclusiveGroup: true,
                checked: v == value,
                selected: v == value,
                button: true,
                label: text,
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onChanged == null ? null : () => onChanged!(v),
                  child: Container(
                    constraints: BoxConstraints(minHeight: small ? 36 : 40),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == value ? c.bg : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: v == value ? [const BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1))] : null,
                    ),
                    child: Text(text, style: T.body(c, size: small ? 13 : 15, w: FontWeight.w600, color: v == value ? c.fg : c.fg2)),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class ChInput extends StatelessWidget {
  const ChInput({super.key, required this.controller, this.hint, this.unit, this.enabled = true, this.keyboardType, this.onChanged, this.label, this.numeric = true, this.maxLength, this.leading, this.inputFormatters});
  final TextEditingController controller;
  final String? hint;
  final String? unit;
  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final String? label;
  final bool numeric;
  final int? maxLength;
  final Widget? leading;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final field = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.borderStrong),
      ),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType ?? (numeric ? TextInputType.number : TextInputType.text),
            onChanged: onChanged,
            maxLength: maxLength,
            inputFormatters: inputFormatters,
            style: numeric ? T.num(c.fg, size: 16, w: FontWeight.w600) : T.body(c, size: 16),
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              counterText: '',
              hintText: hint,
              hintStyle: T.body(c, color: c.fg2),
              semanticCounterText: null,
            ),
          ),
        ),
        if (unit != null) Padding(padding: const EdgeInsets.only(left: 8), child: Txt(unit!, color: c.fg2)),
      ]),
    );
    final w = Semantics(label: label, child: Opacity(opacity: enabled ? 1 : 0.5, child: field));
    if (label == null) return w;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Txt.cap(label!, weight: FontWeight.w500), const SizedBox(height: 6), w]);
  }
}

// ---------------------------------------------------------------- 앱바·스캐폴드

class ChAppBar extends StatelessWidget {
  const ChAppBar({super.key, required this.title, this.meta, this.onBack, this.actions = const [], this.center = false});
  final String title;
  final String? meta;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 56,
      child: Row(children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            tooltip: '뒤로',
            icon: Icon(Icons.arrow_back_rounded, color: c.fg),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          )
        else
          const SizedBox(width: 16),
        Expanded(
          child: Semantics(
            header: true,
            child: Row(
              mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.body(c, size: 16, w: FontWeight.w700))),
                if (meta != null) ...[
                  const SizedBox(width: 8),
                  Text(meta!, maxLines: 1, style: T.num(c.fg2, size: 13, w: FontWeight.w500).copyWith(fontFamilyFallback: [kBodyFont])),
                ],
              ],
            ),
          ),
        ),
        ...actions,
        const SizedBox(width: 4),
      ]),
    );
  }
}

/// 뒤로 가기: 스택이 없으면 [fallback] 경로로.
void goBack(BuildContext context, [String fallback = '/home']) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(fallback);
  }
}

/// 탭 셸 밖 화면 공통 틀: 앱바 + 스크롤 본문 + (선택) 하단 고정 CTA.
class ChScaffold extends StatelessWidget {
  const ChScaffold({super.key, required this.title, required this.children, this.meta, this.back = true, this.backFallback = '/home', this.actions = const [], this.cta, this.gap = 12, this.padding, this.progress, this.onRefresh});
  final String title;
  final String? meta;
  final bool back;
  final String backFallback;
  final List<Widget> actions;
  final List<Widget> children;
  final Widget? cta;
  final double gap;
  final EdgeInsetsGeometry? padding;
  final int? progress;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget body = SingleChildScrollView(
      physics: onRefresh != null ? const AlwaysScrollableScrollPhysics() : null,
      padding: padding ?? const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(children, gap: gap)),
    );
    if (onRefresh != null) body = RefreshIndicator(onRefresh: onRefresh!, child: body);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(children: [
          ChAppBar(title: title, meta: meta, onBack: back ? () => goBack(context, backFallback) : null, actions: actions),
          if (progress != null) _Progress(step: progress!),
          Expanded(child: body),
          if (cta != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              color: c.bg,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([cta!], gap: 8)),
            ),
        ]),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.step});
  final int step;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: '진행 $step/3',
      value: '$step/3',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(children: [
          for (var i = 1; i <= 3; i++) ...[
            if (i > 1) const SizedBox(width: 6),
            Expanded(child: Container(height: 4, decoration: BoxDecoration(color: i <= step ? c.brand : c.border, borderRadius: BorderRadius.circular(2)))),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- 다이얼로그·시트

Future<R?> showChDialog<R>(BuildContext context, {required String title, Color? titleColor, required Widget body, required List<Widget> actions}) {
  return showDialog<R>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: ctx.c.bg,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Txt.title(title, color: titleColor),
          const SizedBox(height: 12),
          body,
          const SizedBox(height: 16),
          Row(children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: actions[i]),
            ],
          ]),
        ]),
      ),
    ),
  );
}

Future<R?> showChSheet<R>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<R>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.c.bg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + MediaQuery.of(ctx).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: ctx.c.borderStrong, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),
          builder(ctx),
        ]),
      ),
    ),
  );
}

void showToast(BuildContext context, String message) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(message), duration: const Duration(milliseconds: 2200)));
}

// ---------------------------------------------------------------- 게이지·반영률

class ChGauge extends StatelessWidget {
  const ChGauge({super.key, required this.value, required this.max, this.warn = false, required this.label});
  final double value;
  final double max;
  final bool warn;
  final String label;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final f = (value / max).clamp(0.0, 1.0);
    return Semantics(
      label: label,
      value: '${value.round()} / ${max.round()}',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 8,
            color: c.borderStrong,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(widthFactor: f, child: Container(color: warn ? c.warn : c.brand)),
          ),
        ),
      ),
    );
  }
}

/// 반영률 4칸(아침·점심·저녁·걸음). 빈칸은 테두리+빗금(색 외 식별).
class Fill4 extends StatelessWidget {
  const Fill4({super.key, required this.cells, this.small = false});
  final List<bool> cells;
  final bool small;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final w = small ? 7.0 : 10.0;
    final h = small ? 10.0 : 14.0;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < cells.length; i++) ...[
        if (i > 0) const SizedBox(width: 3),
        cells[i]
            ? Container(width: w, height: h, decoration: BoxDecoration(color: c.good, borderRadius: BorderRadius.circular(2)))
            : CustomPaint(
                size: Size(w, h),
                painter: _HatchPainter(c.borderStrong),
              ),
      ],
    ]);
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2));
    canvas.save();
    canvas.clipRRect(r);
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width + size.height; x += 4) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    canvas.restore();
    canvas.drawRRect(r.deflate(0.75), Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = color);
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';

/// 순적자 링(270° 게이지, docs/06 §5.4). 220dp, 두께 18, 트랙 ring-track, 진행 brand.
/// 잠정은 점선 끝, 확정은 실선. 100% 초과(150점 구간)는 끝단 점으로 표시한다.
class CalorieRing extends StatelessWidget {
  const CalorieRing({
    super.key,
    required this.ratio,
    required this.center,
    required this.semanticsLabel,
    this.provisional = true,
    this.empty = false,
    this.targetLabel = '−500',
  });

  /// D/T, 0~1.5
  final double ratio;
  final Widget center;
  final String semanticsLabel;
  final bool provisional;
  final bool empty;
  final String targetLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = empty ? 0.0 : ratio.clamp(0.0, 1.0);
    final over = !empty && ratio > 1;
    final dur = reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 300);
    return Semantics(
      label: semanticsLabel,
      image: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 220,
          height: 224,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: p),
            duration: dur,
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Stack(alignment: Alignment.center, children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RingPainter(
                    progress: v,
                    over: over,
                    provisional: provisional,
                    track: c.ringTrack,
                    brand: c.brand,
                    halo: c.surface,
                    onBrand: c.onBrand,
                  ),
                ),
              ),
              Padding(padding: const EdgeInsets.only(top: 6), child: center),
              Positioned(left: 36, bottom: 10, child: Text('0', style: T.num(c.fg2, size: 11))),
              Positioned(right: 22, bottom: 10, child: Text(targetLabel, style: T.num(c.fg2, size: 11))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.over, required this.provisional, required this.track, required this.brand, required this.halo, required this.onBrand});
  final double progress;
  final bool over;
  final bool provisional;
  final Color track;
  final Color brand;
  final Color halo;
  final Color onBrand;

  static const _r = 92.0;
  static const _start = (225 - 90) * math.pi / 180; // 7:30 위치(좌하단)에서 시작
  static const _sweep = 270 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    const center = Offset(110, 112);
    final rect = Rect.fromCircle(center: center, radius: _r);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, _start, _sweep, false, trackPaint);
    if (progress > 0.001) {
      final sweep = _sweep * progress;
      canvas.drawArc(
        rect,
        _start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 22
          ..strokeCap = StrokeCap.round
          ..color = halo,
      );
      final bp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18
        ..strokeCap = provisional ? StrokeCap.butt : StrokeCap.round
        ..color = brand;
      if (provisional) {
        final path = Path()..addArc(rect, _start, sweep);
        for (final m in path.computeMetrics()) {
          var d = 0.0;
          while (d < m.length) {
            canvas.drawPath(m.extractPath(d, math.min(d + 6, m.length)), bp);
            d += 11;
          }
        }
      } else {
        canvas.drawArc(rect, _start, sweep, false, bp);
      }
    }
    if (over) {
      final a = (225 + 270 - 12 - 90) * math.pi / 180;
      final o = Offset(center.dx + (_r + 20) * math.cos(a), center.dy + (_r + 20) * math.sin(a));
      canvas.drawCircle(o, 9, Paint()..color = brand);
      final tp = TextPainter(
        text: TextSpan(text: '+', style: TextStyle(color: onBrand, fontSize: 11, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.progress != progress || o.over != over || o.provisional != provisional || o.brand != brand || o.track != track;
}

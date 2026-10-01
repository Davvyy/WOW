import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/engine/engine.dart';
import '../router.dart';
import 'widgets/common.dart';

/// 탭 셸: `홈 · 순위 · [촬영 FAB] · 활동 · 규칙` (docs/06 §2). 설정은 홈 톱니, 장부는 '점수 계산 보기'.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  /// 시각에 따른 끼니 자동 태그(04~10:30 아침 / ~15 점심 / ~22 저녁 / 그 외 간식)
  static MealSlot slotForNow(DateTime now) {
    final m = now.hour * 60 + now.minute;
    if (m >= 4 * 60 && m < 10 * 60 + 30) return MealSlot.breakfast;
    if (m < 15 * 60 && m >= 10 * 60 + 30) return MealSlot.lunch;
    if (m >= 15 * 60 && m < 22 * 60) return MealSlot.dinner;
    return MealSlot.snack;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget tab(int index, IconData icon, IconData activeIcon, String label) {
      final active = shell.currentIndex == index;
      return Expanded(
        child: Semantics(
          selected: active,
          button: true,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            onTap: () => shell.goBranch(index, initialLocation: index == shell.currentIndex),
            child: SizedBox(
              height: 64,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(active ? activeIcon : icon, size: 24, color: active ? c.brand : c.fg2),
                const SizedBox(height: 2),
                Text(label, style: T.body(c, size: 11, w: active ? FontWeight.w700 : FontWeight.w500, color: active ? c.brand : c.fg2)),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.bg,
      body: shell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: c.bg, border: Border(top: BorderSide(color: c.border))),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 72,
            child: Row(children: [
              tab(0, Icons.home_outlined, Icons.home_rounded, '홈'),
              tab(1, Icons.leaderboard_outlined, Icons.leaderboard_rounded, '순위'),
              SizedBox(
                width: 72,
                child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
                  Positioned(
                    top: -14,
                    child: Semantics(
                      button: true,
                      label: '식사 촬영',
                      child: Material(
                        color: c.brand,
                        shape: const CircleBorder(),
                        elevation: 4,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => context.push('${R.camera}?slot=${slotForNow(DateTime.now()).name}'),
                          child: SizedBox(width: 56, height: 56, child: Icon(Icons.photo_camera_rounded, color: c.onBrand)),
                        ),
                      ),
                    ),
                  ),
                  Positioned(bottom: 10, child: Text('촬영', style: T.body(c, size: 11, w: FontWeight.w500, color: c.fg2))),
                ]),
              ),
              tab(2, Icons.directions_walk_outlined, Icons.directions_walk_rounded, '활동'),
              tab(3, Icons.gavel_outlined, Icons.gavel_rounded, '규칙'),
            ]),
          ),
        ),
      ),
    );
  }
}

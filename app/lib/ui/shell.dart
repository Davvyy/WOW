import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/engine/engine.dart';
import '../router.dart';
import '../state/app_state.dart';
import '../state/session.dart';
import 'widgets/common.dart';

/// 탭 셸: `홈 · 순위 · [촬영 FAB] · 활동 · 규칙` (docs/06 §2). 설정은 홈 톱니, 장부는 '점수 계산 보기'.
/// 서버 모드에서는 챌린지 세션(my_challenge_summary)을 받기 전까지 탭 화면 대신 로딩·오류·미참가 안내를 보여준다.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  /// 탭 이름의 아래 여백(탭 막대 72 높이 기준). 네 탭과 가운데 촬영이 같은 값을 쓴다.
  static const _labelBottom = 12.0;

  /// 시각에 따른 끼니 자동 태그. 경계는 챌린지 규칙(challenge_rules: 기본 04:00 / 10:30 / 15:00 / 22:00).
  /// 서버도 같은 경계로 태그하므로(create_meal) 여기 값은 화면의 기본 선택일 뿐이다.
  static MealSlot slotForNow(DateTime now) { // now: 실제 시각(인스턴트)
    int mins(String hhmm) {
      final p = hhmm.split(':');
      return int.parse(p[0]) * 60 + int.parse(p[1]);
    }

    final (bs, be, le, de) = currentSession.slotStarts;
    final k = now.toUtc().add(const Duration(hours: 9)); // 서버와 같은 KST 기준(해외 체류자도)
    final m = k.hour * 60 + k.minute;
    if (m >= mins(bs) && m < mins(be)) return MealSlot.breakfast;
    if (m >= mins(be) && m < mins(le)) return MealSlot.lunch;
    if (m >= mins(le) && m < mins(de)) return MealSlot.dinner;
    return MealSlot.snack;
  }

  Widget _gate(BuildContext context, WidgetRef ref, Widget child) {
    final s = ref.watch(sessionProvider); // 모의 모드도 지켜본다: 챌린지를 바꾸면 아래 화면이 다시 그려진다
    if (!ref.read(apiProvider).isRemote) return child;
    final c = context.c;
    Widget card(IconData icon, String title, String body, {Widget? action}) => Scaffold(
          backgroundColor: c.bg,
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: spaced([
                  Icon(icon, color: c.fg2, size: 32),
                  Txt.title(title),
                  Txt.cap(body, align: TextAlign.center),
                  ?action,
                ], gap: 8)),
              ),
            ),
          ),
        );
    // 다시 읽는 동안(참가·나가기·판정 푸시·온보딩 뒤)은 이전 값으로 그린다: 탭 상태와 토스트가 유지된다
    return s.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading:() => card(Icons.hourglass_top_rounded, '챌린지를 불러오고 있어요', '잠시만 기다려 주세요'),
      error: (e, _) => card(Icons.cloud_off_rounded, '챌린지를 불러오지 못했어요', apiErrorText(e),
          action: ChButton('다시 불러오기', small: true, kind: BtnKind.quiet, onPressed: () => ref.invalidate(sessionsProvider))),
      data: (v) => v == null
          ? card(Icons.group_add_rounded, '참가 중인 챌린지가 없어요', '이번 달 챌린지에 참가하거나 초대코드로 참가할 수 있어요',
              action: ChButton('참가하러 가기', small: true, onPressed: () => context.go(R.p1)))
          : child,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _gate(context, ref, _shell(context));

  Widget _shell(BuildContext context) {
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
            // 이름은 촬영 버튼 이름과 같은 아래 여백([_labelBottom])에 맞춰 다섯 이름이 한 줄에 놓인다
            child: SizedBox(
              height: 72,
              child: Padding(
                padding: const EdgeInsets.only(bottom: _labelBottom),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Icon(active ? activeIcon : icon, size: 24, color: active ? c.brand : c.fg2),
                  const SizedBox(height: 2),
                  Text(label, style: T.body(c, size: 11, w: active ? FontWeight.w700 : FontWeight.w500, color: active ? c.brand : c.fg2)),
                ]),
              ),
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
            key: const ValueKey('tab-bar'),
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
                        shadowColor: c.brand.withValues(alpha: 0.35),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => context.push('${R.camera}?slot=${slotForNow(DateTime.now()).name}'),
                          child: SizedBox(width: 56, height: 56, child: Icon(Icons.photo_camera_rounded, color: c.onBrand)),
                        ),
                      ),
                    ),
                  ),
                  Positioned(bottom: _labelBottom, child: Text('촬영', style: T.body(c, size: 11, w: FontWeight.w500, color: c.fg2))),
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

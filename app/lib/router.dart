import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config.dart';
import 'core/engine/engine.dart';
import 'services/auth/auth_service.dart';
import 'state/app_state.dart';
import 'ui/screens/p10_ledger.dart';
import 'ui/screens/p11_rules.dart';
import 'ui/screens/p12_settings.dart';
import 'ui/screens/p1_start.dart';
import 'ui/screens/p2_profile.dart';
import 'ui/screens/p3_consent.dart';
import 'ui/screens/p4_health.dart';
import 'ui/screens/p5_home.dart';
import 'ui/screens/p6_camera.dart';
import 'ui/screens/p7_meal_edit.dart';
import 'ui/screens/p8_activity.dart';
import 'ui/screens/p9_leaderboard.dart';
import 'ui/screens/debug_screens.dart';
import 'ui/shell.dart';

/// 라우트 경로. 탭 셸: /home(P5) /rank(P9) /activity(P8) /rules(P11).
/// P1~P4 온보딩, P6 촬영, P7 편집, P10 장부, P12 설정은 셸 위에 전체 화면으로 쌓인다.
class R {
  R._();
  static const p1 = '/p1';
  static const p2 = '/p2';
  static const p3 = '/p3';
  static const p4 = '/p4';
  static const home = '/home';
  static const rank = '/rank';
  static const activity = '/activity';
  static const rules = '/rules';
  static const camera = '/p6';
  static const ledger = '/p10';
  static const settings = '/p12';
  static const debug = '/debug';
  /// P7: [meal] 은 끼니 키(로컬 키 또는 서버 id). 없으면 [slot] 에 새로 기록한다(빈 슬롯·검색 기록).
  static String meal(MealSlot slot, {String? meal, bool search = false}) {
    final q = {'meal': ?meal, if (search) 'search': '1'};
    return Uri(path: '/p7/${slot.name}', queryParameters: q.isEmpty ? null : q).toString();
  }
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// 화면이 닫힌 뒤(예: 확정 직후 홈 스낵바)에도 시트를 열 수 있는 최상위 Navigator
GlobalKey<NavigatorState> get rootNavigatorKey => _rootKey;

/// 로그인 전에도 열 수 있는 화면(초대코드·규칙 미리 보기·검수 목록)
const _publicPaths = {R.p1, R.rules, R.debug};

/// [auth] 가 있으면 로그인 가드: 로그인 전에는 P1 으로, 로그아웃되면 P1 으로 돌려보낸다.
/// 모의 모드(서버 없음)는 가드 없이 모든 화면을 연다(검수·테스트용).
GoRouter buildRouter({String initialLocation = R.p1, AuthService? auth}) {
  final refresh = auth == null ? null : _StreamListenable(auth.changes);
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: initialLocation,
    debugLogDiagnostics: false,
    refreshListenable: refresh,
    redirect: auth == null
        ? null
        : (_, state) {
            final path = state.uri.path;
            if (!auth.isSignedIn && !_publicPaths.contains(path)) return R.p1;
            return null;
          },
    routes: [
      GoRoute(path: R.p1, builder: (_, _) => const StartScreen()),
      GoRoute(path: R.p2, builder: (_, _) => const ProfileScreen()),
      GoRoute(path: R.p3, builder: (_, _) => const ConsentScreen()),
      GoRoute(path: R.p4, builder: (_, s) => HealthConnectScreen(initialState: s.uri.queryParameters['state'])),
      // 프로토타입 화면 번호 별칭
      GoRoute(path: '/p5', redirect: (_, _) => R.home),
      GoRoute(path: '/p8', redirect: (_, _) => R.activity),
      GoRoute(path: '/p9', redirect: (_, _) => R.rank),
      GoRoute(path: '/p11', redirect: (_, _) => R.rules),
      GoRoute(
        path: R.camera,
        parentNavigatorKey: _rootKey,
        builder: (_, s) => CameraScreen(initialSlot: _slotOf(s.uri.queryParameters['slot'])),
      ),
      GoRoute(
        path: '/p7/:slot',
        parentNavigatorKey: _rootKey,
        builder: (_, s) => MealEditScreen(
          slot: _slotOf(s.pathParameters['slot']) ?? MealSlot.lunch,
          mealKey: s.uri.queryParameters['meal'],
          searchOnly: s.uri.queryParameters['search'] == '1',
        ),
      ),
      GoRoute(
        path: R.ledger,
        parentNavigatorKey: _rootKey,
        builder: (_, s) => LedgerScreen(variant: s.uri.queryParameters['v'], day: int.tryParse(s.uri.queryParameters['day'] ?? '')),
      ),
      GoRoute(path: R.settings, parentNavigatorKey: _rootKey, builder: (_, s) => SettingsScreen(variant: s.uri.queryParameters['v'])),
      if (kDebugMode || const bool.fromEnvironment('SCREEN_LIST')) GoRoute(path: R.debug, parentNavigatorKey: _rootKey, builder: (_, _) => const DebugScreenList()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: R.home, builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: R.rank, builder: (_, _) => const LeaderboardScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: R.activity, builder: (_, _) => const ActivityScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: R.rules, builder: (_, _) => const RulesScreen())]),
        ],
      ),
    ],
  );
}

MealSlot? _slotOf(String? name) {
  if (name == null) return null;
  for (final s in MealSlot.values) {
    if (s.name == name) return s;
  }
  return null;
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authServiceProvider);
  final r = buildRouter(auth: AppConfig.hasSupabase ? auth : null);
  ref.onDispose(r.dispose);
  return r;
});

class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<bool> s) {
    _sub = s.listen((_) => notifyListeners());
  }
  late final StreamSubscription<bool> _sub;
  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

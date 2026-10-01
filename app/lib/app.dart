import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import 'data/models.dart' show slotLabel;
import 'core/theme/theme.dart';
import 'router.dart';
import 'state/app_state.dart';
import 'state/push_controller.dart';

/// 화면 밖(푸시 처리 등)에서 안내를 띄우는 루트 메신저
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

class ChalloryApp extends ConsumerStatefulWidget {
  const ChalloryApp({super.key});

  @override
  ConsumerState<ChalloryApp> createState() => _ChalloryAppState();
}

class _ChalloryAppState extends ConsumerState<ChalloryApp> {
  // 앱으로 돌아올 때 업로드 대기열을 이어서 보낸다(05 §5 재시도 — 앱 실행·포그라운드 복귀·새로고침)
  late final _lifecycle = AppLifecycleListener(onResume: () {
    if (ref.read(authServiceProvider).isSignedIn || !ref.read(apiProvider).isRemote) {
      ref.read(mealsProvider.notifier).retryPendingUploads();
    }
  });

  StreamSubscription<DraftReady>? _drafts;

  @override
  void initState() {
    super.initState();
    _lifecycle; // 등록
    final push = ref.read(pushControllerProvider);
    _drafts = push.draftReady.listen(_onDraftReady);
    // 참가 세션이 준비되면 푸시 수신 시작(이미 허용했으면 토큰 등록, 알림으로 실행됐으면 그 끼니로)
    ref.listenManual(sessionProvider, (_, next) {
      if (next.value != null) push.start();
    }, fireImmediately: true);
  }

  /// 분석 완료(N-04): 알림을 눌러 들어왔으면 P7, 앱을 보고 있었으면 안내 + 확인하기
  void _onDraftReady(DraftReady d) {
    final router = ref.read(routerProvider);
    if (d.opened) {
      router.push(R.meal(d.slot));
      return;
    }
    final m = rootMessengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text('${slotLabel[d.slot]} 분석이 끝났어요'),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(label: '확인하기', onPressed: () => router.push(R.meal(d.slot))),
    ));
  }

  @override
  void dispose() {
    _drafts?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '챌로리',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(routerProvider),
      scaffoldMessengerKey: rootMessengerKey,
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      // 한국어 Material·Cupertino 문구(입력칸·날짜 선택 등). 기본(영어) 대리자만으로는 ko_KR 에서 입력칸이 동작하지 않는다.
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}

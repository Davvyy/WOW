import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/theme.dart';
import 'router.dart';
import 'state/app_state.dart';

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

  @override
  void initState() {
    super.initState();
    _lifecycle; // 등록
  }

  @override
  void dispose() {
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
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      localizationsDelegates: const [
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
    );
  }
}

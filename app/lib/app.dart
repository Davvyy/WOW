import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import 'data/models.dart' show slotLabel;
import 'core/theme/theme.dart';
import 'router.dart';
import 'state/app_state.dart';
import 'state/push_controller.dart';
import 'state/session.dart' show curChallenge;

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

  StreamSubscription<PushEvent>? _pushEvents;

  @override
  void initState() {
    super.initState();
    _lifecycle; // 등록
    final push = ref.read(pushControllerProvider);
    _pushEvents = push.events.listen(_onPush);
    // 참가 세션이 준비되면 푸시 수신 시작(이미 허용했으면 토큰 등록, 알림으로 실행됐으면 그 끼니로)
    ref.listenManual(sessionProvider, (_, next) {
      if (next.value != null) push.start();
    }, fireImmediately: true);
  }

  /// 알림을 눌러 들어왔으면 해당 화면으로, 앱을 보고 있었으면 하단 안내 + 바로가기
  ///  - N-01 어제 결과 → P5 홈(06 랜딩), 안내의 "장부 보기"는 그날 장부
  ///  - N-02 확정 대기 → P7(가장 이른 대기 끼니) · 동기화 → 받자마자 동기화하고 P5 홈(06 랜딩)
  ///  - N-04 분석 완료 → P7(그 끼니) · N-05 검토 안내 → P10(검토 카드·소명) · N-06 판정 결과 → P10 장부(판정 배너·정정 이력)
  void _onPush(PushEvent e) {
    final router = ref.read(routerProvider);
    if ((e is DailyResult || (e is Reminder && (e.isSync || e.slot == null))) && e.opened) {
      router.go(R.home);
      return;
    }
    final (route, text, label, secs) = switch (e) {
      DailyResult(:final localDate, :final message) => (_ledgerDay(localDate), message, '장부 보기', 6),
      Reminder(isSync: true, synced: true) => (R.activity, '오늘 걸음을 동기화했어요', '활동 보기', 4),
      Reminder(isSync: true, :final message) => (R.activity, message, '활동 보기', 6),
      // 확정 대기 알림은 그 슬롯에서 가장 이른 대기 끼니를, 분석 완료 알림은 그 끼니를 연다
      Reminder(:final slot, :final message) => (
          slot == null ? R.home : R.meal(slot, meal: ref.read(mealsProvider.notifier).earliestUnconfirmedIn(slot)?.key),
          message,
          '확정하기',
          6
        ),
      DraftReady(:final slot, :final mealId) => (R.meal(slot, meal: mealId), '${slotLabel[slot]} 분석이 끝났어요', '확인하기', 4),
      ReviewNotice(:final message) => (R.ledger, message, '설명 남기기', 8),
      VerdictReady(:final message) => (R.ledger, message, '장부 보기', 8),
    };
    if (e.opened) {
      router.push(route);
      return;
    }
    final m = rootMessengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      duration: Duration(seconds: secs),
      persist: false,
      action: SnackBarAction(label: label, onPressed: () => router.push(route)),
    ));
  }

  /// 그날 장부(P10 ?day=n, 챌린지 시작일이 1일째). 날짜를 모르면 최신 확정일.
  static String _ledgerDay(DateTime? d) {
    if (d == null) return R.ledger;
    final s = curChallenge.start;
    final n = d.difference(DateTime(s.year, s.month, s.day)).inDays + 1;
    return n >= 1 ? '${R.ledger}?day=$n' : R.ledger;
  }

  @override
  void dispose() {
    _pushEvents?.cancel();
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

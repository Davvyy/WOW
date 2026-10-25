import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart' show isSamsungSource;
import '../../router.dart';
import '../../services/health/health_models.dart';
import '../../services/health/health_package_source.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

enum _P4State { idle, ok, zero, denied, unsupported }

/// P4 건강 데이터 연결. 교육 카드(읽는 항목 5개) → 권한 요청 → "오늘 N걸음을 읽었어요" 검증.
/// 쓰기 권한은 요청하지 않는다. `?state=ok|zero|denied|unsupported` 로 상태 변형을 바로 볼 수 있다(검수용).
/// [inApp]: 설정 연결 줄·활동 탭 연결 진단에서 연 경우(`from=app`). 온보딩 버튼 대신 '권한 다시 확인'·돌아가기.
/// 걸음·출처·동기화 시각은 이 기기에서 읽은 오늘 활동(없으면 서버의 마지막 동기화)을 쓴다.
class HealthConnectScreen extends ConsumerStatefulWidget {
  const HealthConnectScreen({super.key, this.initialState, this.inApp = false});
  final String? initialState;
  final bool inApp;

  @override
  ConsumerState<HealthConnectScreen> createState() => _HealthConnectScreenState();
}

class _HealthConnectScreenState extends ConsumerState<HealthConnectScreen> {
  late _P4State _state = _P4State.values.firstWhere((s) => s.name == widget.initialState, orElse: () => _P4State.idle);
  /// 이 화면에서 방금 읽은 오늘 걸음(읽기 전이면 오늘 활동 값)
  int? _steps;
  int _denials = 0;
  bool _busy = false;

  Future<void> _connect() async {
    final src = ref.read(healthSourceProvider);
    setState(() => _busy = true);
    try {
      final avail = await src.availability();
      if (avail == HealthAvailability.needsInstall) {
        if (mounted) setState(() => _state = _P4State.unsupported);
        return;
      }
      if (avail == HealthAvailability.unsupported) {
        if (mounted) setState(() => _state = _P4State.unsupported);
        return;
      }
      final res = await src.requestPermissions();
      if (!mounted) return;
      if (res == PermissionResult.denied) {
        _denials++;
        setState(() => _state = _denials >= 2 ? _P4State.denied : _P4State.idle);
        if (_denials < 2) showToast(context, '권한을 허용하면 걸음을 자동으로 읽어요');
        return;
      }
      final days = await src.fetchDays();
      if (!mounted) return;
      final today = days.isEmpty ? 0 : days.first.stepsVerified;
      if (src is HealthPackageSource) await ref.read(activityProvider.notifier).refresh();
      setState(() {
        _steps = today;
        _state = today > 0 ? _P4State.ok : _P4State.zero;
      });
    } catch (_) {
      if (mounted) setState(() => _state = _P4State.unsupported);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final src = ref.watch(healthSourceProvider);
    final platform = src.platformLabel == 'Apple 건강' ? 'Apple 건강' : 'Health Connect';
    final ios = platform == 'Apple 건강';
    final ch = curChallenge;
    final act = ref.watch(activityProvider);
    // 출처: 이 기기에서 읽은 오늘 출처 → 서버의 마지막 동기화 출처 → 플랫폼 이름(D77).
    // 서버 모드는 받은 세션의 값만 쓴다(세션 전 전역 값은 프로토타입이다)
    final remote = ref.read(apiProvider).isRemote;
    final server = remote ? ref.watch(sessionProvider).value?.challenge : ch;
    final serverSource = server == null || server.source == '—' ? '' : server.source;
    final source = act.source.isNotEmpty ? act.source : (serverSource.isNotEmpty ? serverSource : platform);
    final knownSource = source != platform;
    final syncTime = act.syncTime.isNotEmpty ? act.syncTime : (server == null || server.syncTime == '—' ? '' : server.syncTime);
    final samsung = !ios && (isSamsungSource(act.source) || isSamsungSource(serverSource));
    const items = [
      (Icons.directions_walk_rounded, '걸음'),
      (Icons.straighten_rounded, '거리'),
      (Icons.stairs_rounded, '층수'),
      (Icons.directions_run_rounded, '운동 세션'),
      (Icons.local_fire_department_rounded, '활동 칼로리(참고)'),
    ];
    Widget result() => switch (_state) {
          _P4State.ok => InfoBanner(
              tone: Tone.good,
              icon: Icons.check_circle_rounded,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                boldThen(context, '오늘 ${fmtInt(_steps ?? act.stepsTotal)}걸음을 읽었어요 ✓', '', color: c.good),
                Text(['출처 $source', platform, if (syncTime.isNotEmpty) syncTime].join(' · ')),
              ]),
            ),
          _P4State.zero => ChCard(
              color: c.warnSoft,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                Row(children: [Icon(Icons.error_rounded, color: c.warn), const SizedBox(width: 8), Txt('아직 읽은 걸음이 없어요', weight: FontWeight.w600, color: c.warn)]),
                // 갤럭시 전용 안내는 삼성헬스 출처일 때만(D77)
                Txt.cap(
                    samsung
                        ? '삼성헬스 → 설정 → Health Connect → 데이터 동기화를 켜 주세요. 켠 뒤 이 화면을 당겨서 새로고침하면 바로 반영돼요.'
                        : ios
                        ? '설정 → 건강 → 데이터 접근 및 기기 → 챌로리에서 걸음 읽기를 켜 주세요. iPhone·Apple Watch 가 건강 앱에 기록한 걸음을 읽어요.'
                        : '걸음을 기록하는 앱(휴대폰 기본 걸음·워치 앱 등)에서 Health Connect 로 보내기를 켜고, Health Connect 권한에서 챌로리 "걸음"을 허용해 주세요.',
                    color: c.warn),
                if (samsung) ChButton('삼성헬스 열기', small: true, kind: BtnKind.quiet, onPressed: () => showToast(context, '삼성헬스 앱을 열어 동기화를 켜 주세요')),
              ], gap: 8)),
            ),
          _P4State.denied => ChCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                Row(children: [Icon(Icons.settings_rounded, color: c.fg2), const SizedBox(width: 8), const Expanded(child: Txt('설정 앱에서 권한을 켜면 바로 이어져요', weight: FontWeight.w600))]),
                Txt.cap(ios
                    ? '권한 요청이 두 번 취소되어 앱에서는 다시 물을 수 없어요. 설정 → 건강 → 데이터 접근 및 기기 → 챌로리.'
                    : '권한 요청이 두 번 취소되어 앱에서는 다시 물을 수 없어요. 설정 → 앱 → 챌로리 → Health Connect 권한.'),
                ChButton('설정 열기', small: true, kind: BtnKind.quiet, onPressed: () => showToast(context, '설정 → 앱 → 챌로리에서 권한을 켜 주세요')),
              ], gap: 8)),
            ),
          _P4State.unsupported => ChCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                Row(children: [Icon(Icons.download_rounded, color: c.fg2), const SizedBox(width: 8), const Expanded(child: Txt('Health Connect 앱 설치가 필요해요', weight: FontWeight.w600))]),
                const Txt.cap('Android 13 이하에서는 Play 스토어에서 Health Connect를 설치한 뒤 연결할 수 있어요.'),
                ChButton('Play 스토어에서 설치', small: true, kind: BtnKind.quiet, onPressed: () {
                  final s = ref.read(healthSourceProvider);
                  if (s is HealthPackageSource) s.installHealthConnect();
                }),
              ], gap: 8)),
            ),
          _P4State.idle => const SizedBox.shrink(),
        };
    final ok = _state == _P4State.ok;
    // 앱 안에서 연 경우: 온보딩 버튼(시작하기·나중에 연결) 대신 권한 다시 확인 · 돌아가기
    final inAppCta = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ChButton('권한 다시 확인', icon: Icons.monitor_heart_rounded, onPressed: _busy ? null : _connect),
      const SizedBox(height: 8),
      ChButton('돌아가기', kind: BtnKind.quiet, onPressed: () => context.canPop() ? context.pop() : context.go(R.settings)),
    ]);
    return ChScaffold(
      title: '건강 데이터 연결',
      backFallback: widget.inApp ? R.settings : R.p3,
      progress: widget.inApp ? null : 3,
      cta: widget.inApp ? inAppCta : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ChButton(
          ok ? '시작하기' : '$platform 연결',
          icon: Icons.monitor_heart_rounded,
          onPressed: _busy ? null : (ok ? () => context.go(R.home) : _connect),
        ),
        const SizedBox(height: 8),
        ChButton('나중에 연결 (활동 0으로 집계)', kind: BtnKind.quiet, onPressed: () => context.go(R.home)),
      ]),
      children: [
        Txt('걸음과 운동을\n자동으로 읽어올게요', size: 24, weight: FontWeight.w700, color: c.fg, height: 1.33),
        Txt('걸음·거리·층수·운동 세션을 읽어요. 활동 칼로리는 참고 표시용으로만 읽고, 어떤 데이터도 쓰지 않아요.', color: c.fg2),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Txt.cap('읽는 항목 5개 — 권한 화면에 그대로 나와요', weight: FontWeight.w600),
            for (final (icon, label) in items)
              SizedBox(
                height: 40,
                child: Row(children: [
                  Icon(icon, color: c.fg2, size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Txt(label)),
                  Icon(Icons.check_rounded, size: 18, color: c.fg2),
                ]),
              ),
          ]),
        ),
        Semantics(liveRegion: true, child: result()),
        ChCard(
          outline: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            Kv(Txt.cap('연결 플랫폼'), Txt(platform, weight: FontWeight.w600)),
            Kv(Txt.cap('데이터 출처'), Txt(source, weight: FontWeight.w600)),
            const Txt.cap('iPhone에서는 Apple 건강이 연결돼요. 워치가 없어도 폰 걸음으로 같은 공식이 적용돼요.'),
          ], gap: 6)),
        ),
        // 갤럭시 가이드: iPhone 에는 없고, 이미 다른 앱 출처로 읽고 있으면 숨긴다(D77)
        if (!ios && (samsung || !knownSource)) ChCard(
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Txt('Galaxy 사용자 가이드 — 삼성헬스 → Health Connect', weight: FontWeight.w600),
              children: const [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Txt.cap('1. 삼성헬스 → 설정 → Health Connect\n2. "데이터 동기화" 켜기 → 걸음·운동 세션 허용\n3. 챌로리로 돌아와 "Health Connect 연결"'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

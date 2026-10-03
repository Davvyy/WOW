import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/engine/engine.dart' show MealSlot;
import '../services/push/push_service.dart';
import 'app_state.dart';

/// 푸시 수신 계층. main 에서 FCM 이 준비되면 [FirebasePushService] 로 바꿔 끼운다.
final pushServiceProvider = Provider<PushService>((_) => NoPushService());

/// 서버 devices 행 id 를 기기에 남겨 두는 곳(다음 실행 때 같은 행을 갱신)
abstract class DeviceIdStore {
  Future<String?> read();
  Future<void> write(String? id);
}

class MemoryDeviceIdStore implements DeviceIdStore {
  String? _id;
  @override
  Future<String?> read() async => _id;
  @override
  Future<void> write(String? id) async => _id = id;
}

class FileDeviceIdStore implements DeviceIdStore {
  FileDeviceIdStore(this._file);
  final Future<File> Function() _file;
  @override
  Future<String?> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final v = (await f.readAsString()).trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String? id) async {
    try {
      final f = await _file();
      if (id == null) {
        if (await f.exists()) await f.delete();
      } else {
        await f.parent.create(recursive: true);
        await f.writeAsString(id, flush: true);
      }
    } catch (_) {}
  }
}

final deviceIdStoreProvider = Provider<DeviceIdStore>((_) => AppConfig.hasSupabase
    ? FileDeviceIdStore(() async => File('${(await getApplicationSupportDirectory()).path}/push_device_id'))
    : MemoryDeviceIdStore());

/// 푸시를 반영한 결과. [opened] 면 알림을 눌러 들어온 것(해당 화면으로 이동), 아니면 화면에 떠 있을 때 받은 것(안내만).
sealed class PushEvent {
  const PushEvent({required this.opened});
  final bool opened;
}

/// N-01 어제 확정 결과 → 장부·순위를 다시 읽음(P5 랜딩, 안내에서 그날 장부로)
class DailyResult extends PushEvent {
  const DailyResult(this.localDate, this.message, {required super.opened});
  final DateTime? localDate;
  final String message;
}

/// N-02 저녁 리마인드. confirm: 오늘 끼니를 다시 읽음(P7 그 끼니) · sync: 받자마자 건강 데이터를 읽어 올림([synced])
class Reminder extends PushEvent {
  const Reminder(this.kind, this.message, {this.slot, this.synced = false, required super.opened});
  final String kind;
  final String message;
  final MealSlot? slot;
  final bool synced;
  bool get isSync => kind == 'sync';
}

/// N-04 분석 완료 → 그 끼니가 초안이 됨(P7)
class DraftReady extends PushEvent {
  const DraftReady(this.slot, {required super.opened});
  final MealSlot slot;
}

/// N-05 검토 안내 → 검토 카드(소명 72h)·장부('검토 중')·순위를 다시 읽음(P10 소명)
class ReviewNotice extends PushEvent {
  const ReviewNotice(this.reviewId, this.message, {required super.opened});
  final String? reviewId;
  final String message;
}

/// N-06 판정 결과 → 장부·검토 카드·순위를 다시 읽음(P10)
class VerdictReady extends PushEvent {
  const VerdictReady(this.reviewId, this.message, {this.verdict, required super.opened});
  final String reviewId;
  final String message;
  final String? verdict;
}

/// 기기 등록(토큰·권한 → register_device)과 N-04 처리.
/// N-04 를 받으면 그 끼니를 서버에서 다시 읽어 초안으로 바꾸고, N-01·N-05·N-06 을 받으면 장부·순위(·검토)를 다시 읽게 하고,
/// N-02 를 받으면 오늘 끼니를 다시 읽거나(확정 대기) 걸음을 동기화한 뒤
/// [events] 로 알린다(화면 이동·안내는 앱 셸이 한다).
class PushController {
  PushController(this._ref);
  final Ref _ref;
  final _subs = <StreamSubscription<Object?>>[];
  final _ready = StreamController<PushEvent>.broadcast();
  bool _started = false;
  String? _lastToken;

  Stream<PushEvent> get events => _ready.stream;
  bool get started => _started;

  PushService get _push => _ref.read(pushServiceProvider);

  /// 참가 세션이 준비되면 한 번. 이미 권한이 있으면 토큰을 등록하고 수신을 시작한다.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final push = _push;
    _subs
      ..add(push.foreground.listen((m) => handle(m, opened: false)))
      ..add(push.opened.listen((m) => handle(m, opened: true)))
      ..add(push.tokenRefresh.listen((t) => _register(PushPermission.granted, token: t)));
    final p = await push.permission();
    if (p == PushPermission.granted) await _register(p);
    final launch = await push.initialMessage();
    if (launch != null) await handle(launch, opened: true);
  }

  /// P6 첫 촬영 뒤 "알림 켜기": OS 권한 창 → 결과(허용·거부)를 서버에 남긴다.
  Future<PushPermission> enable() async {
    final p = await _push.requestPermission();
    await _register(p);
    return p;
  }

  /// 로그아웃: 이 기기 행을 지워 더는 이 계정 알림이 오지 않게 한다.
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _started = false;
    _lastToken = null;
    final store = _ref.read(deviceIdStoreProvider);
    final id = await store.read();
    if (id != null) {
      try {
        await _ref.read(apiProvider).unregisterDevice(id);
      } catch (e) {
        debugPrint('push: 기기 해제 건너뜀 ($e)');
      }
    }
    await store.write(null);
  }

  Future<void> _register(PushPermission p, {String? token}) async {
    final platform = _push.platform;
    if (platform == null) return;
    final t = p == PushPermission.granted ? (token ?? await _push.token()) : null;
    final store = _ref.read(deviceIdStoreProvider);
    try {
      final id = await _ref.read(apiProvider).registerDevice(
          deviceId: await store.read(), platform: platform, token: t, permission: p.wire);
      _lastToken = t;
      await store.write(id);
    } catch (e) {
      debugPrint('push: 기기 등록 건너뜀 ($e)'); // 다음 실행·토큰 갱신 때 다시 시도
    }
  }

  /// 마지막으로 서버에 올린 토큰(테스트·점검용)
  String? get registeredToken => _lastToken;

  /// 받은 푸시 처리. N-01·N-02·N-04·N-05·N-06 을 다룬다(공지 N-03 등은 화면에 들어올 때 다시 읽는다).
  Future<void> handle(PushMessage m, {required bool opened}) async {
    // 연 알림이 특정 챌린지 것이면 그 챌린지를 본다(기록 공유 알림 N-02·N-04 는 홈 그대로)
    if (opened && !m.isAnalysisDone && !m.isReminder) {
      final mine = (_ref.read(sessionsProvider).value ?? const []).map((s) => s.challengeId).toSet();
      final id = m.challengeIds.where(mine.contains).firstOrNull;
      if (id != null) _ref.read(selectedChallengeProvider.notifier).select(id);
    }
    if (m.isAnalysisDone) {
      final slot = await _ref.read(mealsProvider.notifier).applyAnalysisPush(m.mealId!, hint: m.slot);
      if (slot != null) _emit(DraftReady(slot, opened: opened));
    } else if (m.isReminder) {
      final kind = m.reminderKind;
      if (kind == 'sync') {
        // "앱을 열면 걸음이 동기화돼요" — 연 김에(또는 떠 있는 김에) 바로 동기화
        final synced = await _ref.read(activityProvider.notifier).refresh();
        _emit(Reminder(kind, m.body ?? '앱을 열면 걸음이 동기화돼요', synced: synced, opened: opened));
      } else {
        await _ref.read(mealsProvider.notifier).loadToday();
        _emit(Reminder(kind, m.body ?? '사진이 확정을 기다려요', slot: m.slot, opened: opened));
      }
    } else if (m.isDailyResult) {
      // 09:00 확정 배치가 어제 점수·누적·순위 스냅샷을 확정했으므로 잠정 값을 버린다
      _ref.invalidate(ledgerProvider);
      _ref.invalidate(leaderboardProvider);
      _emit(DailyResult(m.localDate, m.body ?? '어제 결과가 확정됐어요', opened: opened));
    } else if (m.isReviewNotice) {
      _refreshReviews();
      _emit(ReviewNotice(m.reviewId, m.body ?? '기록을 확인 중이에요. 72시간 안에 설명을 남길 수 있어요', opened: opened));
    } else if (m.isVerdict) {
      _applyVerdict(m.verdict);
      _emit(VerdictReady(m.reviewId!, m.body ?? '판정 결과가 나왔어요', verdict: m.verdict, opened: opened));
    }
  }

  /// 판정은 점수(무효면 그날 대체값으로 재계산)·검토 상태·순위를 바꾼다. 경고·순위 제외는 참가 상태도 바뀌므로 세션까지.
  void _applyVerdict(String? verdict) {
    _refreshReviews();
    if (verdict == 'warn' || verdict == 'exclude') _ref.invalidate(sessionsProvider);
  }

  /// 검토가 생기거나(N-05: 그날 점수 '검토 중', 순위에서 집계 중) 끝나면(N-06) 바뀌는 것들
  void _refreshReviews() {
    _ref.invalidate(myReviewsProvider);
    _ref.invalidate(ledgerProvider);
    _ref.invalidate(leaderboardProvider);
  }

  void _emit(PushEvent e) {
    if (!_ready.isClosed) _ready.add(e);
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _ready.close();
  }
}

final pushControllerProvider = Provider<PushController>((ref) {
  final c = PushController(ref);
  ref.onDispose(c.dispose);
  return c;
});

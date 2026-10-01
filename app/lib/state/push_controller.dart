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

/// 분석 완료 푸시를 반영한 결과. [opened] 면 알림을 눌러 들어온 것(P7 로 이동), 아니면 화면에 떠 있을 때 받은 것(안내만).
class DraftReady {
  const DraftReady(this.slot, {required this.opened});
  final MealSlot slot;
  final bool opened;
}

/// 기기 등록(토큰·권한 → register_device)과 N-04 처리.
/// N-04 를 받으면 그 끼니를 서버에서 다시 읽어 초안으로 바꾸고 [draftReady] 로 알린다(화면 이동·안내는 앱 셸이 한다).
class PushController {
  PushController(this._ref);
  final Ref _ref;
  final _subs = <StreamSubscription<Object?>>[];
  final _ready = StreamController<DraftReady>.broadcast();
  bool _started = false;
  String? _lastToken;

  Stream<DraftReady> get draftReady => _ready.stream;
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

  /// 받은 푸시 처리. N-04 만 다룬다(공지 N-03 등은 화면에 들어올 때 다시 읽는다).
  Future<void> handle(PushMessage m, {required bool opened}) async {
    if (!m.isAnalysisDone) return;
    final slot = await _ref.read(mealsProvider.notifier).applyAnalysisPush(m.mealId!, hint: m.slot);
    if (slot != null && !_ready.isClosed) _ready.add(DraftReady(slot, opened: opened));
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

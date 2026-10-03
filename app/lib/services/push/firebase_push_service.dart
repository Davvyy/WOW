import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'background_push.dart';
import 'push_service.dart';

/// FCM(Android) · APNs 경유 FCM(iOS). 네이티브 설정 파일(google-services.json · GoogleService-Info.plist)이 있어야 한다.
/// 초기화가 안 되면 [tryCreate] 가 null 을 돌려주고 앱은 [NoPushService] 로 동작한다.
class FirebasePushService implements PushService {
  FirebasePushService._(this._fm);
  final FirebaseMessaging _fm;

  static Future<FirebasePushService?> tryCreate() async {
    if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) return null;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      // 앱이 꺼져 있을 때 받은 걸음 동기화 리마인드(N-02 sync)는 별도 isolate 에서 바로 올린다
      FirebaseMessaging.onBackgroundMessage(onBackgroundPush);
      return FirebasePushService._(FirebaseMessaging.instance);
    } catch (e) {
      debugPrint('push: Firebase 초기화 건너뜀 ($e)');
      return null;
    }
  }

  @override
  String? get platform => defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  static PushPermission _map(AuthorizationStatus s) => switch (s) {
        AuthorizationStatus.authorized || AuthorizationStatus.provisional => PushPermission.granted,
        AuthorizationStatus.denied || AuthorizationStatus.deniedPermanently => PushPermission.denied,
        AuthorizationStatus.notDetermined => PushPermission.notAsked,
      };

  static PushMessage _msg(RemoteMessage m) => PushMessage(
        data: {for (final e in m.data.entries) e.key: '${e.value}'},
        title: m.notification?.title,
        body: m.notification?.body,
      );

  @override
  Future<PushPermission> permission() async => _map((await _fm.getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async => _map((await _fm.requestPermission()).authorizationStatus);

  @override
  Future<String?> token() async {
    try {
      return await _fm.getToken();
    } catch (e) {
      debugPrint('push: 토큰 없음 ($e)'); // iOS 시뮬레이터·APNs 미설정
      return null;
    }
  }

  @override
  Stream<String> get tokenRefresh => _fm.onTokenRefresh;

  @override
  Stream<PushMessage> get foreground => FirebaseMessaging.onMessage.map(_msg);

  @override
  Stream<PushMessage> get opened => FirebaseMessaging.onMessageOpenedApp.map(_msg);

  @override
  Future<PushMessage?> initialMessage() async {
    final m = await _fm.getInitialMessage();
    return m == null ? null : _msg(m);
  }
}

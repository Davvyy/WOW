import 'dart:async';

import '../../core/engine/engine.dart' show MealSlot;

/// OS 알림 권한(05 devices.push_permission 과 같은 값)
enum PushPermission {
  granted('granted'),
  denied('denied'),
  notAsked('not_asked');

  const PushPermission(this.wire);
  final String wire;
}

/// 받은 푸시 한 건. 서버 notify·analyze-meal 이 data 에 type·id(알림)와 payload(N-04: meal_id·slot)를 싣는다.
class PushMessage {
  const PushMessage({required this.data, this.title, this.body});
  final Map<String, String> data;
  final String? title;
  final String? body;

  String? get type => data['type'];
  String? get mealId => data['meal_id'];
  MealSlot? get slot => MealSlot.values.where((s) => s.name == data['slot']).firstOrNull;

  /// N-04 분석 완료
  bool get isAnalysisDone => type == 'N-04' && mealId != null;
}

/// 푸시 수신 계약. [FirebasePushService](FCM) · [NoPushService](설정 없음) · [MockPushService](테스트).
abstract class PushService {
  /// 'android' | 'ios' (devices.platform). 지원하지 않는 기기면 null.
  String? get platform;

  Future<PushPermission> permission();

  /// OS 권한 창(iOS requestAuthorization, Android 13+ POST_NOTIFICATIONS). 이미 정해졌으면 창 없이 현재 값.
  Future<PushPermission> requestPermission();

  /// FCM 등록 토큰. 권한이 없거나 설정이 없으면 null.
  Future<String?> token();

  Stream<String> get tokenRefresh;

  /// 앱이 화면에 떠 있을 때 받은 푸시(OS 알림은 뜨지 않음)
  Stream<PushMessage> get foreground;

  /// 알림을 눌러 앱으로 들어옴(백그라운드 → 포그라운드)
  Stream<PushMessage> get opened;

  /// 앱이 꺼진 상태에서 알림을 눌러 실행됐으면 그 알림(한 번만)
  Future<PushMessage?> initialMessage();
}

/// FCM 설정이 없을 때: 권한·토큰 없음. N-04 는 서버에서 no_push 로 남고 앱은 홈에서 다시 읽어 초안을 채운다.
class NoPushService implements PushService {
  @override
  String? get platform => null;
  @override
  Future<PushPermission> permission() async => PushPermission.notAsked;
  @override
  Future<PushPermission> requestPermission() async => PushPermission.notAsked;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Stream<PushMessage> get foreground => const Stream.empty();
  @override
  Stream<PushMessage> get opened => const Stream.empty();
  @override
  Future<PushMessage?> initialMessage() async => null;
}

/// 테스트용: 권한 응답·토큰을 정하고 푸시를 직접 흘려보낸다
class MockPushService implements PushService {
  MockPushService({this.platform = 'android', this.answer = PushPermission.granted, this.currentToken = 'mock-token', this.launch});

  @override
  final String? platform;

  /// 권한 창에서 사용자가 고를 답
  PushPermission answer;
  PushPermission current = PushPermission.notAsked;
  String? currentToken;
  PushMessage? launch;
  int requests = 0;

  final _refresh = StreamController<String>.broadcast();
  final _fg = StreamController<PushMessage>.broadcast();
  final _opened = StreamController<PushMessage>.broadcast();

  void emitForeground(PushMessage m) => _fg.add(m);
  void emitOpened(PushMessage m) => _opened.add(m);
  void rotateToken(String t) {
    currentToken = t;
    _refresh.add(t);
  }

  @override
  Future<PushPermission> permission() async => current;
  @override
  Future<PushPermission> requestPermission() async {
    requests++;
    if (current == PushPermission.notAsked) current = answer;
    return current;
  }

  @override
  Future<String?> token() async => current == PushPermission.granted ? currentToken : null;
  @override
  Stream<String> get tokenRefresh => _refresh.stream;
  @override
  Stream<PushMessage> get foreground => _fg.stream;
  @override
  Stream<PushMessage> get opened => _opened.stream;
  @override
  Future<PushMessage?> initialMessage() async {
    final m = launch;
    launch = null;
    return m;
  }
}

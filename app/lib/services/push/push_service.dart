import 'dart:async';
import 'dart:convert';

import '../../core/engine/engine.dart' show MealSlot;

/// OS 알림 권한(05 devices.push_permission 과 같은 값)
enum PushPermission {
  granted('granted'),
  denied('denied'),
  notAsked('not_asked');

  const PushPermission(this.wire);
  final String wire;
}

/// 받은 푸시 한 건. 서버 notify·analyze-meal·verdict 가 data 에 type·id(알림)와 payload(N-01: local_date, N-02: local_date·kind·slot·pending, N-04: meal_id·slot, N-05: review_id, N-06: review_id·verdict)를 싣는다.
class PushMessage {
  const PushMessage({required this.data, this.title, this.body});
  final Map<String, String> data;
  final String? title;
  final String? body;

  String? get type => data['type'];
  String? get mealId => data['meal_id'];
  MealSlot? get slot => MealSlot.values.where((s) => s.name == data['slot']).firstOrNull;

  String? get reviewId => data['review_id'];

  /// 알림의 챌린지(D53): challenge_ids(FCM 은 JSON 배열 문자열) 또는 challenge_id. 이전 서버는 없음.
  List<String> get challengeIds {
    final many = data['challenge_ids'];
    if (many != null) {
      try {
        final v = jsonDecode(many);
        if (v is List) return [for (final x in v) if (x is String) x];
      } catch (_) {}
      return const [];
    }
    final one = data['challenge_id'];
    return one == null ? const [] : [one];
  }

  /// approve · warn · void · exclude
  String? get verdict => data['verdict'];

  /// N-01 대상 날짜(KST, payload local_date 'YYYY-MM-DD')
  DateTime? get localDate {
    final v = data['local_date'];
    if (v == null) return null;
    final d = DateTime.tryParse(v);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  /// N-01 어제 확정 결과(09:30, 본문 "어제 32.4점, 누적 11위")
  bool get isDailyResult => type == 'N-01';

  /// N-02 21:00 조건부 리마인드(확정 대기 끼니 또는 오늘 동기화 0건)
  bool get isReminder => type == 'N-02';

  /// N-02 종류: confirm(확정 대기) · sync(동기화). payload 에 kind 가 없던 이전 서버는 문장으로 가른다.
  String get reminderKind => data['kind'] ?? ((body ?? '').contains('동기화') ? 'sync' : 'confirm');

  /// N-04 분석 완료
  bool get isAnalysisDone => type == 'N-04' && mealId != null;

  /// N-05 검토 안내·소명 요청(신고·배치 플래그). 신고자·사유는 실리지 않는다.
  bool get isReviewNotice => type == 'N-05';

  /// N-06 판정 결과(통지 문장 = 알림 본문: 사유 + 판정 + 점수 영향)
  bool get isVerdict => type == 'N-06' && reviewId != null;
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

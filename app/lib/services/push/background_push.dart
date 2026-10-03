import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../api/challory_api.dart';
import '../api/supabase_api.dart';
import '../health/health_package_source.dart';
import '../health/health_source.dart';
import 'push_service.dart';

/// 앱이 꺼져 있거나 백그라운드일 때 받은 푸시(별도 isolate). 걸음 동기화 리마인드(N-02 sync)만 다룬다:
/// D36 대로 받자마자 건강 데이터를 읽어 sync-activity 로 올린다. 다른 알림은 OS 알림만 뜨고 앱을 열 때 다시 읽는다.
enum BackgroundSyncResult { notLoggedIn, noData, uploaded, failed }

bool isBackgroundStepSync(PushMessage m) => m.isReminder && m.reminderKind == 'sync';

/// 건강 데이터 3일치를 읽어 올린다. 읽기·업로드가 안 되면 던지지 않고 failed(다음에 앱을 열 때 같은 3일을 다시 올린다).
Future<BackgroundSyncResult> syncStepsInBackground({
  required bool loggedIn,
  required HealthSource health,
  required ChalloryApi api,
}) async {
  if (!loggedIn) return BackgroundSyncResult.notLoggedIn;
  try {
    final days = await health.fetchDays();
    if (days.isEmpty) return BackgroundSyncResult.noData;
    await api.syncActivity(buildSyncBatch(days));
    return BackgroundSyncResult.uploaded;
  } catch (e) {
    debugPrint('push(background): 걸음 동기화 건너뜀 ($e)');
    return BackgroundSyncResult.failed;
  }
}

/// FirebaseMessaging.onBackgroundMessage 처리기. 최상위 함수여야 하고 별도 isolate 에서 돈다.
@pragma('vm:entry-point')
Future<void> onBackgroundPush(RemoteMessage message) async {
  final m = PushMessage(data: {for (final e in message.data.entries) e.key: '${e.value}'}, body: message.notification?.body);
  if (!isBackgroundStepSync(m) || !AppConfig.hasSupabase) return;
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false), // 이 isolate 는 딥링크를 받지 않는다
    );
  } catch (_) {
    // 같은 isolate 에서 이미 초기화됨
  }
  final auth = Supabase.instance.client.auth;
  var session = auth.currentSession;
  // 저장된 세션은 바로 들어오지만 만료 갱신은 뒤에서 진행되므로, 만료됐으면 기다려서 갱신한다
  if (session != null && session.isExpired) {
    try {
      session = (await auth.refreshSession()).session;
    } catch (_) {
      session = null;
    }
  }
  final result = await syncStepsInBackground(
    loggedIn: session != null,
    health: createHealthSource(),
    api: SupabaseChalloryApi(Supabase.instance.client),
  );
  debugPrint('push(background): N-02 sync → ${result.name}');
}

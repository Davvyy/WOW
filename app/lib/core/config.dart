/// 실행 설정. 값이 없으면 모의(mock) 모드로 동작한다.
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class AppConfig {
  AppConfig._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// 카카오 네이티브 앱 키(카카오 디벨로퍼스). 없으면 카카오 로그인은 브라우저 OAuth 로 한다.
  static const kakaoNativeAppKey = String.fromEnvironment('KAKAO_NATIVE_APP_KEY');

  /// 브라우저 OAuth 복귀 딥링크. Supabase Auth > URL Configuration > Redirect URLs 에도 등록해야 한다.
  static const authRedirect = 'app.challory://login-callback';

  /// 서버 규칙 steps_spike_abs 기본값(검토 플래그 기준). 앱은 안내 문구에만 쓴다.
  static const stepsSpikeAbs = 25000;
}

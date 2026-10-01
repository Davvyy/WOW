/// 실행 설정. 값이 없으면 모의(mock) 모드로 동작한다.
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class AppConfig {
  AppConfig._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// 서버 규칙 steps_spike_abs 기본값(검토 플래그 기준). 앱은 안내 문구에만 쓴다.
  static const stepsSpikeAbs = 25000;
}

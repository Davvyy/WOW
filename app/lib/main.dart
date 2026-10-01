import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // SUPABASE_URL / SUPABASE_ANON_KEY 가 있으면 서버 연결, 없으면 모의 데이터로만 동작한다.
  // 카카오 네이티브 로그인(앱 키가 있을 때만). 없으면 카카오 로그인은 Supabase 브라우저 OAuth 로 한다.
  if (AppConfig.kakaoNativeAppKey.isNotEmpty) KakaoSdk.init(nativeAppKey: AppConfig.kakaoNativeAppKey);
  if (AppConfig.hasSupabase) {
    await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseAnonKey);
  }
  runApp(const ProviderScope(child: ChalloryApp()));
}

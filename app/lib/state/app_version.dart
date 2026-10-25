import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 설치된 앱 버전 '이름 (빌드 번호)', 예: '1.0.7 (8)'. 설정 맨 아래 표시와 알림 기기 등록(p_app_version)에 쓴다.
/// main 에서 시작할 때 한 번 읽어 넣는다([readAppVersion]). 넣지 않으면(테스트 등) null.
final appVersionProvider = Provider<String?>((ref) => null);

/// 플랫폼에서 앱 버전을 읽는다. 못 읽으면 null(버전 없이 동작)
Future<String?> readAppVersion() async {
  try {
    final i = await PackageInfo.fromPlatform().timeout(const Duration(seconds: 2));
    return '${i.version} (${i.buildNumber})';
  } catch (e) {
    debugPrint('app: 버전 읽기 건너뜀 ($e)');
    return null;
  }
}

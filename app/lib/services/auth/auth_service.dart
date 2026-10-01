import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';

/// 로그인(05 API #1, 02 §3-1 Kakao·Apple).
/// 기본 경로는 네이티브 SDK 로 받은 ID 토큰을 Supabase Auth 에 넘기는 `grant_type=id_token`.
/// 네이티브 경로가 없으면(카카오 앱 키 미설정·Android 의 Apple) 브라우저 OAuth → 딥링크([AppConfig.authRedirect]) 복귀.
abstract class AuthService {
  bool get isSignedIn;
  String? get userId;

  /// 로그인 제공자가 준 표시 이름(닉네임 기본값)
  String? get displayName;

  /// 로그인 상태가 바뀔 때마다(true = 로그인)
  Stream<bool> get changes;

  Future<AuthOutcome> signInWithKakao();
  Future<AuthOutcome> signInWithApple();
  Future<void> signOut();
}

/// 로그인 시도 결과. [redirected] 는 브라우저로 넘어가 복귀(딥링크)를 기다리는 중.
enum AuthOutcome { signedIn, redirected, cancelled }

class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 원본 nonce 와 SHA-256(hex). 제공자에게는 해시를, Supabase 에는 원본을 보낸다.
({String raw, String hashed}) newNonce([Random? rng]) {
  const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
  final r = rng ?? Random.secure();
  final raw = List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
  return (raw: raw, hashed: crypto.sha256.convert(utf8.encode(raw)).toString());
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this._client);
  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  @override
  bool get isSignedIn => _auth.currentSession != null;
  @override
  String? get userId => _auth.currentUser?.id;
  @override
  String? get displayName {
    final m = _auth.currentUser?.userMetadata;
    return (m?['nickname'] ?? m?['name'] ?? m?['full_name']) as String?;
  }

  @override
  Stream<bool> get changes => _auth.onAuthStateChange.map((s) => s.session != null);

  @override
  Future<AuthOutcome> signInWithKakao() async {
    if (AppConfig.kakaoNativeAppKey.isEmpty) return _oauth(OAuthProvider.kakao);
    final nonce = newNonce();
    try {
      // 카카오톡 앱이 있으면 앱으로, 없으면 카카오계정 웹 로그인. OpenID Connect 활성화 필요(id_token).
      final token = await kakao.isKakaoTalkInstalled()
          ? await kakao.UserApi.instance.loginWithKakaoTalk(nonce: nonce.hashed)
          : await kakao.UserApi.instance.loginWithKakaoAccount(nonce: nonce.hashed);
      final idToken = token.idToken;
      if (idToken == null) throw const AuthFailure('카카오 로그인 설정을 확인해 주세요(OpenID Connect)');
      await _auth.signInWithIdToken(provider: OAuthProvider.kakao, idToken: idToken, accessToken: token.accessToken, nonce: nonce.raw);
      return AuthOutcome.signedIn;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') return AuthOutcome.cancelled; // 사용자가 카카오톡 동의 화면을 닫음
      throw AuthFailure('카카오 로그인을 마치지 못했어요(${e.code})');
    } on kakao.KakaoAuthException catch (e) {
      if (e.error == kakao.AuthErrorCause.accessDenied) return AuthOutcome.cancelled;
      throw AuthFailure('카카오 로그인을 마치지 못했어요(${e.error.name})');
    } on kakao.KakaoClientException catch (e) {
      if (e.reason == kakao.ClientErrorCause.cancelled) return AuthOutcome.cancelled;
      throw AuthFailure('카카오 로그인을 마치지 못했어요(${e.reason.name})');
    } on AuthException catch (e) {
      throw AuthFailure('로그인을 마치지 못했어요: ${e.message}');
    }
  }

  @override
  Future<AuthOutcome> signInWithApple() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return _oauth(OAuthProvider.apple);
    final nonce = newNonce();
    try {
      final cred = await SignInWithApple.getAppleIDCredential(scopes: const [], nonce: nonce.hashed);
      final idToken = cred.identityToken;
      if (idToken == null) throw const AuthFailure('Apple 로그인 정보를 받지 못했어요');
      await _auth.signInWithIdToken(provider: OAuthProvider.apple, idToken: idToken, nonce: nonce.raw);
      return AuthOutcome.signedIn;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return AuthOutcome.cancelled;
      throw AuthFailure('Apple 로그인을 마치지 못했어요(${e.code.name})');
    } on AuthException catch (e) {
      throw AuthFailure('로그인을 마치지 못했어요: ${e.message}');
    }
  }

  Future<AuthOutcome> _oauth(OAuthProvider p) async {
    try {
      final ok = await _auth.signInWithOAuth(p, redirectTo: AppConfig.authRedirect, authScreenLaunchMode: LaunchMode.externalApplication);
      return ok ? AuthOutcome.redirected : AuthOutcome.cancelled;
    } on AuthException catch (e) {
      throw AuthFailure('로그인을 시작하지 못했어요: ${e.message}');
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

/// 서버 없이(SUPABASE_URL 미설정) 버튼을 누르면 바로 로그인된 것으로 본다.
class MockAuthService implements AuthService {
  MockAuthService([this._signedIn = false]);
  bool _signedIn;
  final _ctrl = StreamController<bool>.broadcast();
  final calls = <String>[];

  @override
  bool get isSignedIn => _signedIn;
  @override
  String? get userId => _signedIn ? 'mock-user' : null;
  @override
  String? get displayName => _signedIn ? '지수' : null;
  @override
  Stream<bool> get changes => _ctrl.stream;

  Future<AuthOutcome> _in(String p) async {
    calls.add(p);
    _signedIn = true;
    _ctrl.add(true);
    return AuthOutcome.signedIn;
  }

  @override
  Future<AuthOutcome> signInWithKakao() => _in('kakao');
  @override
  Future<AuthOutcome> signInWithApple() => _in('apple');
  @override
  Future<void> signOut() async {
    calls.add('signOut');
    _signedIn = false;
    _ctrl.add(false);
  }
}

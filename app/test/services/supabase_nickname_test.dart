// SupabaseChalloryApi.setNickname(D81): RPC set_my_nickname 에 p_nickname 을 보내고 {nickname} 을 받는다.
// 서버 오류(PT422·PT409)는 ApiException(422·409, 서버 문구 그대로) — 화면은 apiErrorText 로 그 문구를 보인다.
// 이 컴퓨터에 띄운 가짜 서버(127.0.0.1)로 실제 supabase-js 호출 경로를 그대로 탄다.
import 'dart:convert';
import 'dart:io';

import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/supabase_api.dart';
import 'package:challory/state/app_state.dart' show apiErrorText;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late HttpServer server;
  late SupabaseChalloryApi api;
  final requests = <String>[];
  Object? body;
  var status = 200;
  Object response = const {'nickname': '새이름'};

  setUp(() async {
    requests.clear();
    status = 200;
    response = const {'nickname': '새이름'};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add('${req.method} ${req.uri.path}');
      body = jsonDecode(await utf8.decoder.bind(req).join());
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(response));
      await req.response.close();
    });
    api = SupabaseChalloryApi(SupabaseClient('http://127.0.0.1:${server.port}', 'anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false)));
  });
  tearDown(() => server.close(force: true));

  test('set_my_nickname 에 p_nickname 을 보내고 저장된 닉네임을 돌려준다', () async {
    expect(await api.setNickname('새이름'), '새이름');
    expect(requests, ['POST /rest/v1/rpc/set_my_nickname']);
    expect(body, {'p_nickname': '새이름'});
  });

  test('중복(PT409)·길이(PT422)는 서버 문구 그대로', () async {
    status = 409;
    response = const {'code': 'PT409', 'message': '이미 같은 챌린지에 있는 닉네임이에요', 'details': null, 'hint': null};
    final e = await api.setNickname('Bobby').then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<ApiException>().having((x) => x.status, 'status', 409));
    expect(apiErrorText(e!), '이미 같은 챌린지에 있는 닉네임이에요');

    status = 400;
    response = const {'code': 'PT422', 'message': '닉네임은 2~12자로 정해 주세요', 'details': null, 'hint': null};
    await expectLater(api.setNickname('가'),
        throwsA(isA<ApiException>().having((x) => x.status, 'status', 422).having((x) => x.message, 'message', '닉네임은 2~12자로 정해 주세요')));
  });
}

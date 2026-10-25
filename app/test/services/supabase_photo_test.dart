// SupabaseChalloryApi.fetchMealPhoto(전수 점검 #22): Edge photo-url 에 meal_id 를 보내 서명 URL 을 받고, 그 URL 로 사진을 받는다.
// 이 컴퓨터에 띄운 가짜 서버(127.0.0.1)로 실제 supabase-js 호출 경로를 그대로 탄다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/supabase_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _meal = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
final _jpeg = Uint8List.fromList([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);

/// photo-url 응답 상태와 서명 URL GET 상태를 고를 수 있는 가짜 Supabase
class _FakeSupabase {
  _FakeSupabase(this.server);
  final HttpServer server;
  int fnStatus = 200;
  int objectStatus = 200;
  final requests = <String>[];
  Object? fnBody;

  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_FakeSupabase> start() async {
    final s = _FakeSupabase(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s.server.listen(s._handle);
    return s;
  }

  Future<void> _handle(HttpRequest req) async {
    requests.add('${req.method} ${req.uri.path}');
    final res = req.response;
    if (req.uri.path == '/functions/v1/photo-url') {
      fnBody = jsonDecode(await utf8.decoder.bind(req).join());
      res.statusCode = fnStatus;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(fnStatus == 200
          ? {'meal_id': _meal, 'signed_url': '$url/storage/v1/object/sign/meal-photos/c/p/ph.jpg?token=t', 'expires_in': 300}
          : {'error': 'photo not found'}));
    } else if (req.uri.path == '/storage/v1/object/sign/meal-photos/c/p/ph.jpg') {
      res.statusCode = objectStatus;
      if (objectStatus == 200) {
        res.headers.contentType = ContentType('image', 'jpeg');
        res.add(_jpeg);
      } else {
        res.write('{"error":"not_found"}');
      }
    } else {
      res.statusCode = 500;
    }
    await res.close();
  }
}

void main() {
  late _FakeSupabase fake;
  late SupabaseChalloryApi api;

  setUp(() async {
    fake = await _FakeSupabase.start();
    api = SupabaseChalloryApi(SupabaseClient(fake.url, 'anon-key', authOptions: const AuthClientOptions(autoRefreshToken: false)));
  });
  tearDown(() => fake.server.close(force: true));

  test('내 사진: photo-url 에 meal_id 를 보내고 서명 URL 로 받은 바이트를 돌려준다', () async {
    expect(await api.fetchMealPhoto(_meal), _jpeg);
    expect(fake.fnBody, {'meal_id': _meal});
    expect(fake.requests, ['POST /functions/v1/photo-url', 'GET /storage/v1/object/sign/meal-photos/c/p/ph.jpg']);
  });

  test('404(사진 없음·파기·남의 끼니)는 null, 서명 URL 을 받지 않는다', () async {
    fake.fnStatus = 404;
    expect(await api.fetchMealPhoto(_meal), isNull);
    expect(fake.requests, ['POST /functions/v1/photo-url']);
  });

  test('객체가 없어진 서명 URL(400·404)도 null', () async {
    for (final s in [400, 404]) {
      fake.objectStatus = s;
      expect(await api.fetchMealPhoto(_meal), isNull);
    }
  });

  test('그 밖의 서버 오류는 ApiException(상태 그대로), 연결이 안 되면 0', () async {
    fake.fnStatus = 502;
    await expectLater(api.fetchMealPhoto(_meal), throwsA(isA<ApiException>().having((e) => e.status, 'status', 502)));
    fake.fnStatus = 200;
    fake.objectStatus = 500;
    await expectLater(api.fetchMealPhoto(_meal), throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
    await fake.server.close(force: true);
    await expectLater(api.fetchMealPhoto(_meal), throwsA(isA<ApiException>().having((e) => e.status, 'status', 0)));
  });
}

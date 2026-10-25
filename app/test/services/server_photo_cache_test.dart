// 서버 사진 메모리 캐시(전수 점검 #22): 끼니마다 세션 동안 한 번만 받는다. 동시에 물어도 한 번,
// 서버에 없으면(404) 그 답도 기억하고, 연결 오류는 기억하지 않아 다음에 다시 받는다. 오래 안 본 끼니부터 비운다.
import 'dart:async';
import 'dart:typed_data';

import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/photo/server_photo_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = Uint8List.fromList([1, 2, 3]);

  test('같은 끼니는 한 번만 받고, 동시에 물어도 한 번', () async {
    final asked = <String>[];
    final gate = Completer<Uint8List?>();
    final cache = ServerPhotoCache((id) {
      asked.add(id);
      return gate.future;
    });
    final f1 = cache.get('m1'), f2 = cache.get('m1');
    gate.complete(a);
    expect(await f1, a);
    expect(await f2, a);
    expect(await cache.get('m1'), a);
    expect(asked, ['m1']);
    expect(cache.has('m1'), isTrue);
  });

  test('서버에 없음(null)도 기억한다', () async {
    var n = 0;
    final cache = ServerPhotoCache((_) async {
      n++;
      return null;
    });
    expect(await cache.get('m1'), isNull);
    expect(await cache.get('m1'), isNull);
    expect(n, 1);
  });

  test('연결 오류는 null 로 돌려주고 기억하지 않는다', () async {
    var n = 0;
    final cache = ServerPhotoCache((_) async {
      n++;
      if (n == 1) throw const ApiException(0, 'offline');
      return a;
    });
    expect(await cache.get('m1'), isNull);
    expect(cache.has('m1'), isFalse);
    expect(await cache.get('m1'), a);
    expect(n, 2);
  });

  test('forget·clear 하면 다시 받는다', () async {
    var n = 0;
    final cache = ServerPhotoCache((_) async {
      n++;
      return a;
    });
    await cache.get('m1');
    cache.forget('m1');
    expect(cache.has('m1'), isFalse);
    await cache.get('m1');
    cache.clear();
    await cache.get('m1');
    expect(n, 3);
  });

  test('상한을 넘으면 가장 오래 안 본 끼니부터 비운다', () async {
    final asked = <String>[];
    final cache = ServerPhotoCache((id) async {
      asked.add(id);
      return a;
    }, maxEntries: 2);
    await cache.get('m1');
    await cache.get('m2');
    await cache.get('m1'); // m1 을 최근으로
    await cache.get('m3'); // m2 를 비운다
    expect(cache.has('m1'), isTrue);
    expect(cache.has('m2'), isFalse);
    expect(cache.has('m3'), isTrue);
    expect(asked, ['m1', 'm2', 'm3']);
  });
}

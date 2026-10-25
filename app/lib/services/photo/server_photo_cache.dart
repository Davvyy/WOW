import 'dart:typed_data';

/// 서버에 있는 내 끼니 사진(Edge photo-url 서명 URL로 받은 것)의 세션 메모리 캐시.
/// 이 폰에 공유용 보관본이 없을 때(다시 설치·7일 지남·다른 폰) P7 사진 칸과 홈 썸네일이 쓴다.
/// - 끼니마다 한 번만 받는다. 받는 중에 또 물으면 같은 Future 를 준다.
/// - 서버에 없음(사진 없음·파기·404 → null)도 기억한다.
/// - 연결 오류는 null 로 돌려주고 기억하지 않는다: 다음에 다시 열면 다시 받는다.
/// - [maxEntries] 를 넘으면 가장 오래 안 본 끼니부터 비운다(사진 1장 수백 KB).
class ServerPhotoCache {
  ServerPhotoCache(this._fetch, {this.maxEntries = 30});

  final Future<Uint8List?> Function(String mealId) _fetch;
  final int maxEntries;

  /// 삽입 순서 = 최근에 본 순서(LinkedHashMap)
  final _byMeal = <String, Future<Uint8List?>>{};

  bool has(String mealId) => _byMeal.containsKey(mealId);

  Future<Uint8List?> get(String mealId) {
    final hit = _byMeal.remove(mealId);
    if (hit != null) return _byMeal[mealId] = hit;
    late final Future<Uint8List?> f;
    Future<Uint8List?> load() async {
      try {
        return await Future.microtask(() => _fetch(mealId)); // f 를 넣은 뒤에 부른다(동기 예외도 아래에서)
      } catch (_) {
        if (identical(_byMeal[mealId], f)) _byMeal.remove(mealId);
        return null;
      }
    }

    f = load();
    _byMeal[mealId] = f;
    while (_byMeal.length > maxEntries) {
      _byMeal.remove(_byMeal.keys.first);
    }
    return f;
  }

  void forget(String mealId) => _byMeal.remove(mealId);

  void clear() => _byMeal.clear();
}

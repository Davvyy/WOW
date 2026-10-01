import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// docs/06 §6: 수치심 없는 문구. 화면 문자열(과 주석)에 아래 어휘를 쓰지 않는다.
const forbidden = ['실패', '부정', '조작', '거짓', '적발', '꼴찌'];

void main() {
  test('lib/**/*.dart 에 금지 어휘가 없다', () {
    final root = Directory('lib');
    expect(root.existsSync(), isTrue);
    final hits = <String>[];
    for (final f in root.listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final w in forbidden) {
          if (lines[i].contains(w)) hits.add('$path:${i + 1} "$w"');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}

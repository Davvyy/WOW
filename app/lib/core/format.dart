import 'engine/engine.dart';

/// 숫자 포맷 (prototype/data.js fmt 와 동일 규칙).
String _group(String digits) {
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return b.toString();
}

/// 정수 반올림(half-up) + 천 단위 구분.
String fmtInt(num n) {
  final r = (n + 0.5).floor();
  final s = _group(r.abs().toString());
  return r < 0 ? '−$s' : s;
}

/// 소수 1자리(항상 표시).
String fmtK1(num n) {
  final r = round1(n);
  final neg = r < 0;
  final parts = r.abs().toStringAsFixed(1).split('.');
  return '${neg ? '−' : ''}${_group(parts[0])}.${parts[1]}';
}

String fmtSigned(num n) {
  final r = (n + 0.5).floor();
  final s = _group(r.abs().toString());
  return r > 0 ? '+$s' : (r < 0 ? '−$s' : s);
}

String fmtPct(num ratio) => '${(ratio * 100 + 0.5).floor()}%';

/// 소수점 최대 4자리(0.0327 kcal/보 등), 불필요한 0 제거 없이 고정.
String fmtFixed(num n, int digits) => n.toStringAsFixed(digits);

String weekdayKo(int month, int day, {int year = 2026}) =>
    const ['월', '화', '수', '목', '금', '토', '일'][DateTime(year, month, day).weekday - 1];

/// 대체값 M_p 표기: 742.5 → 743 (프로토타입 Math.ceil)
String fmtM(double m) => fmtInt(m.ceil());

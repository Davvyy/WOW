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

/// 요일 한 글자('월'~'일'). 날짜의 실제 연도로 계산한다.
String weekdayKo(DateTime date) => const ['월', '화', '수', '목', '금', '토', '일'][DateTime(date.year, date.month, date.day).weekday - 1];

/// 대체값 M_p 표기: 742.5 → 743 (프로토타입 Math.ceil)
String fmtM(double m) => fmtInt(m.ceil());

/// 조사 '로/으로' 선택. 받침 없음·ㄹ 받침 → 로, 그 외 → 으로. 숫자는 끝자리 발음 기준.
String roParticle(String s) {
  final t = s.trim();
  if (t.isEmpty) return '로';
  final ch = t[t.length - 1];
  if (RegExp(r'\d').hasMatch(ch)) {
    return const ['0', '1', '3', '6', '7', '8'].contains(ch) ? '으로' : '로';
  }
  final code = ch.codeUnitAt(0);
  if (code < 0xAC00 || code > 0xD7A3) return '로';
  final jong = (code - 0xAC00) % 28;
  return (jong == 0 || jong == 8) ? '로' : '으로';
}

/// 날짜 "10.6" (월.일, 06 §6 표기)
String fmtMd(DateTime d) => '${d.month}.${d.day}';

/// 날짜의 확정 칩(홈 지난 날 · 순위 누적): 그날 점수는 다음 날 [finalizeTime] 에 확정된다. 확정됐으면 '확정 · M.D HH:MM', 아직이면 '확정 예정 · …'.
/// 다음 날은 달력 날짜로 더한다(10.31 → 11.1).
String pastDayChipText(DateTime date, {required bool isFinal, required String finalizeTime}) {
  final next = DateTime(date.year, date.month, date.day + 1);
  return '${isFinal ? '확정' : '확정 예정'} · ${fmtMd(next)} $finalizeTime';
}

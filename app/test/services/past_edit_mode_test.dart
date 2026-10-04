// 지난 날 끼니를 고칠 수 있는지: 확정 전이면 전부, 확정 뒤 48시간 안이면 정정만, 그 뒤로는 보기만.
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/past_meals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 10.12 기록은 10.13 09:00 KST(= 00:00 UTC)에 확정
  final finalizedAt = DateTime.utc(2026, 10, 13);
  PastEditMode at(Duration after, {bool isFinal = true, DateTime? fin}) =>
      pastEditMode(isFinal: isFinal, finalizedAt: isFinal ? (fin ?? finalizedAt) : null, now: finalizedAt.add(after), editWindow: kEditWindow);

  test('확정 전 날짜는 확정·지우기 모두', () {
    expect(pastEditMode(isFinal: false, finalizedAt: null, now: finalizedAt.subtract(const Duration(hours: 1)), editWindow: kEditWindow),
        PastEditMode.full);
  });

  test('확정 뒤 47시간: 정정만(지우기 없음)', () {
    expect(at(const Duration(hours: 47)), PastEditMode.correctOnly);
  });

  test('확정 뒤 49시간: 보기만', () {
    expect(at(const Duration(hours: 49)), PastEditMode.readOnly);
  });

  test('확정됐는데 finalized_at 이 없으면 짐작하지 않고 보기만', () {
    expect(pastEditMode(isFinal: true, finalizedAt: null, now: finalizedAt, editWindow: kEditWindow), PastEditMode.readOnly);
  });

  test('수정 기한은 규칙 값(48시간)', () {
    expect(kEditWindow, const Duration(hours: 48));
  });

  test('장부 행은 finalized_at 과 날짜(YYYY-MM-DD)를 함께 읽는다', () {
    final row = ledgerRowFromServer({
      'id': 'ds-7',
      'local_date': '2026-10-12',
      'is_final': true,
      'finalized_at': '2026-10-13T00:00:05+00:00',
      'breakdown': const <String, dynamic>{},
    }, mockChallenge.start);
    expect(row.d, 7);
    expect(row.localDate, '2026-10-12');
    expect(row.provisional, isFalse);
    expect(row.finalizedAt, DateTime.utc(2026, 10, 13, 0, 0, 5));
    final open = ledgerRowFromServer({'id': 'ds-8', 'local_date': '2026-10-13', 'is_final': false, 'breakdown': const <String, dynamic>{}}, mockChallenge.start);
    expect(open.finalizedAt, isNull);
  });

  test('날짜 계산은 기기 시간대(서머타임)와 무관: 10.20 시작 7일째 = 10.26', () {
    final start = DateTime(2026, 10, 20);
    expect(localDateOfDay(start, 7), '2026-10-26');
    expect(dayOfLocalDate(start, '2026-10-26'), 7);
    expect(localDateOfDay(DateTime(2026, 10, 6), 28), '2026-11-02');
    expect(dayOfLocalDate(DateTime(2026, 10, 6), '2026-11-02'), 28);
    expect(dayOfLocalDate(start, 'oops'), isNull);
  });
}

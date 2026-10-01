// supabase/tests/run.sh 가 만든 test/fixtures/server_ledger.json(시드 DB의 실제 서버 응답 모양)을 앱 모델로 바꿔
// 프로토타입 숫자와 맞는지 확인한다: 지수 10.12 저녁 무효 판정 후 41.2→12.7, 누적 341.1→312.6.
import 'dart:convert';
import 'dart:io';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final f = jsonDecode(File('test/fixtures/server_ledger.json').readAsStringSync()) as Map<String, dynamic>;
  final start = DateTime.parse(f['start_date'] as String);
  final pid = f['participant_id'] as String;
  final rows = (f['daily_scores'] as List).cast<Map<String, dynamic>>();
  final revs = (f['revisions'] as List).cast<Map<String, dynamic>>();
  final types = {for (final r in (f['reviews'] as List)) (r as Map)['id'] as String: r['type'] as String};
  final ledger = [
    for (final r in rows) ledgerRowFromServer(r, start, revisions: [for (final v in revs) if (v['daily_score_id'] == r['id']) v], reviewTypes: types),
  ];

  group('장부(daily_scores → LedgerRow)', () {
    test('D1~D8, 날짜 표기, 점검 기간·잠정', () {
      expect(ledger.map((r) => r.d), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(ledger.first.date, '10.6');
      expect(ledger.take(3).every((r) => r.check), isTrue);
      expect(ledger.last.provisional, isTrue);
      expect(ledger.take(7).every((r) => !r.provisional), isTrue);
    });
    test('서버 값 = 프로토타입 장부(정정 반영)', () {
      for (var i = 0; i < 8; i++) {
        expect(ledger[i].s, closeTo(mockLedger[i].s, 0.05), reason: 'D${i + 1} S');
        expect(ledger[i].a, closeTo(mockLedger[i].a, 0.05), reason: 'D${i + 1} A');
        expect(ledger[i].i, closeTo(mockLedger[i].i, 0.05), reason: 'D${i + 1} I');
        expect(ledger[i].steps, mockLedger[i].steps, reason: 'D${i + 1} 걸음');
      }
    });
    test('10.12 판정 정정: 41.2 → 12.7, 사유 dup_photo, 저녁 대체값', () {
      final d7 = ledger[6];
      expect(d7.s, 12.7);
      expect(d7.sBefore, 41.2);
      expect(d7.revisionReason, 'dup_photo');
      expect(d7.hasRevision, isTrue);
      expect(d7.substituted, [MealSlot.dinner]);
      expect(d7.history, contains('판정 41.2→12.7점'));
    });
    test('D3 아침 미기록 → 대체값 슬롯, D6 하한 적용', () {
      expect(ledger[2].substituted, [MealSlot.breakfast]);
      expect(ledger[5].floorApplied, isTrue);
    });
    test('누적(확정분) 312.6 · 주간 피드백은 장부에서 계산', () {
      final cum = round1(ledger.where((x) => !x.check && !x.provisional).fold(0.0, (a, x) => a + x.s));
      expect(cum, (f['expect'] as Map)['cumulative']);
      final w = weeklyFrom(ledger)!;
      expect(w.days, 4);
      expect(w.avg, 78.1); // 06 P9 "하루 평균 약 78.1점"
    });
    test('화면용 결과(공식 카드)는 서버 분해값 그대로', () {
      final t = resultFromLedgerRow(ledger.last);
      expect([t.bmr, t.activity.aD, t.intake.iD, t.score.sD], [1650, 294.0, 1800.0, 28.8]);
      expect(t.intake.mP, 742.5);
    });
  });

  group('리더보드(스냅샷 rows → LeaderRow)', () {
    test('누적: 내 행 표시·공동 순위·격차', () {
      final lb = leaderboardFromServer(
        todayRows: f['snapshot_today'] as List,
        cumulativeRows: f['snapshot_cumulative'] as List,
        myParticipantId: pid,
        myNickname: '지수',
        myToday: 28.8,
        myCumulative: 312.6,
      );
      final me = lb.meIn(lb.cumulative)!;
      expect(me.score, 312.6);
      expect(me.participantId, pid);
      expect(me.underReview, isFalse);
      final ranks = lb.cumulative.map((r) => r.rank).toList();
      for (var i = 1; i < ranks.length; i++) {
        expect(ranks[i] >= ranks[i - 1], isTrue, reason: '순위 오름차순');
      }
      // 검토 중인 참가자(달려라하니 R-0412·오이냉국 R-0417)는 '집계 중' — 이름·점수 없음
      final agg = lb.cumulative.where((r) => r.aggregating).toList();
      expect(agg, hasLength(2));
      expect(agg.every((r) => r.score == null && r.participantId == null), isTrue);
      if (me.rank > 1) expect(me.gapToPrev, isNotNull);
      expect(lb.meIn(lb.today)!.score, 28.8);
    });

    test('내가 검토 중이면 서버는 집계 중 → 내 점수로 순위를 계산해 그 자리에 내 행', () {
      final raw = f['snapshot_cumulative_under_review'] as List;
      expect(raw.where((r) => (r as Map)['participant_id'] == pid), isEmpty, reason: '서버 스냅샷에는 내 이름이 없음');
      final rows = leaderRowsFromSnapshot(raw, myParticipantId: pid, myNickname: '지수', myScore: 341.1, myUnderReview: true);
      final me = rows.firstWhere((r) => r.me);
      expect(me.underReview, isTrue);
      expect(me.score, 341.1);
      expect(rows.where((r) => r.aggregating), hasLength(raw.where((r) => (r as Map)['aggregating'] == true).length - 1));
      expect(rows.length, raw.length);
    });

    test('순위 제외(기록 모드·비공개)는 순위 0 으로 맨 끝', () {
      final rows = leaderRowsFromSnapshot(f['snapshot_cumulative'] as List, myParticipantId: 'not-in-snapshot', myNickname: '나', myScore: 50, myRankEligible: false);
      expect(rows.last.me, isTrue);
      expect(rows.last.rank, 0);
    });
  });
}

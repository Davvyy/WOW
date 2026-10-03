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
      // 누적 스냅샷 점수 = 순위 점수(일평균 × (1 + 참여율), D49). 시드 10.13 기준 반영 가능 4일 → 참여율 1.0
      expect(me.score, closeTo(me.avg! * 2, 0.11));
      expect(me.rate, 1.0);
      expect(me.days, 4);
      expect(me.pending, isFalse);
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

    test('내가 검토 중이면 서버는 집계 중 → 내 순위 점수로 순위를 계산해 그 자리에 내 행', () {
      final raw = f['snapshot_cumulative_under_review'] as List;
      expect(raw.where((r) => (r as Map)['participant_id'] == pid), isEmpty, reason: '서버 스냅샷에는 내 이름이 없음');
      // 판정 전 순위 점수(stats.score): 반영 4일 합 341.1 → 일평균 85.3 × (1 + 참여율 1.0) = 170.6. 스냅샷 점수(순위 점수)와 같은 척도
      final rows = leaderRowsFromSnapshot(raw, myParticipantId: pid, myNickname: '지수', myScore: 170.6, myUnderReview: true,
          myAvg: 85.3, myRate: 1.0, myDays: 4, myMinDays: 2);
      final me = rows.firstWhere((r) => r.me);
      expect(me.underReview, isTrue);
      expect(me.score, 170.6);
      expect(me.rank, 1, reason: '170.6 > 강남콩 159.2 — 서버가 집계 중으로 가린 1위 자리');
      expect(rows.first.me, isTrue);
      expect([me.avg, me.rate, me.days, me.minDays, me.pending], [85.3, 1.0, 4, 2, false]);
      expect(rows.where((r) => r.aggregating), hasLength(raw.where((r) => (r as Map)['aggregating'] == true).length - 1));
      expect(rows.length, raw.length);
    });

    test('스냅샷에 아직 없으면 순위 점수로 순위를 계산(일평균·참여율 표시값도 함께)', () {
      final rows = leaderRowsFromSnapshot(f['snapshot_cumulative'] as List, myParticipantId: 'not-in-snapshot', myNickname: '나', myScore: 120,
          myAvg: 60, myRate: 1.0, myDays: 4, myMinDays: 2);
      final me = rows.firstWhere((r) => r.me);
      expect(me.rank, 4, reason: '159.2 · 156.3 · 134.2 다음');
      expect([me.avg, me.rate, me.days, me.minDays], [60, 1.0, 4, 2]);
      expect(me.gapToPrev, 14.2);
    });

    test('순위 대기(pending)인데 스냅샷에 없으면 순위 0 · 대기 행으로', () {
      final raw = f['snapshot_cumulative'] as List;
      final rows = leaderRowsFromSnapshot(raw, myParticipantId: 'not-in-snapshot', myNickname: '나', myPending: true, myAvg: 30, myRate: 0.5,
          myDays: 1, myMinDays: 2);
      expect(rows, hasLength(raw.length + 1));
      final me = rows.last;
      expect(me.me, isTrue);
      expect(me.rank, 0);
      expect(me.pending, isTrue);
      expect(me.score, isNull);
      expect([me.avg, me.rate, me.days, me.minDays], [30, 0.5, 1, 2]);
      expect(me.gapToPrev, isNull);
    });

    test('누적 대기 행은 누적 탭에만, 오늘 탭은 오늘 점수 그대로', () {
      final lb = leaderboardFromServer(
        todayRows: f['snapshot_today'] as List,
        cumulativeRows: f['snapshot_cumulative'] as List,
        myParticipantId: 'not-in-snapshot',
        myNickname: '나',
        myToday: 28.8,
        myPending: true,
        myDays: 1,
        myMinDays: 2,
      );
      final cum = lb.meIn(lb.cumulative)!;
      expect([cum.rank, cum.pending, cum.days, cum.minDays], [0, true, 1, 2]);
      final today = lb.meIn(lb.today)!;
      expect(today.pending, isFalse);
      expect(today.score, 28.8);
      expect(today.rank, greaterThan(0));
    });

    test('순위 제외(기록 모드·비공개)는 순위 0 으로 맨 끝', () {
      final rows = leaderRowsFromSnapshot(f['snapshot_cumulative'] as List, myParticipantId: 'not-in-snapshot', myNickname: '나', myScore: 50, myRankEligible: false);
      expect(rows.last.me, isTrue);
      expect(rows.last.rank, 0);
    });
  });
}


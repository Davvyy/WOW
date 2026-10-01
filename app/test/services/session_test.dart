// my_challenge_summary(시드 DB 실제 응답, test/fixtures/server_ledger.json 의 summary) → 세션
import 'dart:convert';
import 'dart:io';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final summary = Map<String, dynamic>.from((jsonDecode(File('test/fixtures/server_ledger.json').readAsStringSync()) as Map)['summary'] as Map);
  tearDown(resetSession);

  test('챌린지 요약: 이름·기간·인원·D+n·이의 기간', () {
    final s = sessionFromSummary(summary, today: DateTime(2026, 10, 13));
    final ch = s.challenge;
    expect(ch.name, '가을 걷기 챌린지');
    expect(ch.code, 'K7Q2MD');
    expect([ch.days, ch.capacity, ch.joined, ch.dayIndex], [28, 60, 12, 8]);
    expect(ch.objectionUntil, '11.10', reason: '발표 전: 종료 다음 날 확정 + 7일');
    expect(phaseOfStatus(s.status), ChallengePhase.active);
  });

  test('잠긴 프로필·BMR(서버 값)', () {
    final me = sessionFromSummary(summary).me;
    expect([me.nickname, me.sex, me.age, me.bmr], ['지수', Sex.m, 30, 1650]);
    expect(me.weightKg, 70);
  });

  test('규칙 상수·시간·운영자 규칙', () {
    final s = sessionFromSummary(summary);
    expect([s.rules.t, s.rules.c, s.rules.mMin, s.rules.fRatio], [500, 1000, 700, 0.8]);
    expect(s.slotStarts, ('04:00', '10:30', '15:00', '22:00'));
    expect([s.finalizeTime, s.editWindowHours, s.appealHours], ['09:00', 48, 72]);
    expect(s.rulesMd, contains('운영자 추가 규칙'));
  });

  test('운영자가 바꾼 상수·경계가 엔진·끼니 태그에 그대로 들어감', () {
    final custom = Map<String, dynamic>.from(summary)
      ..['rules'] = {...(summary['rules'] as Map), 't': 400, 'dinner_end': '21:00:00', 'edit_window': '1 day 12:00:00'};
    final s = sessionFromSummary(custom);
    applySession(s);
    expect(engine.rules.t, 400);
    expect(s.editWindowHours, 36);
    // 예시 1(28.8 at T=500) → T=400 이면 D 144 / 400 = 36.0
    final r = engine.simulate(const SimulateInput(bmr: 1650, weightKg: 70, stepsTotal: 9000, meals: [
      MealInput(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: 420),
      MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 780),
      MealInput(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: 600),
    ]));
    expect(r.score.sD, 36.0);
    // 21:30 KST: 기본은 저녁, 저녁 마감 21:00 이면 간식
    expect(AppShell.slotForNow(DateTime.utc(2026, 10, 13, 12, 30)), MealSlot.snack);
    resetSession();
    expect(AppShell.slotForNow(DateTime.utc(2026, 10, 13, 12, 30)), MealSlot.dinner);
  });

  test('생명주기 상태 → 화면 단계', () {
    expect(['recruiting', 'checking', 'running', 'closing', 'published', 'archived'].map(phaseOfStatus).toList(), [
      ChallengePhase.recruiting, ChallengePhase.active, ChallengePhase.active, ChallengePhase.closing, ChallengePhase.published,
      ChallengePhase.published,
    ]);
  });

  test('reviews 행(+appeals) → 내 검토', () {
    final r = myReviewFromServer({
      'id': 'r1', 'type': 'steps_spike', 'status': 'appealed', 'local_date': '2026-10-12', 'sla_due_at': '2026-10-16T00:00:00+00:00',
      'reason_template': 'steps_spike', 'verdict': null, 'message': null, 'decided_at': null,
      'appeals': [{'text': '하프마라톤에 나갔어요'}],
    });
    expect([r.type, r.status, r.appealText, r.open, r.decided], ['steps_spike', 'appealed', '하프마라톤에 나갔어요', false, false]);
    expect(myReviewFromServer({'id': 'r2', 'type': 'report', 'status': 'open', 'appeals': []}).appealText, isNull);
  });
}

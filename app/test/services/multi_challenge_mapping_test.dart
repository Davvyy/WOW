// 월간·동시 참가(D46~D54) 서버 응답 → 앱 모델
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> summary({String kind = 'monthly', Object? capacity, Map<String, dynamic>? stats}) => {
      'today': '2026-10-20',
      'challenge': {'id': 'c-oct', 'name': '10월 챌린지', 'kind': kind, 'status': 'running', 'start_date': '2026-10-01',
        'end_date': '2026-10-31', 'capacity': capacity ?? 0, 'invite_code': null, 'join_open': true, 'rules_md': '', 'published_at': null},
      'joined': 5,
      'rules': {},
      'participant': {'id': 'p-1', 'nickname': '지수', 'sex': 'M', 'birth_year': 1996, 'age': 30, 'height_cm': 175, 'weight_locked': 70,
        'bmr_locked': 1650, 'status': 'active', 'rank_eligible': true, 'leaderboard_visible': true, 'grade_badge_public': false,
        'warning_count': 0, 'last_synced_at': null, 'last_sync_source': null, 'check_start': '2026-10-15', 'joined_at': '2026-10-15T01:00:00Z'},
      'stats': stats ?? {'days': 2, 'total': 80, 'meals': 6, 'avail': 16, 'min_days': 7, 'avg': 40.0, 'rate': 0.125, 'pending': true, 'score': null},
      'notice': null,
    };

void main() {
  test('세션: 종류·점검 시작일·순위 통계, 월간 정원은 0', () {
    final s = sessionFromSummary(summary());
    expect(s.kind, 'monthly');
    expect(s.monthly, isTrue);
    expect(s.checkStart, DateTime(2026, 10, 15));
    expect(s.challenge.capacity, 0);
    expect(s.challenge.code, '');
    expect(s.stats!.pending, isTrue);
    expect([s.stats!.days, s.stats!.minDays, s.stats!.avail], [2, 7, 16]);
    expect(s.stats!.score, isNull);
  });

  test('세션: 이전 서버(kind·stats 없음)는 운영자 챌린지·통계 없음', () {
    final j = summary()..remove('stats');
    (j['challenge'] as Map).remove('kind');
    final s = sessionFromSummary(j);
    expect(s.kind, 'operator');
    expect(s.stats, isNull);
  });

  test('리더보드 누적 행: 순위 점수·일평균·참여율, 순위 대기는 rank 0', () {
    final rows = leaderRowsFromSnapshot([
      {'rank': 1, 'participant_id': 'p-2', 'nickname': '하니', 'score': 90.0, 'fill': 4, 'cheer_count': 0, 'badge': null, 'tie': false,
        'pending': false, 'avg': 60.0, 'rate': 0.5, 'days': 14, 'min_days': 7},
      {'rank': 0, 'participant_id': 'p-1', 'nickname': '지수', 'score': null, 'fill': 2, 'cheer_count': 0, 'badge': null, 'tie': false,
        'pending': true, 'avg': 40.0, 'rate': 0.125, 'days': 2, 'min_days': 7},
    ], myParticipantId: 'p-1', myNickname: '지수');
    expect(rows[0].avg, 60.0);
    expect(rows[0].rate, 0.5);
    expect(rows[0].pending, isFalse);
    expect(rows[1].me, isTrue);
    expect(rows[1].pending, isTrue);
    expect(rows[1].rank, 0);
    expect([rows[1].days, rows[1].minDays], [2, 7]);
  });

  test('열린 월간 챌린지', () {
    final o = OpenChallenge.fromJson({'challenge_id': 'c-oct', 'name': '10월 챌린지', 'kind': 'monthly', 'status': 'running',
      'start_date': '2026-10-01', 'end_date': '2026-10-31', 'days': 31, 'joined': 5, 'joinable': true, 'me': null});
    expect([o.name, o.days, o.joined], ['10월 챌린지', 31, 5]);
    expect(o.joinable, isTrue);
    expect(o.myStatus, isNull);
  });

  test('초대 요약: 진행 중 참가 가능 여부, 이전 서버는 모집 중일 때만', () {
    final now = InviteSummary.fromJson({'challenge_id': 'x', 'name': '운영 1', 'kind': 'operator', 'status': 'running', 'start_date': '2026-10-01',
      'end_date': '2026-10-26', 'capacity': 30, 'join_open': true, 'joinable': true, 'joined': 3, 'days': 26});
    expect(now.joinable, isTrue);
    expect(now.full, isFalse);
    final old = InviteSummary.fromJson({'challenge_id': 'x', 'name': '운영 1', 'status': 'checking', 'start_date': '2026-10-01',
      'end_date': '2026-10-26', 'capacity': 30, 'joined': 3, 'days': 26});
    expect(old.joinable, isFalse);
  });

  test('참가 요청: 월간은 challenge_id, 운영자는 code', () {
    const base = (nickname: '지수', birthYear: 1996, heightCm: 175.0, weightKg: 70.0);
    final m = JoinRequest(challengeId: 'c-oct', nickname: base.nickname, sex: Sex.m, birthYear: base.birthYear, heightCm: base.heightCm,
        weightKg: base.weightKg, terms: true, sensitiveHealth: true, overseasAi: false, autoContinue: true).toJson();
    expect(m['challenge_id'], 'c-oct');
    expect(m.containsKey('code'), isFalse);
    expect(m['auto_continue'], isTrue);
    final c = JoinRequest(code: 'OPONE1', nickname: base.nickname, sex: Sex.m, birthYear: base.birthYear, heightCm: base.heightCm,
        weightKg: base.weightKg, terms: true, sensitiveHealth: true, overseasAi: false).toJson();
    expect(c['code'], 'OPONE1');
    expect(c.containsKey('challenge_id'), isFalse);
  });
}

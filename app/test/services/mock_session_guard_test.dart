// 모의 세션의 'mock-p' 같은 id 는 서버로 보내지 않는다(isMockSession 으로 "세션 없음" 취급)
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _summary() => {
      'today': '2026-10-20',
      'challenge': {'id': 'c-oct', 'name': '10월 챌린지', 'kind': 'monthly', 'status': 'running', 'start_date': '2026-10-01',
        'end_date': '2026-10-31', 'capacity': 0, 'invite_code': null, 'join_open': true, 'rules_md': '', 'published_at': null},
      'joined': 5,
      'rules': {},
      'participant': {'id': 'p-1', 'nickname': '지수', 'sex': 'M', 'birth_year': 1996, 'age': 30, 'height_cm': 175, 'weight_locked': 70,
        'bmr_locked': 1650, 'status': 'active', 'rank_eligible': true, 'leaderboard_visible': true, 'grade_badge_public': false,
        'warning_count': 0, 'last_synced_at': null, 'last_sync_source': null, 'check_start': '2026-10-15', 'joined_at': '2026-10-15T01:00:00Z'},
      'stats': {'days': 2, 'total': 80, 'meals': 6, 'avail': 16, 'min_days': 7, 'avg': 40.0, 'rate': 0.125, 'pending': true, 'score': null},
      'notice': null,
    };

void main() {
  test('모의 세션 둘은 모의로 판정된다', () {
    expect(isMockSession(ChallengeSession.mock), isTrue);
    expect(isMockSession(ChallengeSession.mockMonthly), isTrue);
  });

  test('서버 응답으로 만든 세션은 모의가 아니다', () {
    final s = sessionFromSummary(_summary());
    expect(s.participantId, 'p-1');
    expect(isMockSession(s), isFalse);
  });
}

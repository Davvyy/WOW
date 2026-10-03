import '../core/engine/engine.dart';
import '../data/mock/mock_data.dart';
import '../data/models.dart';

/// 현재 챌린지 세션: 챌린지 요약 · 잠긴 내 프로필 · 규칙 상수 · 운영자 규칙.
/// 서버 모드는 RPC `my_challenge_summary` 로 채우고(sessionProvider), 모의 모드는 프로토타입 예시 값이다.
/// 화면은 [curChallenge]·[curMe]·[engine] 접근자로 읽는다. sessionProvider 를 지켜보는 게이트(AppShell)가
/// 값이 바뀌면 아래 화면을 다시 그린다.
class ChallengeSession {
  const ChallengeSession({
    required this.challenge,
    required this.me,
    required this.rules,
    required this.status,
    this.participantId,
    this.challengeId,
    this.rulesMd = '',
    this.slotStarts = const ('04:00', '10:30', '15:00', '22:00'),
    this.finalizeTime = '09:00',
    this.editWindowHours = 48,
    this.appealHours = 72,
    this.rankEligible = true,
    this.kind = 'operator',
    this.checkStart,
    this.stats,
    this.joinOpen = true,
  });

  final ChallengeInfo challenge;
  final MeInfo me;
  final EngineRules rules;

  /// challenges.status (draft/recruiting/checking/running/closing/published/archived/cancelled)
  final String status;
  final String? participantId;
  final String? challengeId;

  /// 운영자 추가 규칙(Markdown, P11)
  final String rulesMd;

  /// 끼니 경계(아침 시작·아침 끝·점심 끝·저녁 끝), challenge_rules 와 같은 값
  final (String, String, String, String) slotStarts;
  final String finalizeTime;
  final int editWindowHours;
  final int appealHours;
  final bool rankEligible;

  /// challenges.kind: 'operator'(코드로 참가) · 'monthly'(월간, 코드 없이 참가)
  final String kind;

  /// 내 점검(점수 집계) 시작일. 서버가 주지 않으면 null
  final DateTime? checkStart;

  /// 내 순위 통계. 이전 서버는 null
  final RankStats? stats;

  /// 참가 접수 중인지(challenges.join_open)
  final bool joinOpen;

  bool get monthly => kind == 'monthly';

  ChalloryEngine get engine => ChalloryEngine(rules);

  static final mock = ChallengeSession(
    challenge: mockChallenge,
    me: mockMe,
    rules: EngineRules.defaults,
    status: 'running',
    challengeId: 'mock-challenge',
    participantId: 'mock-p',
    checkStart: DateTime(2026, 10, 6),
    rulesMd: '## 운영자 추가 규칙\n- 회식 날(10.17)은 저녁 자동 확정 대신 대체값 적용을 요청할 수 있어요(운영자에게 메시지).\n- 상품은 상위 3명 + 반영률 100% 달성자 추첨 2명.',
  );

  /// 모의 월간 챌린지(코드 없이 참가, 정원 없음). 기록은 [mock] 과 공유된다.
  static final mockMonthly = ChallengeSession(
    challenge: ChallengeInfo(
      name: '10월 챌린지', code: '', start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 31), days: 31, capacity: 0, joined: 128,
      today: mockChallenge.today, dayIndex: mockChallenge.today.difference(DateTime(2026, 10, 1)).inDays + 1,
      syncTime: mockChallenge.syncTime, source: mockChallenge.source, platform: mockChallenge.platform,
      noticeTitle: '', noticeBody: '', noticeDate: '', objectionUntil: '11.8'),
    me: mockMe,
    rules: EngineRules.defaults,
    status: 'running',
    kind: 'monthly',
    challengeId: 'mock-monthly',
    participantId: 'mock-p-monthly',
    checkStart: DateTime(2026, 10, 1),
    stats: const RankStats(days: 9, avail: 9, minDays: 4, avg: 41.3, rate: 1.0, pending: false, score: 82.6),
  );
}

ChallengeSession _current = ChallengeSession.mock;

ChallengeSession get currentSession => _current;
ChallengeInfo get curChallenge => _current.challenge;
MeInfo get curMe => _current.me;

/// 현재 챌린지 규칙으로 계산하는 엔진(서버 challenge_rules 와 같은 상수)
ChalloryEngine get engine => _current.engine;

/// 내 대체값 M_p · 섭취 하한 F_p (잠긴 BMR 기준)
double get meM => engine.m(curMe.bmr);
double get meF => engine.f(curMe.bmr);

void applySession(ChallengeSession s) => _current = s;

/// 테스트·로그아웃용
void resetSession() => _current = ChallengeSession.mock;

/// 모의 세션(서버 id 가 아닌 'mock-p' 같은 값)인지. 서버 호출은 이런 세션을 "세션 없음"으로 본다.
bool isMockSession(ChallengeSession s) => identical(s, ChallengeSession.mock) || identical(s, ChallengeSession.mockMonthly);

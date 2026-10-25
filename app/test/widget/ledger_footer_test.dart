// 점수 장부(P10) 표 아래 안내: 점검 기간 날짜는 내 점검 시작일에서, 누를 수 있는 정정된 날은 장부에서(시안 날짜 고정 문구 제거)
import 'package:challory/core/format.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 시작 다음 날 참가(점검 시작 = 시작일 + 1일), 장부는 비어 있음(정정된 날 없음)
class _Api extends MockChalloryApi {
  _Api() {
    final base = ChallengeSession.mock;
    sessions[0] = ChallengeSession(challenge: base.challenge, me: base.me, rules: base.rules, status: base.status,
        challengeId: base.challengeId, participantId: base.participantId, checkStart: base.challenge.start.add(const Duration(days: 1)));
  }
  @override
  Future<List<LedgerRow>> fetchLedger() async => const [];
}

void main() {
  tearDown(resetSession);

  testWidgets('점검 기간은 내 점검 시작일부터 3일, 정정된 날이 없으면 "오늘 행"만 안내', (tester) async {
    await pumpApp(tester, location: R.ledger, overrides: [apiProvider.overrideWithValue(_Api())]);
    final st = ChallengeSession.mock.challenge.start;
    final s = DateTime(st.year, st.month, st.day + 1);
    final last = DateTime(s.year, s.month, s.day + 2);
    expect(find.textContaining('첫 3일(${fmtMd(s)}~${fmtMd(last)})은 점검 기간', findRichText: true), findsOneWidget);
    expect(find.textContaining('오늘 행을 누르면 그날 홈으로 이동해요.'), findsOneWidget);
    expect(find.textContaining('(10.12)'), findsNothing);
  });
}

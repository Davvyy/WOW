import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart' show Leaderboard;
import '../../data/models.dart';
import '../../state/session.dart' show ChallengeSession;

/// 서버 행(PostgREST JSON) → 앱 모델. 네트워크와 분리해 단위 테스트한다.

MealSlot? _slot(Object? v) => MealSlot.values.where((s) => s.name == v).firstOrNull;

MealStatus _status(Object? v) => v == 'void' ? MealStatus.voided : MealStatus.values.firstWhere((s) => s.name == v, orElse: () => MealStatus.empty);

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

/// daily_scores 1행(+정정 이력) → P10 장부 한 줄. [start] = 챌린지 시작일(D1).
/// [revisions] 는 이 날짜의 score_revisions(오래된 순), [reviewTypes] 는 review_id → reviews.type.
LedgerRow ledgerRowFromServer(Map<String, dynamic> row, DateTime start,
    {List<Map<String, dynamic>> revisions = const [], Map<String, String> reviewTypes = const {}}) {
  final date = DateTime.parse(row['local_date'] as String);
  final b = Map<String, dynamic>.from(row['breakdown'] as Map? ?? const {});
  final inputs = Map<String, dynamic>.from(b['inputs'] as Map? ?? const {});
  final intake = Map<String, dynamic>.from(b['intake'] as Map? ?? const {});
  final score = Map<String, dynamic>.from(b['score'] as Map? ?? const {});
  final i = _d(row['i_d']);
  final f = _d(row['f_p']);
  final isCounted = row['is_counted'] as bool? ?? false;
  final isFinal = row['is_final'] as bool? ?? false;
  final underReview = row['under_review'] as bool? ?? false;

  String revText(Map<String, dynamic> r) {
    final who = switch (r['reason']) { 'user_edit' => '본인 수정', 'verdict' => '판정', 'late_sync' => '지연 동기화', _ => '자동 확정' };
    return '$who ${fmtK1(_d(r['prev_s_d']))}→${fmtK1(_d(r['new_s_d']))}점';
  }

  final verdictRev = revisions.where((r) => r['reason'] == 'verdict').lastOrNull;
  return LedgerRow(
    d: date.difference(DateTime(start.year, start.month, start.day)).inDays + 1,
    date: fmtMd(date),
    steps: ((inputs['steps_verified'] ?? inputs['steps_total']) as num?)?.toInt() ?? 0,
    bmr: (row['bmr'] as num?)?.toInt() ?? 0,
    a: _d(row['a_d']),
    i: i,
    dd: _d(row['d_d']),
    s: _d(row['s_d']),
    f: f,
    floorApplied: score['floor_applied'] as bool? ?? (i < f),
    substituted: [
      for (final s in [...(intake['substitute_slots'] as List? ?? const []), ...(intake['pending_slots'] as List? ?? const [])])
        ?_slot(s),
    ],
    check: !isCounted,
    provisional: !isFinal,
    note: [if (!isCounted) '점검 기간', if (underReview) '검토 중'].join(' · '),
    history: revisions.map(revText).join(' · '),
    health: false, // 건강 알림은 운영자 전용(05 health_alerts RLS) — 본인 화면은 P5 인라인 안내로만
    meals: [
      for (final m in (inputs['meals'] as List? ?? const []))
        if (_slot((m as Map)['slot']) case final slot?)
          MealInput(slot: slot, status: _status(m['status']), kcal: _d(m['kcal']), aiKcal: (m['ai_kcal'] as num?)?.toDouble()),
    ],
    revisionReason: verdictRev == null ? null : reviewTypes[verdictRev['review_id']],
    sBefore: revisions.isEmpty ? null : _d(revisions.first['prev_s_d']),
  );
}

/// 스냅샷 rows(서버 build_leaderboard) → [LeaderRow] 목록. 내 행([myParticipantId])은 me 표시.
/// 내 행이 없을 때(검토 중이라 '집계 중'으로 가려짐 · 순위 비공개 · 기록 모드):
///   [myScore] 로 순위를 계산해 넣는다. 검토 중이면 같은 순위의 '집계 중' 행 하나를 내 행으로 바꾼다.
///   순위 제외(기록 모드·경고 3회)는 순위 0 으로 넣는다(화면은 '—').
List<LeaderRow> leaderRowsFromSnapshot(List<dynamic> rows,
    {required String myParticipantId, required String myNickname, double? myScore, bool myUnderReview = false, bool myRankEligible = true}) {
  final out = <LeaderRow>[];
  var foundMe = false;
  for (final raw in rows) {
    final r = Map<String, dynamic>.from(raw as Map);
    final agg = r['aggregating'] as bool? ?? false;
    final pid = r['participant_id'] as String?;
    final me = pid != null && pid == myParticipantId;
    foundMe |= me;
    out.add(LeaderRow(
      rank: (r['rank'] as num).toInt(),
      name: agg ? '집계 중' : (r['nickname'] as String? ?? ''),
      score: agg ? null : _d(r['score']),
      fill: (r['fill'] as num?)?.toInt() ?? 0,
      watch: r['badge'] == 'watch',
      tie: r['tie'] as bool? ?? false,
      aggregating: agg,
      me: me,
      participantId: pid,
    ));
  }
  if (!foundMe && myScore != null) {
    final rank = myRankEligible ? 1 + out.where((r) => !r.aggregating && (r.score ?? 0) > myScore).length : 0;
    if (myUnderReview) {
      final i = out.indexWhere((r) => r.aggregating && r.rank == rank);
      if (i >= 0) out.removeAt(i);
    }
    final mine = LeaderRow(rank: rank, name: myNickname, score: myScore, fill: 0, me: true, underReview: myUnderReview);
    final at = rank == 0 ? out.length : out.indexWhere((r) => r.rank > rank);
    out.insert(at < 0 ? out.length : at, mine);
  }
  // 위 순위까지 격차(점수가 보이는 바로 위 행)
  final mi = out.indexWhere((r) => r.me);
  if (mi > 0) {
    final above = out.take(mi).where((r) => !r.aggregating && r.score != null && (r.score! > (out[mi].score ?? 0))).lastOrNull;
    if (above != null) {
      final m = out[mi];
      out[mi] = LeaderRow(rank: m.rank, name: m.name, score: m.score, fill: m.fill, watch: m.watch, me: true, tie: m.tie,
          participantId: m.participantId, underReview: m.underReview, gapToPrev: double.parse((above.score! - (m.score ?? 0)).toStringAsFixed(1)));
    }
  }
  return out;
}

Leaderboard leaderboardFromServer({
  required List<dynamic> todayRows,
  required List<dynamic> cumulativeRows,
  required String myParticipantId,
  required String myNickname,
  double? myToday,
  double? myCumulative,
  bool myUnderReview = false,
  bool myRankEligible = true,
  bool todayFinal = false,
  DateTime? asOf,
}) {
  final today = leaderRowsFromSnapshot(todayRows, myParticipantId: myParticipantId, myNickname: myNickname, myScore: myToday,
      myUnderReview: myUnderReview, myRankEligible: myRankEligible);
  final cum = leaderRowsFromSnapshot(cumulativeRows, myParticipantId: myParticipantId, myNickname: myNickname, myScore: myCumulative,
      myUnderReview: myUnderReview, myRankEligible: myRankEligible);
  return Leaderboard(total: cumulativeRows.length, today: today, cumulative: cum, todayFinal: todayFinal, asOf: asOf);
}

String _hhmm(Object? t) {
  final s = (t as String?) ?? '';
  return s.length >= 5 ? s.substring(0, 5) : s;
}

int _hours(Object? interval, int fallback) {
  // Postgres interval 의 JSON 표기("48:00:00" 또는 "2 days")
  final s = (interval as String?) ?? '';
  final hm = RegExp(r'^(\d+):').firstMatch(s);
  if (hm != null) return int.parse(hm.group(1)!);
  final days = RegExp(r'(\d+) day').firstMatch(s);
  final hours = RegExp(r'(\d+):\d+:\d+').firstMatch(s.replaceFirst(RegExp(r'^\d+ days? '), ''));
  if (days != null) return int.parse(days.group(1)!) * 24 + (hours != null ? int.parse(hours.group(1)!) : 0);
  return fallback;
}

/// RPC my_challenge_summary → 세션. [platformLabel] 은 이 기기의 건강 플랫폼 이름("Health Connect"/"Apple 건강").
ChallengeSession sessionFromSummary(Map<String, dynamic> j, {String platformLabel = 'Health Connect', DateTime? today}) {
  final ch = Map<String, dynamic>.from(j['challenge'] as Map);
  final p = Map<String, dynamic>.from(j['participant'] as Map);
  final rulesJson = Map<String, dynamic>.from(j['rules'] as Map? ?? const {});
  final notice = j['notice'] == null ? null : Map<String, dynamic>.from(j['notice'] as Map);
  final start = DateTime.parse(ch['start_date'] as String);
  final end = DateTime.parse(ch['end_date'] as String);
  final days = end.difference(start).inDays + 1;
  final now = today ?? DateTime.parse(j['today'] as String);
  final dayIndex = (now.difference(start).inDays + 1).clamp(1, days);
  final published = ch['published_at'] == null ? null : DateTime.parse(ch['published_at'] as String).toUtc().add(const Duration(hours: 9));
  // 이의 기간: 발표 후 7일(03 §7). 발표 전이면 예상치(종료 다음 날 확정 + 7일)
  final objection = published != null ? published.add(const Duration(days: 7)) : end.add(const Duration(days: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  final synced = p['last_synced_at'] == null ? null : DateTime.parse(p['last_synced_at'] as String).toUtc().add(const Duration(hours: 9));
  final noticeAt = notice?['created_at'] == null ? null : DateTime.parse(notice!['created_at'] as String).toUtc().add(const Duration(hours: 9));

  final sex = p['sex'] == 'F' ? Sex.f : Sex.m;
  final age = (p['age'] as num?)?.toInt() ?? 0;
  final h = (p['height_cm'] as num?)?.toDouble() ?? 0;
  final w = (p['weight_locked'] as num?)?.toDouble() ?? 0;
  final raw = ChalloryEngine.bmr(Profile(sex: sex, weightKg: w, heightCm: h, age: age)).raw;

  return ChallengeSession(
    challenge: ChallengeInfo(
      name: ch['name'] as String,
      code: (ch['invite_code'] as String?) ?? '',
      start: start,
      end: end,
      days: days,
      capacity: (ch['capacity'] as num).toInt(),
      joined: (j['joined'] as num?)?.toInt() ?? 0,
      today: DateTime(now.year, now.month, now.day),
      dayIndex: dayIndex,
      syncTime: synced == null ? '—' : '${two(synced.hour)}:${two(synced.minute)}',
      source: _sourceLabel(p['last_sync_source'] as String?),
      platform: platformLabel,
      noticeTitle: (notice?['title'] as String?) ?? '',
      noticeBody: (notice?['body'] as String?) ?? '',
      noticeDate: noticeAt == null ? '' : fmtMd(noticeAt),
      objectionUntil: fmtMd(objection),
    ),
    me: MeInfo(
      nickname: p['nickname'] as String,
      sex: sex,
      birthYear: (p['birth_year'] as num?)?.toInt() ?? 0,
      heightCm: h,
      weightKg: w,
      age: age,
      bmr: (p['bmr_locked'] as num?)?.toInt() ?? 0, // 서버가 잠근 값(시작 후 변경 없음)
      bmrRaw: raw,
    ),
    rules: rulesJson.isEmpty ? EngineRules.defaults : EngineRules.fromJson(rulesJson),
    status: ch['status'] as String,
    participantId: p['id'] as String?,
    rulesMd: (ch['rules_md'] as String?) ?? '',
    slotStarts: (
      _hhmm(rulesJson['breakfast_start'] ?? '04:00'),
      _hhmm(rulesJson['breakfast_end'] ?? '10:30'),
      _hhmm(rulesJson['lunch_end'] ?? '15:00'),
      _hhmm(rulesJson['dinner_end'] ?? '22:00'),
    ),
    finalizeTime: _hhmm(rulesJson['finalize_time'] ?? '09:00'),
    editWindowHours: _hours(rulesJson['edit_window'], 48),
    appealHours: _hours(rulesJson['appeal_window'], 72),
    rankEligible: p['rank_eligible'] as bool? ?? true,
  );
}

/// 출처(dataOrigin/HKSource) → 화면 이름
String _sourceLabel(String? origin) => switch (origin) {
      null => '—',
      'com.sec.android.app.shealth' => '삼성헬스',
      'com.apple.health' || 'com.apple.health.watch' => 'Apple 건강',
      'com.google.android.apps.healthdata' || 'android' => 'Health Connect',
      'com.garmin.android.apps.connectmobile' => 'Garmin',
      'com.fitbit.FitbitMobile' => 'Fitbit',
      _ => origin,
    };

/// notifications 행(N-03) → 공지
Notice noticeFromServer(Map<String, dynamic> r) => Notice(
      id: r['id'] as String,
      title: (r['title'] as String?) ?? '공지',
      body: (r['body'] as String?) ?? '',
      at: DateTime.parse((r['scheduled_at'] ?? r['created_at']) as String).toUtc().add(const Duration(hours: 9)),
      read: r['read_at'] != null,
    );

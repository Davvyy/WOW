import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/burn.dart';
import '../../core/config.dart';
import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../services/health/health_models.dart' show toKstWall;
import '../../state/app_state.dart';
import '../../state/coverage.dart';
import '../../state/past_meals.dart';
import '../widgets/challenge_cards.dart';
import '../widgets/common.dart';
import '../widgets/day_timeline.dart';
import '../widgets/ring.dart';
import '../../state/session.dart';

/// P5 홈(오늘, 구조 C · D71): 앱바(남은 날) · 안내 한 줄 · 날짜 · 링 + 숫자 셋(카드 없이) · 누적·순위 한 줄 ·
/// '오늘 기록' 목록 하나(끼니마다 한 줄, 머리글에 반영 n/4) · 활동 한 줄.
/// 모든 숫자는 엔진(`engine.simulate`)으로 계산한다. 링을 좌우로 스와이프하면 날짜가 바뀐다.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _noticeOpen = true;

  /// 안내 한 줄에서 지금 보이는 안내('외 n건'을 누르면 다음)
  int _noticeIndex = 0;

  @override
  void initState() {
    super.initState();
    // 앱 실행 시 3일 재조회(모의 원천은 변화 없음)
    Future.microtask(() async {
      if (!mounted) return;
      ref.read(activityProvider.notifier).refresh();
      final meals = ref.read(mealsProvider.notifier);
      final err = await meals.loadToday(); // 서버 연결 시 오늘 끼니
      if (err != null && mounted) showToast(context, err);
      // 지난번에 못 보낸 사진(앱 전용 폴더에 저장됨)을 표시하고 이어서 보낸다
      if (await meals.restorePendingUploads() > 0) await meals.retryPendingUploads();
      // 공유 카드용 사진은 7일만 보관
      if (mounted) unawaited(ref.read(sharePhotoStoreProvider).prune());
    });
  }

  /// 오늘 끼니의 보관 사진(이 폰, 서버 끼니 id 기준). 없으면 null → 아이콘 썸네일
  Uint8List? _photoOf(MealRecord m) {
    final id = m.serverId;
    return id == null ? null : ref.watch(mealPhotoProvider(id)).value;
  }

  /// '오늘 기록' 목록에서 한 슬롯의 줄들. 기록이 없으면 빈 칸 한 줄(오늘은 '찍기'·간식은 '+ 추가'),
  /// 있으면 끼니마다 한 줄(오늘은 마지막 줄 끝에 '+'). 누르면 그 끼니의 P7(지난 날은 그 날짜의 P7).
  /// 지난 날 끼니를 못 읽었거나 모의 모드면 장부 값으로 슬롯당 한 줄(누를 수 없음). 지난 날에는 촬영·'추가'가 없다.
  /// [sub] 는 이 칸의 대체값 max(M_p, 전날 같은 칸)(D61). [overLimitSkip] 은 한도를 넘어 대체값이 들어간 건너뜀.
  List<Widget> _slotRows(MealSlot s, List<MealRecord> dayMeals, bool isToday, String? pastDate, double sub, bool overLimitSkip) {
    void camera() => context.push('${R.camera}?slot=${s.name}');
    final label = slotLabel[s]!;
    if (!isToday && pastDate == null) {
      final m = dayMeals.firstWhere((m) => m.slot == s, orElse: () => MealRecord(slot: s));
      return [DayTimelineRow(meal: m, substitute: sub, overLimitSkip: overLimitSkip, today: false)];
    }
    final list = mealsIn(dayMeals, s);
    if (list.isEmpty) {
      final snack = s == MealSlot.snack;
      return [
        DayTimelineRow(
          meal: MealRecord(slot: s),
          substitute: sub,
          today: isToday,
          onTap: isToday ? camera : null,
          actionHint: snack ? '추가' : '찍기',
          trailing: isToday
              ? RowAction(
                  label: snack ? '추가' : '찍기',
                  icon: snack ? Icons.add_rounded : Icons.photo_camera_rounded,
                  semanticsLabel: '$label ${snack ? '추가' : '찍기'}',
                  onTap: camera,
                )
              : null,
        ),
      ];
    }
    void open(MealRecord m) {
      final search = (m.status == MealStatus.captured && m.noAnalysis) || m.status == MealStatus.failed;
      if (!isToday) {
        context.push(R.meal(m.slot, meal: m.key, search: search, date: pastDate));
      } else if (m.status == MealStatus.skipped) {
        camera(); // 건너뜀은 지금처럼 촬영으로
      } else {
        context.push(R.meal(m.slot, meal: m.key, search: search));
      }
    }

    return [
      for (var i = 0; i < list.length; i++)
        DayTimelineRow(
          meal: list[i],
          photo: _photoOf(list[i]), // 홈 build 안에서 읽어 사진이 바뀌면 다시 그린다
          substitute: sub,
          overLimitSkip: overLimitSkip,
          today: isToday,
          // 지난 날 건너뜀은 열 것이 없다(건너뜀은 오늘만)
          onTap: !isToday && list[i].status == MealStatus.skipped ? null : () => open(list[i]),
          trailing: !isToday
              ? null
              : i == list.length - 1
              ? RowAction(label: '추가', icon: Icons.add_rounded, iconOnly: true, semanticsLabel: '$label 추가', onTap: camera)
              : const SizedBox(width: RowAction.width),
        ),
    ];
  }

  /// [day] 일째 날짜(달력 날짜 필드로 계산: 서머타임이 있는 시간대에서도 하루씩)
  DateTime _dateOf(int day) {
    final s = curChallenge.start;
    return DateTime(s.year, s.month, s.day + day - 1);
  }

  /// [day] 의 날짜(YYYY-MM-DD, KST)
  String _localDateOf(int day) => localDateOfDay(curChallenge.start, day);

  void _swipe(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final cur = ref.read(selectedDayProvider);
    final n = ref.read(selectedDayProvider.notifier);
    if (v > 250) n.set(cur - 1); // 오른쪽으로 밀면 이전 날
    if (v < -250) n.set(cur + 1);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ch = curChallenge;
    final phase = ref.watch(phaseProvider);
    final day = ref.watch(selectedDayProvider);
    final isToday = day == ch.dayIndex;
    final meals = ref.watch(mealsProvider);
    final act = ref.watch(activityProvider);

    final remote = ref.read(apiProvider).isRemote;
    // ---- 선택한 날의 계산 ----
    late final SimulateResult sim;
    late final List<MealRecord> dayMeals;
    late final int steps;
    LedgerRow? row;
    // 지난 날 서버 끼니를 읽었으면 그 날짜(YYYY-MM-DD) — 끼니마다 한 줄, 눌러서 연다
    String? pastDate;
    if (isToday) {
      sim = ref.watch(todayResultProvider);
      dayMeals = meals;
      steps = act.stepsTotal;
    } else {
      // 지난 날: 서버 모드는 서버 장부 값 그대로, 모의 모드는 프로토타입 장부를 엔진으로 재계산
      final ledger = watchLedger(ref) ?? const <LedgerRow>[];
      row = ledger.where((r) => r.d == day).firstOrNull ?? (remote ? null : mockLedger[day - 1]);
      steps = row?.steps ?? 0;
      sim = row == null
          ? engine.simulate(SimulateInput(profile: curMe.profile))
          : remote
          ? resultFromLedgerRow(row)
          : engine.simulate(SimulateInput(profile: curMe.profile, stepsTotal: steps, meals: row.meals));
      // 서버 모드는 그 날짜 끼니를 따로 읽는다(오늘 목록과 섞지 않음). 읽기 전·못 읽으면 장부 요약.
      final past = remote ? ref.watch(pastMealsProvider(_localDateOf(day))).value : null;
      if (past != null) pastDate = _localDateOf(day);
      dayMeals = past ??
          [
            for (final s in MealSlot.values)
              () {
                final mi = (row?.meals ?? const <MealInput>[]).where((m) => m.slot == s);
                return mi.isEmpty ? MealRecord(slot: s) : MealRecord(slot: s, status: mi.first.status, kcal: mi.first.kcal);
              }(),
          ];
    }

    final lifecycle = phase != ChallengePhase.active;
    final date = _dateOf(day);
    final appTitle = ch.name;
    // 참가 챌린지가 하나면 카드 대신 앱바에 남은 날을 붙인다. 여럿이면 카드 목록(전환)이 위에 그대로 있다.
    final sessionCount = (ref.watch(sessionsProvider).value ?? const <ChallengeSession>[]).length;
    final multi = sessionCount > 1;
    final meta = lifecycle ? null : 'D+$day/${ch.days}${sessionCount == 1 ? ' · ${ChallengeCards.leftText(ch)}' : ''}';

    final lb = watchLeaderboard(ref);
    final finalRows = watchFinalRows(ref);
    final myFinal = myFinalRow(finalRows) ?? cumFallback(finalRows);
    // 누적(확정분, 점검 기간 제외) = 내 장부 합계. 장부를 아직 못 받았으면 순위표의 내 누적
    final ledgerNow = watchLedger(ref);
    final cumulative = ledgerNow != null
        ? round1(ledgerNow.where((x) => !x.check && !x.provisional).fold(0.0, (a, x) => a + x.s))
        : (lb?.meIn(lb.cumulative)?.score ?? 0);
    final cumMe = lb?.meIn(lb.cumulative) ?? LeaderRow(rank: 0, name: curMe.nickname, me: true, score: 0);
    final todayMe = lb?.meIn(lb.today);
    final reviewing = isToday && (remote ? (todayMe?.underReview ?? false) : steps > AppConfig.stepsSpikeAbs);
    final provisional = isToday;
    // 검토 배너 문구: 서버 모드는 오늘 열린 검토의 종류를 따른다(목록을 못 받았으면 일반 문구)
    final reviewBanner = reviewBannerText(
      remote: remote,
      review: remote && reviewing ? openReviewOn(ref.watch(myReviewsProvider).value, ch.today) : null,
    );

    String? caption;
    final inn = sim.intake;
    // 칸별 대체값(전날 같은 끼니가 더 크면 그 값, D61). 모두 같으면 한 번만, 다르면 칸 순서대로 743·900
    String subOf(List<MealSlot> slots) {
      final v = [for (final s in slots) fmtM(inn.substituteFor(s))];
      return v.toSet().length == 1 ? v.first : v.join('·');
    }
    if (isToday || row != null) {
      if (inn.substituteSlots.isNotEmpty) caption = '${inn.substituteSlots.map((s) => slotLabel[s]).join('·')} 미기록 → ${subOf(inn.substituteSlots)} kcal 적용 중';
      if (inn.pendingSlots.isNotEmpty) caption = '${inn.pendingSlots.map((s) => slotLabel[s]).join('·')} 확정 대기 → ${subOf(inn.pendingSlots)} kcal로 잠정 계산 중 · 검색으로 확정하면 반영';
      if (inn.draftSlots.isNotEmpty) caption = '${slotLabel[inn.draftSlots.first.slot]} 미확정 → ${fmtInt(inn.draftSlots.first.value)} kcal로 잠정 계산 중 · 확정하면 반영';
      if (sim.score.floorApplied) caption = '섭취 하한 ${fmtInt(sim.score.fP)} 적용';
      if (row != null && row.hasRevision) caption = '저녁 무효 → 대체값 ${fmtM(inn.substituteFor(MealSlot.dinner))} 적용 · ${fmtK1(row.sBefore!)} → ${fmtK1(row.s)}점';
    }

    // 반영률: 순위표 내 줄·서버 fill 과 같은 계산(D69, coverageCells)
    bool confirmed(MealRecord m) => isCountedStatus(m.status);
    final cells = coverageCells(meals: dayMeals, intake: inn, steps: steps, snackKcal: engine.rules.snackKcal);
    final slotFilled = {for (final s in mainSlots) s: mealsIn(dayMeals, s).any((m) => confirmed(m) && m.kcal >= engine.rules.snackKcal)};
    final slotSkipped = {
      for (final s in mainSlots) s: !slotFilled[s]! && mealsIn(dayMeals, s).any((m) => m.status == MealStatus.skipped),
    };
    // 한도를 넘은 건너뜀: 대체값이 들어간 칸(반영 아님)
    bool overLimitSkip(MealSlot s) => (slotSkipped[s] ?? false) && inn.substituteValues.containsKey(s);

    // 건강 안내(확정 섭취, 대체값 제외 < 남 1,500 / 여 1,200)
    final confirmedKcal = dayMeals.where(confirmed).fold<double>(0, (a, m) => a + m.kcal);
    final nudgeMin = curMe.sex == Sex.m ? engine.rules.nudgeMinM : engine.rules.nudgeMinF;
    // 오늘은 하루가 거의 끝났을 때만(저녁을 기록했거나 건너뜀, 또는 KST 21시 이후). 지난 날은 그대로.
    final dinnerDone = mealsIn(dayMeals, MealSlot.dinner).any((m) => confirmed(m) || m.status == MealStatus.skipped);
    final lateEnough = toKstWall(ref.watch(clockProvider)()).hour >= 21;
    final showNudge = !lifecycle && inn.mainMealCount > 0 && confirmedKcal < nudgeMin && (!isToday || dinnerDone || lateEnough);

    final d = sim.score.dD;
    // 소비·활동 kcal: 활동 탭과 같은 계산·같은 반올림(정수)
    final burn = BurnFigures.of(sim);
    final zeroMeal = inn.mainMealCount == 0;

    // ---- 링 ----
    Widget ringCenter;
    String ringLabel;
    bool ringEmpty = false;
    double ringRatio = sim.score.ratio;
    if (phase == ChallengePhase.recruiting) {
      ringEmpty = true;
      final startText = '${ch.start.month}월 ${ch.start.day}일에 시작해요';
      ringLabel = '시작 전, $startText';
      ringCenter = Column(mainAxisSize: MainAxisSize.min, children: [NumText('—', size: 44, weight: FontWeight.w700), Txt.cap(startText)]);
    } else if (phase == ChallengePhase.closing) {
      ringEmpty = true;
      ringLabel = '최종 집계 중, 링 잠금';
      ringCenter = Column(mainAxisSize: MainAxisSize.min, children: [Txt('잠금', size: 26, weight: FontWeight.w700, color: c.fg), const Txt.cap('운영자 확인 후 발표돼요')]);
    } else if (phase == ChallengePhase.published) {
      final f = myFinal;
      ringEmpty = true;
      ringLabel = '최종 ${f.rank}위, 누적 ${fmtK1(f.score ?? 0)}점';
      ringCenter = Column(mainAxisSize: MainAxisSize.min, children: [NumText(fmtK1(f.score ?? 0), size: 44, weight: FontWeight.w700, unit: '점'), Txt.cap('28일 누적 · 최종 ${f.rank}위')]);
    } else if (zeroMeal) {
      ringEmpty = true;
      ringLabel = '끼니를 1개 이상 확정하면 점수가 생겨요';
      ringCenter = Txt('끼니를 1개 이상\n확정하면\n점수가 생겨요', size: 15, weight: FontWeight.w600, color: c.fg, align: TextAlign.center, height: 1.3);
    } else {
      ringLabel = '오늘 순적자 ${fmtInt(d.abs())} kcal, 목표의 ${fmtPct(d / engine.rules.t)}';
      ringCenter = Column(mainAxisSize: MainAxisSize.min, children: [
        NumText('${d < 0 ? '+' : '−'}${fmtInt(d.abs())}', size: 44, weight: FontWeight.w700, unit: 'kcal'),
        Txt.cap(d >= 0 ? '목표 −${fmtInt(engine.rules.t)}의 ${fmtPct(d / engine.rules.t)}' : '목표보다 섭취가 많아요 · 0점'),
      ]);
    }
    ringRatio = ringRatio.isNaN ? 0 : ringRatio;

    // ---- 상태 칩 ----
    Widget statusChip;
    if (phase == ChallengePhase.recruiting) {
      statusChip = ChChip('시작 전 · ${ch.start.difference(ch.today).inDays}일 뒤 시작', icon: Icons.event_rounded);
    } else if (phase == ChallengePhase.closing) {
      statusChip = const ChChip('최종 집계 중', tone: Tone.review, icon: Icons.hourglass_top_rounded);
    } else if (phase == ChallengePhase.published) {
      statusChip = const ChChip('결과 확정', tone: Tone.good, icon: Icons.verified_rounded);
    } else if (reviewing) {
      // 설명은 위 검토 배너 한 곳에서. 여기는 짧은 표시만
      statusChip = const ChChip('검토 중', tone: Tone.review, icon: Icons.policy_rounded);
    } else if (!isToday) {
      statusChip = Wrap(spacing: 6, children: [
        ChChip('확정 · ${date.month}.${date.day + 1} 09:00', tone: Tone.good, icon: Icons.check_rounded),
        if (row != null && row.hasRevision) const ChChip('정정됨 · 저녁 무효', tone: Tone.warn, icon: Icons.history_rounded),
        if (row != null && row.check) const ChChip('점검 기간 · 누적 미반영', icon: Icons.fact_check_rounded),
      ]);
    } else {
      statusChip = ChChip('잠정 · ${act.syncTime} 동기화 · ${act.source}', icon: Icons.schedule_rounded);
    }

    final dayStart = (day - 4).clamp(1, 4);
    final strip = Row(children: [
      for (var i = 0; i < 7; i++)
        Expanded(
          child: Builder(builder: (_) {
            final dd = dayStart + i;
            final dt = _dateOf(dd);
            final future = dd > ch.dayIndex || dd < firstSelectableDay; // 오늘 이후·참가 이전은 고를 수 없다
            final sel = dd == day;
            final wk = weekdayKo(dt.month, dt.day);
            return Semantics(
              button: !future,
              selected: sel,
              label: '${dt.month}월 ${dt.day}일 $wk요일${sel ? ' 선택됨' : (!future ? ' 확정됨' : '')}',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: future ? null : () => ref.read(selectedDayProvider.notifier).set(dd),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 64), // 글자를 키우면 칸이 늘어난다
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(color: sel ? c.brand : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    NumText('${dt.day}', size: 20, weight: FontWeight.w700, color: sel ? c.onBrand : (future ? c.borderStrong : c.fg)),
                    Txt(wk, size: 11, color: sel ? c.onBrand : (future ? c.borderStrong : c.fg2)),
                    SizedBox(height: 12, child: !future && !sel ? Icon(Icons.check_rounded, size: 12, color: c.good) : null),
                  ]),
                ),
              ),
            );
          }),
        ),
    ]);

    // ---- 링 + 숫자 셋(카드 없이 바탕 위) ----
    Widget ringSection() {
      final threeNums = Row(children: [
        _Num(label: '소비', dot: c.burn, prefix: '약', value: fmtInt(burn.total), unit: 'kcal'),
        _Num(label: '섭취', dot: c.intake, value: fmtInt(inn.iD), unit: 'kcal'),
        _Num(label: '점수', star: true, value: fmtK1(sim.score.sD), unit: '점'),
      ]);
      Widget lifecycleCard() => switch (phase) {
            ChallengePhase.recruiting => ChCard(
                color: c.brandSoft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                  Txt.title('${ch.start.month}월 ${ch.start.day}일 ${weekdayKo(ch.start.month, ch.start.day, year: ch.start.year)}요일에 시작해요'),
                  const Txt.cap('첫 3일은 점검 기간이라 누적에 들어가지 않아요. 지금 연결 상태를 확인해 두면 첫날부터 걸음이 반영돼요.'),
                  ChLink('연결 상태 확인', onTap: () => context.push(R.p4)),
                ], gap: 6)),
              ),
            ChallengePhase.closing => ChCard(
                color: c.reviewSoft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                  Txt.title('최종 집계 중 · 운영자 확인 후 발표돼요', color: c.review),
                  Txt.cap('마지막 날 기록은 ${fmtMd(ch.end.add(const Duration(days: 1)))} 09:00에 확정됐어요. 미결 검토가 끝나면 결과가 발표되고 7일 이의 기간이 시작돼요.'),
                ], gap: 6)),
              ),
            _ => ChCard(
                color: c.brandSoft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                  Txt.title('최종 결과 · 이의 기간 ~${ch.objectionUntil}'),
                  Txt.cap('최종 ${myFinal.rank == 0 ? '순위 제외' : '${myFinal.rank}위'} · 누적 ${fmtK1(myFinal.score ?? 0)}점. 결과에 이의가 있으면 점수 장부에서 1회 남길 수 있어요.'),
                  ChLink('최종 순위 보기', onTap: () => context.go(R.rank)),
                ], gap: 6)),
              ),
          };
      final ringAndNums = Column(children: [
        Center(child: CalorieRing(ratio: ringRatio, provisional: provisional, empty: ringEmpty, center: ringCenter, semanticsLabel: ringLabel)),
        if (!lifecycle) ...[const SizedBox(height: 6), threeNums],
      ]);
      return GestureDetector(
        onHorizontalDragEnd: lifecycle ? null : _swipe,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (lifecycle)
            ringAndNums
          else
            Semantics(
              button: true,
              label: '점수 계산 보기',
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => context.push('${R.ledger}?day=$day'),
                child: Padding(padding: const EdgeInsets.only(top: 4, bottom: 4), child: ringAndNums),
              ),
            ),
          const SizedBox(height: 6),
          if (lifecycle) lifecycleCard() else ...[
            Center(child: statusChip),
            if (caption != null) ...[
              const SizedBox(height: 4),
              // 한 줄 · 조용히(줄임표). 읽기 이름에는 전체 문장이 남는다
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.info_rounded, size: 14, color: c.warn),
                const SizedBox(width: 4),
                Flexible(child: Txt.cap(caption, maxLines: 1)),
              ]),
            ],
          ],
        ]),
      );
    }

    // ---- 누적·순위 한 줄(카드 없이) ----
    final rankRow = lifecycle && phase != ChallengePhase.published
        ? null
        : Row(children: [
            Expanded(
              child: phase == ChallengePhase.published
                  ? Text.rich(TextSpan(children: [
                      TextSpan(text: '최종 누적 ', style: T.body(c, size: 15)),
                      TextSpan(text: fmtK1(myFinal.score ?? 0), style: T.num(c.fg, size: 17, w: FontWeight.w700)),
                      TextSpan(
                          text: '점 · 최종 ${myFinal.rank == 0 ? '순위 제외' : '${myFinal.rank}위'} · ${finalRows.where((r) => !r.aggregating).length}명',
                          style: T.body(c, size: 15)),
                    ]))
                  : Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(text: '누적 ', style: T.body(c, size: 15)),
                        TextSpan(text: fmtK1(cumulative), style: T.num(c.fg, size: 17, w: FontWeight.w700)),
                        TextSpan(text: '점 · ', style: T.body(c, size: 15)),
                      ])),
                      Txt(cumMe.rank == 0 ? '순위 제외 · 점수만 보여요' : '잠정 ${cumMe.rank}위'),
                      if (cumMe.delta > 0) Semantics(label: '${cumMe.delta}계단 상승', child: ExcludeSemantics(child: Txt('▲${cumMe.delta}', color: c.good))),
                      if (reviewing) Txt('· 검토 중', color: c.fg2),
                    ]),
            ),
            ChLink('점수 계산 보기', onTap: () => context.push('${R.ledger}?day=$day')),
          ]);

    // ---- 안내 한 줄(검토 → 섭취 적음 → 분석 완료 → 공지). 하나만 보이고 나머지는 '외 n건' 뒤에 ----
    final latestNotice = ref.watch(noticesProvider).value?.firstOrNull;
    final fullReview = reviewBanner.spike
        ? '걸음 ${fmtInt(steps)}이 평소의 2.5배를 넘어 검토 중이에요. 순위는 잠정으로 유지되고, 72시간 안에 설명을 남길 수 있어요.'
        : '${reviewBanner.lead}${reviewBanner.rest}';
    // 걸음 급증·출처 미확인은 '운동 기록', 그 밖의 사유는 그 사유 문장(짧은 한 줄)
    final reviewLine = reviewBanner.spike || reviewBanner.lead == reasonText['source_unknown'] ? '운동 기록을 확인 중이에요' : reviewBanner.lead;
    final draftMeal = isToday ? meals.where((m) => m.status == MealStatus.draft).firstOrNull : null;
    final notices = <_HomeNotice>[
      if (reviewing)
        _HomeNotice(
          tone: Tone.review,
          icon: Icons.policy_rounded,
          text: reviewLine,
          semantics: fullReview,
          action: ('소명하기', () => context.push('${R.ledger}?v=review')),
        ),
      if (showNudge)
        _HomeNotice(
          tone: Tone.neutral,
          icon: Icons.spa_rounded,
          text: '${isToday ? '오늘' : '이날'} 섭취 기록이 적어요',
          info: () => showChSheet<void>(context, builder: (ctx) => const _NudgeSheet()),
        ),
      if (draftMeal case final m?)
        _HomeNotice(
          tone: Tone.brand,
          icon: Icons.notifications_off_rounded,
          text: '${slotLabel[m.slot]} 분석 완료 · 확인하기',
          semantics: '${slotLabel[m.slot]} 분석 완료 · 확인하기. 알림이 꺼져 있어도 홈에서 알려드려요',
          onTap: () => context.push(R.meal(m.slot, meal: m.key)),
        ),
      if (_noticeOpen && !lifecycle && latestNotice != null)
        _HomeNotice(
          tone: Tone.neutral,
          icon: Icons.campaign_rounded,
          text: '[공지] ${latestNotice.title}',
          boldPrefix: '[공지] ',
          unread: !latestNotice.read,
          onTap: () {
            ref.read(noticesProvider.notifier).markRead([latestNotice.id]);
            showChSheet(context, builder: (_) => _NoticeSheet(title: latestNotice.title, body: latestNotice.body, date: fmtMd(latestNotice.at)));
          },
          onClose: () => setState(() => _noticeOpen = false),
        ),
    ];
    final noticeAt = notices.isEmpty ? 0 : _noticeIndex % notices.length;

    // ---- '오늘 기록' 목록(끼니 칸 4개 + 반영률을 한 목록으로) ----
    Widget timeline() {
      final rows = <Widget>[
        for (final s in [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner, MealSlot.snack])
          ..._slotRows(s, dayMeals, isToday, pastDate, inn.substituteFor(s), overLimitSkip(s)),
      ];
      final divider = Divider(height: 1, thickness: 1, color: c.border);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TimelineHeader(
          title: isToday ? '오늘 기록' : '${date.month}.${date.day} 기록',
          cells: cells,
          semanticsDetail: [
            for (final s in mainSlots) '${slotLabel[s]} ${slotFilled[s]! ? '확정' : slotSkipped[s]! ? '건너뜀' : '미확정'}',
            '걸음 ${cells[3] ? '동기화됨' : '미동기화'}',
          ].join(', '),
        ),
        for (final r in rows) ...[divider, r],
        divider,
      ]);
    }

    // ---- 활동 한 줄 ----
    Widget activityRow() {
      final label = steps == 0 ? '오늘 걸음을 못 읽었어요 · 연결 확인' : '걸음 ${fmtInt(steps)} · 활동 ${fmtInt(burn.activity)} kcal';
      return Semantics(
        button: true,
        label: '$label${reviewing ? ' · 걸음 검토 중' : ''}, 활동 상세 보기',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('home-activity'),
          onTap: () => context.go(R.activity),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(children: [
              Icon(Icons.directions_walk_rounded, size: 20, color: c.fg),
              const SizedBox(width: 10),
              Expanded(
                child: Row(children: [
              Flexible(
                child: steps == 0
                    ? Text.rich(TextSpan(children: [
                        TextSpan(text: '오늘 걸음을 못 읽었어요 · ', style: T.body(c)),
                        TextSpan(text: '연결 확인', style: T.body(c, w: FontWeight.w700, color: c.brand)),
                      ]), maxLines: 1, overflow: TextOverflow.ellipsis)
                    : Text.rich(TextSpan(children: [
                        TextSpan(text: '걸음 ', style: T.body(c)),
                        TextSpan(text: fmtInt(steps), style: T.num(c.fg, size: 17, w: FontWeight.w700)),
                        TextSpan(text: ' · 활동 ', style: T.body(c)),
                        TextSpan(text: fmtInt(burn.activity), style: T.num(c.fg, size: 17, w: FontWeight.w700)),
                        TextSpan(text: ' kcal', style: T.body(c, size: 13, color: c.fg2)),
                      ]), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              // 검토 중: 설명은 위 안내 줄에서, 여기는 방패 표시만
              if (reviewing) ...[
                const SizedBox(width: 6),
                Tooltip(message: '검토 중', excludeFromSemantics: true, child: Semantics(label: '검토 중', child: Icon(Icons.policy_rounded, size: 16, color: c.review))),
              ],
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: c.fg2),
            ]),
          ),
        ),
      );
    }

    final body = <Widget>[
      if (multi) const ChallengeCards(),
      if (notices.isNotEmpty)
        _NoticeLine(
          key: const ValueKey('home-notice'),
          notice: notices[noticeAt],
          more: notices.length - 1,
          onNext: () => setState(() => _noticeIndex = noticeAt + 1),
        ),
      if (!lifecycle) strip,
      // 챌린지가 하나면 카드 대신 날짜 아래 작은 링크(이번 달 참가 · 초대코드로 참가)
      if (!multi) const ChallengeCards(),
      ringSection(),
      ?rankRow,
      if (!lifecycle) timeline(),
      if (!lifecycle) activityRow(),
      const Disclaimer('모든 수치는 추정이에요 · 의료 조언이 아니에요'),
    ];

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          ChAppBar(
            title: appTitle,
            meta: meta,
            actions: [IconButton(onPressed: () => context.push(R.settings), tooltip: '설정', icon: Icon(Icons.settings_rounded, color: c.fg), constraints: const BoxConstraints(minWidth: 48, minHeight: 48))],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                final meals = ref.read(mealsProvider.notifier);
                await Future.wait([ref.read(activityProvider.notifier).refresh(), meals.retryPendingUploads(force: true)]);
                await meals.loadToday();
                // 지난 날을 보고 있으면 그 날짜 끼니도 다시 읽는다
                final d = ref.read(selectedDayProvider);
                if (remote && d != curChallenge.dayIndex) ref.invalidate(pastMealsProvider(_localDateOf(d)));
                ref.invalidate(ledgerProvider);
                ref.invalidate(leaderboardProvider);
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(body)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Num extends StatelessWidget {
  const _Num({required this.label, required this.value, required this.unit, this.prefix, this.dot, this.star = false});
  final String label;

  /// 값 앞의 작은 말('약')
  final String? prefix;
  final String value;
  final String unit;
  final Color? dot;
  final bool star;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Expanded(
      child: Semantics(
        label: '$label ${prefix == null ? '' : '$prefix '}$value $unit',
        excludeSemantics: true,
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (dot != null) Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2))),
            if (star) Icon(Icons.star_rounded, size: 14, color: c.fg2),
            const SizedBox(width: 4),
            Txt(label, size: 11, color: c.fg2),
          ]),
          // 값은 세 칸 모두 같은 높이의 한 줄: 좁은 폭이면 줄바꿈 대신 글자를 줄인다
          SizedBox(
            key: ValueKey('home-stat-$label'),
            height: 32,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text.rich(
                TextSpan(children: [
                  if (prefix != null) TextSpan(text: '$prefix ', style: T.body(c, size: 13, w: FontWeight.w500, color: c.fg2)),
                  TextSpan(text: value, style: T.num(c.fg, size: 22, w: FontWeight.w700)),
                  TextSpan(text: ' $unit', style: T.body(c, size: 12, w: FontWeight.w500, color: c.fg2)),
                ]),
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 홈 맨 위 안내 한 줄의 내용
class _HomeNotice {
  const _HomeNotice({required this.tone, required this.icon, required this.text, this.semantics, this.boldPrefix, this.action, this.info, this.onTap,
    this.onClose, this.unread = false});
  final Tone tone;
  final IconData icon;

  /// 한 줄 문장(넘치면 줄임표)
  final String text;

  /// 읽기 이름(없으면 [text]). 줄임표로 잘린 설명을 여기에 모두 담는다
  final String? semantics;

  /// [text] 앞부분을 굵게('[공지] ')
  final String? boldPrefix;

  /// 끝 버튼(이름, 누르면)
  final (String, VoidCallback)? action;

  /// 정보 버튼(설명 시트)
  final VoidCallback? info;

  /// 줄 전체를 누르면
  final VoidCallback? onTap;
  final VoidCallback? onClose;
  final bool unread;
}

/// 안내 한 줄: 아이콘 · 문장(한 줄) · '외 n건' · 끝 버튼. 누르는 곳은 모두 48dp 이상.
class _NoticeLine extends StatelessWidget {
  const _NoticeLine({super.key, required this.notice, required this.more, required this.onNext});
  final _HomeNotice notice;
  final int more;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final n = notice;
    final (bg, fg) = toneColors(c, n.tone);
    final textColor = n.tone == Tone.neutral ? c.fg : fg;
    final style = T.body(c, size: 13, w: FontWeight.w600, color: textColor);
    final bold = n.boldPrefix;
    final text = bold != null && n.text.startsWith(bold)
        ? Text.rich(TextSpan(children: [TextSpan(text: bold, style: style), TextSpan(text: n.text.substring(bold.length), style: style.copyWith(fontWeight: FontWeight.w400))]),
            maxLines: 1, overflow: TextOverflow.ellipsis)
        : Text(n.text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);

    Widget textButton(String label, VoidCallback onTap, {String? semantics, bool strong = true}) => Semantics(
          button: true,
          label: semantics ?? label,
          excludeSemantics: true,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(widthFactor: 1, child: Txt(label, size: 13, weight: strong ? FontWeight.w700 : FontWeight.w500, color: strong ? textColor : c.fg2)),
              ),
            ),
          ),
        );

    final main = Row(children: [
      Icon(n.icon, size: 18, color: n.tone == Tone.neutral ? c.fg2 : fg),
      const SizedBox(width: 8),
      Flexible(child: text),
      if (n.unread)
        Semantics(
          label: '읽지 않음',
          child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c.critical, shape: BoxShape.circle), margin: const EdgeInsets.only(left: 6)),
        ),
      if (n.onTap != null && n.onClose == null) Icon(Icons.chevron_right_rounded, size: 18, color: n.tone == Tone.neutral ? c.fg2 : fg),
    ]);

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 4),
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Expanded(
            child: n.onTap == null
                ? Semantics(label: n.semantics, excludeSemantics: n.semantics != null, child: main)
                : Semantics(
                    button: true,
                    label: n.semantics,
                    excludeSemantics: n.semantics != null,
                    child: InkWell(onTap: n.onTap, child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: main)),
                  ),
          ),
          if (more > 0) textButton('외 $more건', onNext, semantics: '다음 안내 보기, 외 $more건', strong: false),
          if (n.info != null)
            IconButton(
              onPressed: n.info,
              tooltip: '섭취 안내 보기',
              icon: Icon(Icons.info_outline_rounded, size: 20, color: c.fg2),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          if (n.action case (final label, final onTap)) textButton(label, onTap),
          if (n.onClose != null)
            IconButton(
              onPressed: n.onClose,
              tooltip: '닫기',
              icon: Icon(Icons.close_rounded, size: 18, color: c.fg2),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
        ]),
      ),
    );
  }
}

/// 섭취 적음 안내의 설명(기존 카드 문장 그대로)
class _NudgeSheet extends StatelessWidget {
  const _NudgeSheet();
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
        const Txt.title('섭취 안내'),
        const Txt('점수와 상관없이 충분히 드세요.\n이 안내는 순위와 점수에 영향을 주지 않아요.'),
        ChButton('닫기', kind: BtnKind.quiet, onPressed: () => Navigator.of(context).pop()),
      ]));
}

class _NoticeSheet extends StatelessWidget {
  const _NoticeSheet({required this.title, required this.body, required this.date});
  final String title;
  final String body;
  final String date;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
        const Txt.title('공지'),
        Txt(title, weight: FontWeight.w600),
        Txt(body),
        Txt.cap(date),
        ChButton('닫기', kind: BtnKind.quiet, onPressed: () => Navigator.of(context).pop()),
      ]));
}

/// 최종 순위표에 내 행이 없을 때(순위 제외)
LeaderRow cumFallback(List<LeaderRow> rows) => LeaderRow(rank: 0, name: curMe.nickname, me: true, score: 0);

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/meal_slot_card.dart';
import '../widgets/ring.dart';
import '../../state/session.dart';

/// P5 홈(오늘): 링 하나 + 숫자 셋, 점수·순위 → '점수 계산 보기', 반영률 4칸, 끼니 슬롯 4개, 활동 카드.
/// 모든 숫자는 엔진(`engine.simulate`)으로 계산한다. 링 카드를 좌우로 스와이프하면 날짜가 바뀐다.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _noticeOpen = true;

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

  DateTime _dateOf(int day) => curChallenge.start.add(Duration(days: day - 1));

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
      dayMeals = [
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
    final meta = lifecycle ? null : 'D+$day/${ch.days}';

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

    String? caption;
    final inn = sim.intake;
    if (isToday || row != null) {
      if (inn.substituteSlots.isNotEmpty) caption = '${inn.substituteSlots.map((s) => slotLabel[s]).join('·')} 미기록 → ${fmtM(inn.mP)} kcal 적용 중';
      if (inn.pendingSlots.isNotEmpty) caption = '${inn.pendingSlots.map((s) => slotLabel[s]).join('·')} 확정 대기 → ${fmtM(inn.mP)} kcal로 잠정 계산 중 · 검색으로 확정하면 반영';
      if (inn.draftSlots.isNotEmpty) caption = '${slotLabel[inn.draftSlots.first.slot]} 미확정 → ${fmtInt(inn.draftSlots.first.value)} kcal로 잠정 계산 중 · 확정하면 반영';
      if (sim.score.floorApplied) caption = '섭취 하한 ${fmtInt(sim.score.fP)} 적용';
      if (row != null && row.hasRevision) caption = '저녁 무효 → 대체값 ${fmtM(inn.mP)} 적용 · ${fmtK1(row.sBefore!)} → ${fmtK1(row.s)}점';
    }

    // 반영률: 아침·점심·저녁 확정 + 걸음
    bool confirmed(MealRecord m) => m.status == MealStatus.confirmed || m.status == MealStatus.auto || m.status == MealStatus.corrected;
    final cells = [
      for (final s in mainSlots) confirmed(dayMeals.firstWhere((m) => m.slot == s)),
      steps > 0,
    ];
    final pct = (cells.where((x) => x).length * 25);

    // 건강 안내(확정 섭취, 대체값 제외 < 남 1,500 / 여 1,200)
    final confirmedKcal = dayMeals.where(confirmed).fold<double>(0, (a, m) => a + m.kcal);
    final nudgeMin = curMe.sex == Sex.m ? engine.rules.nudgeMinM : engine.rules.nudgeMinF;
    final showNudge = !lifecycle && inn.mainMealCount > 0 && confirmedKcal < nudgeMin;

    final d = sim.score.dD;
    final zeroMeal = inn.mainMealCount == 0;

    // ---- 링 ----
    Widget ringCenter;
    String ringLabel;
    bool ringEmpty = false;
    double ringRatio = sim.score.ratio;
    if (phase == ChallengePhase.recruiting) {
      ringEmpty = true;
      ringLabel = '시작 전, 10월 6일에 시작해요';
      ringCenter = Column(mainAxisSize: MainAxisSize.min, children: [NumText('—', size: 44, weight: FontWeight.w700), const Txt.cap('10월 6일에 시작해요')]);
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
      statusChip = const ChChip('시작 전 · D−3', icon: Icons.event_rounded);
    } else if (phase == ChallengePhase.closing) {
      statusChip = const ChChip('최종 집계 중', tone: Tone.review, icon: Icons.hourglass_top_rounded);
    } else if (phase == ChallengePhase.published) {
      statusChip = const ChChip('결과 확정', tone: Tone.good, icon: Icons.verified_rounded);
    } else if (reviewing) {
      statusChip = const ChChip('검토 중 · 잠정 유지', tone: Tone.review, icon: Icons.policy_rounded);
    } else if (!isToday) {
      statusChip = Wrap(spacing: 6, children: [
        ChChip('확정 · ${date.month}.${date.day + 1} 09:00', tone: Tone.good, icon: Icons.check_rounded),
        if (row != null && row.hasRevision) const ChChip('정정됨 · 저녁 무효', tone: Tone.warn, icon: Icons.history_rounded),
        if (row != null && row.check) const ChChip('점검 기간 · 누적 미반영', icon: Icons.fact_check_rounded),
      ]);
    } else {
      statusChip = ChChip('잠정 · ${act.syncTime} 동기화 · ${act.source}', icon: Icons.schedule_rounded);
    }

    final slotTargets = <MealSlot, VoidCallback?>{
      for (final m in dayMeals)
        m.slot: !isToday
            ? null
            : () {
                if (m.status == MealStatus.empty || m.status == MealStatus.skipped) {
                  context.push('${R.camera}?slot=${m.slot.name}');
                } else {
                  context.push(R.meal(m.slot, search: (m.status == MealStatus.captured && (m.noAnalysis)) || m.status == MealStatus.failed));
                }
              },
    };

    final dayStart = (day - 4).clamp(1, 4);
    final strip = Row(children: [
      for (var i = 0; i < 7; i++)
        Expanded(
          child: Builder(builder: (_) {
            final dd = dayStart + i;
            final dt = _dateOf(dd);
            final future = dd > ch.dayIndex;
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
                  height: 64,
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

    // ---- 카드 본문 ----
    Widget ringCard() {
      final threeNums = Row(children: [
        _Num(label: '소비', dot: c.burn, value: '약 ${fmtInt(sim.e)}', unit: 'kcal'),
        _Num(label: '섭취', dot: c.intake, value: fmtInt(inn.iD), unit: 'kcal'),
        _Num(label: '점수', star: true, value: fmtK1(sim.score.sD), unit: '점'),
      ]);
      Widget lifecycleCard() => switch (phase) {
            ChallengePhase.recruiting => ChCard(
                color: c.brandSoft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                  Txt.title('10월 6일 ${weekdayKo(10, 6)}요일에 시작해요'),
                  const Txt.cap('첫 3일은 점검 기간이라 누적에 들어가지 않아요. 지금 연결 상태를 확인해 두면 첫날부터 걸음이 반영돼요.'),
                  ChLink('연결 상태 확인', onTap: () => context.push(R.p4)),
                ], gap: 6)),
              ),
            ChallengePhase.closing => ChCard(
                color: c.reviewSoft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                  Txt.title('최종 집계 중 · 운영자 확인 후 발표돼요', color: c.review),
                  const Txt.cap('마지막 날 기록은 11.3 09:00에 확정됐어요. 미결 검토가 끝나면 결과가 발표되고 7일 이의 기간이 시작돼요.'),
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
      return GestureDetector(
        onHorizontalDragEnd: lifecycle ? null : _swipe,
        child: ChCard(
          onTap: lifecycle ? null : () => context.push('${R.ledger}?day=$day'),
          semanticsLabel: '점수 계산 보기',
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
          child: Column(children: [
            CalorieRing(ratio: ringRatio, provisional: provisional, empty: ringEmpty, center: ringCenter, semanticsLabel: ringLabel),
            const SizedBox(height: 6),
            if (lifecycle) lifecycleCard() else ...[
              threeNums,
              const SizedBox(height: 8),
              Center(child: statusChip),
              if (caption != null) ...[
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.info_rounded, size: 14, color: c.warn),
                  const SizedBox(width: 4),
                  Flexible(child: Txt.cap(caption, color: c.warn, align: TextAlign.center)),
                ]),
              ],
            ],
          ]),
        ),
      );
    }

    final scoreToday = fmtK1(sim.score.sD);
    final rankCard = lifecycle && phase != ChallengePhase.published
        ? null
        : ChCard(
            onTap: () => context.push('${R.ledger}?day=$day'),
            semanticsLabel: '점수 계산 보기',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
              if (phase == ChallengePhase.published)
                Text.rich(TextSpan(children: [
                  TextSpan(text: '최종 누적 ', style: T.body(c, size: 17, w: FontWeight.w600)),
                  TextSpan(text: fmtK1(myFinal.score ?? 0), style: T.num(c.fg, size: 21, w: FontWeight.w700)),
                  TextSpan(text: '점', style: T.body(c, size: 17, w: FontWeight.w600)),
                ]))
              else
                Text.rich(TextSpan(children: [
                  TextSpan(text: isToday ? '오늘 ' : '${date.month}.${date.day} ', style: T.body(c, size: 17, w: FontWeight.w600)),
                  TextSpan(text: scoreToday, style: T.num(c.fg, size: 21, w: FontWeight.w700)),
                  TextSpan(text: '점 · 누적 ', style: T.body(c, size: 17, w: FontWeight.w600)),
                  TextSpan(text: fmtK1(cumulative), style: T.num(c.fg, size: 21, w: FontWeight.w700)),
                  TextSpan(text: '점', style: T.body(c, size: 17, w: FontWeight.w600)),
                ])),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                if (phase == ChallengePhase.published)
                  Txt('최종 ${myFinal.rank == 0 ? '순위 제외' : '${myFinal.rank}위'} · ${finalRows.where((r) => !r.aggregating).length}명')
                else
                  Flexible(
                    child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
                      Txt(cumMe.rank == 0 ? '순위 제외 · 점수만 보여요' : '잠정 ${cumMe.rank}위'),
                      if (cumMe.delta > 0) Semantics(label: '${cumMe.delta}계단 상승', child: ExcludeSemantics(child: Txt('▲${cumMe.delta}', color: c.good))),
                      if (reviewing) Txt('· 검토 중', color: c.fg2),
                    ]),
                  ),
                ChLink('점수 계산 보기', onTap: () => context.push('${R.ledger}?day=$day')),
              ]),
            ], gap: 6)),
          );

    // 최신 공지(N-03) 1건. 읽지 않았으면 빨간 점, 누르면 전문 + 읽음 처리
    final latestNotice = ref.watch(noticesProvider).value?.firstOrNull;
    final body = <Widget>[
      if (_noticeOpen && !lifecycle && latestNotice != null)
        InfoBanner(
          tone: Tone.neutral,
          icon: Icons.campaign_rounded,
          onClose: () => setState(() => _noticeOpen = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              ref.read(noticesProvider.notifier).markRead([latestNotice.id]);
              showChSheet(context, builder: (_) => _NoticeSheet(title: latestNotice.title, body: latestNotice.body, date: fmtMd(latestNotice.at)));
            },
            child: Row(children: [
              Expanded(child: boldThen(context, '[공지] ', latestNotice.title, color: c.fg2)),
              if (!latestNotice.read)
                Semantics(
                  label: '읽지 않음',
                  child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c.critical, shape: BoxShape.circle), margin: const EdgeInsets.only(left: 6)),
                ),
            ]),
          ),
        ),
      if (reviewing)
        InfoBanner(
          tone: Tone.review,
          icon: Icons.policy_rounded,
          action: ChButton('소명하기', small: true, kind: BtnKind.quiet, onPressed: () => context.push('${R.ledger}?v=review')),
          child: boldThen(context, '걸음 ${fmtInt(steps)}이 평소의 2.5배를 넘어 검토 중이에요.', ' 순위는 잠정으로 유지되고, 72시간 안에 설명을 남길 수 있어요.', color: c.review),
        ),
      if (isToday)
        for (final m in meals.where((m) => m.status == MealStatus.draft).take(1))
          InfoBanner(
            tone: Tone.brand,
            icon: Icons.notifications_off_rounded,
            action: ChButton('${slotLabel[m.slot]} 확인하기', small: true, kind: BtnKind.quiet, onPressed: () => context.push(R.meal(m.slot))),
            child: boldThen(context, '${slotLabel[m.slot]} 분석 완료 · 확인하기', '\n알림이 꺼져 있어도 홈에서 알려드려요', color: c.brand),
          ),
      if (!lifecycle) strip,
      ringCard(),
      ?rankCard,
      if (!lifecycle)
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            Semantics(
              label: '아침 ${cells[0] ? '확정' : '미확정'}, 점심 ${cells[1] ? '확정' : '미확정'}, 저녁 ${cells[2] ? '확정' : '미확정'}, 걸음 ${cells[3] ? '동기화됨' : '미동기화'} · 반영률 $pct%',
              child: ExcludeSemantics(
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
                  Fill4(cells: cells),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '아침 ${cells[0] ? '✓' : '–'} · 점심 ${cells[1] ? '✓' : '–'} · 저녁 ${cells[2] ? '✓' : '–'} · 걸음 ${cells[3] ? '✓' : '–'} · ', style: T.body(c, size: 13, color: c.fg2)),
                    TextSpan(text: '반영률 $pct%', style: T.body(c, size: 13, w: FontWeight.w700, color: c.fg)),
                  ])),
                ]),
              ),
            ),
            if (pct < 100) const Txt.cap('반영률이 낮으면 대체값이 들어가 점수가 낮아져요. 확정하면 바로 올라가요.'),
          ], gap: 8)),
        ),
      if (!lifecycle)
        for (final s in [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner, MealSlot.snack])
          MealSlotCard(meal: dayMeals.firstWhere((m) => m.slot == s), onTap: slotTargets[s]),
      if (showNudge)
        ChCard(
          outline: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.spa_rounded, color: c.fg2),
            const SizedBox(width: 8),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Txt('오늘 섭취 기록이 적어요', weight: FontWeight.w600),
                Txt.cap('점수와 무관하게 충분히 드세요 · 추정치예요 · 이 안내는 순위·점수에 영향이 없어요'),
              ]),
            ),
          ]),
        ),
      if (!lifecycle)
        ChCard(
          onTap: () => context.go(R.activity),
          semanticsLabel: '활동 상세 보기',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            Row(children: [
              Icon(Icons.directions_walk_rounded, color: c.fg),
              const SizedBox(width: 6),
              const Expanded(child: Txt.title('활동')),
              ChChip('${act.syncTime} 동기화', tone: Tone.good, icon: Icons.sync_rounded),
            ]),
            if (steps == 0)
              Row(children: [const Txt('오늘 걸음을 못 읽었어요 · '), Txt('연결 확인', weight: FontWeight.w700, color: c.brand)])
            else
              Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text.rich(TextSpan(children: [TextSpan(text: '걸음 ', style: T.body(c)), TextSpan(text: fmtInt(steps), style: T.num(c.fg, size: 18, w: FontWeight.w700))])),
                Text.rich(TextSpan(children: [TextSpan(text: '활동 ', style: T.body(c)), TextSpan(text: '약 ${fmtInt(sim.activity.aD)}', style: T.num(c.fg, size: 18, w: FontWeight.w700)), TextSpan(text: ' kcal', style: T.body(c))])),
                Txt(act.source, color: c.fg2),
              ]),
            if (reviewing) Row(children: [Icon(Icons.policy_rounded, size: 14, color: c.review), const SizedBox(width: 4), Expanded(child: Txt.cap('걸음이 검토 중이에요 · 잠정 점수에는 그대로 반영돼요', color: c.review))]),
          ], gap: 6)),
        ),
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
  const _Num({required this.label, required this.value, required this.unit, this.dot, this.star = false});
  final String label;
  final String value;
  final String unit;
  final Color? dot;
  final bool star;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Expanded(
      child: Semantics(
        label: '$label $value $unit',
        excludeSemantics: true,
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (dot != null) Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2))),
            if (star) Icon(Icons.star_rounded, size: 14, color: c.fg2),
            const SizedBox(width: 4),
            Txt(label, size: 11, color: c.fg2),
          ]),
          NumText(value, size: 22, weight: FontWeight.w700, unit: unit),
        ]),
      ),
    );
  }
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

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
import '../../state/session.dart';

/// P8 활동 상세: 소비 분해(BMR+걸음+세션+층수), 검증 상태, 문제 해결.
/// 플랫폼 활동 칼로리는 '참고값'으로만 보여주고 점수에는 쓰지 않는다. 수동 입력 걸음은 어디에도 입력할 수 없다.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  bool _watch = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ch = curChallenge;
    final act = ref.watch(activityProvider);
    final mySim = ref.watch(todayResultProvider);

    final SimulateResult sim = _watch ? watchToday() : mySim;
    final a = sim.activity;
    final who = _watch ? mockWatchProfile : curMe.profile;
    final steps = _watch ? 12000 : act.stepsTotal;
    final src = _watch ? 'Apple 건강' : act.source;
    final ios = !_watch && act.stepsManual > 0;
    final manualSource = !_watch && act.hasManualSource && !ios;
    final reviewing = !_watch && steps > AppConfig.stepsSpikeAbs;
    final zero = !_watch && steps == 0;
    final perStep = engine.kcalPerStep(who.weightKg);

    Widget syncChip() {
      if (zero) return const ChChip('동기화 없음 · 연결 확인', tone: Tone.critical, icon: Icons.sync_problem_rounded);
      if (manualSource || reviewing) return const ChChip('검토 중 · 잠정 유지', tone: Tone.review, icon: Icons.policy_rounded);
      return ChChip('${act.syncTime} 동기화 · $src', tone: Tone.good, icon: Icons.sync_rounded);
    }

    Widget stepsCard() {
      if (zero) {
        return ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            const Row(children: [Expanded(child: Txt.title('걸음')), ChChip('0', tone: Tone.critical)]),
            const Txt('걸음이 0이에요', weight: FontWeight.w600),
            const Txt.cap('1. 삼성헬스 → 설정 → Health Connect 동기화 켜기\n2. Health Connect 권한에서 챌로리 "걸음" 허용\n3. 챌로리를 다시 열거나 당겨서 새로고침', color: null),
            Row(children: [
              ChButton('삼성헬스 열기', small: true, kind: BtnKind.quiet, onPressed: () => showToast(context, '삼성헬스 앱에서 동기화를 켜 주세요')),
              const SizedBox(width: 8),
              ChButton('연결 진단', small: true, kind: BtnKind.quiet, onPressed: () => context.push('${R.p4}?state=zero')),
            ]),
          ], gap: 8)),
        );
      }
      if (manualSource) {
        return ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            const Row(children: [Expanded(child: Txt.title('걸음')), ChChip('검토 중', tone: Tone.review, icon: Icons.policy_rounded)]),
            const Txt('수동 입력 출처가 섞여 있어 검토 중이에요 · 잠정 유지'),
            const Txt.cap('Health Connect 집계는 출처별로만 나눌 수 있어 수동 걸음을 분리할 수 없어요. 운영자 확인 뒤 자동 기록분만 반영돼요.'),
          ], gap: 6)),
        );
      }
      if (ios) {
        return ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            Row(children: [const Expanded(child: Txt.title('걸음')), Txt.cap(src)]),
            Kv(Txt.cap('검증 걸음(순위 반영)'), NumText(fmtInt(act.stepsTotal), size: 19, weight: FontWeight.w700)),
            Kv(Txt.cap('기록 걸음'), NumText(fmtInt(act.stepsRecorded ?? act.stepsTotal + act.stepsManual), size: 17)),
            Kv(Txt.cap('미인정'), Row(mainAxisSize: MainAxisSize.min, children: [NumText(fmtInt(act.stepsManual), size: 17), const SizedBox(width: 4), const Txt.cap('(수동 입력)')])),
            const Txt.cap('직접 입력한 걸음은 순위에 들어가지 않아요(WasUserEntered).'),
          ], gap: 6)),
        );
      }
      return ChCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
          Row(children: [const Expanded(child: Txt.title('걸음')), Txt.cap(src)]),
          Kv(Txt.cap(_watch ? '세션 밖 걸음' : '걸음'), NumText(fmtInt(_watch ? a.stepsOut : steps), size: 20, weight: FontWeight.w700)),
          if (_watch) Txt.cap('기록 ${fmtInt(steps)}보 중 ${fmtInt(mockWatchSession.stepsInRange)}보는 세션으로 계산됐어요(이중 계산 방지).'),
          if (reviewing)
            Txt.cap('걸음 ${fmtInt(steps)}이 평소 중앙값의 2.5배를 넘어 검토 중이에요 · 잠정 점수에는 반영돼요', color: c.review)
          else
            const Txt.cap('자동 기록만 인정 · 세션 창 걸음은 세션 쪽에서만 계산돼요'),
        ], gap: 6)),
      );
    }

    // 세션 목록
    final sessions = _watch ? [mockWatchSession] : act.sessions;
    Widget sessionsCard() => ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [Expanded(child: Txt.title('운동 세션')), Txt.cap('자동 기록만')]),
            const SizedBox(height: 4),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [Icon(Icons.directions_run_rounded, color: c.fg2), const SizedBox(width: 12), const Expanded(child: Txt.cap('자동 기록된 운동이 없어요. 워치·운동 앱 세션만 인정돼요.'))]),
              )
            else
              for (var i = 0; i < sessions.length; i++)
                InkWell(
                  onTap: () {
                    final s = sessions[i];
                    final met = a.sessionMets.length > i ? a.sessionMets[i] : null;
                    showChSheet<void>(context, builder: (_) => _SessionSheet(session: s, met: met, weightKg: who.weightKg, source: _watch ? 'Apple Watch' : src));
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(Icons.directions_run_rounded, color: c.fg2),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Txt('${_sessionLabel(sessions[i].type)} ${sessions[i].minutes.round()}분${_kmh(sessions[i]) == null ? '' : ' · ${_kmh(sessions[i])!.toStringAsFixed(0)} km/h'}', weight: FontWeight.w600),
                          Txt.cap('${_watch ? '06:30 · Apple Watch · ' : ''}MET ${a.sessionMets.length > i ? a.sessionMets[i] : '—'}'),
                        ]),
                      ),
                      NumText(fmtK1(a.sessionsNetKcal), size: 18, weight: FontWeight.w700),
                    ]),
                  ),
                ),
          ]),
        );

    // 최근 7일 막대(오늘은 현재 계산값). 서버 모드는 내 장부, 모의는 프로토타입 장부
    final ledger = watchLedger(ref) ?? const <LedgerRow>[];
    final week = [
      for (final r in ledger.skip(ledger.length > 7 ? ledger.length - 7 : 0)) (r.date.split('.').last, r.provisional ? a.aD : r.a, r.provisional),
    ];
    final maxA = week.fold<double>(1, (m, w) => w.$2 > m ? w.$2 : m);

    final todayAct = _watch ? null : act;
    final platformRef = _watch || ios ? (_watch ? 380.0 : todayAct?.platformActiveKcal) : null;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          ChAppBar(title: '활동', meta: _watch ? '밤산책 예시' : '${ch.today.month}.${ch.today.day} 오늘'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(activityProvider.notifier).refresh(),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
                  ChSeg<bool>(small: true, label: '보기', items: const [(false, '내 활동'), (true, '워치 예시(밤산책)')], value: _watch, onChanged: (v) => setState(() => _watch = v)),
                  Align(alignment: Alignment.centerLeft, child: syncChip()),
                  ChCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
                      const Txt.title('소비 분해'),
                      Kv(Txt.cap('기초대사 (BMR)'), NumText(fmtInt(sim.bmr))),
                      Kv(Txt.cap('+ 걸음'), NumText(fmtK1(a.stepsNetKcal))),
                      Kv(Txt.cap('+ 운동 세션'), NumText(fmtK1(a.sessionsNetKcal))),
                      if (a.floorsKcal > 0) Kv(Txt.cap('+ 층수'), NumText(fmtK1(a.floorsKcal))),
                      Divider(height: 1, color: c.border),
                      Kv(Txt.cap('= 소비 (추정)'), Row(mainAxisSize: MainAxisSize.min, children: [Txt('약 ', color: c.fg2), NumText(fmtInt(sim.e), size: 24, weight: FontWeight.w700), const Txt.cap(' kcal')])),
                      Column(children: [
                        Kv(Txt.cap('활동 ${fmtK1(a.aD)}'), Txt.cap('상한 ${fmtInt(engine.rules.c)}')),
                        const SizedBox(height: 4),
                        ChGauge(value: a.aD, max: engine.rules.c, warn: a.aCapped, label: '활동 칼로리 상한 게이지'),
                        if (a.aCapped) Padding(padding: const EdgeInsets.only(top: 4), child: Txt.cap('상한 초과 ${fmtInt(a.overCap)} kcal 미반영', color: c.warn)),
                      ]),
                    ], gap: 8)),
                  ),
                  stepsCard(),
                  sessionsCard(),
                  if (!_watch)
                    ChCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Row(children: [Expanded(child: Txt.title('최근 7일 활동 kcal')), Txt.cap('추정 · 상한 1,000')]),
                        const SizedBox(height: 6),
                        Semantics(
                          label: '최근 7일 활동 칼로리: ${week.map((w) => '10월 ${w.$1}일 ${fmtInt(w.$2)}').join(', ')}',
                          child: ExcludeSemantics(
                            child: SizedBox(
                              height: 110,
                              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                for (final w in week)
                                  Expanded(
                                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                                      NumText(fmtInt(w.$2), size: 11, color: c.fg2),
                                      const SizedBox(height: 2),
                                      Container(width: 22, height: (w.$2 / maxA * 60).clamp(4, 60), decoration: BoxDecoration(color: w.$3 ? c.brand : c.brand.withValues(alpha: 0.55), borderRadius: const BorderRadius.vertical(top: Radius.circular(4)))),
                                      const SizedBox(height: 4),
                                      NumText(w.$1, size: 11, color: w.$3 ? c.brand : c.fg2, weight: w.$3 ? FontWeight.w700 : FontWeight.w500),
                                    ]),
                                  ),
                              ]),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ChCard(
                    outline: true,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                      const Row(children: [Expanded(child: Txt.title('플랫폼 활동 칼로리')), ChChip('참고값 · 순위 미반영', icon: Icons.info_rounded)]),
                      Txt(platformRef != null ? 'Apple 건강 활동 ${fmtInt(platformRef)} kcal' : '삼성헬스 활동 칼로리 — 제공 안 됨'),
                      const Txt.cap('폰이든 워치든 순위는 같은 공식(MET 엔진)으로 계산해요.'),
                    ], gap: 6)),
                  ),
                  ChCard(
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        title: const Txt('계산 내역', weight: FontWeight.w600),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '걸음 × (${engine.rules.stepMet}−1) × ${who.weightKg.round()} ÷ 6,000 = ${fmtFixed(perStep, 4)} kcal/보'
                              '${_watch ? '\n세션 (MET ${a.sessionMets.isEmpty ? '—' : a.sessionMets.first}−1) × ${who.weightKg.round()} kg × 0.5 h = ${fmtK1(a.sessionsNetKcal)}' : ''}'
                              '\n상한: 걸음 ${fmtInt(engine.rules.stepsCap)}보 · 층수 ${engine.rules.floorsCap}층 · 활동 ${fmtInt(engine.rules.c)} kcal · 2024 Compendium 17190(걷기) · 17131(계단)',
                              style: T.body(c, size: 13, color: c.fg2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Disclaimer('모든 수치는 추정이에요'),
                ])),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  static String _sessionLabel(SessionType t) => switch (t) {
        SessionType.running => '달리기',
        SessionType.stair => '계단',
        SessionType.walking => '걷기',
      };

  static double? _kmh(SessionInput s) => (s.distanceM == null || s.minutes <= 0) ? null : s.distanceM! * 60 / (s.minutes * 1000);
}

class _SessionSheet extends StatelessWidget {
  const _SessionSheet({required this.session, required this.met, required this.weightKg, required this.source});
  final SessionInput session;
  final double? met;
  final double weightKg;
  final String source;

  @override
  Widget build(BuildContext context) {
    final net = met == null ? 0.0 : (met! - 1) * weightKg * (session.minutes / 60);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
      Txt.title('${_ActivityScreenState._sessionLabel(session.type)} 세션'),
      Kv(const Txt.cap('시간'), NumText('${session.minutes.round()}분', size: 17)),
      Kv(const Txt.cap('MET'), NumText('${met ?? '—'}', size: 17)),
      Kv(const Txt.cap('출처'), Txt(source, weight: FontWeight.w600)),
      Kv(const Txt.cap('세션 창 걸음(이중 계산 방지)'), NumText(fmtInt(session.stepsInRange), size: 17)),
      Txt.cap('(${met ?? '—'}−1) × ${weightKg.round()} kg × ${(session.minutes / 60).toStringAsFixed(1)} h = ${fmtK1(net)} kcal'),
      ChButton('닫기', kind: BtnKind.quiet, onPressed: () => Navigator.of(context).pop()),
    ], gap: 10));
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// P11 챌린지 규칙: 규칙 카드 4장 · 상수 블록(EngineRules에서 자동) · 시간 · 판정 · 내 숫자 시뮬레이터.
/// 시뮬레이터는 [ScoreSimulator] 인터페이스로 계산한다(모의=로컬 엔진, 서버=RPC score_simulate_from_inputs).
class RulesScreen extends ConsumerStatefulWidget {
  const RulesScreen({super.key});

  @override
  ConsumerState<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends ConsumerState<RulesScreen> {
  final _steps = TextEditingController(text: '9000');
  final _run = TextEditingController(text: '0');
  final _intake = TextEditingController(text: '1800');
  final _pager = PageController(viewportFraction: 0.86);
  int _page = 0;
  int _seq = 0;
  late SimulateResult _result;

  /// 달리기 가정: 9 km/h(분당 150 m), 달리기 중 걸음 150보/분은 걸음에서 뺀다.
  static const _runKmh = 9.0;
  static const _runStepsPerMin = 150;

  @override
  void initState() {
    super.initState();
    _result = engine.simulate(_input()); // 첫 프레임부터 값이 있도록 로컬 계산
    _recompute();
  }

  @override
  void dispose() {
    _steps.dispose();
    _run.dispose();
    _intake.dispose();
    _pager.dispose();
    super.dispose();
  }

  int _n(TextEditingController c) => int.tryParse(c.text.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;

  SimulateInput _input() {
    final run = _n(_run);
    // 3끼 확정 가정: 섭취를 세 끼에 균등 분할(끼니 최소 간식 기준 이상으로 보정)
    final per = (_n(_intake) / 3).clamp(engine.rules.snackKcal, 100000).toDouble();
    return SimulateInput(
      profile: mockMe.profile,
      stepsTotal: _n(_steps),
      sessions: run > 0
          ? [SessionInput(type: SessionType.running, minutes: run.toDouble(), distanceM: _runKmh * 1000 / 60 * run, stepsInRange: run * _runStepsPerMin)]
          : const [],
      meals: [
        MealInput(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: per),
        MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: per),
        MealInput(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: per),
      ],
    );
  }

  Future<void> _recompute() async {
    final my = ++_seq;
    final input = _input();
    final res = await ref.read(scoreSimulatorProvider).simulate(input);
    if (!mounted || my != _seq) return;
    setState(() => _result = res);
  }

  void _onInput() {
    setState(() => _result = engine.simulate(_input()));
    _recompute();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = engine.rules;
    final m = fmtM(meM);
    final cards = [
      ('①', '먹은 걸 찍어요', '세 끼를 찍고 확정하면 끝. 안 찍은 끼니는 $m kcal로, 간식은 찍은 만큼 더해져요.', '대체값 $m · 간식 ${fmtInt(r.snackKcal)} 미만', const Color(0xFF0B6E70)),
      ('②', '움직여요', '걸음·달리기·계단 자동 기록만 인정. 하루 활동 최대 ${fmtInt(r.c)} kcal.', '활동 상한 ${fmtInt(r.c)} · 걸음 ${fmtInt(r.stepsCap)}', const Color(0xFF1F5E8F)),
      ('③', '점수는 이렇게', '(기초대사 + 활동) − 섭취 = 순적자. ${fmtInt(r.t)} kcal면 100점, 최대 ${fmtInt(r.sMax)}점.', 'T ${fmtInt(r.t)} · 최대 ${fmtInt(r.sMax)}점', const Color(0xFF4A3F8A)),
      ('④', '공정하게', '폰이든 워치든 같은 공식. 이상 기록은 조용히 확인하고 설명 기회를 드려요.', '소명 1회 · 72시간', const Color(0xFF3E6B3A)),
    ];

    final s = _result;
    final chips = [
      'T ${fmtInt(r.t)}',
      '활동 상한 ${fmtInt(r.c)}',
      '섭취 하한 max(${fmtInt(r.fMin)}, ${r.fRatio}×BMR)',
      '대체값 max(${fmtInt(r.mMin)}, ${r.mRatio}×BMR)',
      '간식 ${fmtInt(r.snackKcal)}',
      '걸음 ${fmtInt(r.stepsCap)}',
      '층수 ${r.floorsCap}',
      '건너뜀 ${r.skipPerDay}/일 · ${r.skipPerWeek}/주',
    ];

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          ChAppBar(title: '규칙', meta: mockChallenge.name),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
                Column(children: [
                  SizedBox(
                    height: 188,
                    child: PageView.builder(
                      controller: _pager,
                      padEnds: false,
                      itemCount: cards.length,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (_, i) {
                        final (no, title, body, tag, color) = cards[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Semantics(
                            container: true,
                            label: '규칙 ${i + 1}/4 $title. $body',
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(no, style: T.num(Colors.white.withValues(alpha: 0.85), size: 24, w: FontWeight.w700)),
                                const SizedBox(height: 4),
                                Txt(title, size: 17, weight: FontWeight.w700, color: Colors.white),
                                const SizedBox(height: 6),
                                Expanded(child: Txt(body, size: 14, color: Colors.white, height: 1.5)),
                                Txt(tag, size: 11, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.85)),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    IconButton(
                      onPressed: _page > 0 ? () => _pager.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut) : null,
                      tooltip: '이전 규칙',
                      icon: const Icon(Icons.chevron_left_rounded),
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                    for (var i = 0; i < cards.length; i++)
                      Container(width: 6, height: 6, margin: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: i == _page ? c.brand : c.borderStrong, shape: BoxShape.circle)),
                    IconButton(
                      onPressed: _page < cards.length - 1 ? () => _pager.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut) : null,
                      tooltip: '다음 규칙',
                      icon: const Icon(Icons.chevron_right_rounded),
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                  ]),
                ]),
                ChCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                    Row(children: [const Txt.title('상수 '), const Txt.cap('챌린지 시작 후 잠금')]),
                    Wrap(spacing: 6, runSpacing: 6, children: [for (final t in chips) ChChip(t)]),
                  ], gap: 6)),
                ),
                ChCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                    const Txt.title('시간'),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      const ChChip('매시간 잠정', icon: Icons.schedule_rounded),
                      const ChChip('D+1 09:00 확정', tone: Tone.good, icon: Icons.check_rounded),
                      ChChip('점검 첫 ${r.checkDays}일'),
                      const ChChip('수정 48시간'),
                    ]),
                  ], gap: 6)),
                ),
                ChCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                    const Txt.title('판정'),
                    const Txt('검토 중 → 소명 1회(72h) → 승인 · 경고 · 무효 · 순위 제외(경고 3회)'),
                    const Txt.cap('검토 중인 기록은 다른 참가자에게 "집계 중"으로만 보여요. 자동 차단과 공개 지목은 없어요.'),
                  ], gap: 6)),
                ),
                ChCard(
                  color: c.brandSoft,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
                    Row(children: [const Txt.title('내 숫자 시뮬레이터 '), Txt.cap('BMR ${fmtInt(s.bmr)} 기준', color: c.brand)]),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: ChInput(label: '걸음', controller: _steps, maxLength: 6, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: (_) => _onInput())),
                      const SizedBox(width: 8),
                      Expanded(child: ChInput(label: '달리기(분)', controller: _run, maxLength: 3, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: (_) => _onInput())),
                      const SizedBox(width: 8),
                      Expanded(child: ChInput(label: '섭취', controller: _intake, maxLength: 5, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: (_) => _onInput())),
                    ]),
                    Semantics(
                      liveRegion: true,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                        Expanded(child: Txt.cap('활동 ${fmtK1(s.activity.aD)} · 순적자 ${fmtInt(s.score.dD)}${s.score.floorApplied ? ' · 하한 적용' : ''}')),
                        const Txt('예상 '),
                        NumText(fmtK1(s.score.sD), size: 26, weight: FontWeight.w700),
                        const Txt('점'),
                      ]),
                    ),
                    ChGauge(value: s.score.ratio, max: r.sMax / 100, label: '예상 점수 게이지'),
                    Txt.cap('가정: 3끼 확정 · 달리기는 ${_runKmh.round()} km/h 기준이고 달리기 중 걸음 $_runStepsPerMin보/분은 걸음에서 빼요 · 결과는 P5·P10과 같은 산식 함수'),
                    ChLink('오늘 실제값과 비교', onTap: () => context.push(R.ledger)),
                  ], gap: 10)),
                ),
                const InlineNote(Icons.info_rounded, '일부만 찍는 기록은 완전히 막을 수 없어요. 신고와 운영자 확인으로 보완해요.'),
                const Disclaimer('모든 수치는 추정이에요 · 의료 조언이 아니에요'),
              ])),
            ),
          ),
        ]),
      ),
    );
  }
}

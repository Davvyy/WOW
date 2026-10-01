import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

/// P10 점수 장부·소명: "왜 이 점수인가"를 숫자로. 산식 대입 카드 · 일별 표 · 적용 규칙 칩 · 변경 이력 ·
/// 검토·소명(당사자만). 모든 값은 엔진 계산값이다. 판정 문구는 docs/06 §6 템플릿만 쓴다.
/// variant: revision | review | verdict-approve | verdict-warn | verdict-void | verdict-exclude | expired | objection
class LedgerScreen extends ConsumerStatefulWidget {
  const LedgerScreen({super.key, this.variant, this.day});
  final String? variant;

  /// 장부를 볼 날(1~8). 비우면 오늘.
  final int? day;

  @override
  ConsumerState<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends ConsumerState<LedgerScreen> {
  final _appeal = TextEditingController();
  final _objection = TextEditingController();
  String? _variant;
  bool _sent = false;
  bool _busy = false;
  bool _objectionSent = false;

  /// 소명 보내기(서버: appeals insert, RLS 로 본인·open·72h·1회). [reviewId] 가 없으면 모의 시나리오.
  Future<void> _sendAppeal(String reviewId) async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).submitAppeal(reviewId, _appeal.text);
      if (!mounted) return;
      setState(() => _sent = true);
      ref.invalidate(myReviewsProvider);
    } catch (e) {
      if (mounted) showToast(context, apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 결과 이의(서버 RPC submit_objection: 발표 후 7일·1회)
  Future<void> _sendObjection() async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).submitObjection(_objection.text);
      if (!mounted) return;
      setState(() => _objectionSent = true);
      ref.invalidate(myReviewsProvider);
      showToast(context, '이의를 남겼어요. 운영자가 확인해요');
    } catch (e) {
      if (mounted) showToast(context, apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _variant = widget.variant;
  }

  @override
  void dispose() {
    _appeal.dispose();
    _objection.dispose();
    super.dispose();
  }

  Widget _verdictSection(BuildContext context, String v) {
    final c = context.c;
    final m = fmtM(meM);
    final r7 = mockLedger[6]; // 판정 변형(v=verdict-*)은 프로토타입 시나리오 화면
    switch (v) {
      case 'verdict-approve':
        final t = verdictText['approve']!;
        return InfoBanner(
          tone: Tone.good,
          icon: Icons.check_circle_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [boldThen(context, t.text, ' · ${t.effect}', color: c.good), Text('${reasonText['steps_spike']} · 10.13 확인')]),
        );
      case 'verdict-warn':
        final t = verdictText['warn']!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
          InfoBanner(
            tone: Tone.warn,
            icon: Icons.warning_rounded,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [boldThen(context, t.text.replaceFirst('{n}', '1'), ' · ${t.effect}', color: c.warn), Text(reasonText['source_unknown']!)]),
          ),
          const ChChip('경고 1/3', tone: Tone.warn, icon: Icons.warning_rounded),
        ], gap: 8));
      case 'verdict-void':
        final t = verdictText['void']!;
        return InfoBanner(
          tone: Tone.warn,
          icon: Icons.history_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            boldThen(context, '${reasonText['dup_photo']}.', ' ${t.text.replaceFirst('{대체 처리}로', '대체값 $m${roParticle(m)}')}', color: c.warn),
            Text('10.12 ${fmtK1(r7.sBefore!)}→${fmtK1(r7.s)}점 · 누적 −${fmtK1(r7.sBefore! - r7.s)}'),
          ]),
        );
      case 'verdict-exclude':
        final t = verdictText['exclude']!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
          InfoBanner(tone: Tone.review, icon: Icons.visibility_off_rounded, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [boldThen(context, t.text, '', color: c.review), Text(t.effect)])),
          const ChChip('경고 3/3 · 순위 제외', tone: Tone.review, icon: Icons.policy_rounded),
        ], gap: 8));
      case 'expired':
        return InfoBanner(tone: Tone.neutral, icon: Icons.schedule_rounded, child: boldThen(context, verdictText['expired']!.text, '', color: c.fg2));
      case 'objection':
        return _objectionCard(context);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _objectionCard(BuildContext context, {bool already = false}) {
    final c = context.c;
    if (already || _objectionSent) {
      return InfoBanner(tone: Tone.brand, icon: Icons.send_rounded, child: boldThen(context, '이의를 남겼어요.', ' 운영자가 확인하고 정정 여부를 알려드려요', color: c.brand));
    }
    return ChCard(
      color: c.brandSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
        const Txt.title('최종 결과에 이의 남기기'),
        Txt.cap('이의 기간 ~${curChallenge.objectionUntil} · 1회만 남길 수 있어요. 운영자가 확인하고 정정 여부를 알려드려요.'),
        TextField(
          controller: _objection,
          minLines: 4,
          maxLines: 6,
          maxLength: 1000,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: '어느 날짜의 어떤 점수가 다르다고 생각하는지 적어 주세요.', filled: true, fillColor: c.bg, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
        ),
        ChButton('이의 보내기', icon: Icons.send_rounded, onPressed: _objection.text.trim().length < 5 || _busy ? null : _sendObjection),
      ], gap: 8)),
    );
  }

  /// 서버 모드: 내 검토 카드(진행 중) · 최근 판정 통지 · 결과 이의
  List<Widget> _serverReviewCards(BuildContext context, List<MyReview> reviews) {
    final c = context.c;
    final active = reviews.where((r) => r.type != 'objection' && !r.decided).firstOrNull;
    final decided = reviews.where((r) => r.decided && r.message != null && r.type != 'objection').firstOrNull;
    final hasObjection = reviews.any((r) => r.type == 'objection');
    String two(int v) => v.toString().padLeft(2, '0');
    String when(DateTime t) {
      final k = t.toUtc().add(const Duration(hours: 9));
      return '${fmtMd(k)} ${two(k.hour)}:${two(k.minute)}';
    }

    final out = <Widget>[];
    if (active != null) {
      final reason = reasonText[active.reasonTemplate ?? active.type] ?? (active.type == 'report' ? '신고가 접수돼 기록을 확인 중이에요' : '기록을 확인 중이에요');
      final day = active.localDate == null ? '' : '${fmtMd(active.localDate!)} · ';
      if (active.status == 'appealed' || _sent) {
        out.add(InfoBanner(
          tone: Tone.review,
          icon: Icons.send_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            boldThen(context, '설명을 보냈어요.', ' 운영자가 확인하고 결과를 알려드려요', color: c.review),
            if ((active.appealText ?? _appeal.text).isNotEmpty) Txt.cap('“${active.appealText ?? _appeal.text}”'),
          ]),
        ));
      } else {
        out.add(ChCard(
          color: c.reviewSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.policy_rounded, color: c.review),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Txt('$day$reason · 검토 중', weight: FontWeight.w600, color: c.review),
                  Txt.cap(
                      '${active.slaDueAt == null ? '' : '${when(active.slaDueAt!)}까지 '}설명을 남길 수 있어요(1회). 순위는 잠정으로 유지되고, 다른 참가자에게는 "집계 중"으로만 보여요.',
                      color: c.review),
                ]),
              ),
            ]),
            const Txt.cap('무슨 일이 있었나요?', weight: FontWeight.w600),
            TextField(
              controller: _appeal,
              maxLength: 500,
              minLines: 4,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '예: 북한산 등산을 다녀왔어요. 삼성헬스 운동 기록 캡처를 함께 보냅니다.',
                filled: true,
                fillColor: c.bg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            ChButton('설명 보내기', icon: Icons.send_rounded, onPressed: _appeal.text.trim().isEmpty || _busy ? null : () => _sendAppeal(active.id)),
          ], gap: 8)),
        ));
      }
    }
    if (decided != null) {
      final tone = switch (decided.verdict) { 'approve' => Tone.good, 'warn' => Tone.warn, 'void' => Tone.warn, _ => Tone.review };
      out.add(InfoBanner(
        tone: tone,
        icon: Icons.gavel_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Txt('판정 결과${decided.decidedAt == null ? '' : ' · ${when(decided.decidedAt!)}'}', weight: FontWeight.w600),
          Txt(decided.message!), // 사유 + 판정 + 점수 영향 문장(서버 템플릿 조합)
        ]),
      ));
    }
    if (ref.watch(phaseProvider) == ChallengePhase.published) out.add(_objectionCard(context, already: hasObjection));
    return out;
  }

  Widget _reviewSection(BuildContext context) {
    final c = context.c;
    if (_sent) {
      return InfoBanner(tone: Tone.review, icon: Icons.send_rounded, child: boldThen(context, '설명을 보냈어요.', ' 운영자가 72시간 안에 확인해요', color: c.review));
    }
    return ChCard(
      color: c.reviewSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.policy_rounded, color: c.review),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Txt('걸음 ${fmtInt(reviewStepsCase)}이 평소의 2.5배를 넘어 검토 중이에요', weight: FontWeight.w600, color: c.review),
              Txt.cap('72시간 안에 설명을 남길 수 있어요(1회). 순위는 잠정으로 유지되고, 다른 참가자에게는 "집계 중"으로만 보여요.', color: c.review),
            ]),
          ),
        ]),
        const Txt.cap('무슨 일이 있었나요?', weight: FontWeight.w600),
        TextField(
          controller: _appeal,
          maxLength: 500,
          minLines: 4,
          maxLines: 6,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: '예: 북한산 등산을 다녀왔어요. 삼성헬스 운동 기록 캡처를 함께 보냅니다.',
            filled: true,
            fillColor: c.bg,
            counterText: '${_appeal.text.length} / 500',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        ChButton('설명 보내기', icon: Icons.send_rounded, onPressed: _appeal.text.trim().isEmpty || _busy ? null : () => _sendAppeal('mock-review')),
        const Center(child: Txt.cap('운영자가 72시간 안에 확인해요')),
      ], gap: 8)),
    );
  }

  Widget _loading(BuildContext context) {
    final err = ref.watch(ledgerProvider).error;
    return ChScaffold(title: '점수 장부', backFallback: R.home, children: [
      ChCard(
        child: Column(children: spaced([
          Txt.title(err == null ? '장부를 불러오고 있어요' : '장부를 불러오지 못했어요'),
          if (err != null) Txt.cap(apiErrorText(err), align: TextAlign.center),
          if (err != null) ChButton('다시 불러오기', small: true, kind: BtnKind.quiet, onPressed: () => ref.invalidate(ledgerProvider)),
        ], gap: 6)),
      ),
    ]);
  }

  Widget _mockHistory(String m) {
    final r7 = mockLedger[6];
    return ChCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Txt.title('변경 이력'),
        const SizedBox(height: 4),
        _HistoryRow(Icons.history_rounded, '10.12 저녁 무효 → 대체값 $m · ${fmtK1(r7.sBefore!)} → ${fmtK1(r7.s)}', '${reasonText['dup_photo']} · 운영자 판정(정정)'),
        const _HistoryRow(Icons.edit_rounded, '10.10 점심 850 → 780 확정(본인)', 'AI 초안 수정 · 확정값만 반영'),
        const _HistoryRow(Icons.sync_rounded, '10.9 걸음 재조회 +120보', '삼성헬스 지연 동기화 · 확정 전 반영'),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = _variant;
    final todaySim = ref.watch(todayResultProvider);
    final act = ref.watch(activityProvider);
    final review = v == 'review';
    final remote = ref.read(apiProvider).isRemote;
    final loaded = watchLedger(ref);
    if (loaded == null) return _loading(context);
    final ledger = loaded;
    final cumulative = round1(ledger.where((x) => !x.check && !x.provisional).fold(0.0, (a, x) => a + x.s));

    // 서버 모드: 선택한 날(없으면 오늘 잠정 행)을 서버 값 그대로 보여준다. 모의: 엔진으로 다시 계산(라이브 반영)
    final dayRow = widget.day == null ? null : ledger.where((r) => r.d == widget.day).firstOrNull;
    final pastRow = remote ? (dayRow ?? ledger.lastOrNull) : ((dayRow != null && !dayRow.provisional) ? dayRow : null);
    final SimulateResult t = remote && pastRow != null
        ? resultFromLedgerRow(pastRow)
        : pastRow != null
        ? engine.simulate(SimulateInput(profile: curMe.profile, stepsTotal: pastRow.steps, meals: pastRow.meals))
        : review
        ? engine.simulate(SimulateInput(profile: curMe.profile, stepsTotal: reviewStepsCase, meals: ref.watch(mealsProvider).map((m) => m.toInput()).toList(), skipsUsedThisWeek: ref.watch(skipsUsedProvider)))
        : todaySim;
    final steps = review ? reviewStepsCase : act.stepsTotal;
    final iEff = t.intake.iD > t.score.fP ? t.intake.iD : t.score.fP;
    final m = fmtM(t.intake.mP);

    final ruleChips = <Widget>[
      ChChip('대체값 $m = max(${fmtInt(engine.rules.mMin)}, ${engine.rules.mRatio}×BMR)'),
      ChChip('섭취 하한 ${fmtInt(t.score.fP)} = max(${fmtInt(engine.rules.fMin)}, ${engine.rules.fRatio}×BMR)'),
      ChChip('활동 상한 ${fmtInt(engine.rules.c)}'),
      for (final d in t.intake.draftSlots) ChChip('미확정 초안 ${fmtInt(d.value)} 잠정 반영(${slotLabel[d.slot]})', tone: Tone.warn),
      for (final s in t.intake.substituteSlots) ChChip('대체값 $m 적용(${slotLabel[s]})', tone: Tone.warn),
      const ChChip('체중 비례 목표 시 —점 [미결]'),
    ];

    LedgerRow live(LedgerRow r) => !r.provisional || remote
        ? r
        : LedgerRow(
            d: r.d,
            date: r.date,
            steps: steps,
            bmr: t.bmr,
            a: t.activity.aD,
            i: t.intake.iD,
            dd: t.score.dD,
            s: t.score.sD,
            f: t.score.fP,
            floorApplied: t.score.floorApplied,
            substituted: t.intake.substituteSlots,
            check: r.check,
            provisional: true,
            note: r.note,
            history: r.history,
            health: r.health,
            meals: r.meals,
          );

    Widget tableRow(LedgerRow r) {
      final flags = [
        if (r.check) '점검',
        if (r.substituted.isNotEmpty) '대체(${r.substituted.map((s) => slotLabel[s]).join()})',
        if (r.floorApplied) '하한',
        if (r.hasRevision) '정정',
        if (r.provisional) '잠정',
        if (r.health) '건강 안내',
      ].join(' · ');
      final dim = r.check ? c.fg2 : c.fg;
      final tappable = r.provisional || r.hasRevision;
      return Semantics(
        button: tappable,
        label: '${r.date} 점수 ${fmtK1(r.s)}점 $flags',
        child: InkWell(
          onTap: !tappable
              ? null
              : () {
                  ref.read(selectedDayProvider.notifier).set(r.d);
                  context.go(R.home);
                },
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(color: r.provisional ? c.brandSoft : null, border: Border(bottom: BorderSide(color: c.border))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                flex: 14,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  NumText(r.date, size: 14, color: dim),
                  if (flags.isNotEmpty) Txt(flags, size: 10, color: c.fg2),
                ]),
              ),
              Expanded(flex: 8, child: Align(alignment: Alignment.centerRight, child: NumText(fmtInt(r.bmr), size: 14, color: dim))),
              Expanded(flex: 8, child: Align(alignment: Alignment.centerRight, child: NumText(fmtInt(r.a), size: 14, color: dim))),
              Expanded(flex: 8, child: Align(alignment: Alignment.centerRight, child: NumText(fmtInt(r.i), size: 14, color: dim))),
              Expanded(flex: 8, child: Align(alignment: Alignment.centerRight, child: NumText(fmtInt(r.dd), size: 14, color: dim))),
              Expanded(
                flex: 12,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: r.hasRevision
                      ? Column(crossAxisAlignment: CrossAxisAlignment.end, children: [NumText(fmtK1(r.sBefore!), size: 11, color: c.fg2), NumText(fmtK1(r.s), size: 15, weight: FontWeight.w700)])
                      : NumText(fmtK1(r.s), size: 15, weight: FontWeight.w700, color: dim),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    final revised = ledger.where((r) => r.history.isNotEmpty).toList().reversed.toList();
    final history = remote
        ? ChCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Txt.title('변경 이력'),
              const SizedBox(height: 4),
              if (revised.isEmpty) const Txt.cap('아직 정정된 날이 없어요'),
              for (final r in revised)
                _HistoryRow(r.revisionReason != null ? Icons.history_rounded : Icons.edit_rounded, '${r.date} ${r.history}',
                    r.revisionReason != null ? '${reasonText[r.revisionReason] ?? '운영자 판정'} · 운영자 판정(정정)' : '확정 후 수정 · 정정으로 기록'),
            ]),
          )
        : _mockHistory(m);

    return ChScaffold(
      title: '점수 장부',
      backFallback: R.home,
      children: [
        if (remote) ..._serverReviewCards(context, ref.watch(myReviewsProvider).value ?? const []),
        if (!remote && v != null && v != 'revision' && v != 'review') _verdictSection(context, v),
        if (!remote && review) _reviewSection(context),
        ChCard(
          color: c.brandSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
            Txt.cap(pastRow != null ? '${pastRow.date} · ${pastRow.provisional ? '잠정' : '확정'}${pastRow.check ? ' · 점검 기간(누적 미반영)' : ''}${pastRow.note.contains('검토 중') ? ' · 검토 중' : ''}' : '오늘 ${curChallenge.today.month}.${curChallenge.today.day} · 잠정${review ? ' · 검토 중(걸음 ${fmtInt(reviewStepsCase)} 잠정 반영)' : ''}', color: c.brand, weight: FontWeight.w600),
            Semantics(
              label: '기초대사 ${fmtInt(t.bmr)} 더하기 활동 ${fmtInt(t.activity.aD)} 빼기 섭취 ${fmtInt(iEff)} 는 순적자 ${fmtInt(t.score.dD)}, 점수 ${fmtK1(t.score.sD)}점',
              child: ExcludeSemantics(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '(${fmtInt(t.bmr)} + ${fmtInt(t.activity.aD)}) − max(${fmtInt(t.intake.iD)}, ${fmtInt(t.score.fP)}) = ${fmtInt(t.score.dD)}\n${fmtInt(t.score.dD)} ÷ ${fmtInt(engine.rules.t)} × 100 = ', style: T.num(c.fg, size: 18)),
                  TextSpan(text: '${fmtK1(t.score.sD)}점', style: T.num(c.brand, size: 22, w: FontWeight.w700)),
                ]), style: const TextStyle(height: 1.5)),
              ),
            ),
            Txt.cap('기초대사 + 활동(상한 ${fmtInt(engine.rules.c)}) − 섭취(하한 ${fmtInt(t.score.fP)}) = 순적자 · ${fmtInt(engine.rules.t)} kcal = 100점 · 최대 ${fmtInt(engine.rules.sMax)}점'),
          ], gap: 6)),
        ),
        Wrap(spacing: 6, runSpacing: 6, children: ruleChips),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                const Row(mainAxisSize: MainAxisSize.min, children: [Txt.title('일별 장부 '), Txt.cap('추정 kcal 기준')]),
                Txt.cap('누적 ${fmtK1(cumulative)}점 (확정분)'),
              ],
            ),
            const SizedBox(height: 6),
            Semantics(
              header: true,
              child: Row(children: [
                Expanded(flex: 14, child: Txt('날짜', size: 11, color: c.fg2)),
                Expanded(flex: 8, child: Txt('BMR', size: 11, color: c.fg2, align: TextAlign.right)),
                Expanded(flex: 8, child: Txt('활동 A', size: 11, color: c.fg2, align: TextAlign.right)),
                Expanded(flex: 8, child: Txt('섭취 I', size: 11, color: c.fg2, align: TextAlign.right)),
                Expanded(flex: 8, child: Txt('순적자 D', size: 11, color: c.fg2, align: TextAlign.right)),
                Expanded(flex: 12, child: Txt('점수 S', size: 11, color: c.fg2, align: TextAlign.right)),
              ]),
            ),
            if (ledger.isEmpty) const Txt.cap('아직 기록된 날이 없어요'),
            for (final r in ledger) tableRow(live(r)),
            const SizedBox(height: 6),
            const Txt.cap('첫 3일(10.6~10.8)은 점검 기간으로 누적에 들어가지 않아요. 오늘·정정된 날(10.12) 행을 누르면 그날 홈으로 이동해요.'),
          ]),
        ),
        history,
        const Disclaimer('모든 수치는 추정이에요 · 점수는 매시간 잠정 · D+1 09:00 확정 · 이후 변경은 "정정"으로 기록돼요'),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow(this.icon, this.title, this.sub);
  final IconData icon;
  final String title;
  final String sub;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: c.fg2),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Txt(title), Txt.cap(sub)])),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../services/health/health_source.dart' show newUuidV4;
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

const _avatarColors = [Color(0xFFB85C2A), Color(0xFF2F6E8F), Color(0xFF5E7A2F), Color(0xFF7A4F9A), Color(0xFF9A4F6E), Color(0xFF4F6E9A)];
Color _avatarColor(String name) => _avatarColors[name.runes.fold<int>(0, (a, r) => a + r) % _avatarColors.length];

class _Avatar extends StatelessWidget {
  const _Avatar(this.name, {this.size = 32});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: _avatarColor(name), shape: BoxShape.circle),
        child: Text(String.fromCharCode(name.runes.first), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.4)),
      );
}

/// P9 리더보드: 오늘(잠정)/누적(확정), 포디움 3, 내 행 고정, 격차(위 순위까지 점수), 반영률 칩,
/// 응원 하트(하루 1회), 익명 신고, '집계 중' 행. 비교는 격차만 보여주고 하위 순위 지목은 하지 않는다.
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  bool _today = true;

  void _heart(String name) {
    final cur = ref.read(heartedTodayProvider);
    if (cur == null) {
      ref.read(heartedTodayProvider.notifier).send(name);
      showToast(context, '응원했어요(오늘 1회)');
    } else {
      showToast(context, '내일 다시 응원할 수 있어요');
    }
  }

  void _report(LeaderRow target) {
    showChSheet<void>(context, builder: (_) => _ReportSheet(target: target.name, participantId: target.participantId));
  }

  /// 서버 모드에서 스냅샷을 아직 못 받았을 때(로딩·오류)
  Widget _loadingScaffold(BuildContext context, String meta) {
    final c = context.c;
    final err = ref.watch(leaderboardProvider).error;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          ChAppBar(title: '순위', meta: meta),
          Padding(
            padding: const EdgeInsets.all(16),
            child: ChCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 36),
              child: Column(children: spaced([
                Icon(err == null ? Icons.hourglass_top_rounded : Icons.cloud_off_rounded, color: c.fg2),
                Txt.title(err == null ? '순위를 불러오고 있어요' : '순위를 불러오지 못했어요'),
                if (err != null) Txt.cap(apiErrorText(err), align: TextAlign.center),
                if (err != null) ChButton('다시 불러오기', small: true, kind: BtnKind.quiet, onPressed: () => ref.invalidate(leaderboardProvider)),
              ], gap: 6)),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ch = curChallenge;
    final phase = ref.watch(phaseProvider);
    final hearted = ref.watch(heartedTodayProvider);
    final visible = ref.watch(rankVisibleProvider);
    final act = ref.watch(activityProvider);
    final remote = ref.read(apiProvider).isRemote;
    final loaded = watchLeaderboard(ref);
    if (loaded == null) return _loadingScaffold(context, ch.name);
    final lb = loaded;
    final today = _today;
    final list = today ? lb.today : lb.cumulative;
    final me = lb.meIn(list) ?? LeaderRow(rank: 0, name: curMe.nickname, me: true);
    // 검토 중: 서버는 내 장부의 under_review, 모의는 걸음 급증 시나리오
    final reviewMe = remote ? me.underReview : act.stepsTotal > AppConfig.stepsSpikeAbs;
    final third = lb.thirdScore;
    final weekly = weeklyFrom(watchLedger(ref) ?? const []);
    String rankText(int rank) => rank == 0 ? '—' : '$rank';

    Widget rowW(LeaderRow r, {bool pinned = false}) {
      if (r.aggregating) {
        return Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(children: [
            SizedBox(width: 32, child: Center(child: NumText(rankText(r.rank), size: 17, weight: FontWeight.w700, color: c.fg2))),
            const SizedBox(width: 10),
            Icon(Icons.hourglass_top_rounded, size: 18, color: c.review),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Txt('집계 중', weight: FontWeight.w600, color: c.review),
                Txt('점수는 잠시 뒤 보여요', size: 11, color: c.fg2),
              ]),
            ),
            Txt('—', color: c.fg2),
          ]),
        );
      }
      final mine = r.me;
      final isHearted = hearted == r.name;
      final locked = hearted != null && !isHearted;
      final fillPct = r.fill * 25;
      final cells = [for (var i = 0; i < 4; i++) i < r.fill];
      final semantics = '${r.rank == 0 ? '순위 제외' : '${r.rank}위'}${r.tie ? '(공동)' : ''} ${r.name}${mine ? '(나)' : ''} ${r.score == null ? '' : '${fmtK1(r.score!)}점'} 반영률 $fillPct%';
      return Semantics(
        label: semantics,
        button: mine,
        container: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: mine ? () => context.push(R.ledger) : null,
          onLongPress: mine ? null : () => _report(r),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: mine ? c.brandSoft : null, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              if (mine) Container(width: 3, height: 40, margin: const EdgeInsets.only(right: 7), decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(2))),
              SizedBox(
                width: 32,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  NumText(rankText(r.rank), size: 17, weight: FontWeight.w700, color: c.fg2),
                  if (r.tie) Txt('공동', size: 11, color: c.fg2),
                ]),
              ),
              const SizedBox(width: 10),
              _Avatar(r.name),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Txt('${r.name}${mine ? '(나)' : ''}', weight: FontWeight.w600, maxLines: 1)),
                    if (r.watch) ...[const SizedBox(width: 6), const ChChip('워치', icon: Icons.watch_rounded)],
                    if (mine && reviewMe && today) ...[const SizedBox(width: 6), const ChChip('검토 중', tone: Tone.review, icon: Icons.policy_rounded)],
                  ]),
                  const SizedBox(height: 2),
                  Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                    Semantics(label: '반영률 ${r.fill}/4', child: ExcludeSemantics(child: Fill4(cells: cells, small: true))),
                    Txt('$fillPct%', size: 11, color: c.fg2),
                    if (mine && r.delta > 0) Semantics(label: '${r.delta}계단 상승', child: ExcludeSemantics(child: Txt('▲${r.delta}', size: 11, color: c.good))),
                    if (mine && reviewMe && today) InkWell(onTap: () => context.push('${R.ledger}?v=review'), child: Txt('소명하기', size: 11, weight: FontWeight.w600, color: c.brand)),
                  ]),
                  if (pinned && mine && r.rank != 1 && r.rank != 0)
                    Txt(
                        today || third == null || (r.score ?? 0) >= third
                            ? '위 순위까지 ${fmtK1(r.gapToPrev ?? 0)}점'
                            : '3위까지 ${fmtK1(third - (r.score ?? 0))}점',
                        size: 11,
                        weight: FontWeight.w600,
                        color: c.brand),
                ]),
              ),
              NumText(fmtK1(r.score ?? 0), size: 19, weight: FontWeight.w700),
              if (!mine)
                IconButton(
                  onPressed: () => _heart(r.name),
                  tooltip: '${r.name} 응원하기${isHearted ? ' (응원했어요)' : locked ? ' (오늘 응원을 이미 보냈어요)' : ''}',
                  icon: Icon(isHearted ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 20, color: isHearted ? c.critical : c.fg2.withValues(alpha: locked ? 0.45 : 1)),
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  padding: EdgeInsets.zero,
                ),
            ]),
          ),
        ),
      );
    }

    Widget podium(List<LeaderRow> top) {
      Widget p(LeaderRow? r, {required bool first}) {
        if (r == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
          decoration: BoxDecoration(color: first ? c.brandSoft : c.surface, borderRadius: BorderRadius.circular(12)),
          child: Semantics(
            label: '${r.rank}위 ${r.name} ${fmtK1(r.score!)}점',
            child: ExcludeSemantics(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _Avatar(r.name, size: first ? 52 : 44),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(r.rank == 1 ? Icons.workspace_premium_rounded : Icons.military_tech_rounded, size: 18, color: c.fg2),
                  NumText('${r.rank}위', size: 13, weight: FontWeight.w700, color: c.fg2),
                ]),
                Txt(r.name, size: 13, weight: FontWeight.w600, maxLines: 1),
                NumText(fmtK1(r.score!), size: 19, weight: FontWeight.w700),
              ]),
            ),
          ),
        );
      }

      LeaderRow? at(int i) => i < top.length ? top[i] : null;
      return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(flex: 100, child: p(at(1), first: false)),
        const SizedBox(width: 8),
        Expanded(flex: 115, child: p(at(0), first: true)),
        const SizedBox(width: 8),
        Expanded(flex: 100, child: p(at(2), first: false)),
      ]);
    }

    Widget centerCard(IconData icon, String title, String body, {Widget? extra}) => ChCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 36),
          child: Column(children: spaced([
            Icon(icon, color: c.fg2),
            Txt.title(title),
            Txt.cap(body, align: TextAlign.center),
            ?extra,
          ], gap: 6)),
        );

    final slivers = <Widget>[];
    void addBox(Widget w, {double bottom = 10}) => slivers.add(SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(bottom: bottom), child: w)));

    final showSeg = phase == ChallengePhase.active;
    if (showSeg) addBox(ChSeg<bool>(label: '기간', items: const [(true, '오늘 (잠정)'), (false, '누적')], value: today, onChanged: (v) => setState(() => _today = v)));

    switch (phase) {
      case ChallengePhase.recruiting:
        addBox(centerCard(Icons.event_rounded, '10월 6일에 시작해요', '첫 3일(점검 기간) 점수는 누적에 들어가지 않아요.', extra: ChLink('규칙 미리 보기', onTap: () => context.go(R.rules))));
      case ChallengePhase.closing:
        addBox(Align(alignment: Alignment.centerLeft, child: const ChChip('최종 집계 중 · 운영자 확인 후 발표돼요', tone: Tone.review, icon: Icons.hourglass_top_rounded)));
        addBox(centerCard(Icons.hourglass_top_rounded, '최종 집계 중', '11.3 09:00 확정 · 미결 검토가 끝나면 발표돼요. 발표 뒤 7일 동안 이의를 남길 수 있어요.'));
      case ChallengePhase.published:
        addBox(Align(alignment: Alignment.centerLeft, child: ChChip('최종 결과 · 이의 기간 ~${ch.objectionUntil}', tone: Tone.good, icon: Icons.verified_rounded)));
        final fin = watchFinalRows(ref);
        final finMe = myFinalRow(fin);
        addBox(podium(fin.where((r) => !r.aggregating).take(3).toList()));
        if (finMe != null) slivers.add(SliverPersistentHeader(pinned: true, delegate: _PinnedRow(height: 68, color: c.bg, child: rowW(finMe, pinned: false))));
        slivers.add(SliverList(delegate: SliverChildListDelegate([for (final r in fin.skip(3)) if (!r.me) rowW(r)])));
        addBox(Center(child: Txt.cap('최종 ${ref.read(apiProvider).isRemote ? fin.where((r) => !r.aggregating).length : lb.total - 2}명 · 결과 이의는 점수 장부에서 1회')), bottom: 0);
      case ChallengePhase.active:
        if (!visible) {
          addBox(Align(alignment: Alignment.centerLeft, child: const ChChip('순위 비공개 중 · 내 행만 보여요', icon: Icons.visibility_off_rounded)));
          slivers.add(SliverPersistentHeader(pinned: true, delegate: _PinnedRow(height: 68, color: c.bg, child: rowW(me))));
          addBox(centerCard(Icons.visibility_off_rounded, '순위 비공개', '설정에서 "순위에 내 행 보이기"를 켜면 전체 순위를 볼 수 있어요.', extra: ChLink('설정으로', onTap: () => context.push(R.settings))));
          break;
        }
        addBox(Align(
          alignment: Alignment.centerLeft,
          child: today ? const ChChip('잠정 · 매시간 갱신 · 내일 09:00 확정', icon: Icons.schedule_rounded) : ChChip('확정 · ${ch.today.month}.${ch.today.day} 09:00', tone: Tone.good, icon: Icons.check_rounded),
        ));
        final others = list.where((r) => !r.me).toList();
        final top3 = others.where((r) => !r.aggregating).take(3).toList();
        final rest = list.where((r) => (r.rank > 3 || r.aggregating) && !r.me).toList();
        addBox(podium(top3));
        slivers.add(SliverPersistentHeader(pinned: true, delegate: _PinnedRow(height: 76, color: c.bg, child: rowW(me, pinned: true))));
        slivers.add(SliverList(delegate: SliverChildListDelegate([for (final r in rest) rowW(r)])));
        addBox(Center(child: Txt.cap('전체 ${lb.total}명 · 20명씩 더 보기')), bottom: 10);
        if (weekly != null) {
          addBox(ChCard(
            outline: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
              Row(children: [const Txt.title('내 기록 피드백 '), Txt.cap('점검 기간 뒤 확정 ${weekly.days}일')]),
              Txt('하루 평균 약 ${fmtK1(weekly.avg)}점 · 저녁 확정률 ${fmtPct(weekly.dinnerConfirmRate)}'),
              const Txt.cap('순위와 무관한 내 기록이에요. 저녁을 확정하는 날이 늘면 반영률이 올라가요.'),
            ], gap: 4)),
          ), bottom: 4);
        } else if (list.isEmpty || list.every((r) => r.me)) {
          addBox(centerCard(Icons.hourglass_empty_rounded, '아직 확정된 점수가 없어요', '점검 기간이 끝나고 첫 확정(다음 날 09:00) 뒤에 순위가 보여요.'));
        }
        addBox(const Disclaimer('점수는 추정 kcal 기준이에요 · 의료 조언이 아니에요'), bottom: 0);
    }

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          ChAppBar(
            title: '순위',
            meta: ch.name,
            actions: [
              if (phase == ChallengePhase.active && today && visible)
                PopupMenuButton<String>(
                  tooltip: '더보기',
                  icon: Icon(Icons.more_vert_rounded, color: c.fg),
                  onSelected: (_) {
                    final target = list.where((r) => !r.me && !r.aggregating).firstOrNull;
                    if (target != null) _report(target);
                  },
                  itemBuilder: (_) => const [PopupMenuItem(value: 'report', child: Text('익명으로 신고'))],
                ),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(ledgerProvider);
                ref.invalidate(leaderboardProvider);
                await ref.read(leaderboardProvider.future);
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), sliver: SliverMainAxisGroup(slivers: slivers))],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PinnedRow extends SliverPersistentHeaderDelegate {
  _PinnedRow({required this.height, required this.color, required this.child});
  final double height;
  final Color color;
  final Widget child;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => Container(color: color, padding: const EdgeInsets.symmetric(vertical: 4), alignment: Alignment.center, child: child);
  @override
  bool shouldRebuild(_PinnedRow old) => true;
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.target, this.participantId});
  final String target;
  final String? participantId;
  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  bool _sending = false;
  // 같은 시트에서 다시 눌러도 같은 신고(멱등)
  final _key = newUuidV4();

  int _reason = 0;
  static const _reasons = ['사진 재사용', '음식 아님', '걸음 비정상', '기타'];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
      const Txt.title('익명으로 신고'),
      const Txt.cap('신고자는 표시되지 않아요. 운영자가 확인하고 당사자에게만 결과를 알려요.'),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Txt.cap('대상', weight: FontWeight.w500),
        const SizedBox(height: 6),
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(border: Border.all(color: c.borderStrong), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [_Avatar(widget.target, size: 28), const SizedBox(width: 8), Txt('${widget.target} · 10.12 저녁', weight: FontWeight.w600)]),
        ),
      ]),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Txt.cap('사유', weight: FontWeight.w500),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < _reasons.length; i++)
            Semantics(
              inMutuallyExclusiveGroup: true,
              checked: i == _reason,
              button: true,
              label: _reasons[i],
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => setState(() => _reason = i),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(color: i == _reason ? c.brandSoft : c.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: i == _reason ? c.brand : c.border, width: i == _reason ? 2 : 1)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (i == _reason) ...[Icon(Icons.check_rounded, size: 14, color: c.brand), const SizedBox(width: 4)],
                    Txt(_reasons[i], size: 13, weight: FontWeight.w500, color: i == _reason ? c.brand : c.fg),
                  ]),
                ),
              ),
            ),
        ]),
      ]),
      Row(children: [
        Expanded(child: ChButton('취소', kind: BtnKind.quiet, onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: ChButton('신고하기', onPressed: _sending ? null : () async {
            final nav = Navigator.of(context);
            final messenger = ScaffoldMessenger.of(context);
            setState(() => _sending = true);
            try {
              // 서버: 신고자는 운영자 전용 기록에만, 대상에게는 '확인 중' 안내만 간다(05 API #19)
              await ref.read(apiProvider).report(participantId: widget.participantId, reason: _reasons[_reason], idempotencyKey: _key);
              nav.pop();
              messenger.showSnackBar(const SnackBar(content: Text('신고했어요. 운영자가 확인해요')));
            } catch (e) {
              if (mounted) setState(() => _sending = false);
              messenger.showSnackBar(SnackBar(content: Text(apiErrorText(e))));
            }
          }),
        ),
      ]),
    ], gap: 12));
  }
}

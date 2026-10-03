import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../services/api/challory_api.dart';
import '../../state/app_state.dart';
import '../../state/session.dart';
import 'common.dart';

/// 동시 참가 상한(D47)
const kMaxConcurrent = 3;

/// 홈 맨 위: 참가 중인 챌린지 카드(누르면 그 챌린지를 본다) + 이번 달 참가 + 초대코드 참가.
class ChallengeCards extends ConsumerWidget {
  const ChallengeCards({super.key});

  static String statusLine(ChallengeSession s, DateTime today) {
    final cs = s.checkStart;
    if (cs != null && today.isBefore(cs)) return '';
    if (cs != null && today.isBefore(cs.add(const Duration(days: 3)))) {
      return '점검 기간 ${today.difference(cs).inDays + 1}/3일';
    }
    final st = s.stats;
    if (st == null) return '';
    if (st.pending) return '순위 대기 · 참여 ${st.days}/${st.minDays}일';
    return '순위 점수 ${fmtK1(st.score ?? 0)}점';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final list = ref.watch(sessionsProvider).value ?? const <ChallengeSession>[];
    final current = ref.watch(sessionProvider).value;
    final open = (ref.watch(openChallengesProvider).value ?? const <OpenChallenge>[])
        .where((o) => o.myStatus == null && o.joinable)
        .firstOrNull;
    final full = list.length >= kMaxConcurrent;
    Widget card(int i, ChallengeSession s) {
      // 같은 id 가 여러 번 있으면(테스트 목록) 첫 카드만 선택 표시
      final sel = current?.challengeId == s.challengeId && i == list.indexWhere((x) => x.challengeId == s.challengeId);
      final ch = s.challenge;
      final left = ch.end.difference(ch.today).inDays;
      return SizedBox(
        key: ValueKey('challenge-card-$i'),
        width: 220,
        child: ChCard(
          outline: !sel,
          color: sel ? c.brandSoft : null,
          onTap: () => ref.read(selectedChallengeProvider.notifier).select(s.challengeId),
          semanticsLabel: '${ch.name} 보기',
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Txt(ch.name, weight: FontWeight.w600, maxLines: 1)),
              ChChip(s.monthly ? '월간' : '초대'),
            ]),
            const SizedBox(height: 2),
            Txt.cap(left >= 0 ? 'D-$left' : '종료'),
            Txt.cap(statusLine(s, ch.today), maxLines: 1),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 96,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (var i = 0; i < list.length; i++) ...[card(i, list[i]), const SizedBox(width: 8)],
          if (!full && open != null)
            SizedBox(
              width: 200,
              child: ChCard(
                dashed: true,
                onTap: () => showJoinSheet(context, monthly: open),
                semanticsLabel: '이번 달 챌린지 참가하기',
                child: const Center(child: Txt('이번 달 챌린지 참가하기', weight: FontWeight.w600)),
              ),
            ),
        ]),
      ),
      if (full) const Padding(padding: EdgeInsets.only(top: 4), child: Txt.cap('동시에 3개까지 참가할 수 있어요')),
      if (list.length >= 2) Padding(padding: const EdgeInsets.only(top: 4), child: Txt.cap('기록은 참가 중인 ${list.length}개 챌린지에 함께 반영돼요')),
      if (!full) Align(alignment: Alignment.centerLeft, child: ChLink('초대코드로 참가', onTap: () => _showCodeSheet(context))),
    ]);
  }
}

/// 두 번째 이후 참가: 체중만 확인하고 참가(프로필·동의는 첫 참가 때 받은 것을 쓴다)
Future<void> showJoinSheet(BuildContext context, {OpenChallenge? monthly, InviteSummary? invite, String? code}) =>
    showChSheet<void>(context, builder: (_) => _JoinSheet(monthly: monthly, invite: invite, code: code));

class _JoinSheet extends ConsumerStatefulWidget {
  const _JoinSheet({this.monthly, this.invite, this.code});
  final OpenChallenge? monthly;
  final InviteSummary? invite;
  final String? code;
  @override
  ConsumerState<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends ConsumerState<_JoinSheet> {
  late final _w = TextEditingController(text: fmtFixed(curMe.weightKg, 1));
  String? _err;
  bool _busy = false;

  String get _name => widget.monthly?.name ?? widget.invite?.name ?? '';

  @override
  void dispose() {
    _w.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final kg = double.tryParse(_w.text.trim());
    if (kg == null || kg < 25 || kg > 300) {
      setState(() => _err = '체중을 다시 확인해 주세요');
      return;
    }
    setState(() => _busy = true);
    final me = curMe;
    final err = await ref.read(challengesActionsProvider).join(JoinRequest(
        challengeId: widget.monthly?.challengeId,
        code: widget.monthly == null ? widget.code : null,
        nickname: me.nickname,
        sex: me.sex,
        birthYear: me.birthYear,
        heightCm: me.heightCm,
        weightKg: kg,
        terms: true,
        sensitiveHealth: true,
        overseasAi: ref.read(aiConsentProvider)));
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _err = err;
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('$_name에 참가했어요'), duration: const Duration(milliseconds: 2200)));
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Txt.title('$_name 참가'),
        const SizedBox(height: 8),
        const Txt('참가하는 날부터 3일은 점검 기간이에요. 체중을 확인해 주세요'),
        const SizedBox(height: 12),
        ChInput(controller: _w, label: '체중', unit: 'kg', maxLength: 5),
        if (_err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Txt.cap(_err!, color: context.c.critical)),
        const SizedBox(height: 12),
        ChButton('참가하기', onPressed: _busy ? null : _join),
      ]);
}

Future<void> _showCodeSheet(BuildContext context) => showChSheet<void>(context, builder: (_) => const _CodeSheet());

class _CodeSheet extends ConsumerStatefulWidget {
  const _CodeSheet();
  @override
  ConsumerState<_CodeSheet> createState() => _CodeSheetState();
}

class _CodeSheetState extends ConsumerState<_CodeSheet> {
  final _code = TextEditingController();
  String? _err;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final nav = Navigator.of(context);
    final host = nav.context;
    final code = _code.text.trim().toUpperCase();
    if (_busy) return;
    if (code.length != 6) return setState(() => _err = '코드를 다시 확인해 주세요');
    setState(() => _busy = true);
    final InviteSummary? inv;
    try {
      inv = await ref.read(apiProvider).getInvite(code);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    if (!mounted) return;
    if (inv == null) return setState(() { _busy = false; _err = '코드를 다시 확인해 주세요'; });
    if (!inv.joinable || inv.full) return setState(() { _busy = false; _err = '참가가 마감된 챌린지예요'; });
    nav.pop();
    if (!host.mounted) return;
    await showJoinSheet(host, invite: inv, code: code);
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Txt.title('초대코드로 참가'),
        const SizedBox(height: 12),
        ChInput(controller: _code, label: '초대코드 6자리', numeric: false, maxLength: 6),
        if (_err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Txt.cap(_err!, color: context.c.critical)),
        const SizedBox(height: 12),
        ChButton('확인', onPressed: _check),
      ]);
}

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

/// 상한에 세는 상태(서버 join_challenge 와 같음). 마감·발표된 챌린지는 세지 않는다.
const kActiveStatuses = {'recruiting', 'checking', 'running'};

/// 홈: 참가 중인 챌린지가 여럿이면 맨 위에 카드(누르면 그 챌린지를 본다) + 이번 달 참가 + 초대코드 참가.
/// 하나뿐이면 카드 없이(남은 날은 앱바에) 날짜 아래 작은 링크만: 이번 달 참가 · 초대코드로 참가.
class ChallengeCards extends ConsumerWidget {
  const ChallengeCards({super.key});

  /// 남은 날: 'N일 남음' · '오늘 마지막 날' · '종료'
  static String leftText(ChallengeInfo ch) {
    final left = ch.end.difference(ch.today).inDays;
    return left > 0 ? '$left일 남음' : (left == 0 ? '오늘 마지막 날' : '종료');
  }

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
    final full = list.where((s) => kActiveStatuses.contains(s.status)).length >= kMaxConcurrent;
    if (list.length <= 1) {
      // 카드 없이 링크만(오른쪽 정렬, 날짜 줄 아래)
      return Wrap(alignment: WrapAlignment.end, spacing: 12, children: [
        if (!full && open != null) ChLink('이번 달 챌린지 참가하기', onTap: () => showJoinSheet(context, monthly: open)),
        if (!full) ChLink('초대코드로 참가', onTap: () => _showCodeSheet(context)),
      ]);
    }
    Widget card(int i, ChallengeSession s) {
      // 같은 id 가 여러 번 있으면(테스트 목록) 첫 카드만 선택 표시
      final sel = current?.challengeId == s.challengeId && i == list.indexWhere((x) => x.challengeId == s.challengeId);
      final ch = s.challenge;
      // 남은 날은 'N일 남음' 하나로(앱바는 D+경과일)
      final left = leftText(ch);
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
            Txt.cap(left),
            Txt.cap(statusLine(s, ch.today), maxLines: 1),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 24 + MediaQuery.textScalerOf(context).scale(72), // 글자를 키우면 카드 줄도 높인다
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

/// 두 번째 이후 참가: 체중과 안전 체크 2문항을 확인하고 참가(프로필·필수 동의는 첫 참가 때 받은 것을 쓴다).
/// 국외 AI 동의는 여기서 보내지 않는다(false): 서버에 있는 기존 동의 행이 그대로 쓰인다.
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
  bool _pregnant = false;
  bool _eatingDisorder = false;

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
        pregnancy: _pregnant,
        eatingDisorder: _eatingDisorder,
        terms: true,
        sensitiveHealth: true,
        overseasAi: false)); // 동의를 새로 넣지 않는다: 기존 동의 행이 있으면 서버가 그대로 쓴다
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
  Widget build(BuildContext context) {
    final c = context.c;
    // P2 와 같은 안전 체크 2문항(체크하면 기록 모드)
    Widget safety(String text, String label, bool value, ValueChanged<bool> onChanged) => Row(children: [
          ChCheck(value: value, onChanged: _busy ? null : (v) => setState(() => onChanged(v)), label: label),
          const SizedBox(width: 4),
          Expanded(child: Txt(text)),
        ]);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Txt.title('$_name 참가'),
      const SizedBox(height: 8),
      const Txt('참가하는 날부터 3일은 점검 기간이에요. 체중을 확인해 주세요'),
      const SizedBox(height: 12),
      ChInput(controller: _w, label: '체중', unit: 'kg', maxLength: 5),
      const SizedBox(height: 12),
      const Txt.title('안전 체크 2문항'),
      safety('현재 임신 또는 수유 중이에요', '임신 또는 수유 중', _pregnant, (v) => _pregnant = v),
      safety('섭식장애 진단·치료 경험이 있어요', '섭식장애 진단·치료 경험', _eatingDisorder, (v) => _eatingDisorder = v),
      if (_pregnant || _eatingDisorder)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: InfoBanner(
            tone: Tone.review,
            icon: Icons.visibility_off_rounded,
            child: boldThen(context, '기록 모드로 참가해요.', ' 점수는 보이고 순위에는 들어가지 않아요. 이유는 아무에게도 보이지 않아요.', color: c.review),
          ),
        ),
      if (_err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Txt.cap(_err!, color: c.critical)),
      const SizedBox(height: 12),
      ChButton('참가하기', onPressed: _busy ? null : _join),
    ]);
  }
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
      // 버튼 핸들러라 다시 던지지 않는다: 안내하고 다시 누를 수 있게
      if (mounted) setState(() { _busy = false; _err = '연결이 불안정해요. 잠시 뒤 다시 입력해 주세요'; });
      return;
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

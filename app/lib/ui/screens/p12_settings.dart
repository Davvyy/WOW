import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../services/api/challory_api.dart' show MySettings, SettingKey;
import '../../state/app_state.dart';
import '../../state/app_version.dart';
import '../../services/push/push_service.dart' show PushPermission;
import '../../state/push_controller.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

/// P12 설정: 프로필(잠금) · 연결 진단 · 알림 · 공지 · 공개 · 동의/데이터 · 계정.
/// 알림·공개·AI 동의 토글은 서버에 저장한다(D75). 체중 기록(참고용)은 저장 기능이 없어 숨겼다(D76).
/// variant(검수용): disconnected | push-off | notices | delete
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.variant});
  final String? variant;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late bool _osNotifOff = widget.variant == 'push-off';
  late final bool _connected = widget.variant != 'disconnected';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 실제 OS 알림 권한: 허용 전(거부·아직 안 물어봄 — 재설치 직후 등)이면 상단 배너(06 P12).
      // 푸시를 쓸 수 없는 기기(platform 없음)는 제외. 검수용 variant 는 그대로 둔다.
      if (widget.variant == null) {
        final push = ref.read(pushServiceProvider);
        if (push.platform != null) {
          final p = await push.permission();
          if (mounted && p != PushPermission.granted) setState(() => _osNotifOff = true);
        }
      }
      if (!mounted) return;
      switch (widget.variant) {
        case 'notices':
          _openNotices();
        case 'delete':
          _openDelete();
      }
    });
  }

  /// 토글 저장(서버). 저장하지 못하면 화면 값은 되돌아가고 안내한다.
  Future<void> _set(SettingKey key, bool value) async {
    final err = await ref.read(mySettingsProvider.notifier).change(key, value);
    if (err != null && mounted) showToast(context, err);
  }

  /// AI 사진 분석 동의 철회·재동의: 확인 창을 거친 뒤 서버에 저장(#5)
  Future<void> _toggleAiConsent(bool consent) async {
    final revoke = consent;
    final go = await showChDialog<bool>(
      context,
      title: revoke ? 'AI 사진 분석 동의를 철회할까요?' : 'AI 사진 분석에 다시 동의할까요?',
      body: Txt.cap(revoke
          ? '철회하면 음식 사진을 국외 AI 서버로 보내지 않아요. 촬영한 뒤 음식 이름을 검색해서 확정해요. 아직 분석 전인 사진도 검색으로 확정해요.'
          : '동의하면 음식 사진이 국외 AI 서버로 전송돼 음식과 양을 찾아 줘요. 언제든 다시 철회할 수 있어요.'),
      actions: [
        Builder(builder: (ctx) => ChButton('취소', kind: BtnKind.quiet, onPressed: () => Navigator.of(ctx).pop(false))),
        Builder(builder: (ctx) => ChButton(revoke ? '철회' : '동의', kind: revoke ? BtnKind.critical : BtnKind.primary, onPressed: () => Navigator.of(ctx).pop(true))),
      ],
    );
    if (go != true || !mounted) return;
    final err = await ref.read(mySettingsProvider.notifier).change(SettingKey.aiConsent, !consent);
    if (!mounted) return;
    showToast(context, err ?? (revoke ? '동의를 철회했어요. 촬영 후 검색으로 확정해요' : '다시 동의했어요'));
  }

  /// 공지 보관함(N-03, 서버 notifications). 열 때 보이는 공지를 모두 읽음 처리한다.
  void _openNotices() {
    final list = ref.read(noticesProvider).value ?? const <Notice>[];
    final unreadIds = {for (final n in list) if (!n.read) n.id}; // 이번에 새로 본 공지 표시용
    ref.read(noticesProvider.notifier).markAllRead();
    showChSheet<void>(context, builder: (ctx) => _NoticeList(notices: list, fresh: unreadIds));
  }

  /// 배너 "알림 켜기": 권한 창을 다시 띄울 수 있으면 띄우고, OS 가 막았으면 설정 앱 안내
  Future<void> _enablePush() async {
    if (widget.variant == 'push-off') return setState(() => _osNotifOff = false); // 검수용
    final p = await ref.read(pushControllerProvider).enable();
    if (!mounted) return;
    if (p == PushPermission.granted) {
      setState(() => _osNotifOff = false);
      showToast(context, '알림을 켰어요');
    } else {
      showToast(context, '설정 → 앱 → 챌로리 → 알림에서 켜 주세요');
    }
  }

  /// 로그아웃: 이 기기의 알림 등록을 지우고(다른 계정 알림이 오지 않게) 로그인을 끝낸다.
  Future<void> _logout() async {
    await ref.read(pushControllerProvider).stop();
    await ref.read(sharePhotoStoreProvider).clear(); // 공유용 사진도 이 기기에서 지움
    ref.read(serverPhotoCacheProvider).clear(); // 받아 둔 서버 사진(메모리)도
    await ref.read(authServiceProvider).signOut();
    if (mounted) context.go(R.p1);
  }

  Future<void> _openDelete() async {
    // 입력 칸 컨트롤러는 창 안의 위젯이 가진다 — 닫히는 애니메이션 동안에도 살아 있어야 해서(P7 직접 입력 창과 같은 방식)
    final ok = await showDialog<bool>(context: context, builder: (_) => const _DeleteConfirm());
    if (ok == true && mounted) {
      try {
        // 서버: 기록 즉시 삭제 · 일별 점수만 익명 보존 · 로그인 차단(05 API #22)
        await ref.read(apiProvider).deleteAccount('삭제');
        await ref.read(pushControllerProvider).stop(); // 기기 행은 서버가 지움, 저장해 둔 id 만 정리
        await ref.read(sharePhotoStoreProvider).clear();
        ref.read(serverPhotoCacheProvider).clear();
        if (!mounted) return;
        showToast(context, '계정을 삭제했어요');
        context.go(R.p1);
      } catch (e) {
        if (mounted) showToast(context, apiErrorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ch = curChallenge;
    final notices = ref.watch(noticesProvider).value ?? const <Notice>[];
    final unread = notices.where((n) => !n.read).length;
    final act = ref.watch(activityProvider);
    final settings = ref.watch(mySettingsProvider).value ?? const MySettings();
    final visible = ref.watch(rankVisibleProvider);
    final aiConsent = ref.watch(aiConsentProvider);
    final autoContinue = ref.watch(autoContinueProvider).value ?? true;

    Widget li(IconData icon, String title, {String? sub, Widget? trailing, VoidCallback? onTap, Color? titleColor}) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(icon, color: c.fg2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Txt(title, weight: FontWeight.w600, color: titleColor),
                  if (sub != null) Txt.cap(sub),
                ]),
              ),
              trailing ?? (onTap == null ? const SizedBox.shrink() : Icon(Icons.chevron_right_rounded, color: c.fg2)),
            ]),
          ),
        );
    Widget toggle(String title, String sub, bool v, ValueChanged<bool> on) => Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Txt(title, weight: FontWeight.w600), Txt.cap(sub)])),
          ChSwitch(value: v, onChanged: on, label: title),
        ]);

    return ChScaffold(
      title: '설정',
      backFallback: R.home,
      gap: 10,
      children: [
        if (_osNotifOff)
          InfoBanner(
            tone: Tone.warn,
            icon: Icons.notifications_off_rounded,
            action: ChButton('알림 켜기', small: true, kind: BtnKind.quiet, onPressed: _enablePush),
            child: boldThen(context, '알림이 꺼져 있어요', ' · 그동안 분석 결과는 홈 화면에서 알려드려요.', color: c.warn),
          ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('프로필'),
            // 닉네임 바꾸기 API 가 없어 눌리지 않는 줄로 둔다(#24)
            li(Icons.person_rounded, curMe.nickname, sub: '닉네임 · 순위에는 닉네임만 보여요'),
            li(Icons.lock_rounded, '체중 ${curMe.weightKg.round()} kg · 키 ${curMe.heightCm.round()} cm', sub: '시작 시 잠금 · 변경은 운영자 문의', trailing: const ChChip('잠금', icon: Icons.lock_rounded)),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('연결'),
            // 오늘 걸음을 아직 못 읽었으면(동기화 시각 없음) 읽은 것처럼 보이지 않게 연결 확인 줄로
            if (_connected && act.syncTime.isNotEmpty)
              li(Icons.sync_rounded, '${act.source} · ${act.syncTime} 동기화', sub: '오늘 ${fmtInt(act.stepsTotal)}걸음 ✓ · ${ch.platform}', onTap: () => context.push(R.p4Check(ok: true)))
            else
              // 마지막 동기화는 이 기기에서 실제로 읽은 시각만(없으면 '못 읽었어요'만)
              li(Icons.sync_problem_rounded, act.source.isEmpty ? '${ch.platform} · 걸음 미확인' : '${act.source} · 연결 끊김',
                  sub: act.syncTime.isEmpty ? '오늘 걸음을 못 읽었어요' : '마지막 동기화 ${act.syncTime} · 오늘 걸음을 못 읽었어요', trailing: const Row(mainAxisSize: MainAxisSize.min, children: [ChChip('연결 확인', tone: Tone.critical), Icon(Icons.chevron_right_rounded)]), onTap: () => context.push(R.p4Check(ok: false))),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('알림'),
            toggle('어제 결과', '09:30', settings.notifyYesterday, (v) => _set(SettingKey.notifyYesterday, v)),
            toggle('저녁 리마인드', '21:00 · 미확정·미동기화일 때만', settings.notifyReminder, (v) => _set(SettingKey.notifyReminder, v)),
            toggle('분석 완료', '사진 분석이 끝났을 때', settings.notifyAnalysis, (v) => _set(SettingKey.notifyAnalysis, v)),
            const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Txt.cap('공지·검토·판정·건강 안내 알림은 끌 수 없어요.')),
            li(Icons.campaign_rounded, '공지',
                sub: notices.isEmpty ? '아직 공지가 없어요' : '${notices.first.title} · ${unread == 0 ? '모두 읽음' : '읽지 않음 $unread'}',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (unread > 0) Container(width: 8, height: 8, decoration: BoxDecoration(color: c.critical, shape: BoxShape.circle)),
                  Icon(Icons.chevron_right_rounded, color: c.fg2),
                ]),
                onTap: _openNotices),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('공개'),
            toggle('순위에 내 행 보이기', '끄면 내 행만 보여요', visible, (v) => _set(SettingKey.leaderboardVisible, v)),
            // 측정 등급 배지 공개 토글은 서버가 등급(폰/워치)을 채울 때까지 숨긴다 — 켜도 보이는 게 없어서(D80). 저장 경로는 그대로 둔다.
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('챌린지'),
            toggle('다음 달 챌린지 자동 참가', '켜 두면 매달 1일에 새 월간 챌린지에 이어서 참가해요', autoContinue, (v) async {
              final err = await ref.read(autoContinueProvider.notifier).set(v);
              if (err != null && context.mounted) showToast(context, err);
            }),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('동의·데이터'),
            li(Icons.smart_toy_rounded, aiConsent ? 'AI 사진 분석 동의 철회' : 'AI 사진 분석 동의 철회됨', sub: aiConsent ? '철회하면 촬영 후 검색으로 확정해요' : '촬영 후 검색으로 확정해요 · 다시 동의하려면 눌러 주세요', onTap: () => _toggleAiConsent(aiConsent)),
            li(Icons.schedule_rounded, '사진 보관', sub: '챌린지 종료 7일 후 삭제 · 해시·확정값만 보존'),
            // 개인정보 처리방침 · 이용약관: 게시 주소가 정해지면 다시 연결한다(#24)
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('계정'),
            li(Icons.logout_rounded, '로그아웃', onTap: _logout),
            li(Icons.delete_forever_rounded, '계정 삭제', sub: '사진·건강 기록이 즉시 삭제돼요', titleColor: c.critical, onTap: _openDelete),
          ]),
        ),
        // 설치된 버전(이름 + 빌드 번호). 못 읽었으면 이름만
        Disclaimer('챌로리${switch (ref.watch(appVersionProvider)) { final v? => ' $v', _ => '' }} · 모든 수치는 추정이에요'),
      ],
    );
  }
}

/// 계정 삭제 확인 창. "삭제"를 입력해야 버튼이 켜진다. 삭제하면 true.
class _DeleteConfirm extends StatefulWidget {
  const _DeleteConfirm();

  @override
  State<_DeleteConfirm> createState() => _DeleteConfirmState();
}

class _DeleteConfirmState extends State<_DeleteConfirm> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Dialog(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
          Txt.title('계정을 삭제할까요?', color: c.critical),
          const Txt('사진·식사·걸음·체중 기록이 즉시 삭제돼요. 일별 점수는 닉네임 없이 익명으로 챌린지 종료까지만 남아요. 되돌릴 수 없어요.'),
          ChInput(label: '확인을 위해 "삭제"를 입력해 주세요', controller: _ctrl, numeric: false, hint: '삭제', onChanged: (_) => setState(() {})),
          Row(children: [
            Expanded(child: ChButton('취소', kind: BtnKind.quiet, onPressed: () => Navigator.of(context).pop(false))),
            const SizedBox(width: 8),
            Expanded(child: ChButton('계정 삭제', kind: BtnKind.critical, onPressed: _ctrl.text.trim() == '삭제' ? () => Navigator.of(context).pop(true) : null)),
          ]),
        ], gap: 12)),
      ),
    );
  }
}

class _NoticeList extends StatefulWidget {
  const _NoticeList({required this.notices, required this.fresh});
  final List<Notice> notices;
  final Set<String> fresh;
  @override
  State<_NoticeList> createState() => _NoticeListState();
}

class _NoticeListState extends State<_NoticeList> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Txt.title('공지'),
      if (widget.notices.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Txt.cap('아직 공지가 없어요')),
      for (final n in widget.notices) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.campaign_rounded, color: c.fg2),
          title: Txt(n.title, weight: FontWeight.w600),
          subtitle: Txt.cap('${fmtMd(n.at)} · ${widget.fresh.contains(n.id) ? '새 공지' : '읽음'}'),
          trailing: Icon(_open == n.id ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: c.fg2),
          onTap: () => setState(() => _open = _open == n.id ? null : n.id),
        ),
        if (_open == n.id) Padding(padding: const EdgeInsets.only(left: 40, bottom: 8), child: Txt(n.body)),
      ],
      const SizedBox(height: 8),
      ChButton('닫기', kind: BtnKind.quiet, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}

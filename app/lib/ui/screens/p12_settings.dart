import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../services/health/health_package_source.dart';
import '../../state/app_state.dart';
import '../../services/push/push_service.dart' show PushPermission;
import '../../state/push_controller.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

/// P12 설정: 프로필(잠금) · 체중 기록(참고) · 연결 진단 · 알림 · 공지 · 공개 · 동의/데이터 · 계정.
/// variant(검수용): disconnected | push-off | notices | delete | weight-read
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.variant});
  final String? variant;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _weight = TextEditingController(text: '69.4');
  String _weightBadge = '직접 입력 · 10.13';
  bool _yesterday = true;
  bool _evening = true;
  bool _analysis = true;
  bool _grade = false;
  late bool _osNotifOff = widget.variant == 'push-off';
  late final bool _connected = widget.variant != 'disconnected';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 실제 OS 알림 권한: 거부 상태면 상단 배너(06 P12). 검수용 variant 는 그대로 둔다.
      if (widget.variant == null) {
        final p = await ref.read(pushServiceProvider).permission();
        if (mounted && p == PushPermission.denied) setState(() => _osNotifOff = true);
      }
      if (!mounted) return;
      switch (widget.variant) {
        case 'notices':
          _openNotices();
        case 'delete':
          _openDelete();
        case 'weight-read':
          _readWeight();
      }
    });
  }

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  Future<void> _readWeight() async {
    final go = await showChDialog<bool>(
      context,
      title: '체중을 건강 앱에서 읽을까요?',
      body: const Txt.cap('최초 1회 체중(WeightRecord) 읽기 권한을 요청해요. 읽은 체중은 참고용으로만 저장되고 점수·BMR에는 반영되지 않아요.'),
      actions: [
        Builder(builder: (ctx) => ChButton('직접 입력', kind: BtnKind.quiet, onPressed: () => Navigator.of(ctx).pop(false))),
        Builder(builder: (ctx) => ChButton('읽기 허용', onPressed: () => Navigator.of(ctx).pop(true))),
      ],
    );
    if (go != true || !mounted) return;
    final src = ref.read(healthSourceProvider);
    double? kg = 69.4; // 모의 값
    if (src is HealthPackageSource) kg = await src.readLatestWeightKg();
    if (!mounted) return;
    if (kg == null) {
      showToast(context, '건강 앱에서 읽은 체중이 없어요. 직접 입력해 주세요');
      return;
    }
    setState(() {
      _weight.text = kg!.toStringAsFixed(1);
      _weightBadge = '건강 앱 · 10.13';
    });
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
    await ref.read(authServiceProvider).signOut();
    if (mounted) context.go(R.p1);
  }

  Future<void> _openDelete() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final c = ctx.c;
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
              ChInput(label: '확인을 위해 "삭제"를 입력해 주세요', controller: ctrl, numeric: false, hint: '삭제', onChanged: (_) => setD(() {})),
              Row(children: [
                Expanded(child: ChButton('취소', kind: BtnKind.quiet, onPressed: () => Navigator.of(ctx).pop(false))),
                const SizedBox(width: 8),
                Expanded(child: ChButton('계정 삭제', kind: BtnKind.critical, onPressed: ctrl.text.trim() == '삭제' ? () => Navigator.of(ctx).pop(true) : null)),
              ]),
            ], gap: 12)),
          ),
        );
      }),
    );
    ctrl.dispose();
    if (ok == true && mounted) {
      try {
        // 서버: 기록 즉시 삭제 · 일별 점수만 익명 보존 · 로그인 차단(05 API #22)
        await ref.read(apiProvider).deleteAccount('삭제');
        await ref.read(pushControllerProvider).stop(); // 기기 행은 서버가 지움, 저장해 둔 id 만 정리
        await ref.read(sharePhotoStoreProvider).clear();
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
            li(Icons.person_rounded, curMe.nickname, sub: '닉네임 · 순위에는 닉네임만 보여요', onTap: () {}),
            li(Icons.lock_rounded, '체중 ${curMe.weightKg.round()} kg · 키 ${curMe.heightCm.round()} cm', sub: '시작 시 잠금 · 변경은 운영자 문의', trailing: const ChChip('잠금', icon: Icons.lock_rounded)),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
            const SectionTitle('체중 기록 (참고용)'),
            Row(children: [
              Expanded(child: ChInput(controller: _weight, unit: 'kg', label: null, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() => _weightBadge = '직접 입력 · 10.13'))),
              const SizedBox(width: 8),
              ChButton('건강 앱에서 읽기', small: true, kind: BtnKind.secondary, icon: Icons.monitor_heart_rounded, onPressed: _readWeight),
            ]),
            Wrap(spacing: 6, runSpacing: 6, children: [
              ChChip(_weightBadge, icon: _weightBadge.startsWith('건강') ? Icons.monitor_heart_rounded : Icons.edit_rounded),
              Builder(builder: (_) {
                final w = double.tryParse(_weight.text);
                if (w == null) return const SizedBox.shrink();
                final d = w - curMe.weightKg;
                return ChChip('시작 ${curMe.weightKg.toStringAsFixed(1)} → ${w.toStringAsFixed(1)} (${d >= 0 ? '+' : '−'}${d.abs().toStringAsFixed(1)})', icon: Icons.trending_down_rounded);
              }),
            ]),
            const Txt.cap('점수·BMR에는 반영되지 않아요. 추세 확인용이에요.'),
          ], gap: 6)),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('연결'),
            if (_connected)
              li(Icons.sync_rounded, '${act.source} · ${act.syncTime} 동기화', sub: '오늘 ${fmtInt(act.stepsTotal)}걸음 ✓ · ${ch.platform}', onTap: () => context.push('${R.p4}?state=ok'))
            else
              li(Icons.sync_problem_rounded, '${act.source} · 연결 끊김', sub: '마지막 동기화 10.12 22:40 · 오늘 걸음을 못 읽었어요', trailing: const Row(mainAxisSize: MainAxisSize.min, children: [ChChip('연결 확인', tone: Tone.critical), Icon(Icons.chevron_right_rounded)]), onTap: () => context.push('${R.p4}?state=zero')),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('알림'),
            toggle('어제 결과', '09:30', _yesterday, (v) => setState(() => _yesterday = v)),
            toggle('저녁 리마인드', '21:00 · 미확정·미동기화일 때만', _evening, (v) => setState(() => _evening = v)),
            toggle('분석 완료', '사진 분석이 끝났을 때', _analysis, (v) => setState(() => _analysis = v)),
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
            toggle('순위에 내 행 보이기', '끄면 내 행만 보여요', visible, (v) => ref.read(rankVisibleProvider.notifier).set(v)),
            toggle('측정 등급 배지 보이기', '기본 꺼짐 · 폰/워치 표시', _grade, (v) => setState(() => _grade = v)),
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
            li(Icons.smart_toy_rounded, aiConsent ? 'AI 사진 분석 동의 철회' : 'AI 사진 분석 동의 철회됨', sub: aiConsent ? '철회하면 촬영 후 검색으로 확정해요' : '촬영 후 검색으로 확정해요 · 다시 동의하려면 눌러 주세요', onTap: () {
              ref.read(aiConsentProvider.notifier).set(!aiConsent);
              showToast(context, aiConsent ? '동의를 철회했어요. 촬영 후 검색으로 확정해요' : '다시 동의했어요');
            }),
            li(Icons.schedule_rounded, '사진 보관', sub: '챌린지 종료 7일 후 삭제 · 해시·확정값만 보존'),
            li(Icons.description_rounded, '개인정보 처리방침 · 이용약관', onTap: () {}),
          ]),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SectionTitle('계정'),
            li(Icons.logout_rounded, '로그아웃', onTap: _logout),
            li(Icons.delete_forever_rounded, '계정 삭제', sub: '사진·건강 기록이 즉시 삭제돼요', titleColor: c.critical, onTap: _openDelete),
          ]),
        ),
        const Disclaimer('챌로리 1.0 · 모든 수치는 추정이에요'),
      ],
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

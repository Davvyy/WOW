import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../router.dart';
import '../../services/api/challory_api.dart';
import '../../services/auth/auth_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

/// P1 시작·이번 달 챌린지·초대코드·로그인.
/// 기본은 "이번 달 챌린지 참가하기"(코드 없이). 초대코드가 있으면 아래 접힘 영역을 펼쳐 입력한다.
/// 6자리가 되면 서버 get_invite 로 챌린지를 확인하고(모의: K7Q2MD 유효 · FULL00 모집 마감 · BLOCK0 참가 단계에서 거절),
/// Kakao/Apple 로그인 뒤 이미 참가 중이면 홈, 아니면 P2 로 간다.
class StartScreen extends ConsumerStatefulWidget {
  const StartScreen({super.key});

  @override
  ConsumerState<StartScreen> createState() => _StartScreenState();
}

enum _CodeState { empty, checking, valid, wrong, closed, offline }

class _StartScreenState extends ConsumerState<StartScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _clipboardBanner = true;
  bool _showCode = false;
  bool _monthlyChosen = false;
  _CodeState _st = _CodeState.empty;
  InviteSummary? _invite;
  String _checked = '';
  bool _busy = false;
  StreamSubscription<bool>? _authSub;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authServiceProvider);
    // 브라우저 OAuth 에서 돌아오면(딥링크) 로그인 이후 단계로
    _authSub = auth.changes.listen((signedIn) {
      if (signedIn && mounted && _busy) _afterLogin();
    });
    // 재실행: 이미 로그인 + 참가 중이면 바로 홈
    if (auth.isSignedIn && ref.read(apiProvider).isRemote) {
      Future.microtask(() async {
        if (await ref.read(apiProvider).hasParticipation() && mounted) context.go(R.home);
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _code => _ctrl.text;

  _CodeState get _state => _code.length < 6 ? _CodeState.empty : (_checked == _code ? _st : _CodeState.checking);

  Future<void> _lookup() async {
    final code = _code;
    if (code.length < 6 || code == _checked) {
      setState(() {});
      return;
    }
    setState(() => _st = _CodeState.checking);
    try {
      final inv = await ref.read(apiProvider).getInvite(code);
      if (!mounted || code != _code) return;
      setState(() {
        _checked = code;
        _invite = inv;
        _monthlyChosen = false;
        _st = inv == null ? _CodeState.wrong : (!inv.joinable || inv.full ? _CodeState.closed : _CodeState.valid);
      });
      ref.read(onboardingProvider.notifier).setInvite(code, inv);
    } catch (_) {
      if (mounted) {
        setState(() {
          _checked = code;
          _st = _CodeState.offline;
        });
      }
    }
  }

  Future<void> _login(Future<AuthOutcome> Function(AuthService) how) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final out = await how(ref.read(authServiceProvider));
      if (!mounted) return;
      if (out == AuthOutcome.signedIn) {
        await _afterLogin();
      } else if (out == AuthOutcome.cancelled) {
        setState(() => _busy = false);
      } // redirected: 딥링크 복귀 때 _authSub 가 이어서 처리
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.message);
    }
  }

  Future<void> _afterLogin() async {
    final api = ref.read(apiProvider);
    var participating = false;
    try {
      participating = await api.hasParticipation();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    if (participating) {
      context.go(R.home);
      return;
    }
    final draft = ref.read(onboardingProvider);
    if (draft.nickname.isEmpty) {
      final name = ref.read(authServiceProvider).displayName;
      if (name != null) ref.read(onboardingProvider.notifier).setNickname(name);
    }
    context.go(R.p2);
  }

  /// 코드 없이 이번 달 챌린지로: 입력해 둔 코드는 비우고 로그인 단계로
  void _chooseMonthly() {
    ref.read(onboardingProvider.notifier).chooseMonthly();
    setState(() {
      _monthlyChosen = true;
      _showCode = false;
      _ctrl.clear();
      _checked = '';
      _invite = null;
      _st = _CodeState.empty;
    });
  }

  void _paste() {
    setState(() {
      _ctrl.text = curChallenge.code;
      _clipboardBanner = false;
    });
    _lookup();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = _state;
    final err = switch (st) {
      _CodeState.wrong => '코드를 다시 확인해 주세요',
      _CodeState.closed => '참가가 마감된 챌린지예요',
      _CodeState.offline => '연결이 불안정해요. 잠시 뒤 다시 입력해 주세요',
      _ => null,
    };
    final inv = _invite;
    final valid = st == _CodeState.valid && inv != null;
    final canLogin = valid || _monthlyChosen;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              // 앱 아이콘과 같은 마크(C 링 + 불꽃). 원본은 108dp 캔버스 중 72dp 가 보이는 영역이라 1.5배로 그리고 잘라 쓴다.
              child: Container(
                width: 64,
                height: 64,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(20)),
                child: OverflowBox(
                  maxWidth: 96,
                  maxHeight: 96,
                  child: Image.asset('assets/icon/app_icon_monochrome.png', width: 96, height: 96, color: c.onBrand),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(child: Txt('챌로리', size: 30, weight: FontWeight.w700, color: c.fg)),
            const SizedBox(height: 4),
            Center(child: Txt('찍고, 걷고, 순위를 확인해요', color: c.fg2)),
            const SizedBox(height: 24),
            ChButton('이번 달 챌린지 참가하기', onPressed: _chooseMonthly),
            const SizedBox(height: 4),
            Center(child: ChLink('초대코드가 있어요', onTap: () => setState(() => _showCode = true))),
            const SizedBox(height: 16),
            if (_showCode) ...[
              if (_clipboardBanner && _code.isEmpty) ...[
                InfoBanner(
                  tone: Tone.brand,
                  icon: Icons.content_paste_rounded,
                  action: ChButton('붙여넣기', small: true, kind: BtnKind.quiet, onPressed: _paste),
                  onClose: () => setState(() => _clipboardBanner = false),
                  child: boldThen(context, '복사한 초대코드 ${curChallenge.code}를 붙여넣을까요?', '', color: c.brand),
                ),
                const SizedBox(height: 12),
              ],
              Txt('초대코드를 입력해 주세요', size: 13, weight: FontWeight.w500, color: c.fg2),
              const SizedBox(height: 6),
              Semantics(
                container: true,
                label: '초대코드 6자리',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _focus.requestFocus(),
                  child: Stack(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      for (var i = 0; i < 6; i++)
                        Container(
                          width: 48,
                          height: 55,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.bg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: err != null ? c.critical : (i == _code.length && _focus.hasFocus ? c.brand : c.borderStrong),
                              width: i == _code.length ? 2 : 1,
                            ),
                          ),
                          child: Text(i < _code.length ? _code[i] : '', style: T.num(c.fg, size: 24, w: FontWeight.w700)),
                        ),
                    ]),
                    // 실제 입력은 보이지 않는 TextField가 받는다(대문자 변환·붙여넣기 지원).
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.0,
                        child: TextField(
                          controller: _ctrl,
                          focusNode: _focus,
                          autofocus: false,
                          maxLength: 6,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                            TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
                          ],
                          onChanged: (_) => _lookup(),
                          decoration: const InputDecoration(counterText: ''),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                child: Txt.cap(err ?? '초대코드 6자리 · 카카오톡 링크로 들어오면 자동으로 채워져요', color: err != null ? c.critical : null),
              ),
              const SizedBox(height: 16),
              if (valid)
                ChCard(
                  color: c.brandSoft,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced([
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Txt.cap('초대받은 챌린지', color: c.brand),
                          Txt.title(inv.name),
                        ]),
                      ),
                      Icon(Icons.check_circle_rounded, color: c.brand),
                    ]),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      ChChip('${fmtMd(inv.startDate)} ~ ${fmtMd(inv.endDate)} · ${inv.days}일', icon: Icons.calendar_month_rounded),
                      ChChip(inv.capacity == null ? '${inv.joined}명 참가' : '${inv.joined}/${inv.capacity}명 참가', icon: Icons.group_rounded),
                    ]),
                    ChLink('규칙 미리 보기', onTap: () => context.go(R.rules)),
                  ], gap: 10)),
                )
              else if (st == _CodeState.checking)
                ChCard(outline: true, child: Center(child: Txt.cap('챌린지를 확인하고 있어요')))
              else
                ChCard(outline: true, child: Center(child: Txt.cap('코드를 입력하면 챌린지 정보가 여기에 보여요'))),
            ],
            const SizedBox(height: 32),
            ChButton('카카오로 계속하기', kind: BtnKind.kakao, icon: Icons.chat_bubble_rounded,
                onPressed: canLogin && !_busy ? () => _login((a) => a.signInWithKakao()) : null),
            const SizedBox(height: 8),
            ChButton('Apple로 계속하기', kind: BtnKind.apple, icon: Icons.apple_rounded,
                onPressed: canLogin && !_busy ? () => _login((a) => a.signInWithApple()) : null),
            const SizedBox(height: 12),
            Center(child: Txt.cap('계속하면 이용약관과 개인정보 처리방침을 확인한 것으로 봐요', align: TextAlign.center)),
            if (kDebugMode || const bool.fromEnvironment('SCREEN_LIST')) ...[
              const SizedBox(height: 8),
              Center(child: ChLink('화면 목록 (검수용)', onTap: () => context.push(R.debug))),
            ],
          ]),
        ),
      ),
    );
  }
}

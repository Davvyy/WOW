import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/mock/mock_data.dart';
import '../../router.dart';
import '../widgets/common.dart';

/// P1 시작·초대코드·로그인.
/// 모의 코드: K7Q2MD 유효 · FULL00 모집 마감 · BLOCK0 참가 불가(사유 미노출) · 그 외 오류.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

enum _CodeState { empty, valid, wrong, closed, blocked }

class _StartScreenState extends State<StartScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _clipboardBanner = true;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _code => _ctrl.text;

  _CodeState get _state {
    if (_code.length < 6) return _CodeState.empty;
    return switch (_code) {
      'K7Q2MD' => _CodeState.valid,
      'FULL00' => _CodeState.closed,
      'BLOCK0' => _CodeState.blocked,
      _ => _CodeState.wrong,
    };
  }

  void _paste() {
    setState(() {
      _ctrl.text = mockChallenge.code;
      _clipboardBanner = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = _state;
    final err = switch (st) {
      _CodeState.wrong => '코드를 다시 확인해 주세요',
      _CodeState.closed => '모집이 마감된 챌린지예요',
      _CodeState.blocked => '참가할 수 없는 코드예요',
      _ => null,
    };
    final ch = mockChallenge;
    final valid = st == _CodeState.valid;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(20)),
                child: Icon(Icons.local_fire_department_rounded, color: c.onBrand, size: 32),
              ),
            ),
            const SizedBox(height: 8),
            Center(child: Txt('챌로리', size: 30, weight: FontWeight.w700, color: c.fg)),
            const SizedBox(height: 4),
            Center(child: Txt('찍고, 걷고, 순위를 확인해요', color: c.fg2)),
            const SizedBox(height: 24),
            if (_clipboardBanner && _code.isEmpty) ...[
              InfoBanner(
                tone: Tone.brand,
                icon: Icons.content_paste_rounded,
                action: ChButton('붙여넣기', small: true, kind: BtnKind.quiet, onPressed: _paste),
                onClose: () => setState(() => _clipboardBanner = false),
                child: boldThen(context, '복사한 초대코드 ${ch.code}를 붙여넣을까요?', '', color: c.brand),
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
                        onChanged: (_) => setState(() {}),
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
                        Txt.title(ch.name),
                      ]),
                    ),
                    Icon(Icons.check_circle_rounded, color: c.brand),
                  ]),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    const ChChip('10.6 ~ 11.2 · 28일', icon: Icons.calendar_month_rounded),
                    ChChip('${ch.joined}/${ch.capacity}명 참가', icon: Icons.group_rounded),
                  ]),
                  ChLink('규칙 미리 보기', onTap: () => context.go(R.rules)),
                ], gap: 10)),
              )
            else
              ChCard(outline: true, child: Center(child: Txt.cap('코드를 입력하면 챌린지 정보가 여기에 보여요'))),
            const SizedBox(height: 32),
            ChButton('카카오로 계속하기', kind: BtnKind.kakao, icon: Icons.chat_bubble_rounded, onPressed: valid ? () => context.go(R.p2) : null),
            const SizedBox(height: 8),
            ChButton('Apple로 계속하기', kind: BtnKind.apple, icon: Icons.apple_rounded, onPressed: valid ? () => context.go(R.p2) : null),
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

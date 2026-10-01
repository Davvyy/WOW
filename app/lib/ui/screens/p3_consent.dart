import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../router.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// P3 동의(3분리): 건강 정보(필수, P2에서 완료) / 이용약관(필수) / 국외 AI 분석(선택).
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _terms = false;
  bool _ai = false;
  bool _busy = false;

  /// 참가 신청(05 API #3 join_challenge): 자격·기록 모드·BMR 잠금은 서버가 판정
  Future<void> _submit() async {
    setState(() => _busy = true);
    ref.read(aiConsentProvider.notifier).set(_ai);
    final err = await ref.read(onboardingProvider.notifier).join(terms: _terms, overseasAi: _ai);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      showToast(context, err);
      return;
    }
    context.go(R.p4);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget card({required Widget lead, required String title, required String optional, required String sub, Widget? extra}) => ChCard(
          outline: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            lead,
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: title, style: T.body(c, w: FontWeight.w600)),
                    TextSpan(text: ' $optional', style: T.body(c, color: c.fg2)),
                  ])),
                  const SizedBox(height: 2),
                  Txt.cap(sub),
                  if (extra != null) ...[const SizedBox(height: 6), extra],
                ]),
              ),
            ),
            Padding(padding: const EdgeInsets.only(top: 10), child: Icon(Icons.expand_more_rounded, color: c.fg2)),
          ]),
        );

    return ChScaffold(
      title: '동의',
      backFallback: R.p2,
      progress: 2,
      cta: Column(mainAxisSize: MainAxisSize.min, children: [
        if (!_terms) Padding(padding: const EdgeInsets.only(bottom: 6), child: Txt.cap('필수 항목에 동의해 주세요')),
        ChButton(_busy ? '참가 신청 중' : '동의하고 계속', onPressed: _terms && !_busy ? _submit : null),
      ]),
      children: [
        Txt('세 가지만 확인해 주세요', size: 24, weight: FontWeight.w700, color: c.fg, height: 1.33),
        card(
          lead: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Semantics(
                label: '동의 완료',
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(color: c.good, borderRadius: BorderRadius.circular(6)),
                  child: Icon(Icons.check_rounded, size: 18, color: c.bg),
                ),
              ),
            ),
          ),
          title: '건강 정보 수집·이용',
          optional: '(필수)',
          sub: '앞 화면에서 동의했어요 ✓ · 철회는 설정에서',
        ),
        card(
          lead: ChCheck(value: _terms, onChanged: (v) => setState(() => _terms = v), label: '이용약관 (필수)'),
          title: '이용약관',
          optional: '(필수)',
          sub: '챌린지 참가 규칙과 서비스 이용 조건',
        ),
        card(
          lead: ChCheck(value: _ai, onChanged: (v) => setState(() => _ai = v), label: '음식 사진 AI 분석 (선택)'),
          title: '음식 사진 AI 분석',
          optional: '(선택)',
          sub: '사진이 국외 AI 서버로 전송돼요. 동의하지 않아도 검색으로 기록할 수 있고 불이익은 없어요.',
          extra: _ai ? null : const Align(alignment: Alignment.centerLeft, child: ChChip('미동의 시 촬영 후 검색으로 확정', icon: Icons.search_rounded)),
        ),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: spaced(const [
            InlineNote(Icons.schedule_rounded, '사진은 챌린지 종료 7일 후 삭제돼요.'),
            InlineNote(Icons.info_rounded, '모든 칼로리는 추정치이며 의료 조언이 아니에요.'),
            InlineNote(Icons.visibility_off_rounded, '사진과 건강 기록은 다른 참가자에게 보이지 않아요. 순위에는 닉네임과 점수만 보여요.'),
          ], gap: 6)),
        ),
      ],
    );
  }
}

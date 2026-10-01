import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

/// 검수용 화면 목록(디버그 빌드 또는 --dart-define=SCREEN_LIST=true).
/// P1~P12로 바로 이동하고, 모의 상태(끼니·활동·생명주기)를 바꿔 변형을 확인한다.
class DebugScreenList extends ConsumerWidget {
  const DebugScreenList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    Widget link(String id, String name, String path) => ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(width: 36, child: NumText(id, size: 14, color: c.fg2)),
          title: Txt(name),
          subtitle: Txt.cap(path),
          trailing: Icon(Icons.chevron_right_rounded, color: c.fg2),
          onTap: () => context.push(path),
        );
    Widget scenario(String label, VoidCallback f) => ChButton(label, small: true, kind: BtnKind.quiet, onPressed: () {
          f();
          showToast(context, '적용: $label');
        });
    final meals = ref.read(mealsProvider.notifier);
    final act = ref.read(activityProvider.notifier);
    final phase = ref.read(phaseProvider.notifier);
    return ChScaffold(
      title: '화면 목록',
      backFallback: R.p1,
      children: [
        const SectionTitle('화면'),
        link('P1', '시작·초대코드·로그인', R.p1),
        link('P2', '프로필·안전 체크', R.p2),
        link('P3', '동의', R.p3),
        link('P4', '건강 데이터 연결', R.p4),
        link('P4', '… 걸음 0', '${R.p4}?state=zero'),
        link('P4', '… 거부 2회', '${R.p4}?state=denied'),
        link('P5', '홈(오늘)', R.home),
        link('P6', '식사 촬영', R.camera),
        link('P7', '식사 확인·편집(점심)', R.meal(MealSlot.lunch)),
        link('P7', '… 검색 전용', R.meal(MealSlot.snack, search: true)),
        link('P8', '활동 상세', R.activity),
        link('P9', '리더보드', R.rank),
        link('P10', '점수 장부', R.ledger),
        link('P10', '… 검토 중 + 소명', '${R.ledger}?v=review'),
        link('P10', '… 판정: 무효', '${R.ledger}?v=verdict-void'),
        link('P10', '… 판정: 경고', '${R.ledger}?v=verdict-warn'),
        link('P10', '… 판정: 승인', '${R.ledger}?v=verdict-approve'),
        link('P10', '… 판정: 순위 제외', '${R.ledger}?v=verdict-exclude'),
        link('P10', '… 소명 기간 만료', '${R.ledger}?v=expired'),
        link('P10', '… 결과 이의', '${R.ledger}?v=objection'),
        link('P11', '챌린지 규칙', R.rules),
        link('P12', '설정', R.settings),
        link('P12', '… 연결 끊김', '${R.settings}?v=disconnected'),
        link('P12', '… OS 알림 꺼짐', '${R.settings}?v=push-off'),
        const SectionTitle('끼니 시나리오(모의 상태)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          scenario('기본(3끼 확정)', () => meals.reset(buildTodayMeals())),
          scenario('점심 AI 초안 850', () => meals.reset(buildLunchDraftMeals())),
          scenario('저녁 미기록', () {
            final m = buildTodayMeals();
            m[2] = const MealRecord(slot: MealSlot.dinner);
            meals.reset(m);
          }),
          scenario('점심 확정 대기', () {
            final m = buildTodayMeals();
            m[1] = const MealRecord(slot: MealSlot.lunch, status: MealStatus.captured, noAnalysis: true, time: '12:20');
            meals.reset(m);
          }),
          scenario('점심 자동 확정', () {
            final m = buildTodayMeals();
            m[1] = MealRecord(slot: MealSlot.lunch, status: MealStatus.auto, kcal: engine.autoConfirmValue(curMe.bmr, lunchAiTotal), aiKcal: lunchAiTotal, time: '12:20', title: '김치찌개 백반', items: lunchDraftItems());
            meals.reset(m);
          }),
          scenario('0끼', () => meals.reset([for (final s in MealSlot.values) MealRecord(slot: s)])),
        ]),
        const SectionTitle('활동 시나리오(모의 상태)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          scenario('Galaxy 9,000', () => act.set(mockTodayActivity)),
          scenario('iPhone 변형', () => act.set(mockTodayActivityIos)),
          scenario('걸음 0', () => act.set(const TodayActivity(stepsTotal: 0))),
          scenario('걸음 26,000(검토)', () => act.set(const TodayActivity(stepsTotal: reviewStepsCase))),
          scenario('수동 출처(Android)', () => act.set(const TodayActivity(stepsTotal: 9000, hasManualSource: true))),
        ]),
        const SectionTitle('챌린지 생명주기'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in ChallengePhase.values) scenario(switch (p) { ChallengePhase.recruiting => '시작 전', ChallengePhase.active => '진행 중', ChallengePhase.closing => '최종 집계 중', ChallengePhase.published => '결과 확정' }, () => phase.set(p)),
        ]),
      ],
    );
  }
}

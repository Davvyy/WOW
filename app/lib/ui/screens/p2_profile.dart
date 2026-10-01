import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../state/session.dart';

/// P2 프로필·안전 체크. 4항목(성별·생년·키·체중)으로 BMR을 즉시 계산한다(엔진 사용).
/// 입력값은 온보딩 초안(onboardingProvider)에 담아 P3 참가 신청(join_challenge)에 쓴다.
/// 서버 모드는 빈 칸(닉네임만 로그인 이름으로)에서, 모의 모드는 프로토타입 값(지수)에서 시작한다.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late bool _consent;
  late Sex _sex;
  late final TextEditingController _nick;
  late final TextEditingController _birth;
  late final TextEditingController _height;
  late final TextEditingController _weight;
  late bool _pregnant;
  late bool _eatingDisorder;

  @override
  void initState() {
    super.initState();
    final d = ref.read(onboardingProvider);
    final mock = !ref.read(apiProvider).isRemote;
    String init(num? v, num fallback) => v != null ? '${v.round()}' : (mock ? '${fallback.round()}' : '');
    _consent = d.sensitiveHealth || mock;
    _sex = d.birthYear != null ? d.sex : curMe.sex;
    _nick = TextEditingController(text: d.nickname.isNotEmpty ? d.nickname : (mock ? curMe.nickname : ''));
    _birth = TextEditingController(text: init(d.birthYear, curMe.birthYear));
    _height = TextEditingController(text: init(d.heightCm, curMe.heightCm));
    _weight = TextEditingController(text: init(d.weightKg, curMe.weightKg));
    _pregnant = d.pregnancy;
    _eatingDisorder = d.eatingDisorder;
  }

  /// 시작일(나이 기준): 초대코드로 받은 챌린지, 없으면 예시 챌린지
  DateTime get _start => ref.read(onboardingProvider).invite?.startDate ?? curChallenge.start;

  bool get _nickOk => _nick.text.trim().length >= 2 && _nick.text.trim().length <= 12;

  void _next() {
    ref.read(onboardingProvider.notifier).setProfile(
          nickname: _nick.text,
          sex: _sex,
          birthYear: _year!,
          heightCm: _h!,
          weightKg: _w!,
          pregnancy: _pregnant,
          eatingDisorder: _eatingDisorder,
          sensitiveHealth: _consent,
        );
    context.go(R.p3);
  }

  @override
  void dispose() {
    _nick.dispose();
    _birth.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  int? get _year => int.tryParse(_birth.text);
  double? get _h => double.tryParse(_height.text);
  double? get _w => double.tryParse(_weight.text);

  /// BMR 나이 = 시작 연도 − 출생 연도
  int? get _age => _year == null ? null : ChalloryEngine.ageOnDate(_year!, _start);

  /// 자격 판정은 12월 31일생으로 보수 적용
  int? get _ageCons => _year == null ? null : ChalloryEngine.ageConservative(_year!, _start);

  BmrResult? get _bmr {
    if (_age == null || _h == null || _w == null || _h! <= 0 || _w! <= 0) return null;
    return ChalloryEngine.bmr(Profile(sex: _sex, weightKg: _w!, heightCm: _h!, age: _age!));
  }

  double? get _bmi => (_h == null || _w == null || _h! <= 0) ? null : _w! / ((_h! / 100) * (_h! / 100));

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bmr = _bmr;
    final blocked = _ageCons != null && _ageCons! < 14;
    final minorRecord = _ageCons != null && _ageCons! >= 14 && _ageCons! < 19;
    final recordMode = _pregnant || _eatingDisorder || minorRecord || (_bmi != null && _bmi! < 18.5);
    final recheck = _bmi != null && (_bmi! < 15 || _bmi! > 45);
    final canNext = _consent && bmr != null && !blocked && _nickOk;
    final inputsEnabled = _consent;
    return ChScaffold(
      title: '기본 정보',
      backFallback: R.p1,
      progress: 1,
      cta: ChButton('다음', onPressed: canNext ? _next : null),
      children: [
        ChCard(
          outline: _consent,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ChCheck(value: _consent, onChanged: (v) => setState(() => _consent = v), label: '건강 정보 수집·이용 동의 (필수)'),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Txt.cap('건강 정보 수집·이용에 동의해요 (필수)', color: c.fg, weight: FontWeight.w600),
                  const SizedBox(height: 2),
                  const Txt.cap('성별·생년·키·체중·안전 체크, 걸음·운동·식사 기록. 민감정보라 따로 받아요.'),
                ]),
              ),
            ),
          ]),
        ),
        Txt('기본 정보 4가지만\n알려주세요', size: 24, weight: FontWeight.w700, color: c.fg, height: 1.33),
        ChInput(label: '닉네임 (2~12자 · 순위에 보여요)', controller: _nick, numeric: false, hint: '지수', enabled: inputsEnabled, maxLength: 12,
            onChanged: (_) => setState(() {})),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Txt.cap('성별', weight: FontWeight.w500),
          const SizedBox(height: 6),
          ChSeg<Sex>(
            label: '성별',
            items: const [(Sex.m, '남'), (Sex.f, '여')],
            value: _sex,
            onChanged: inputsEnabled ? (v) => setState(() => _sex = v) : null,
          ),
        ]),
        ChInput(label: '태어난 연도', controller: _birth, unit: '년', hint: '1996', enabled: inputsEnabled, maxLength: 4, onChanged: (_) => setState(() {})),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: ChInput(label: '키', controller: _height, unit: 'cm', hint: '170', enabled: inputsEnabled, maxLength: 5, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}))),
          const SizedBox(width: 10),
          Expanded(child: ChInput(label: '체중', controller: _weight, unit: 'kg', hint: '65', enabled: inputsEnabled, maxLength: 5, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}))),
        ]),
        Semantics(
          liveRegion: true,
          child: ChCard(
            color: c.brandSoft,
            child: bmr == null || !_consent
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Txt('기초대사량 — · 하루 목표 적자 — kcal', color: c.fg2),
                    const Txt.cap('위 항목에 동의하고 입력하면 바로 계산돼요'),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text.rich(TextSpan(children: [
                      TextSpan(text: '기초대사량 ', style: T.body(c)),
                      TextSpan(text: '약 ${fmtInt(bmr.bmr)}', style: T.num(c.fg, size: 19, w: FontWeight.w700)),
                      TextSpan(text: ' kcal · 하루 목표 적자 ', style: T.body(c)),
                      TextSpan(text: fmtInt(engine.rules.t), style: T.num(c.fg, size: 16, w: FontWeight.w700)),
                      TextSpan(text: ' kcal = ', style: T.body(c)),
                      TextSpan(text: '100', style: T.num(c.fg, size: 16, w: FontWeight.w700)),
                      TextSpan(text: '점', style: T.body(c)),
                    ])),
                    const SizedBox(height: 2),
                    Txt.cap('Mifflin-St Jeor 공식, 10 kcal 단위 반올림(${bmr.raw.toStringAsFixed(2)} → ${fmtInt(bmr.bmr)}) · 챌린지 안 모두 같은 공식이에요'),
                  ]),
          ),
        ),
        if (blocked) InfoBanner(tone: Tone.critical, icon: Icons.block_rounded, child: boldThen(context, '만 14세 이상만 참가할 수 있어요', '', color: c.critical)),
        if (minorRecord) InfoBanner(tone: Tone.review, icon: Icons.visibility_off_rounded, child: const Text('만 19세 이상만 순위에 참여해요. 만 14~18세는 기록 모드로 참가해요(점수는 보여요)')),
        if (recheck) InfoBanner(tone: Tone.warn, icon: Icons.info_rounded, child: const Text('입력값을 한 번 더 확인해 주세요')),
        ChCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Txt.title('안전 체크 2문항'),
            Row(children: [
              const Expanded(child: Txt('현재 임신 또는 수유 중이에요')),
              ChSwitch(value: _pregnant, onChanged: inputsEnabled ? (v) => setState(() => _pregnant = v) : null, label: '임신 또는 수유 중'),
            ]),
            Row(children: [
              const Expanded(child: Txt('섭식장애 진단·치료 경험이 있어요')),
              ChSwitch(value: _eatingDisorder, onChanged: inputsEnabled ? (v) => setState(() => _eatingDisorder = v) : null, label: '섭식장애 진단·치료 경험'),
            ]),
            if (recordMode && !minorRecord) ...[
              const SizedBox(height: 8),
              InfoBanner(
                tone: Tone.review,
                icon: Icons.visibility_off_rounded,
                child: boldThen(context, '기록 모드로 참가해요.', ' 점수는 보이고 순위에는 들어가지 않아요. 이유는 아무에게도 보이지 않아요.', color: c.review),
              ),
            ],
          ]),
        ),
        const InlineNote(Icons.lock_rounded, '시작 후에는 체중·키를 바꿀 수 없어요. 변경은 운영자에게 요청해 주세요. 만 19세 미만·BMI 18.5 미만은 기록 모드로 참가해요.'),
      ],
    );
  }
}

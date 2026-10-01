import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../data/models.dart';
import '../../router.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../widgets/common.dart';

/// P6 식사 촬영. 인앱 카메라(`camera`) 전용 — 갤러리 선택·파일 가져오기 경로는 없다.
/// 촬영 파일은 앱 임시 폴더에만 존재하며 분석 요청 뒤 삭제한다(기기 사진첩에 저장하지 않음).
class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key, this.initialSlot});
  final MealSlot? initialSlot;

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  CameraController? _controller;
  bool _failed = false;
  bool _busy = false;
  bool _confirmNow = false;
  bool _toast = false;
  late MealSlot _slot = widget.initialSlot ?? AppShell.slotForNow(DateTime.now());

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('no_camera', '사용 가능한 카메라가 없어요');
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final ctrl = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _controller = ctrl);
    } catch (e) {
      debugPrint('camera init failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  String _timeNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}';
  }

  Future<void> _shutter() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ctrl = _controller;
      Uint8List? photo;
      final capturedAt = DateTime.now();
      if (ctrl != null && ctrl.value.isInitialized) {
        final file = await ctrl.takePicture();
        // 원본은 메모리로만 읽고 임시 파일은 바로 지운다(사진첩 저장 없음). 리사이즈·EXIF 제거·SHA-256 은 업로드 파이프라인이 한다.
        photo = await File(file.path).readAsBytes();
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
      if (!mounted) return;
      final meals = ref.read(mealsProvider.notifier);
      final consent = ref.read(aiConsentProvider);
      if (_confirmNow && consent) {
        meals.captureNow(_slot, _timeNow());
        context.pushReplacement(R.meal(_slot));
        return;
      }
      // 업로드는 기다리지 않는다(3초 내 홈 복귀). 결과 문구는 홈에서 토스트로.
      final messenger = ScaffoldMessenger.of(context);
      unawaited(meals.capture(_slot, _timeNow(), aiConsent: consent, photo: photo, capturedAt: capturedAt).then((err) {
        if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
      }));
      final firstTime = !ref.read(notifAskedProvider);
      if (firstTime) {
        ref.read(notifAskedProvider.notifier).done();
        await _askNotification();
        if (!mounted) return;
      }
      setState(() => _toast = true);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (mounted) context.go(R.home);
    } catch (e) {
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 첫 촬영 직후 1회 프리퍼미션 카드. OS 알림 권한 요청은 푸시 연동(FCM) 단계에서 연결한다.
  Future<void> _askNotification() async {
    await showChDialog<void>(
      context,
      title: '분석이 끝나면 알려드릴게요',
      body: const Txt('사진 분석은 최대 6초 걸려요. 알림을 켜면 홈으로 돌아가 있어도 결과를 바로 확인할 수 있어요. 끄면 홈 화면에서 알려드려요.'),
      actions: [
        Builder(builder: (ctx) => ChButton('나중에', kind: BtnKind.quiet, onPressed: () {
              Navigator.of(ctx).pop();
              showToast(context, '홈 화면에서 결과를 알려드릴게요');
            })),
        Builder(builder: (ctx) => ChButton('알림 켜기', onPressed: () => Navigator.of(ctx).pop())),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0D0D0C);
    final consent = ref.watch(aiConsentProvider);
    final c = context.c;
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(children: [
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(child: CameraPreview(_controller!))
          else
            const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.16), radius: 1.0, colors: [Color(0xFF3C3A37), Color(0xFF1B1A19), bg])))),
          if (_failed)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.no_photography_rounded, color: Colors.white, size: 40),
                  const SizedBox(height: 12),
                  const Txt('카메라를 열 수 없어요 · 검색으로 기록', weight: FontWeight.w600, color: Colors.white),
                  const SizedBox(height: 6),
                  const Txt.cap('기기 설정에서 카메라 권한을 확인해 주세요. 지금은 검색으로 기록할 수 있어요.', color: Color(0xCCFFFFFF), align: TextAlign.center),
                  const SizedBox(height: 12),
                  ChButton('검색으로 기록', small: true, kind: BtnKind.quiet, onPressed: () => context.pushReplacement(R.meal(_slot, search: true))),
                ]),
              ),
            )
          else
            Align(
              alignment: const Alignment(0, -0.25),
              child: FractionallySizedBox(
                widthFactor: 0.78,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x8CFFFFFF), width: 2)),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: const Txt('접시 전체가 보이게,\n위에서 찍어 주세요', color: Color(0xE6FFFFFF), align: TextAlign.center, height: 1.4),
                  ),
                ),
              ),
            ),
          // 상단: 닫기 + 끼니 태그
          Positioned(
            top: 8,
            left: 8,
            right: 12,
            child: Row(children: [
              IconButton(onPressed: () => goBack(context), tooltip: '닫기', icon: const Icon(Icons.close_rounded, color: Colors.white), constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
              const Spacer(),
              PopupMenuButton<MealSlot>(
                tooltip: '끼니 태그 바꾸기',
                initialValue: _slot,
                onSelected: (s) => setState(() => _slot = s),
                itemBuilder: (_) => [for (final s in MealSlot.values) PopupMenuItem(value: s, child: Text(slotLabel[s]!))],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(999)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.schedule_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Txt(slotLabel[_slot]!, size: 13, weight: FontWeight.w600, color: Colors.white),
                    const SizedBox(width: 2),
                    const Icon(Icons.expand_more_rounded, size: 16, color: Colors.white),
                  ]),
                ),
              ),
              const SizedBox(width: 44),
            ]),
          ),
          if (!consent)
            Positioned(
              left: 16,
              right: 16,
              bottom: 210,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(12)),
                child: const Row(children: [
                  Icon(Icons.search_rounded, color: Colors.white),
                  SizedBox(width: 10),
                  Expanded(child: Txt('AI 분석 없이 저장돼요. 검색으로 확정해 주세요', size: 13, color: Colors.white)),
                ]),
              ),
            ),
          // 하단: 확정 시점 토글 · 셔터 · 사진 없이 기록 (갤러리 버튼 없음)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(999)),
                  child: Row(children: [
                    for (final (now, label) in [(false, '나중에 확정'), (true, '지금 확정')])
                      Expanded(
                        child: Semantics(
                          inMutuallyExclusiveGroup: true,
                          checked: _confirmNow == now,
                          button: true,
                          label: label,
                          excludeSemantics: true,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => setState(() => _confirmNow = now),
                            child: Container(
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: _confirmNow == now ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                              child: Txt(label, size: 13, weight: FontWeight.w600, color: _confirmNow == now ? const Color(0xFF111111) : const Color(0xBFFFFFFF)),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              Semantics(
                button: true,
                label: '촬영',
                child: GestureDetector(
                  onTap: _failed ? null : _shutter,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                    alignment: Alignment.center,
                    child: Container(width: 56, height: 56, decoration: BoxDecoration(color: _busy ? const Color(0xAAFFFFFF) : Colors.white, shape: BoxShape.circle)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.pushReplacement(R.meal(_slot, search: true)),
                child: const Text('사진 없이 기록', style: TextStyle(color: Color(0xD9FFFFFF), decoration: TextDecoration.underline, fontSize: 13)),
              ),
            ]),
          ),
          if (_toast)
            Positioned(
              left: 16,
              right: 16,
              bottom: 200,
              child: Material(
                color: c.fg,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    Icon(Icons.check_circle_rounded, color: c.bg),
                    const SizedBox(width: 8),
                    Expanded(child: Txt(consent ? '저장했어요. 분석이 끝나면 알려드려요' : 'AI 분석 없이 저장돼요. 검색으로 확정해 주세요', weight: FontWeight.w500, color: c.bg)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/voice/voice_recognizer.dart';

/// Microphone button for a text field (todo title, agent chat box, …).
///
/// One tap starts a recognition; while it runs the icon becomes a pulsing
/// waveform and further taps are ignored. A non-empty transcription is handed
/// to [onText]; failures and an unavailable backend surface as a [SnackBar]
/// instead of throwing, so a desktop/test environment without a microphone
/// degrades gracefully.
class VoiceInputButton extends ConsumerStatefulWidget {
  const VoiceInputButton({
    super.key,
    required this.onText,
    this.tooltip = '语音输入',
    this.iconSize = 22,
  });

  final ValueChanged<String> onText;
  final String tooltip;
  final double iconSize;

  /// Shown when the current engine cannot run on this platform/config.
  static const unavailableTooltip = '语音识别不可用（可在设置中配置云端 ASR）';
  static const unavailableMessage = '语音识别不可用，可在设置中配置云端语音 API';

  @override
  ConsumerState<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends ConsumerState<VoiceInputButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scale;

  bool _busy = false;

  /// Optimistic until the async probe answers: a tap in that window simply
  /// produces the recognizer's own error message.
  bool _available = true;

  VoiceRecognizer? _recognizer;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _scale = Tween<double>(
      begin: 0.9,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    if (_busy) {
      // Best effort: do not leave the native dialog / recorder running.
      unawaited(_recognizer?.cancel() ?? Future<void>.value());
    }
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _checkAvailability(VoiceRecognizer recognizer) async {
    var available = false;
    try {
      available = await recognizer.available;
    } on Object {
      available = false;
    }
    if (!mounted || !identical(recognizer, _recognizer)) return;
    if (available != _available) {
      setState(() => _available = available);
    }
  }

  Future<void> _onPressed() async {
    if (_busy) return;
    final VoiceRecognizer recognizer =
        _recognizer ?? ref.read(voiceRecognizerProvider);
    if (!_available) {
      _showMessage(VoiceInputButton.unavailableMessage);
      return;
    }

    setState(() => _busy = true);
    _pulse.repeat(reverse: true);
    try {
      final result = await recognizer.recognize();
      if (!mounted) return;
      final text = result.text?.trim() ?? '';
      if (text.isNotEmpty) {
        widget.onText(text);
      } else {
        final error = result.error?.trim() ?? '';
        _showMessage(error.isEmpty ? '语音识别失败，请重试' : error);
      }
    } on Object {
      if (mounted) _showMessage('语音识别失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _pulse.stop();
        _pulse.value = 0;
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final recognizer = ref.watch(voiceRecognizerProvider);
    if (!identical(recognizer, _recognizer)) {
      _recognizer = recognizer;
      // Availability probes are async, so this only calls setState after the
      // current build/frame has finished.
      _checkAvailability(recognizer);
    }

    final scheme = Theme.of(context).colorScheme;
    final tooltip = _available
        ? widget.tooltip
        : VoiceInputButton.unavailableTooltip;

    return ScaleTransition(
      scale: _scale,
      child: IconButton(
        tooltip: tooltip,
        iconSize: widget.iconSize,
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : _onPressed,
        icon: Icon(
          _busy ? Icons.graphic_eq : Icons.mic,
          color: _busy
              ? scheme.primary
              : (_available ? null : scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

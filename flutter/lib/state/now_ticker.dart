import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync_controller.dart';

/// 1 Hz "now" for the current-time line. Emits immediately, then every
/// second, and re-emits at once when the app returns to the foreground.
///
/// It reads the same [serverClockProvider] estimate as [serverNowProvider], so
/// the line and the rest of the UI agree on "now" — but it does not wait for
/// the once-a-minute stream. Android suspends timers in the background, so the
/// minute ticker can be hours behind on return; the lifecycle observer here
/// pushes a fresh instant the moment the app is resumed.
///
/// `autoDispose`: the timer only exists while its consumer (the timeline's now
/// line) is mounted, so hiding the line stops the clock.
final nowTickerProvider = StreamProvider.autoDispose<DateTime>((ref) {
  // A synced clock or a foreground return bumps this; restarting the provider
  // emits the corrected instant instead of waiting out the second.
  ref.watch(clockRevisionProvider);
  final clock = ref.watch(serverClockProvider);
  final binding = WidgetsBinding.instance;
  final controller = StreamController<DateTime>();

  void emit() {
    if (controller.isClosed) return;
    controller.add(clock.estimateNow().toUtc());
  }

  final observer = _ResumeEmitter(emit);
  final timer = Timer.periodic(const Duration(seconds: 1), (_) => emit());
  binding.addObserver(observer);
  // First value lands in the controller's buffer and is delivered as soon as
  // the line subscribes; never wait a second for the initial position.
  emit();

  ref.onDispose(() {
    timer.cancel();
    binding.removeObserver(observer);
    controller.close();
  });

  return controller.stream;
});

/// Re-emits when the app comes back to the foreground, so the line jumps to
/// the right minute on the very first frame after the resume instead of on the
/// next whole second (and, after a long sleep, instead of the next minute).
class _ResumeEmitter with WidgetsBindingObserver {
  _ResumeEmitter(this.onResumed);

  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}

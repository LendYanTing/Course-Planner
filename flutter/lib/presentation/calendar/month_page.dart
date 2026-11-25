import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/time/user_time.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../adaptive/adaptive.dart';
import 'month_view_content.dart';

// Re-exported so existing imports of this library keep working
// (`weekGutterLabel`, `groupEventsByLocalDay`, `eventMeta`).
export 'month_view_content.dart' show eventMeta, groupEventsByLocalDay, weekGutterLabel;

/// Month grid page (docs/ui-interaction.md §11). The grid itself lives in
/// [MonthViewContent], shared with the 日程 page's 「月」 mode.
class MonthPage extends ConsumerStatefulWidget {
  const MonthPage({super.key});

  @override
  ConsumerState<MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends ConsumerState<MonthPage> {
  late DateTime _month; // any instant inside the displayed month (local)

  @override
  void initState() {
    super.initState();
    _month = DateTime.now().toUtc();
  }

  /// Which way the last month change went, so the slide runs the right way.
  int _slideDir = 1;

  void _shiftMonth(int delta) {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    if (delta != 0) _slideDir = delta > 0 ? 1 : -1;
    final local = userTime.localFromUtc(_month);
    setState(() {
      _month = tz.TZDateTime(userTime.location, local.year, local.month + delta, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final userTime = ref.watch(userTimeProvider);
    if (userTime == null) {
      return Scaffold(
        appBar: AppTopBar(title: '月视图'),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final syncState = ref.watch(syncCoordinatorProvider);

    final local = userTime.localFromUtc(_month);

    return Scaffold(
      // The month grid paints its own CalendarBackground, so the scaffold must
      // not cover it with an opaque surface.
      backgroundColor:
          ref.watch(backgroundConfigProvider).hasBackground ? Colors.transparent : null,
      appBar: AppTopBar(
        // Tapping the title jumps to any date; swiping left/right steps a month.
        titleWidget: InkWell(
          onTap: () => _pickDate(userTime),
          child: Text('${local.year}年${local.month}月'),
        ),
        actions: [
          // Hidden for a local session (no server to sync with).
          if (ref.watch(cloudSyncEnabledProvider))
            IconButton(
              onPressed: syncState.syncing
                  ? null
                  : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
              icon: syncState.syncing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
        ],
      ),
      body: GestureDetector(
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 120) return;
          _shiftMonth(v < 0 ? 1 : -1);
        },
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey(_monthKey(local));
            final dx = (incoming ? _slideDir : -_slideDir).toDouble();
            return ClipRect(
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(dx, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey(_monthKey(local)),
            child: MonthViewContent(
              anchorUtc: _month,
              onShiftMonth: _shiftMonth,
              onSelectDate: (d) => setState(() => _month = d),
            ),
          ),
        ),
      ),
    );
  }

  /// Identity of the shown month so the switcher animates on a month change and
  /// stays still on unrelated rebuilds.
  String _monthKey(DateTime local) => '${local.year}-${local.month}';

  /// Jump to a specific month (the header is the entry point).
  Future<void> _pickDate(UserTime userTime) async {
    final local = userTime.localFromUtc(_month);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(local.year, local.month, 1),
      firstDate: DateTime(local.year - 5),
      lastDate: DateTime(local.year + 5),
    );
    if (picked == null || !mounted) return;
    setState(() => _month = tz.TZDateTime(userTime.location, picked.year, picked.month, 1));
  }
}

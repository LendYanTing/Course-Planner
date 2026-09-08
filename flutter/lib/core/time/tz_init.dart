import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Global IANA timezone database initialisation (offline, bundled with the
/// `timezone` package). Must run once before any [UserTime] is created.
bool _initialized = false;

void ensureTimeZonesInitialized() {
  if (!_initialized) {
    tzdata.initializeTimeZones();
    _initialized = true;
  }
}

/// Resolves an IANA name (e.g. `Asia/Shanghai`) to a tz.Location.
///
/// Returns null when the name is unknown; the caller decides whether the
/// error is fatal.
tz.Location? tryLoadLocation(String ianaName) {
  ensureTimeZonesInitialized();
  try {
    return tz.getLocation(ianaName);
  } catch (_) {
    return null;
  }
}

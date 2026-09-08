import 'package:timezone/timezone.dart' as tz;

import 'tz_init.dart';

/// The user's fixed IANA timezone (docs/datetime.md §2).
///
/// Every piece of schedule interpretation goes through this class. Device
/// system timezone is NEVER consulted (`DateTime.now().timeZoneOffset` is
/// banned for interpreting schedule data). Server time offsets (see
/// lib/sync/clock.dart) provide the current-time estimate.
class UserTime {
  UserTime._(this.ianaName, this.location);

  /// Creates a [UserTime] for a validated IANA name; null when unknown.
  static UserTime? tryCreate(String ianaName) {
    final loc = tryLoadLocation(ianaName);
    if (loc == null) return null;
    return UserTime._(ianaName, loc);
  }

  final String ianaName;
  final tz.Location location;

  /// Converts a UTC instant to a [tz.TZDateTime] whose wall-clock fields are
  /// expressed in the user's timezone. Use this before formatting for UI.
  tz.TZDateTime localFromUtc(DateTime utc) {
    return tz.TZDateTime.from(utc.toUtc(), location);
  }

  /// Builds a local wall-clock instant from its (already user-tz) components.
  tz.TZDateTime fromLocalParts(
    int year,
    int month,
    int day,
    int hour,
    int minute,
  ) {
    return tz.TZDateTime(location, year, month, day, hour, minute);
  }

  /// Parses `YYYY-MM-DD` (a local calendar date in the user tz) into the
  /// local midnight instant. Returns null on malformed input.
  tz.TZDateTime? parseLocalDate(String ymd) {
    final parts = ymd.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return fromLocalParts(y, m, d, 0, 0);
  }

  /// Formats a local date as `YYYY-MM-DD` (used for occurrenceDateLocal and
  /// `displayDate` metadata).
  String localDateString(DateTime local) =>
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';

  /// ISO weekday (1=Monday..7=Sunday) of a local calendar day.
  int isoWeekday(DateTime local) {
    final wd = local.weekday; // DateTime.weekday is already 1=Mon..7=Sun
    return wd;
  }

  /// Minute-of-day (0..1439) of a UTC instant in the user tz.
  int minuteOfDayUtc(DateTime utc) {
    final local = localFromUtc(utc);
    return local.hour * 60 + local.minute;
  }

  /// True when [start]..[end] (UTC) both fall on the same local natural day.
  bool sameLocalDay(DateTime start, DateTime end) {
    final a = localFromUtc(start);
    final b = localFromUtc(end);
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Adds [days] local calendar days to a local instant (DST-safe).
  tz.TZDateTime addLocalDays(DateTime local, int days) {
    return tz.TZDateTime(location, local.year, local.month, local.day + days,
        local.hour, local.minute, local.second);
  }

  /// The local date [days] after the local date containing [anchor].
  tz.TZDateTime localDateAfter(DateTime localAnchor, int days) {
    return tz.TZDateTime(location, localAnchor.year, localAnchor.month,
        localAnchor.day + days);
  }

  /// Iterates the local dates from [from] (inclusive) to [to] (exclusive).
  Iterable<tz.TZDateTime> localDatesBetween(DateTime from, DateTime to) sync* {
    var cur = tz.TZDateTime(
        location, from.year, from.month, from.day); // local midnight
    final end = tz.TZDateTime(location, to.year, to.month, to.day);
    while (cur.isBefore(end)) {
      yield cur;
      cur = tz.TZDateTime(location, cur.year, cur.month, cur.day + 1);
    }
  }
}

/// Small wall-clock helpers used across views. All local-time arithmetic
/// happens against the fixed user timezone (see lib/core/time/user_time.dart);
/// these helpers only shape raw minute values and UTC datetimes.
library;

/// Clamps a minute-of-day into [0, 1440).
int clampMinute(int minute) => minute.clamp(0, 1440);

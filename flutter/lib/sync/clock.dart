/// Server clock (docs/datetime.md §8).
///
/// The client keeps `estimatedServerNowUtc = deviceNowUtc + offset` where
/// `offset = serverTimeUtc - deviceTimeAtFetch`, so the "now" line never
/// depends on the device clock being correct.
class ServerClock {
  ServerClock();

  Duration? _offset;
  DateTime? _lastServerUtc;

  Duration? get offset => _offset;

  DateTime? get lastServerUtc => _lastServerUtc;

  bool get synced => _offset != null;

  /// Records a fresh /meta/time answer.
  void record(DateTime serverUtc, DateTime deviceNowUtc) {
    final server = serverUtc.toUtc();
    _lastServerUtc = server;
    _offset = server.difference(deviceNowUtc.toUtc());
  }

  /// Restores a persisted clock observation (offline app start).
  void restore(DateTime serverUtc, DateTime deviceFetchedAt) {
    final server = serverUtc.toUtc();
    _lastServerUtc = server;
    _offset = server.difference(deviceFetchedAt.toUtc());
  }

  /// Estimated server "now" as a UTC instant.
  DateTime estimateNow() {
    final now = DateTime.now().toUtc();
    final off = _offset;
    if (off == null) return now;
    return now.add(off);
  }
}

import 'dart:async';

/// Combines the latest emission of three streams into records.
/// Waits until every stream has emitted once; then emits on any change.
Stream<(A, B, C)> combineLatest3<A, B, C>(
  Stream<A> a,
  Stream<B> b,
  Stream<C> c,
) async* {
  A? lastA;
  B? lastB;
  C? lastC;
  final controller = StreamController<(A, B, C)>();

  bool doneA = false, doneB = false, doneC = false;

  void maybePush() {
    if (doneA && doneB && doneC) {
      controller.add((lastA as A, lastB as B, lastC as C));
    }
  }

  final subA = a.listen((v) {
    lastA = v;
    doneA = true;
    maybePush();
  }, onError: controller.addError, onDone: () {});

  final subB = b.listen((v) {
    lastB = v;
    doneB = true;
    maybePush();
  }, onError: controller.addError, onDone: () {});

  final subC = c.listen((v) {
    lastC = v;
    doneC = true;
    maybePush();
  }, onError: controller.addError, onDone: () {});

  await for (final value in controller.stream) {
    yield value;
  }

  await subA.cancel();
  await subB.cancel();
  await subC.cancel();
  await controller.close();
}

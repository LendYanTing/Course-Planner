import 'package:course_planner/app/router.dart';
import 'package:course_planner/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveAuthRedirect', () {
    test('unknown phase parks on the splash at /', () {
      expect(resolveAuthRedirect(phase: AuthPhase.unknown, location: '/'), isNull);
      expect(resolveAuthRedirect(phase: AuthPhase.unknown, location: '/login'), '/');
      expect(resolveAuthRedirect(phase: AuthPhase.unknown, location: '/home/week'), '/');
    });

    test('signed out goes to login except on auth pages', () {
      expect(resolveAuthRedirect(phase: AuthPhase.signedOut, location: '/'), '/login');
      expect(resolveAuthRedirect(phase: AuthPhase.signedOut, location: '/home/month'), '/login');
      expect(resolveAuthRedirect(phase: AuthPhase.signedOut, location: '/login'), isNull);
      expect(resolveAuthRedirect(phase: AuthPhase.signedOut, location: '/register'), isNull);
    });

    test('signed in leaves every auth/splash page to the home view', () {
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/login'), '/home/week');
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/register'), '/home/week');
      // Regression: a cached-profile restart boots at '/' while already signed
      // in and must never stay on the infinite splash spinner.
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/'), '/home/week');
    });

    test('signed in stays on in-app pages', () {
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/home/week'), isNull);
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/home/todo'), isNull);
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/settings/import'), isNull);
      expect(resolveAuthRedirect(phase: AuthPhase.signedIn, location: '/settings/conflicts'), isNull);
    });
  });
}

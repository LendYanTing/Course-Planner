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

    test('an expired session keeps browsing and can reach the login page', () {
      // Requirement: a rejected token must not force a sign-out — the user
      // keeps the cached content and only re-authenticates when ready.
      for (final location in [
        '/home/week',
        '/home/month',
        '/home/todo',
        '/settings/conflicts',
      ]) {
        expect(
          resolveAuthRedirect(
            phase: AuthPhase.signedIn,
            authExpired: true,
            location: location,
          ),
          isNull,
          reason: 'expired session must stay on $location',
        );
      }
      expect(
        resolveAuthRedirect(
          phase: AuthPhase.signedIn,
          authExpired: true,
          location: '/login',
        ),
        isNull,
        reason: 'the re-login page must be reachable while expired',
      );
      // The splash still hands over to the app (cached profile, offline).
      expect(
        resolveAuthRedirect(
          phase: AuthPhase.signedIn,
          authExpired: true,
          location: '/',
        ),
        '/home/week',
      );
    });

    test('a local session may open the login and register pages', () {
      // A no-account local session keeps working, but the user can go sign in
      // to a cloud server at any time.
      for (final location in ['/login', '/register']) {
        expect(
          resolveAuthRedirect(
            phase: AuthPhase.signedIn,
            isLocalMode: true,
            location: location,
          ),
          isNull,
          reason: 'local mode must reach $location to add a cloud account',
        );
      }
      expect(
        resolveAuthRedirect(
          phase: AuthPhase.signedIn,
          isLocalMode: true,
          location: '/home/week',
        ),
        isNull,
      );
      expect(
        resolveAuthRedirect(
          phase: AuthPhase.signedIn,
          isLocalMode: true,
          location: '/',
        ),
        '/home/week',
      );
    });

    test('a local session with the expired flag can still open the auth pages', () {
      for (final location in ['/login', '/register']) {
        expect(
          resolveAuthRedirect(
            phase: AuthPhase.signedIn,
            authExpired: true,
            isLocalMode: true,
            location: location,
          ),
          isNull,
        );
      }
    });
  });
}

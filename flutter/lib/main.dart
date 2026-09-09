import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';
import 'core/time/tz_init.dart';
import 'state/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[boot] tz init');
  ensureTimeZonesInitialized();
  debugPrint('[boot] creating services…');
  final services = await AppServices.create();
  debugPrint('[boot] services ready');
  runApp(
    ProviderScope(
      overrides: [
        servicesProvider.overrideWithValue(services),
      ],
      child: const CoursePlannerApp(),
    ),
  );
  debugPrint('[boot] runApp posted');
}

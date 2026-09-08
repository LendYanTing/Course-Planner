import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';
import 'core/time/tz_init.dart';
import 'state/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ensureTimeZonesInitialized();
  final services = await AppServices.create();
  runApp(
    ProviderScope(
      overrides: [
        servicesProvider.overrideWithValue(services),
      ],
      child: const CoursePlannerApp(),
    ),
  );
}

/// Variant-aware widgets: the single import surface for screens that must look
/// right under both Material 3 and HyperOS.
library;

import 'package:flutter/widgets.dart';

import '../../app/theme.dart';
import '../../state/prefs.dart';

export 'app_card.dart';
export 'app_dialog.dart';
export 'app_sheet.dart';
export 'app_switch.dart';
export 'app_top_bar.dart';

/// Style lookup shortcuts for the current theme.
extension AppThemeContext on BuildContext {
  AppStyleTokens get tokens => AppStyleTokens.of(this);

  UiVariant get uiVariant => tokens.variant;
}

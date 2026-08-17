// 米读：BuildContext.l10n 本地化扩展便捷调用
import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

extension LocalizationExtension on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

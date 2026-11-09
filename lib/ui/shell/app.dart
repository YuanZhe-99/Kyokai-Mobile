// The app: MyApps-UI's Material 3 Expressive theme on Kyokai's brand colour,
// the language and appearance the user picked, and the navigation shell.

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:myapps_ui/myapps_ui.dart';

import '../../data/app_state.dart';
import '../../l10n/gen/app_localizations.dart';
import 'shell.dart';

/// Kyokai's brand colour, the seed of every tone.
const brandSeed = Color(0xFF3B5BA9);
const _theme = MyAppsTheme(seedColor: brandSeed);

class KyokaiApp extends StatelessWidget {
  const KyokaiApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => AppScope(
    state: state,
    child: ListenableBuilder(
      listenable: state.prefs,
      builder: (context, _) {
        final prefs = state.prefs;
        return DynamicColorBuilder(
          builder: (light, dark) {
            final useDynamic = prefs.dynamicColor;
            return MaterialApp(
              title: 'Kyokai',
              debugShowCheckedModeBanner: false,
              theme: _theme.light(useDynamic ? light : null, prefs.style),
              darkTheme: _theme.dark(useDynamic ? dark : null, prefs.style),
              themeMode: prefs.themeMode,
              locale: _locale(prefs.locale),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              localeResolutionCallback: (device, supported) => _resolve(device, supported),
              home: const Shell(),
            );
          },
        );
      },
    ),
  );

  static Locale? _locale(String? tag) {
    if (tag == null) return null;
    final parts = tag.split('_');
    return parts.length > 1 ? Locale.fromSubtags(languageCode: parts[0], countryCode: parts[1]) : Locale(parts[0]);
  }

  /// Traditional Chinese for Taiwan, Hong Kong and Macao and for `zh_Hant`;
  /// Simplified for the rest of Chinese.
  static Locale _resolve(Locale? device, Iterable<Locale> supported) {
    if (device == null) return const Locale('en');
    if (device.languageCode == 'zh') {
      final hant = device.scriptCode == 'Hant' || const {'TW', 'HK', 'MO'}.contains(device.countryCode);
      return hant ? const Locale('zh', 'TW') : const Locale('zh');
    }
    for (final l in supported) {
      if (l.languageCode == device.languageCode) return l;
    }
    return const Locale('en');
  }
}

/// Shorthand for the app's strings.
extension L10nContext on BuildContext {
  AppLocalizations get l => AppLocalizations.of(this);
}


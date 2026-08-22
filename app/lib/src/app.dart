import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import 'core/notifications/notification_nav.dart';
import 'core/prefs.dart';
import 'core/router/app_router.dart';
import 'core/router/deep_links.dart';
import 'core/theme/app_theme.dart';

class SaarathiApp extends ConsumerWidget {
  const SaarathiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    final locale = ref.watch(localeControllerProvider);
    ref.watch(deepLinkHandlerProvider); // forwards saarathi:// links to routes
    ref.watch(notificationNavProvider); // routes tapped notifications

    return MaterialApp.router(
      title: 'Saarathi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: locale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        AppL10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
      builder: (context, child) =>
          WithForegroundTask(child: child ?? const SizedBox.shrink()),
    );
  }
}

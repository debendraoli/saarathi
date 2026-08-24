import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import 'deep_links.dart';

import '../../features/auth/application/auth_controller.dart';
import '../../features/auth/domain/models.dart';
import '../../features/auth/presentation/otp_screen.dart';
import '../../features/auth/presentation/phone_screen.dart';
import '../../features/comms/presentation/call_screen.dart';
import '../../features/comms/presentation/chat_screen.dart';
import '../../features/contributions/presentation/contribute_screen.dart';
import '../../features/contributions/presentation/my_contributions_screen.dart';
import '../../features/contributions/presentation/points_badges_screen.dart';
import '../../features/driver/presentation/become_driver_screen.dart';
import '../../features/driver/presentation/kyc_documents_screen.dart';
import '../../features/home/presentation/account_tab.dart';
import '../../features/home/presentation/activity_tab.dart';
import '../../features/home/presentation/settings_screen.dart';
import '../../features/home/presentation/home_shell.dart';
import '../../features/marketplace/domain/models.dart';
import '../../features/marketplace/presentation/checkout_screen.dart';
import '../../features/marketplace/presentation/marketplace_screen.dart';
import '../../features/marketplace/presentation/merchant_screen.dart';
import '../../features/marketplace/presentation/order_screen.dart';
import '../../features/merchant/presentation/merchant_dashboard_screen.dart';
import '../../features/merchant/presentation/merchant_analytics_screen.dart';
import '../../features/merchant/presentation/merchant_offers_screen.dart';
import '../../features/merchant/presentation/merchant_menu_screen.dart';
import '../../features/merchant/presentation/merchant_onboarding_screen.dart';
import '../../features/merchant/presentation/merchant_orders_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/onboarding/presentation/intro_screen.dart';
import '../../features/onboarding/presentation/splash_screen.dart';
import '../../features/places/data/places_repository.dart';
import '../../features/places/presentation/saved_places_screen.dart';
import '../../features/wallet/presentation/wallet_screen.dart';
import '../../features/ride/presentation/driver_earnings_screen.dart';
import '../../features/ride/presentation/rider_stats_screen.dart';
import '../../features/ride/presentation/trip_screen.dart';
import '../../features/ride/presentation/where_to_screen.dart';
import '../prefs.dart';

class Routes {
  static const splash = '/splash';
  static const intro = '/intro';
  static const login = '/login';
  static const otp = '/login/otp';
  static const home = '/home';
  static const activity = '/activity';
  static const account = '/account';
  static const whereTo = '/ride/where-to';
  static const trip = '/ride/trip'; // /ride/trip/:id
  static const becomeDriver = '/driver/register';
  static const kyc = '/driver/kyc';
  static const chat = '/ride/chat';
  static const call = '/ride/call';
  static const notifications = '/notifications';
  static const savedPlaces = '/places/saved';
  static const settings = '/settings';
  static const wallet = '/wallet';
  static const myStats = '/me/stats';
  static const driverEarnings = '/driver/earnings';
  static const food = '/food';
  static const grocery = '/grocery';
  static const merchant = '/marketplace/merchant';
  static const checkout = '/marketplace/checkout';
  static const order = '/marketplace/order'; // /marketplace/order/:id
  static const merchantDashboard = '/store';
  static const merchantOnboarding = '/store/apply';
  static const merchantOrders = '/store/orders';
  static const merchantMenu = '/store/menu';
  static const merchantAnalytics = '/store/analytics';
  static const merchantOffers = '/store/offers';
  static const contribute = '/places/contribute';
  static const myContributions = '/places/mine';
  static const pointsBadges = '/places/points';
}

/// One consistent motion language for every screen transition (Material's
/// "shared axis" pattern: fade + a short upward drift) instead of go_router's
/// default abrupt platform swap — applied at the router level so every route
/// gets it for free, no per-screen wiring.
CustomTransitionPage<void> _page(Widget child, {required LocalKey key}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Bridges Riverpod state changes to go_router's redirect re-evaluation.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
    ref.listen(onboardingControllerProvider, (_, __) => notifyListeners());
  }
}

final goRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final onboarded = ref.read(onboardingControllerProvider);
      final loc = state.matchedLocation;

      if (auth.status == AuthStatus.unknown) {
        return loc == Routes.splash ? null : Routes.splash;
      }
      if (!onboarded) {
        return loc == Routes.intro ? null : Routes.intro;
      }
      final loggedOut = auth.status == AuthStatus.unauthenticated;
      final atAuth = loc == Routes.login || loc == Routes.otp;
      if (loggedOut) return atAuth ? null : Routes.login;

      // Authenticated: keep them out of the pre-auth funnel.
      if (loc == Routes.splash || loc == Routes.intro || atAuth) {
        return Routes.home;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: Routes.splash,
        pageBuilder: (_, state) =>
            _page(const SplashScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.intro,
        pageBuilder: (_, state) =>
            _page(const IntroScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.login,
        pageBuilder: (_, state) =>
            _page(const PhoneScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.otp,
        pageBuilder: (_, state) => _page(
          OtpScreen(phone: state.extra as String? ?? ''),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.home,
        pageBuilder: (_, state) => _page(const HomeShell(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.activity,
        pageBuilder: (context, state) => _page(
          Scaffold(
            appBar: AppBar(
              title: Text(AppL10n.of(context).tabActivity),
              leading: BackButton(onPressed: () => context.go(Routes.home)),
            ),
            body: const ActivityTab(),
          ),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.account,
        pageBuilder: (context, state) => _page(
          Scaffold(
            appBar: AppBar(title: Text(AppL10n.of(context).tabAccount)),
            body: const AccountTab(),
          ),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.whereTo,
        pageBuilder: (_, state) {
          final originLat =
              double.tryParse(state.uri.queryParameters['originLat'] ?? '');
          final originLng =
              double.tryParse(state.uri.queryParameters['originLng'] ?? '');
          return _page(
            WhereToScreen(
              initialDest: state.extra as PlaceHit?,
              initialPickup: originLat != null && originLng != null
                  ? LatLng(originLat, originLng)
                  : null,
              initialMode: state.uri.queryParameters['mode'] == 'delivery'
                  ? RideMode.delivery
                  : RideMode.ride,
            ),
            key: state.pageKey,
          );
        },
      ),
      GoRoute(
        path: '${Routes.trip}/:id',
        pageBuilder: (_, state) => _page(
          TripScreen(tripId: state.pathParameters['id']!),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.becomeDriver,
        pageBuilder: (_, state) =>
            _page(const BecomeDriverScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.kyc,
        pageBuilder: (_, state) =>
            _page(const KycDocumentsScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.chat,
        pageBuilder: (_, state) => _page(
          ChatScreen(tripId: state.extra as String),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.call,
        pageBuilder: (_, state) => _page(
          CallScreen(args: state.extra as CallArgs),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.notifications,
        pageBuilder: (_, state) =>
            _page(const NotificationsScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.savedPlaces,
        pageBuilder: (_, state) =>
            _page(const SavedPlacesScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.settings,
        pageBuilder: (_, state) =>
            _page(const SettingsScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.wallet,
        pageBuilder: (_, state) =>
            _page(const WalletScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.myStats,
        pageBuilder: (_, state) =>
            _page(const RiderStatsScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.driverEarnings,
        pageBuilder: (_, state) =>
            _page(const DriverEarningsScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.food,
        pageBuilder: (_, state) => _page(
          const MarketplaceScreen(kind: MarketplaceKind.food),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.grocery,
        pageBuilder: (_, state) => _page(
          const MarketplaceScreen(kind: MarketplaceKind.grocery),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.merchant,
        pageBuilder: (_, state) => _page(
          MerchantScreen(merchant: state.extra as Merchant),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.checkout,
        pageBuilder: (_, state) =>
            _page(const CheckoutScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: '${Routes.order}/:id',
        pageBuilder: (_, state) => _page(
          OrderScreen(orderId: state.pathParameters['id']!),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.merchantDashboard,
        pageBuilder: (_, state) =>
            _page(const MerchantDashboardScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.merchantOnboarding,
        pageBuilder: (_, state) =>
            _page(const MerchantOnboardingScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.merchantOrders,
        pageBuilder: (_, state) => _page(
          MerchantOrdersScreen(merchant: state.extra as Merchant),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.merchantMenu,
        pageBuilder: (_, state) => _page(
          MerchantMenuScreen(merchant: state.extra as Merchant),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.merchantAnalytics,
        pageBuilder: (_, state) => _page(
          MerchantAnalyticsScreen(merchant: state.extra as Merchant),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.merchantOffers,
        pageBuilder: (_, state) => _page(
          MerchantOffersScreen(merchant: state.extra as Merchant),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.contribute,
        pageBuilder: (_, state) =>
            _page(const ContributeScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.myContributions,
        pageBuilder: (_, state) =>
            _page(const MyContributionsScreen(), key: state.pageKey),
      ),
      GoRoute(
        path: Routes.pointsBadges,
        pageBuilder: (_, state) =>
            _page(const PointsBadgesScreen(), key: state.pageKey),
      ),
    ],
    // Android's Flutter embedding independently pushes an incoming
    // `saarathi://…` deep link to go_router's own route parser via
    // `onNewIntent` (separate from — and racing — `deep_links.dart`'s own
    // `app_links` stream handling), and go_router has no route registered
    // for a raw custom-scheme URI, so it 404s here instead of ever reaching
    // `routeForDeepLink`. Recover by mapping it ourselves and redirecting.
    errorBuilder: (context, state) {
      final mapped = routeForDeepLink(state.uri);
      if (mapped != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          GoRouter.of(context).go(mapped);
        });
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return Scaffold(
        body: Center(child: Text('Page not found: ${state.uri}')),
      );
    },
  );
});

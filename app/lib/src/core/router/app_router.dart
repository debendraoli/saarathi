import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/application/auth_controller.dart';
import '../../features/auth/domain/models.dart';
import '../../features/auth/presentation/otp_screen.dart';
import '../../features/auth/presentation/phone_screen.dart';
import '../../features/comms/presentation/call_screen.dart';
import '../../features/comms/presentation/chat_screen.dart';
import '../../features/delivery/presentation/parcel_screen.dart';
import '../../features/driver/presentation/become_driver_screen.dart';
import '../../features/driver/presentation/kyc_documents_screen.dart';
import '../../features/home/presentation/home_shell.dart';
import '../../features/marketplace/domain/models.dart';
import '../../features/marketplace/presentation/checkout_screen.dart';
import '../../features/marketplace/presentation/marketplace_screen.dart';
import '../../features/marketplace/presentation/merchant_screen.dart';
import '../../features/marketplace/presentation/order_screen.dart';
import '../../features/merchant/presentation/merchant_dashboard_screen.dart';
import '../../features/merchant/presentation/merchant_menu_screen.dart';
import '../../features/merchant/presentation/merchant_onboarding_screen.dart';
import '../../features/merchant/presentation/merchant_orders_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/onboarding/presentation/intro_screen.dart';
import '../../features/onboarding/presentation/splash_screen.dart';
import '../../features/places/data/places_repository.dart';
import '../../features/places/presentation/saved_places_screen.dart';
import '../../features/wallet/presentation/wallet_screen.dart';
import '../../features/ride/domain/models.dart';
import '../../features/ride/presentation/confirm_ride_screen.dart';
import '../../features/ride/presentation/trip_screen.dart';
import '../../features/ride/presentation/where_to_screen.dart';
import '../prefs.dart';

class Routes {
  static const splash = '/splash';
  static const intro = '/intro';
  static const login = '/login';
  static const otp = '/login/otp';
  static const home = '/home';
  static const whereTo = '/ride/where-to';
  static const confirm = '/ride/confirm';
  static const trip = '/ride/trip'; // /ride/trip/:id
  static const becomeDriver = '/driver/register';
  static const kyc = '/driver/kyc';
  static const parcel = '/delivery/parcel';
  static const chat = '/ride/chat';
  static const call = '/ride/call';
  static const notifications = '/notifications';
  static const savedPlaces = '/places/saved';
  static const wallet = '/wallet';
  static const food = '/food';
  static const grocery = '/grocery';
  static const merchant = '/marketplace/merchant';
  static const checkout = '/marketplace/checkout';
  static const order = '/marketplace/order'; // /marketplace/order/:id
  static const merchantDashboard = '/store';
  static const merchantOnboarding = '/store/apply';
  static const merchantOrders = '/store/orders';
  static const merchantMenu = '/store/menu';
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
        path: Routes.whereTo,
        pageBuilder: (_, state) => _page(
          WhereToScreen(initialDest: state.extra as PlaceHit?),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: Routes.confirm,
        pageBuilder: (_, state) => _page(
          ConfirmRideScreen(draft: state.extra as RideDraft),
          key: state.pageKey,
        ),
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
        path: Routes.parcel,
        pageBuilder: (_, state) =>
            _page(const ParcelScreen(), key: state.pageKey),
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
        path: Routes.wallet,
        pageBuilder: (_, state) =>
            _page(const WalletScreen(), key: state.pageKey),
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
    ],
  );
});

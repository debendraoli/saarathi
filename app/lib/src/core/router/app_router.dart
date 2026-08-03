import 'package:flutter/foundation.dart';
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
import '../../features/merchant/presentation/merchant_orders_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/onboarding/presentation/intro_screen.dart';
import '../../features/onboarding/presentation/splash_screen.dart';
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
  static const food = '/food';
  static const grocery = '/grocery';
  static const merchant = '/marketplace/merchant';
  static const checkout = '/marketplace/checkout';
  static const order = '/marketplace/order'; // /marketplace/order/:id
  static const merchantDashboard = '/store';
  static const merchantOrders = '/store/orders';
  static const merchantMenu = '/store/menu';
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
      GoRoute(path: Routes.splash, builder: (_, __) => const SplashScreen()),
      GoRoute(path: Routes.intro, builder: (_, __) => const IntroScreen()),
      GoRoute(path: Routes.login, builder: (_, __) => const PhoneScreen()),
      GoRoute(
        path: Routes.otp,
        builder: (_, state) => OtpScreen(phone: state.extra as String? ?? ''),
      ),
      GoRoute(path: Routes.home, builder: (_, __) => const HomeShell()),
      GoRoute(path: Routes.whereTo, builder: (_, __) => const WhereToScreen()),
      GoRoute(
        path: Routes.confirm,
        builder: (_, state) =>
            ConfirmRideScreen(draft: state.extra as RideDraft),
      ),
      GoRoute(
        path: '${Routes.trip}/:id',
        builder: (_, state) => TripScreen(tripId: state.pathParameters['id']!),
      ),
      GoRoute(
          path: Routes.becomeDriver,
          builder: (_, __) => const BecomeDriverScreen()),
      GoRoute(path: Routes.kyc, builder: (_, __) => const KycDocumentsScreen()),
      GoRoute(path: Routes.parcel, builder: (_, __) => const ParcelScreen()),
      GoRoute(
        path: Routes.chat,
        builder: (_, state) => ChatScreen(tripId: state.extra as String),
      ),
      GoRoute(
        path: Routes.call,
        builder: (_, state) => CallScreen(args: state.extra as CallArgs),
      ),
      GoRoute(
          path: Routes.notifications,
          builder: (_, __) => const NotificationsScreen()),
      GoRoute(
        path: Routes.food,
        builder: (_, __) => const MarketplaceScreen(kind: MarketplaceKind.food),
      ),
      GoRoute(
        path: Routes.grocery,
        builder: (_, __) =>
            const MarketplaceScreen(kind: MarketplaceKind.grocery),
      ),
      GoRoute(
        path: Routes.merchant,
        builder: (_, state) =>
            MerchantScreen(merchant: state.extra as Merchant),
      ),
      GoRoute(
        path: Routes.checkout,
        builder: (_, __) => const CheckoutScreen(),
      ),
      GoRoute(
        path: '${Routes.order}/:id',
        builder: (_, state) =>
            OrderScreen(orderId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: Routes.merchantDashboard,
        builder: (_, __) => const MerchantDashboardScreen(),
      ),
      GoRoute(
        path: Routes.merchantOrders,
        builder: (_, state) =>
            MerchantOrdersScreen(merchant: state.extra as Merchant),
      ),
      GoRoute(
        path: Routes.merchantMenu,
        builder: (_, state) =>
            MerchantMenuScreen(merchant: state.extra as Merchant),
      ),
    ],
  );
});

import 'package:saarathi/l10n/app_localizations.dart';

/// Which side of a trip is being rated, and by whom — the tag vocabulary
/// differs for each: a rider praising/criticizing a driver's driving isn't
/// the same list a driver would use for a passenger's behavior, and neither
/// matches what a parcel sender cares about from a courier.
enum RatingContext {
  riderRatesDriver,
  driverRatesRider,
  senderRatesCourier,
  customerRatesMerchant,
}

/// Positive (shown at 4-5★) and negative (shown at 1-3★) tag choices for a
/// [RatingContext] — 5 stars and "reckless driving" don't belong on the same
/// screen, so the sheet swaps the list based on the star the user picked.
(List<String> positive, List<String> negative) ratingTagsFor(
  AppL10n l,
  RatingContext context,
) {
  switch (context) {
    case RatingContext.riderRatesDriver:
      return (
        [
          l.ratingTagSafeDriving,
          l.ratingTagFriendlyDriver,
          l.ratingTagCleanVehicle,
          l.ratingTagOnTime,
          l.ratingTagGreatRoute,
        ],
        [
          l.ratingTagRudeDriver,
          l.ratingTagRecklessDriving,
          l.ratingTagUnhygienicVehicle,
          l.ratingTagLongerRoute,
          l.ratingTagLatePickup,
        ],
      );
    case RatingContext.driverRatesRider:
      return (
        [
          l.ratingTagPolitePassenger,
          l.ratingTagReadyOnTime,
          l.ratingTagEasyPickup,
          l.ratingTagRespectful,
        ],
        [
          l.ratingTagRudePassenger,
          l.ratingTagKeptWaiting,
          l.ratingTagWrongPickupLocation,
          l.ratingTagUnsafeBehavior,
        ],
      );
    case RatingContext.senderRatesCourier:
      return (
        [
          l.ratingTagCourierOnTime,
          l.ratingTagCarefulHandling,
          l.ratingTagFriendlyCourier,
          l.ratingTagWellProtected,
        ],
        [
          l.ratingTagPackageDamaged,
          l.ratingTagVeryLateDelivery,
          l.ratingTagCarelessHandling,
          l.ratingTagRudeCourier,
          l.ratingTagWrongDeliveryLocation,
        ],
      );
    case RatingContext.customerRatesMerchant:
      return (
        [
          l.ratingTagGreatFood,
          l.ratingTagFreshIngredients,
          l.ratingTagGoodPortion,
          l.ratingTagWellPackaged,
          l.ratingTagAccurateOrder,
        ],
        [
          l.ratingTagColdFood,
          l.ratingTagWrongItems,
          l.ratingTagMissingItems,
          l.ratingTagPoorPackaging,
          l.ratingTagNotFresh,
        ],
      );
  }
}

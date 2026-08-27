import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/paged_notifier.dart';

/// A publicly-listable operating/business partner — see
/// `saarathi-partners::routes::public`. Deliberately a narrower set of
/// fields than what staff can see/edit on the dashboard (no email, no
/// commission share, no internal status) — this is what a rider/driver/
/// merchant gets shown for legal disclosure, not an operational record.
class Partner {
  const Partner({
    required this.id,
    required this.name,
    this.panVat,
    this.city,
    this.contactPhone,
  });

  final String id;
  final String name;
  final String? panVat;
  final String? city;
  final String? contactPhone;

  factory Partner.fromJson(Map<String, dynamic> j) => Partner(
        id: j['id'] as String,
        name: j['name'] as String,
        panVat: j['pan_vat'] as String?,
        city: j['city'] as String?,
        contactPhone: j['contact_phone'] as String?,
      );
}

class PartnersRepository {
  PartnersRepository(this._api);
  final ApiClient _api;

  Future<List<Partner>> page({required int limit, required int offset}) async {
    final res = await _api.get('/v1/partners', query: {
      'limit': limit.toString(),
      'offset': offset.toString(),
    }) as List;
    return res.map((e) => Partner.fromJson(e as Map<String, dynamic>)).toList();
  }
}

final partnersRepositoryProvider = Provider<PartnersRepository>((ref) {
  return PartnersRepository(ref.watch(apiClientProvider));
});

class PartnersPaged extends PagedNotifier<Partner> {
  @override
  Future<List<Partner>> fetchPage(int offset, int limit) =>
      ref.read(partnersRepositoryProvider).page(limit: limit, offset: offset);
}

final partnersPagedProvider =
    AsyncNotifierProvider.autoDispose<PartnersPaged, PagedState<Partner>>(
        PartnersPaged.new);

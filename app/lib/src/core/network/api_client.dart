import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../scaffold_messenger.dart';
import '../storage/token_store.dart';

/// A fresh key for `X-Idempotency-Key` — generate once per user action (e.g.
/// when a "place order"/"top up" button is tapped) and reuse it across
/// retries of *that same* attempt, so a dropped response can't turn one tap
/// into two charges/orders. Never reuse a key across a genuinely new attempt.
String newIdempotencyKey() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

/// A friendly, typed API error surfaced to the UI.
class ApiException implements Exception {
  ApiException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  bool get isNetwork => statusCode == null;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

/// Thin dio wrapper: injects the bearer token, transparently refreshes it on a
/// 401 (rotating refresh token), and normalises errors into [ApiException].
class ApiClient {
  ApiClient(this._tokens) {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.apiBase,
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'content-type': 'application/json'},
      ),
    );
    // Dio defaults to decoding JSON synchronously on the calling isolate —
    // for a response over ~50KB (list-heavy endpoints like trip history,
    // item search results) that's real jank on the UI isolate.
    // BackgroundTransformer keeps small payloads synchronous (avoiding
    // compute()'s isolate-hop overhead for the common case) and only
    // offloads genuinely large ones.
    _dio.transformer = BackgroundTransformer();
    _bare = Dio(BaseOptions(baseUrl: AppConfig.apiBase));
    _bare.transformer = BackgroundTransformer();
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          var token = await _tokens.access;
          // Proactively refresh a token that's about to expire (or already
          // has — e.g. the app was backgrounded past it) *before* using it,
          // rather than only reacting to the 401 this request would
          // otherwise get — the previous behaviour, which worked but meant
          // the first request after every ~15min access-token window paid
          // for an extra failed-then-retried round trip. Skipped for the
          // auth endpoints themselves (login, the refresh call this
          // triggers) — same exclusion `onError` below already needs.
          if (token != null &&
              !_isAuthPath(options.path) &&
              _expiresSoon(token)) {
            if (await _refresh()) token = await _tokens.access;
          }
          if (token != null && options.headers['authorization'] == null) {
            options.headers['authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          // Capped to one retry per original request via the `_retried`
          // marker below — without it, a token that refresh reports success
          // for but that the backend keeps rejecting downstream (a
          // permanently revoked/blacklisted token, or any bug on that path)
          // would refresh→retry→401 indefinitely for the same request, with
          // no backoff, since each retry is itself a fresh request that
          // re-enters this same interceptor.
          if (e.response?.statusCode == 401 &&
              !_isAuthPath(e.requestOptions.path) &&
              e.requestOptions.extra['_retried'] != true) {
            final ok = await _refresh();
            if (ok) {
              try {
                final clone = await _retry(e.requestOptions);
                return handler.resolve(clone);
              } catch (_) {/* fall through */}
            }
          }
          handler.next(e);
        },
      ),
    );
  }

  final TokenStore _tokens;
  late final Dio _dio;
  late final Dio _bare;

  /// Called when the session can no longer be refreshed (forces re-login).
  void Function()? onSessionExpired;

  Completer<bool>? _refreshing;

  bool _isAuthPath(String path) => path.contains('/v1/auth/');

  static const _refreshAheadOf = Duration(seconds: 90);

  /// Reads a JWT's own `exp` claim — no signature check, this is purely a
  /// local "is it worth using as-is" hint; the backend is still the one
  /// actual authority on validity. `true` (refresh) on anything that fails
  /// to parse as a well-formed JWT, since that's not a case this app's own
  /// tokens should ever hit and the safe fallback is the existing reactive
  /// 401 path, not silently skipping the freshness check.
  bool _expiresSoon(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = payload['exp'] as num?;
      if (exp == null) return true;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
      return DateTime.now().isAfter(expiresAt.subtract(_refreshAheadOf));
    } catch (_) {
      return true;
    }
  }

  Future<Response<dynamic>> _retry(RequestOptions o) {
    // Drop the stale bearer so the interceptor re-injects the refreshed token.
    final headers = Map<String, dynamic>.from(o.headers)
      ..remove('authorization');
    return _dio.request<dynamic>(
      o.path,
      data: o.data,
      queryParameters: o.queryParameters,
      options: Options(
        method: o.method,
        headers: headers,
        extra: {...o.extra, '_retried': true},
      ),
    );
  }

  Future<bool> _refresh() async {
    if (_refreshing != null) return _refreshing!.future;
    final completer = Completer<bool>();
    _refreshing = completer;
    try {
      final refresh = await _tokens.refresh;
      if (refresh == null) {
        // No refresh token in storage — same unrecoverable state as a
        // refresh call that fails below, so it needs the same fallout:
        // clear whatever's left and force the app back to login, rather
        // than leaving a "still authenticated" UI that can never again
        // complete a request.
        await _tokens.clear();
        onSessionExpired?.call();
        completer.complete(false);
      } else {
        final res = await _bare.post<dynamic>(
          '/v1/auth/refresh',
          data: {
            'refresh_token': refresh,
            'device_id': await _tokens.deviceId,
          },
        );
        final data = res.data as Map<String, dynamic>;
        await _tokens.save(
          access: data['access_token'] as String,
          refresh: data['refresh_token'] as String,
        );
        completer.complete(true);
      }
    } on DioException catch (e) {
      // Only a genuine rejection of the refresh token itself (401/403 from
      // the refresh endpoint) means the session is actually over. Anything
      // else — no connectivity, a timeout, a 5xx blip on our own backend —
      // is transient: keep the stored tokens so the next attempt (the next
      // request, or the next proactive refresh) can succeed once the
      // network/backend recovers, instead of forcing a full re-login on a
      // flaky connection.
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        await _tokens.clear();
        onSessionExpired?.call();
      } else {
        showOfflineToast();
      }
      completer.complete(false);
    } catch (_) {
      // Unexpected (non-Dio) failure — same "don't nuke the session over a
      // transient error" treatment as above.
      completer.complete(false);
    } finally {
      _refreshing = null;
    }
    return completer.future;
  }

  /// [cancelToken], when given, lets a caller abandon this request once it's
  /// been superseded (a rapidly-switched vehicle class, a newer search
  /// query, a newer deep-link resolution) instead of just discarding the
  /// eventual result — the in-flight HTTP call itself is aborted, not just
  /// its response ignored.
  Future<dynamic> get(String path,
          {Map<String, dynamic>? query, CancelToken? cancelToken}) =>
      _send(() => _dio.get<dynamic>(path,
          queryParameters: query, cancelToken: cancelToken));

  Future<dynamic> post(String path,
          {Object? body,
          Map<String, String>? headers,
          CancelToken? cancelToken}) =>
      _send(() => _dio.post<dynamic>(
            path,
            data: body,
            options: headers == null ? null : Options(headers: headers),
            cancelToken: cancelToken,
          ));

  Future<dynamic> put(String path, {Object? body}) =>
      _send(() => _dio.put<dynamic>(path, data: body));

  Future<dynamic> delete(String path, {Object? body}) =>
      _send(() => _dio.delete<dynamic>(path, data: body));

  /// Multipart upload (KYC documents). Lets dio set the multipart boundary.
  Future<dynamic> upload(String path, FormData form) => _send(
        () => _dio.post<dynamic>(
          path,
          data: form,
          options: Options(contentType: 'multipart/form-data'),
        ),
      );

  Future<dynamic> _send(Future<Response<dynamic>> Function() run) async {
    try {
      final res = await run();
      return res.data;
    } on DioException catch (e) {
      // A caller-cancelled request (superseded by a newer one) isn't a real
      // failure worth surfacing as an ApiException — let it propagate as
      // the DioException it is so `e.type == DioExceptionType.cancel` can
      // be checked and silently ignored, same convention CancelToken users
      // rely on elsewhere.
      if (e.type == DioExceptionType.cancel) rethrow;
      throw _mapError(e);
    }
  }

  ApiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? code;
    String? message;
    if (data is Map<String, dynamic>) {
      final err = data['error'];
      if (err is Map<String, dynamic>) {
        code = err['code'] as String?;
        message = err['message'] as String?;
      }
      message ??= data['message'] as String?;
    }
    return ApiException(
      message ?? (status == null ? 'network' : 'request_failed'),
      code: code,
      statusCode: status,
    );
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(ref.watch(tokenStoreProvider));
});

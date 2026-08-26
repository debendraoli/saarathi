import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
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
          final token = await _tokens.access;
          if (token != null && options.headers['authorization'] == null) {
            options.headers['authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          if (e.response?.statusCode == 401 &&
              !_isAuthPath(e.requestOptions.path)) {
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

  Future<Response<dynamic>> _retry(RequestOptions o) {
    // Drop the stale bearer so the interceptor re-injects the refreshed token.
    final headers = Map<String, dynamic>.from(o.headers)
      ..remove('authorization');
    return _dio.request<dynamic>(
      o.path,
      data: o.data,
      queryParameters: o.queryParameters,
      options: Options(method: o.method, headers: headers),
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
    } catch (_) {
      await _tokens.clear();
      onSessionExpired?.call();
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

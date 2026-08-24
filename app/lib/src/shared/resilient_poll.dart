import 'dart:async';
import 'dart:math';

/// A polled value plus whether it's stale (the most recent fetch failed, so
/// this is the last-known-good value, not a fresh one).
class Poll<T> {
  const Poll(this.value, {this.stale = false});
  final T value;
  final bool stale;
}

/// Polls [fetch] every [interval], recovering from transient failures on its
/// own instead of taking the whole screen down:
///
/// - Once a fetch has succeeded at least once, a later failure re-yields the
///   last-known value with [Poll.stale] set, and keeps retrying — the caller
///   never sees an [AsyncError] for a blip once there's something to show.
/// - Before the first success, failures retry with capped exponential
///   backoff and stay silent, up to [maxInitialFailures] — past that, a
///   genuinely broken request (bad id, permanently revoked auth, dead
///   endpoint) surfaces as a real stream error rather than retrying forever.
Stream<Poll<T>> resilientPoll<T>({
  required Future<T> Function() fetch,
  required Duration interval,
  bool Function(T value)? stopWhen,
  int maxInitialFailures = 6,
}) async* {
  T? last;
  var haveValue = false;
  var initialFailures = 0;
  while (true) {
    try {
      final value = await fetch();
      last = value;
      haveValue = true;
      initialFailures = 0;
      yield Poll(value);
      if (stopWhen != null && stopWhen(value)) return;
      await Future<void>.delayed(interval);
    } catch (e, st) {
      if (haveValue) {
        yield Poll(last as T, stale: true);
        await Future<void>.delayed(interval);
        continue;
      }
      initialFailures++;
      if (initialFailures > maxInitialFailures) {
        Error.throwWithStackTrace(e, st);
      }
      // Capped exponential backoff (2s, 4s, 8s, ... up to 30s) while we've
      // never had a value to fall back on — no point hammering a backend
      // that's actually down, but still self-recovers once it's back.
      final backoff = Duration(
        seconds: min(30, pow(2, initialFailures).toInt()),
      );
      await Future<void>.delayed(backoff);
    }
  }
}

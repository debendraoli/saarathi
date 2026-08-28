/// Capped exponential backoff for a one-shot read provider's built-in
/// [Retry] hook: 300ms, 600ms, 1200ms, then gives up. Meant for plain GET
/// `FutureProvider`s with no resilience of their own — not for providers
/// already built on `resilientPoll` or a websocket stream, which have their
/// own recovery semantics, and not for anything that performs a mutation.
Duration? shortNetworkRetry(int retryCount, Object error) =>
    retryCount < 3 ? Duration(milliseconds: 300 * (1 << retryCount)) : null;

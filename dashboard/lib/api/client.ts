// API client. All calls go through the API gateway (Traefik), which routes by
// path to the owning service — so one base URL covers every service.

import { auth } from "./auth";
import type { TokenPair } from "./types";

export const API_BASE = process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:8080";

// ── Core request helper (with one refresh retry) ────────────────────────────

export async function raw(
  path: string,
  init: RequestInit,
  withAuth: boolean,
  base: string = API_BASE,
): Promise<Response> {
  const headers = new Headers(init.headers);
  if (withAuth && auth.access) headers.set("Authorization", `Bearer ${auth.access}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return fetch(`${base}${path}`, { ...init, headers });
}

// Parse the standard error envelope { error: { code, message } } → a display
// string. Apps should map `code` to a localized message; we fall back to message.
export async function apiError(res: Response): Promise<string> {
  try {
    const body = await res.json();
    const err = body?.error;
    if (err && typeof err === "object") return err.message ?? err.code ?? `Request failed (${res.status})`;
    if (typeof err === "string") return err;
  } catch {
    /* ignore */
  }
  return `Request failed (${res.status})`;
}

export async function request<T>(
  path: string,
  init: RequestInit = {},
  withAuth = true,
  base: string = API_BASE,
): Promise<T> {
  let res = await raw(path, init, withAuth, base);

  if (res.status === 401 && withAuth && auth.refresh) {
    // The refresh call itself always goes through the main gateway
    // (API_BASE), regardless of which base this request was for.
    const refreshed = await raw(
      "/v1/auth/refresh",
      { method: "POST", body: JSON.stringify({ refresh_token: auth.refresh }) },
      false,
    );
    if (refreshed.ok) {
      const data = (await refreshed.json()) as TokenPair;
      auth.set(data.access_token, data.refresh_token, data.user);
      res = await raw(path, init, withAuth, base);
    }
  }

  if (!res.ok) {
    throw new Error(await apiError(res));
  }
  return (await res.json()) as T;
}

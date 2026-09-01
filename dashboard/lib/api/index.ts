// Barrel re-export so existing `import { ... } from "@/lib/api"` call sites
// keep working unchanged after the split into per-domain files.

export * from "./types";
export * from "./auth";
export * from "./api";
export * from "./rides";
export * from "./merchant";
export * from "./places";

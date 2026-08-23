/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Standalone output for a small Docker runtime image (Dockerfile copies
  // .next/standalone + .next/static + public, not the full node_modules tree).
  output: "standalone",
};

export default nextConfig;

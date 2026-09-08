import type { NextConfig } from "next";

const apiTarget = process.env.API_PROXY_TARGET ?? "http://127.0.0.1:8080";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  async rewrites() {
    // In dev the Go backend only listens on private HTTP (docs/architecture.md).
    // Proxy the whole /api prefix so the browser talks to a single origin and
    // the HttpOnly refresh cookie (Path=/api/v1/auth) round-trips naturally.
    return [
      {
        source: "/api/:path*",
        destination: `${apiTarget}/api/:path*`,
      },
      {
        source: "/healthz",
        destination: `${apiTarget}/healthz`,
      },
    ];
  },
};

export default nextConfig;

/**
 * Production must name its browser origins. With CORS_ORIGIN unset the API reflects any origin and allows
 * credentials, which is fine for a developer's machine and wrong for real families' data (#765, Fable B4).
 * NODE_ENV=production runs that deliberately accept any origin (on-demand staging, the CI image check) say so
 * with CORS_ALLOW_ANY_ORIGIN=1; the production Terraform never sets it and requires CORS_ORIGIN instead.
 */
export function assertCorsConfigured(env: NodeJS.ProcessEnv): void {
  if (env.NODE_ENV !== "production") return;
  const origins = env.CORS_ORIGIN?.split(",").map((o) => o.trim()).filter(Boolean) ?? [];
  if (origins.some((o) => o === "*")) {
    throw new Error("CORS_ORIGIN must list origins, not '*', in production");
  }
  if (origins.length === 0 && env.CORS_ALLOW_ANY_ORIGIN !== "1") {
    throw new Error("CORS_ORIGIN must be set in production (or CORS_ALLOW_ANY_ORIGIN=1 for a non-production deployment)");
  }
}

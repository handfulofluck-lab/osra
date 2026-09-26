import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // argon2 password hashing is memory-hard and slow on constrained machines.
    testTimeout: 20000,
  },
});

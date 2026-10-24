import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // argon2 password hashing is memory-hard and slow on constrained machines.
    testTimeout: 20000,
    // The idle-request counter (roadmap 5.8) is off unless `IDLE_BUDGET_COUNTING=1`, and the instrument is
    // what the suite tests — so the harness turns it on, the way staging does. A test that needs it off
    // deletes the variable for its own body and restores it afterwards.
    env: { IDLE_BUDGET_COUNTING: "1" },
  },
});

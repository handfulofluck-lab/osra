import { describe, expect, it } from "vitest";
import {
  CLIENT_HEADER_MAX_LENGTH,
  isGateExempt,
  parseClientHeader,
  parseClientPolicy,
  shouldRefuseWith426,
  updateVerdict,
} from "../src/lib/clientHeader.js";

/**
 * ADR-0034 decision 4/5 and amendment A3, as rows.
 *
 * The header is a **hint**: a malformed one is legacy (never a 400), and only the parent app is ever
 * refused. Those two facts are what keep this from becoming a client-bricking control.
 */
describe("A3 — parsing X-OSRA-Client", () => {
  it("reads the documented shape", () => {
    expect(parseClientHeader("child-android/0.2.0+2 (play)")).toEqual({
      app: "child-android",
      version: "0.2.0",
      build: 2,
      flavour: "play",
    });
    expect(parseClientHeader("parent-app/0.1.0+1 (android)")?.app).toBe("parent-app");
  });

  it("anything that is not the pattern is legacy, never an error", () => {
    // Decision 4: every client released before this change is legacy, and legacy is served as today.
    expect(parseClientHeader(undefined)).toBeNull();
    expect(parseClientHeader("")).toBeNull();
    expect(parseClientHeader("child-android/0.2.0")).toBeNull(); // no build, no flavour
    expect(parseClientHeader("child-android/0.2+2 (play)")).toBeNull(); // two-part version
    expect(parseClientHeader("unknown-app/1.0.0+1 (play)")).toBeNull(); // an app we do not know
    expect(parseClientHeader("child-android/1.0.0+1 (Play)")).toBeNull(); // flavour is lower-case only
    expect(parseClientHeader(["child-android/1.0.0+1 (play", "play)"])).toBeNull(); // repeated header
  });

  it("a 65-character value is legacy before any parsing", () => {
    // A3: the length cap runs first, so a hostile 64 KB header never reaches the regex.
    const head = "child-android/1.0.0+1 (play)";
    const padded = head + " ".repeat(CLIENT_HEADER_MAX_LENGTH + 1 - head.length);
    expect(padded.length).toBe(CLIENT_HEADER_MAX_LENGTH + 1);
    expect(parseClientHeader(padded)).toBeNull();
    expect(parseClientHeader(head)).not.toBeNull();
  });
});

describe("decision 5 — CLIENT_POLICY, and what the verdict is", () => {
  it("an empty or unreadable policy means no gate", () => {
    // This is how the change ships: the code goes out with the gate off.
    expect(parseClientPolicy(undefined)).toEqual({});
    expect(parseClientPolicy("")).toEqual({});
    expect(parseClientPolicy("not json")).toEqual({});
    expect(parseClientPolicy("[1,2]")).toEqual({});
  });

  it("parses a policy, ignoring values it cannot use", () => {
    expect(
      parseClientPolicy('{"parent-app":{"min":3,"recommended":4},"child-android":{"min":5}}'),
    ).toEqual({ "parent-app": { min: 3, recommended: 4 }, "child-android": { min: 5 } });
    expect(parseClientPolicy('{"parent-app":{"min":"three"}}')).toEqual({ "parent-app": {} });
  });

  it("computes none, recommended and required, and `none` for legacy", () => {
    const policy = { "parent-app": { min: 3, recommended: 4 } };
    expect(updateVerdict(parseClientHeader("parent-app/0.1.0+4 (android)"), policy)).toBe("none");
    expect(updateVerdict(parseClientHeader("parent-app/0.1.0+3 (android)"), policy)).toBe("recommended");
    expect(updateVerdict(parseClientHeader("parent-app/0.1.0+2 (android)"), policy)).toBe("required");
    expect(updateVerdict(null, policy)).toBe("none");
    expect(updateVerdict(parseClientHeader("child-android/1.0.0+1 (full)"), policy)).toBe("none");
  });
});

describe("A5 — the gate never blocks a data right", () => {
  it("the five exempt routes are exempt, with or without a query string", () => {
    expect(isGateExempt("GET", "/health")).toBe(true);
    expect(isGateExempt("POST", "/v1/auth/logout")).toBe(true);
    expect(isGateExempt("POST", "/v1/auth/logout-all")).toBe(true);
    expect(isGateExempt("POST", "/v1/family/children/child-1/consent/revoke")).toBe(true);
    expect(isGateExempt("DELETE", "/v1/family/children/child-1")).toBe(true);
    expect(isGateExempt("GET", "/health?probe=1")).toBe(true);
  });

  it("everything else is inside the gate", () => {
    expect(isGateExempt("GET", "/v1/family/me")).toBe(false);
    // The verb is part of it: DELETE is exempt on that path, GET is not.
    expect(isGateExempt("GET", "/v1/family/children/child-1")).toBe(false);
    expect(isGateExempt("POST", "/v1/devices")).toBe(false);
  });
});

describe("decision 5 — who is ever refused", () => {
  it("only the parent app, and only when required", () => {
    expect(shouldRefuseWith426(parseClientHeader("parent-app/0.1.0+2 (android)"), "required")).toBe(true);
    expect(shouldRefuseWith426(parseClientHeader("parent-app/0.1.0+2 (android)"), "recommended")).toBe(false);
  });

  it("claim 6 (server half) — the child agent is never refused, however old", () => {
    // A refused agent is an unmonitored phone: the pressure goes to the parent instead.
    expect(shouldRefuseWith426(parseClientHeader("child-android/0.1.0+1 (full)"), "required")).toBe(false);
    expect(shouldRefuseWith426(parseClientHeader("child-ios/0.0.1+1 (dev)"), "required")).toBe(false);
  });

  it("claim 7 (server half) — a legacy client is never refused", () => {
    expect(shouldRefuseWith426(null, "required")).toBe(false);
  });
});

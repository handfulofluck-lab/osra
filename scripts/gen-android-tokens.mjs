#!/usr/bin/env node
/**
 * Generates the child agent's Compose tokens from `docs/design/tokens.json` (roadmap 5.4, #728).
 *
 * Why generated rather than copied: the design file is the single source of the palette, radii, spacing,
 * sizes and type scale, and the Bureau reviews screens against it. A hand-kept Kotlin copy drifts the first
 * time a token changes, and nothing catches it — a wrong hex is not a compile error. **This script is the
 * guard**: `--check` exits 1 when `OsraTokens.kt` no longer matches the design file, and `workflow-lint` runs
 * it beside the other repository checks — so the drift is a red CI job rather than a wrong colour on a child's
 * phone. (There is no JVM test that re-parses the JSON: the earlier comment here named one, and it did not
 * exist — corrected after the #807 review.)
 *
 * Usage:
 *   node scripts/gen-android-tokens.mjs            # writes the file
 *   node scripts/gen-android-tokens.mjs --check    # exits 1 when the file is stale (CI-friendly)
 *
 * No dependencies: JSON.parse and string building only, so it runs in `workflow-lint` beside the other
 * repository checks.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(here, "..");
const TOKENS = resolve(ROOT, "docs/design/tokens.json");
const OUT = resolve(
  ROOT,
  "apps/child-android/app/src/main/java/com/familyshield/agent/ui/theme/OsraTokens.kt",
);

/** `#RRGGBB` (or `transparent`) to a Kotlin `Color(0xAARRGGBB)` literal. */
function colorLiteral(value) {
  if (value === "transparent") return "Color(0x00000000)";
  const m = /^#([0-9a-fA-F]{6})$/.exec(value);
  if (!m) throw new Error(`tokens.json: not a #RRGGBB colour: ${JSON.stringify(value)}`);
  return `Color(0xFF${m[1].toUpperCase()})`;
}

const camel = (s) => s.charAt(0).toLowerCase() + s.slice(1);

function render(tokens) {
  const colours = Object.entries(tokens.color);
  const radii = Object.entries(tokens.radius);
  const spaces = Object.entries(tokens.space);
  const sizes = Object.entries(tokens.size);
  const scale = Object.entries(tokens.type.scale);

  const paletteFields = colours.map(([k]) => `        val ${camel(k)}: Color,`).join("\n");
  const lightValues = colours
    .map(([k, v]) => `        ${camel(k)} = ${colorLiteral(v.light)},`)
    .join("\n");
  const darkValues = colours
    .map(([k, v]) => `        ${camel(k)} = ${colorLiteral(v.dark)},`)
    .join("\n");
  const lightUses = colours.map(([k, v]) => `     * - ${camel(k)}: ${v.use}`).join("\n");

  return `// GENERATED FILE — do not edit by hand.
// Source: docs/design/tokens.json (version ${tokens.version}).
// Generator: scripts/gen-android-tokens.mjs. Written for #728, so every screen after it (lock, block, SOS,
// ring, the PIN gate) has one theme rather than a colour chosen per screen.
//
// This file is checked, not trusted: scripts/gen-android-tokens.mjs --check fails when it no longer matches
// the design file, and workflow-lint runs that check — so a token change that does not reach Android is a red
// CI job, not a wrong colour on a phone.
package com.familyshield.agent.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object OsraTokens {

    /** One colour per name, in the two themes the design file defines. */
    data class Palette(
${paletteFields}
    )

    /** Corner radii. They differ per theme on purpose: dark surfaces read larger, so the design shrinks them. */
    data class Radii(${radii.map(([k]) => "val " + camel(k) + ": Dp").join(", ")})

    /** Spacing steps. */
    data class Spaces(${spaces.map(([k]) => "val " + camel(k) + ": Dp").join(", ")})

    /** Fixed sizes the screens share. */
    data class Sizes(${sizes.map(([k]) => "val " + camel(k) + ": Dp").join(", ")})

    /** One step of the type scale: size, line height and weight, as the design file states them. */
    data class TypeStyle(val sizeSp: Int, val lineSp: Int, val weight: Int)

    /**
     * The palette, light. The names and their use:
${lightUses}
     */
    val light = Palette(
${lightValues}
    )

    /** The palette, dark. Same names, the design file's dark column. */
    val dark = Palette(
${darkValues}
    )

    val lightRadii = Radii(${radii.map(([k, v]) => `${camel(k)} = ${v.light}.dp`).join(", ")})
    val darkRadii = Radii(${radii.map(([k, v]) => `${camel(k)} = ${v.dark}.dp`).join(", ")})

    val spaces = Spaces(${spaces.map(([k, v]) => `${camel(k)} = ${v}.dp`).join(", ")})

    val sizes = Sizes(${sizes.map(([k, v]) => `${camel(k)} = ${v}.dp`).join(", ")})

${scale
  .map(
    ([k, v]) =>
      `    /** ${v.size}/${v.line}, weight ${v.weight}. */\n    val ${camel(k)} = TypeStyle(sizeSp = ${v.size}, lineSp = ${v.line}, weight = ${v.weight})`,
  )
  .join("\n\n")}

    /** The two families; every step above is drawn in one of them (no system font, no system blue). */
    const val FONT_LATIN = "${tokens.type.family.latin}"
    const val FONT_ARABIC = "${tokens.type.family.arabic}"
}
`;
}

/**
 * The Kotlin has to compile, not merely match: a data class whose parameters lost their `val` still matches the
 * design file's values and still fails the build (#807 caught exactly that). This is the cheap half — every field
 * of the three dimension classes is declared `val`.
 */
function assertDeclarations(kotlin) {
  for (const name of ["Radii", "Spaces", "Sizes"]) {
    const marker = `data class ${name}(`;
    const at = kotlin.indexOf(marker);
    if (at < 0) throw new Error(`gen-android-tokens: data class ${name} not found in the output`);
    const params = kotlin.slice(at + marker.length, kotlin.indexOf(")", at + marker.length))
      .split(",")
      .map((p) => p.trim())
      .filter(Boolean);
    const bad = params.filter((p) => !p.startsWith("val "));
    if (bad.length > 0) throw new Error(`gen-android-tokens: ${name} has parameters without val: ${bad.join(", ")}`);
  }
}

const tokens = JSON.parse(readFileSync(TOKENS, "utf8"));
const wanted = render(tokens);
assertDeclarations(wanted);

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(OUT, "utf8").replace(/\r\n/g, "\n");
  } catch {
    console.error(`gen-android-tokens: ${OUT} is missing; run node scripts/gen-android-tokens.mjs`);
    process.exit(1);
  }
  if (current !== wanted) {
    console.error(
      "gen-android-tokens: the Kotlin tokens no longer match docs/design/tokens.json.\n" +
        "  Run: node scripts/gen-android-tokens.mjs",
    );
    process.exit(1);
  }
  console.log("gen-android-tokens: up to date");
  process.exit(0);
}

writeFileSync(OUT, wanted, "utf8");
console.log(`gen-android-tokens: wrote ${OUT.replace(ROOT + "/", "")}`);

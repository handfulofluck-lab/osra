const { appendFileSync, readFileSync } = require("node:fs");

const args = process.argv.slice(2);
if (process.env.FAKE_ADB_LOG) appendFileSync(process.env.FAKE_ADB_LOG, `${JSON.stringify(args)}\n`);
if (process.env.FAKE_ADB_EXIT) process.exit(Number(process.env.FAKE_ADB_EXIT));
if (args.includes("screencap") && process.env.FAKE_SCREENSHOT) {
  process.stdout.write(readFileSync(process.env.FAKE_SCREENSHOT));
} else if (args.includes("dumpsys") && args.includes("window")) {
  process.stdout.write(`mDreamingLockscreen=${process.env.FAKE_LOCKED === "1" ? "true" : "false"}\n`);
} else if (args.includes("trust")) {
  process.stdout.write(`device is ${process.env.FAKE_LOCKED === "1" ? "secure" : "not secure"}\n`);
} else if (args.includes("dumpsys") && args.includes("package")) {
  const flag = process.env.FAKE_BUILD_KIND === "test-only" ? "TEST_ONLY" : process.env.FAKE_BUILD_KIND === "debuggable" ? "DEBUGGABLE" : "";
  const name = args[args.indexOf("package") + 1] || "synthetic.package";
  process.stdout.write(`Package [${name}]\n  flags=[${flag}]\n`);
} else if (args.includes("dpm") && args.includes("list-owners")) {
  process.stdout.write(process.env.FAKE_ADMIN_PACKAGE ? `device admin: ${process.env.FAKE_ADMIN_PACKAGE}\n` : "");
} else if (args.includes("getprop") && args.includes("ro.product.model")) {
  process.stdout.write(`${process.env.FAKE_MODEL || "SM-F711B"}\n`);
} else if (args.includes("getprop") && args.includes("persist.sys.locale")) {
  process.stdout.write("en-US\n");
} else if (args.includes("settings") && args.includes("get")) {
  process.stdout.write(`synthetic-${args[args.indexOf("get") + 2] || "setting"}\n`);
} else if (args.includes("appops")) {
  process.stdout.write("SYSTEM_ALERT_WINDOW: allow\n");
} else {
  process.stdout.write("synthetic\n");
}

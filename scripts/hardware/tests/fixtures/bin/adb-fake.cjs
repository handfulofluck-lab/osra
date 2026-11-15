const { appendFileSync, readFileSync } = require("node:fs");

const args = process.argv.slice(2);
if (process.env.FAKE_ADB_LOG) appendFileSync(process.env.FAKE_ADB_LOG, `${JSON.stringify(args)}\n`);
if (process.env.FAKE_ADB_EXIT) process.exit(Number(process.env.FAKE_ADB_EXIT));
if (args.includes("screencap") && process.env.FAKE_SCREENSHOT) {
  process.stdout.write(readFileSync(process.env.FAKE_SCREENSHOT));
} else if (args.includes("dumpsys") && args.includes("window")) {
  process.stdout.write("mDreamingLockscreen=false\n");
} else if (args.includes("trust")) {
  process.stdout.write("device is secure\n");
} else {
  process.stdout.write("synthetic\n");
}

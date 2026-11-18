"""Extract the five catalogs from #883's comments into apps/child-ios (ADR-0042 step 2)."""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
CHILD = ROOT / "apps" / "child-ios"
comments = json.load(open(ROOT.parent / "tmp" / "c883.json", encoding="utf-8"))

SUMMARY = re.compile(r"<summary><code>([^<]+)</code>")

written = []
for comment in comments:
    body = comment["body"]
    if "<summary>" not in body:
        continue
    for block in re.finditer(
        r"<summary><code>(?P<path>[^<]+)</code>.*?```[a-z]*\n(?P<body>.*?)```", body, re.S
    ):
        path = SUMMARY.search(block.group(0)).group(1).strip()
        content = block.group("body")
        if path.startswith("Extensions/{"):
            for name in ("Monitor", "ShieldAction", "ShieldConfiguration"):
                written.append((path.replace("{Monitor,ShieldAction,ShieldConfiguration}", name), content))
        else:
            written.append((path, content))

if "--dry-run" in sys.argv:
    for path, content in written:
        print(f"{path}: {len(content.splitlines())} lines, first: {content.splitlines()[0][:80]!r}")
    sys.exit(0)

for path, content in written:
    target = CHILD / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8", newline="\n")
    print(f"wrote {path} ({len(content.splitlines())} lines)")

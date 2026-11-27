#!/bin/sh
# RS Extended Range songs (7- and 8-string guitar, 5- and 6-string bass charts) and stock ones: how their tunings
# are read and named, the same in native/rsfile.c (build/rstool), rig.py and app/Sources/Rig.swift. A few seconds:
#   - rig.py's names and low strings from synthetic tunings (6-string bass, 8-string drop E, stock drop D,
#     Eb standard, ...) and from an older index's lines (no tuningName or lowString),
#   - Rig.swift's rule on synthetic manifests (tests/rig_harness.swift),
#   - with the fixture packages (RS_FIXTURES, default ~/rs-gametest/fixtures: mac/*.psarc and pc/*.psarc):
#     `rstool tones` on both forms (tones, changes, tuning, strings, tuningPositional, lowString, tuningName for
#     every arrangement), the app's reading of the Mac ones, and index_songs.py + make_catalog.py on the Mac ones
#     in a temporary game and data folder. Skipped without the fixtures.
# Needs ./build.sh first. Your own data is not touched.
set -e
cd "$(dirname "$0")/.."
[ -x build/rstool ] || { echo "run ./build.sh first" >&2; exit 1; }
FIXTURES=${RS_FIXTURES:-$HOME/rs-gametest/fixtures}
DATA=$(mktemp -d /tmp/rsc.XXXXXX)
trap 'rm -rf "$DATA"' EXIT

echo "rig.py:"
python3 - <<'PY'
import sys
import rig
failures = 0
def check(ok, what):
    global failures
    if not ok:
        failures += 1
        print("FAIL:", what)
cases = [  # tuning, bass, strings -> name
    ([-2, 0, 0, 0, 0, 0], False, None, "Drop D"),
    ([-1, -1, -1, -1, -1, -1], False, None, "Eb standard"),
    ([-5, -3, -3, -3, -3, -3], False, None, "Drop B"),
    ([0, 0, 0, 0, 2, 0], False, None, "custom"),
    ([-2, 0, 0, 0, 5, 7], True, None, "Drop D"),
    ([-2, 0, 0, 0, 0, 0], False, 6, "Drop D"),             # a stock count is stock
    ([0, 0, 0, 0, 0, 0, 0], False, 7, "B standard (7-string)"),
    ([-2, 0, 0, 0, 0, 0, 0], False, 7, "Drop A (7-string)"),
    ([0] * 8, False, 8, "F# standard (8-string)"),
    ([-2, 0, 0, 0, 0, 0, 0, 0], False, 8, "Drop E (8-string)"),
    ([0, 0, 0, 0, 0, 0, -1, 0], False, 8, "custom (8-string)"),
    ([0] * 5, True, 5, "B standard (5-string)"),
    ([-2, 0, 0, 0, 0], True, 5, "Drop A (5-string)"),
    ([0] * 6, True, 6, "B standard (6-string)"),
    ([-2] * 6, True, 6, "A standard (6-string)"),
    (None, False, None, None),
]
for tuning, bass, strings, name in cases:
    got = rig.tuning_name(tuning, bass=bass, strings=strings)
    check(got == name, f"tuning_name({tuning}, bass={bass}, strings={strings}) = {got!r}, expected {name!r}")
check(rig.extended_base(7) == -5 and rig.extended_base(8) == -10 and rig.extended_base(6) == 0, "guitar bases")
check(rig.extended_base(5, bass=True) == -5 and rig.extended_base(6, bass=True) == -5
      and rig.extended_base(4, bass=True) == 0, "bass bases")
# rstool's fields win; an older index (six offsets only) is named and placed as before.
new = {"path": "Lead", "tuning": [0] * 6, "strings": 7, "lowString": -5, "tuningName": "B standard (7-string)"}
old = {"path": "Bass", "tuning": [-2, 0, 0, 0, 0, 0], "centOffset": -50}
check(rig.arrangement_tuning_name(new) == "B standard (7-string)", "tuningName used")
check(rig.low_string(new) == -5, "lowString used")
check(rig.arrangement_tuning_name(old) == "Drop D", "older index named from its offsets")
check(rig.low_string(old) == -2.5, "older index's low string")
check(rig.low_string({"path": "Vocals", "tuning": None, "lowString": None}) == 0, "unknown low string")
check(rig.arrangement_tuning_name({"path": "Vocals", "tuning": None, "tuningName": None}) is None, "unknown name")
print("  all checks passed" if not failures else f"  {failures} failed")
sys.exit(1 if failures else 0)
PY

echo "Rig.swift:"
clang -O1 -c native/rsfile.c -o "$DATA/rsfile.o"
swiftc -parse-as-library -import-objc-header app/Sources/rsfile-bridge.h tests/rig_harness.swift \
  app/Sources/Rig.swift app/Sources/Category.swift "$DATA/rsfile.o" -lz -o "$DATA/harness" 2>&1 | grep -v warning || true
harness() { status=0; "$DATA/harness" "$@" > "$DATA/harness.out" || status=$?; sed 's/^/  /' "$DATA/harness.out"; return $status; }
if [ ! -d "$FIXTURES/mac" ] || [ ! -d "$FIXTURES/pc" ]; then
  harness
  echo "fixture packages skipped: no $FIXTURES/mac and $FIXTURES/pc"
  exit 0
fi
harness "$FIXTURES/mac"

echo "rstool tones:"
for form in mac pc; do build/rstool tones "$FIXTURES/$form"/*.psarc > "$DATA/$form.jsonl"; done
python3 - "$DATA" <<'PY'
import json, sys
data = sys.argv[1]
failures = 0
def check(ok, what):
    global failures
    if not ok:
        failures += 1
        print("FAIL:", what)
SIX = [0] * 6
CDB = [-5, -3, -3, -3, -3, -3]
NB = "dellnickelbackburnittotheground7stringv23_"
ALT = [[127.711998, 0], [134.832993, 1]]
# arrangement -> tuning (stock six), strings, tuningPositional, lowString, tuningName, tone keys, changes
expected = {
    NB + "lead": (SIX, 7, [0] * 7, -5, "B standard (7-string)", ["Dis", "Filter"], [[127.711998, 0], [148.695999, 1]]),
    NB + "rhythm": (CDB, 6, None, -5, "Drop B", ["Dis", "Filter"], ALT),
    NB + "bass": (SIX, 5, [0] * 5, -5, "B standard (5-string)", ["bass_base"], []),
    "dellfearfactorysoulhacker8stringt2_lead": (SIX, 8, [0] * 8, -10, "F# standard (8-string)", ["Dis"], []),
    "delljinjerwallflower5stringbassv22_bass": (SIX, 5, [-2, 0, 0, 0, 0], -7, "Drop A (5-string)", ["bass_base"], []),
    "territorialspissings_lead": (SIX, 6, None, 0, "E standard", ["Territorial Pissings_clean",
                                  "Territorial Pissings_dist", "Territorial Pissings_flanger"],
                                  [[7.90299988, 0], [15.6029997, 1], [81.1940002, 2], [102.040001, 1]]),
    "territorialspissings_bass": (SIX, 4, None, 0, "E standard", ["Territorial Pissings_bass"], []),
    "gametestalternates_bass": (SIX, 4, None, 0, "E standard", ["Territorial Pissings_bass"], []),
}
for part in ("lead", "lead2", "lead3", "rhythm", "rhythm2", "rhythm3"):
    expected["gametestalternates_" + part] = (CDB, 6, None, -5, "Drop B", ["Dis", "Filter"], ALT)
for form in ("mac", "pc"):
    got = {}
    for line in open(f"{data}/{form}.jsonl"):
        a = json.loads(line)
        got[a["arrangement"]] = a
    for name, (tuning, strings, positional, low, tname, tones, changes) in expected.items():
        a = got.get(name)
        if not a:
            check(False, f"{form}: {name} missing")
            continue
        what = f"{form}: {name}"
        check(a["tuning"] == tuning, f"{what}: tuning {a['tuning']}")
        check(a["strings"] == strings, f"{what}: strings {a['strings']}")
        check(a.get("tuningPositional") == positional, f"{what}: tuningPositional {a.get('tuningPositional')}")
        check(a["lowString"] == low, f"{what}: lowString {a['lowString']}")
        check(a["tuningName"] == tname, f"{what}: tuningName {a['tuningName']}")
        check([t["key"] for t in a["tones"]] == tones, f"{what}: tones {[t['key'] for t in a['tones']]}")
        check(len(a["changes"]) == len(changes)
              and all(abs(x[0] - y[0]) < 1e-4 and x[1] == y[1] for x, y in zip(a["changes"], changes)),
              f"{what}: changes {a['changes']}")
        if form == "mac":
            print(f"  {name}: {a['tuningName']}, {a['strings']} strings, lowString {a['lowString']:g}, "
                  f"tuning {a['tuning']}" + (f", positional {a['tuningPositional']}" if "tuningPositional" in a else "")
                  + f", {len(a['tones'])} tones, {len(a['changes'])} changes")
    for name, a in got.items():
        if a["path"] == "Vocals":
            check(a["tuning"] is None and a["tuningName"] is None and a["lowString"] is None, f"{form}: {name} has a tuning")
        else:
            check(name in expected, f"{form}: {name} not expected")
print("  the same on the pc packages" if not failures else f"  {failures} failed")
sys.exit(1 if failures else 0)
PY

echo "index_songs.py and make_catalog.py:"
mkdir -p "$DATA/game/dlc" "$DATA/data"
cp "$FIXTURES"/mac/*.psarc "$FIXTURES"/pc/*.psarc "$DATA/game/dlc/"
RS_COMPANION_DATA="$DATA/data" python3 index_songs.py --game-dir "$DATA/game" 2>&1 | tail -1 | sed 's/^/  /'
RS_COMPANION_DATA="$DATA/data" python3 make_catalog.py | sed 's/^/  /'
python3 - "$DATA/data" "$(wc -l < "$DATA/mac.jsonl")" <<'PY'
import csv, json, sys
d, count = sys.argv[1], int(sys.argv[2])
failures = 0
index = [json.loads(l) for l in open(f"{d}/tones_index.jsonl")]
if not all(a["source"].endswith("_m.psarc") for a in index) or len(index) != count:
    failures += 1
    print(f"FAIL: index has {len(index)} arrangements: {sorted({a['source'] for a in index})}")
if json.load(open(f"{d}/index_cache.json"))["_format"] != 5:
    failures += 1
    print("FAIL: index format")
rows = {r["arrangement"]: r["tuning"] for r in csv.DictReader(open(f"{d}/songs.csv"))}
for name, tuning in {"dellnickelbackburnittotheground7stringv23_lead": "B standard (7-string)",
                     "dellnickelbackburnittotheground7stringv23_rhythm": "Drop B",
                     "dellnickelbackburnittotheground7stringv23_bass": "B standard (5-string)",
                     "dellfearfactorysoulhacker8stringt2_lead": "F# standard (8-string)",
                     "delljinjerwallflower5stringbassv22_bass": "Drop A (5-string)",
                     "territorialspissings_bass": "E standard"}.items():
    if rows.get(name) != tuning:
        failures += 1
        print(f"FAIL: songs.csv {name}: {rows.get(name)!r}, expected {tuning!r}")
print("  songs.csv tunings as rstool names them" if not failures else f"  {failures} failed")
sys.exit(1 if failures else 0)
PY
echo "all passed"

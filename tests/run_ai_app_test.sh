#!/bin/sh
# Test of the app's AI classification (app/Sources/AIClassifier.swift) and of how Presets.swift uses
# the answers, without OpenAI: tests/ai_harness.swift asks tests/stub_responses.py about Bon Jovi's
# "Livin' on a Prayer" (rules: Heavy, Metal) in a temporary data folder whose ai_suggestions.json
# remaps Bon Jovi Crunch -> Heavy. Expected: the request carries the key, the model, the prompt
# line and a strict schema; the answer (Classic rock, crunch) is saved; the song's Heavy tone becomes
# Crunch (", AI") and its style Classic rock, while another Bon Jovi song still goes by the
# artist-wide suggestion; rejecting the song brings back the rules, using it again the answer;
# a wrong key reports the API's message; a broken presets.json is reported, kept in use as last read
# and never saved over, until it is fixed. A few seconds.
set -e
cd "$(dirname "$0")/.."
DATA=$(mktemp -d /tmp/rsc.XXXXXX)
SERVER=
trap 'kill $SERVER 2>/dev/null || true; wait $SERVER 2>/dev/null || true; rm -rf "$DATA"' EXIT
cp presets.default.json "$DATA/presets.json"
echo '{"artists": {"Bon Jovi": {"Crunch": "Heavy"}}, "song_styles": {}}' > "$DATA/ai_suggestions.json"
clang -O1 -c native/rsfile.c -o "$DATA/rsfile.o"
swiftc -parse-as-library -import-objc-header app/Sources/rsfile-bridge.h tests/ai_harness.swift \
  app/Sources/AIClassifier.swift app/Sources/Presets.swift app/Sources/Category.swift app/Sources/Rig.swift \
  "$DATA/rsfile.o" -lz -o "$DATA/harness" 2>&1 | grep -v warning || true
PORT=$((20000 + $$ % 20000))
python3 tests/stub_responses.py $PORT "$DATA/requests.jsonl" & SERVER=$!
sleep 1
"$DATA/harness" "$DATA" "http://127.0.0.1:$PORT/v1/responses" > "$DATA/out.txt"
sed 's/^/  /' "$DATA/out.txt"
python3 - "$DATA" <<'PY'
import json, sys
sys.path.insert(0, ".")
from classify_songs import SYSTEM
data = sys.argv[1]
out = dict(l.split(": ", 1) for l in open(f"{data}/out.txt").read().splitlines())
reqs = [json.loads(l) for l in open(f"{data}/requests.jsonl")]
fail = []
def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    ok or fail.append(what)
b = reqs[0]["body"]
check(reqs[0]["auth"] == "Bearer sk-test", "request sends the key")
check(b["model"] == "test-model" and b["reasoning"] == {"effort": "low"}, "model and low effort")
check(b["text"]["format"]["type"] == "json_schema" and b["text"]["format"]["strict"], "strict JSON schema")
check(b["text"]["format"]["schema"]["properties"]["songs"]["items"]["properties"]["style"]["enum"]
      == ["Soft", "Classic rock", "Metal"], "styles from presets.json in the schema")
check(out["line"] in b["input"] and out["line"] ==
      "BonJoviPrayer | Bon Jovi - Livin' on a Prayer | E standard, 123 bpm | heaviness 0.81, rules say Metal | "
      "tones: 1 Crunch, 2 Heavy | amps: MarshallJCM800", "prompt line as classify_songs.py writes it")
check(b["instructions"] == SYSTEM, "same instructions as classify_songs.py")
saved = json.load(open(f"{data}/ai_classified.json"))["bonjoviprayer"]
check(saved["style"] == "Classic rock" and saved["model"] == "test-model", f"answer saved: {saved}")
check(out["before"] == "Heavy (name)", f"before: {out['before']}")
check(out["after"] == "Crunch (name, AI)", f"after: {out['after']}")
check(out["other song by artist (suggestions)"] == "Heavy (name)",
      f"other Bon Jovi song keeps Heavy (Crunch->Heavy suggestion doesn't touch it): {out['other song by artist (suggestions)']}")
check(out["style"] == "Classic rock" and out["style without ai"] == "Metal", "style from the answer")
check(out["rejected"] == "Heavy (name)" and out["style rejected"] == "Metal", "rejected: rules again")
check(out["used again"] == "Crunch (name, AI)", "used again: answer again")
check("Incorrect API key" in out.get("bad key", ""), f"wrong key: {out.get('bad key')}")
check(out["broken error"].startswith("presets.json is not valid JSON"), f"broken presets.json reported: {out['broken error']}")
check(out["broken file kept"] == "true", "broken presets.json not overwritten by a reject or an override")
check(out["broken mapping"] == "Crunch (name, AI)", f"the last mapping read stays in use: {out['broken mapping']}")
check(out["fixed error"] == "none" and out["fixed override"] == "Clean (song override)",
      f"fixed: saving works again: {out['fixed override']}")
check(json.load(open(f"{data}/presets.json")).get("ai_rejected") is None, "ai_rejected removed when empty")
sys.exit(1 if fail else 0)
PY

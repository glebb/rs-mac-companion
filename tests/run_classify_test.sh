#!/bin/sh
# Test of classify_songs.py without the API: tests/stub_openai stands in for the openai
# package and answers by artist (Bon Jovi and AC/DC Classic rock with crunch, Slayer Metal with
# heavy, Eagles a low-confidence guess). Uses the Bon Jovi, AC/DC, Slayer and Eagles songs from
# your song index (run index_songs.py first) in a temporary data folder. Expected: the model is
# asked once per batch with a JSON schema, Bon Jovi and AC/DC get Heavy -> Crunch, Slayer gets no
# Heavy -> Crunch, nothing is suggested for the Eagles, a second run asks nothing and suggests the
# same, presets.json is not changed, and presets.py uses the suggestions (reason "AI") after your
# own artists entry. Then --redo --limit 1 asks about one song again and keeps every other answer,
# including one RS Companion saved for a song that isn't in the index.
set -e
cd "$(dirname "$0")/.."
INDEX="${RS_COMPANION_DATA:-$HOME/Library/Application Support/rs-mac-companion}/tones_index.jsonl"
[ -f "$INDEX" ] || { echo "no song index at $INDEX (run index_songs.py)" >&2; exit 1; }
DATA=$(mktemp -d /tmp/rsc.XXXXXX)
trap 'rm -rf "$DATA"' EXIT
grep -E '"artist": "(Bon Jovi|AC/DC|Slayer|Eagles)"' "$INDEX" > "$DATA/tones_index.jsonl"
python3 - "$DATA/presets.json" <<'PY'
import json, sys
d = json.load(open("presets.default.json"))
d["artists"] = {"AC/DC": {"Lead": "Crunch"}}  # yours: wins over the suggestions
json.dump(d, open(sys.argv[1], "w"))
PY
run() { RS_COMPANION_DATA="$DATA" STUB_LOG="$DATA/requests.jsonl" OPENAI_API_KEY=stub PYTHONPATH=tests/stub_openai python3 classify_songs.py --batch 40 "$@"; }

cp "$DATA/presets.json" "$DATA/presets.before"
run
REQUESTS=$(wc -l < "$DATA/requests.jsonl")
cp "$DATA/ai_suggestions.json" "$DATA/suggestions.first"
run
RS_COMPANION_DATA="$DATA" python3 - "$DATA" "$REQUESTS" <<'PY'
import json, sys
sys.path.insert(0, ".")
data, first = sys.argv[1], int(sys.argv[2])
fail = []
def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    ok or fail.append(what)
reqs = [json.loads(l) for l in open(f"{data}/requests.jsonl")]
songs = {json.loads(l)["songKey"].lower() for l in open(f"{data}/tones_index.jsonl") if '"Vocals"' not in l}
check(first == -(-len(songs) // 40), f"first run: one request per 40 songs ({first} for {len(songs)})")
check(len(reqs) == first, "second run asks nothing")
check(all(r["model"] == "gpt-6-luna" and r["text"]["format"]["type"] == "json_schema"
          and r["text"]["format"]["strict"] for r in reqs), "gpt-6-luna with a strict JSON schema")
check(len(json.load(open(f"{data}/ai_classified.json"))) == len(songs), "every song answered")
s = json.load(open(f"{data}/ai_suggestions.json"))
check(s["artists"].get("Bon Jovi") == {"Heavy": "Crunch"}, f"Bon Jovi Heavy -> Crunch: {s['artists'].get('Bon Jovi')}")
check(s["artists"].get("AC/DC", {}).get("Heavy") == "Crunch", f"AC/DC Heavy -> Crunch: {s['artists'].get('AC/DC')}")
check("Heavy" not in s["artists"].get("Slayer", {}), f"Slayer keeps Heavy: {s['artists'].get('Slayer')}")
check("Eagles" not in s["artists"] and "Eagles" not in s["song_styles"]
      and not any(r["artist"] == "Eagles" for r in s["_songs"]), "low confidence (Eagles) suggests nothing")
check(json.load(open(f"{data}/suggestions.first")) == s, "second run suggests the same (rules compared without the AI)")
check(open(f"{data}/presets.json").read() == open(f"{data}/presets.before").read(), "presets.json not changed")
from presets import Presets
p = Presets()
hit = p.get("", "", "riff_dist", [], artist="AC/DC")
check(p.category(hit[0]) == "Crunch" and hit[1].endswith(", AI"), f"AC/DC dist tone -> Crunch by AI: {hit}")
lead = p.get("", "", "x", ["LEAD"], artist="AC/DC")
check(lead[1].endswith(", artist AC/DC"), f"your AC/DC Lead entry wins: {lead}")
plain = Presets(ai_path=None).get("", "", "riff_dist", [], artist="AC/DC")
check(p.category(plain[0]) == "Heavy", f"without the suggestions AC/DC stays Heavy: {plain}")
print(f"suggested styles: {s['song_styles']}")
sys.exit(1 if fail else 0)
PY

# --redo --limit 1: one song asked again; the others, and an answer the app saved, stay.
python3 - "$DATA/ai_classified.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
a[sorted(a)[0]]["reason"] = "old"
a["appsong"] = {"style": "Soft", "distortion": "none", "confidence": "high", "reason": "from the app", "song_key": "AppSong"}
json.dump(a, open(sys.argv[1], "w"))
PY
cp "$DATA/ai_classified.json" "$DATA/classified.before"
BEFORE=$(wc -l < "$DATA/requests.jsonl")
run --redo --limit 1
python3 - "$DATA" "$BEFORE" <<'PY'
import json, sys
data, before = sys.argv[1], int(sys.argv[2])
fail = []
def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    ok or fail.append(what)
old, new = json.load(open(f"{data}/classified.before")), json.load(open(f"{data}/ai_classified.json"))
first = sorted(k for k in old if k != "appsong")[0]
check(sum(1 for _ in open(f"{data}/requests.jsonl")) == before + 1, "--redo --limit 1: one request")
check(new[first]["reason"] == "stub", f"--redo --limit 1: {first} asked again")
check(set(new) == set(old) and all(new[k] == old[k] for k in old if k != first),
      f"--redo --limit 1: the other {len(old) - 1} answers stay, the app's included")
sys.exit(1 if fail else 0)
PY

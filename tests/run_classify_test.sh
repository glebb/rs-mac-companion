#!/bin/sh
# Test of classify_songs.py without the API: tests/stub_openai stands in for the openai
# package and answers by artist (Bon Jovi and AC/DC Classic rock with crunch, Slayer Metal with
# heavy, Eagles a low-confidence guess). Uses the Bon Jovi, AC/DC, Slayer and Eagles songs from
# your song index (run index_songs.py first) in a temporary data folder. Expected: the model is
# asked once per batch with a JSON schema, Bon Jovi and AC/DC get Heavy -> Crunch, Slayer gets no
# Heavy -> Crunch, nothing is suggested for the Eagles, a second run asks nothing, and --apply
# keeps an artist entry that is already in presets.json.
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
d["artists"] = {"AC/DC": {"Lead": "Crunch"}}  # yours: --apply must keep it
json.dump(d, open(sys.argv[1], "w"))
PY
run() { RS_COMPANION_DATA="$DATA" STUB_LOG="$DATA/requests.jsonl" OPENAI_API_KEY=stub PYTHONPATH=tests/stub_openai python3 classify_songs.py --batch 40 "$@"; }

run
REQUESTS=$(wc -l < "$DATA/requests.jsonl")
run --apply
python3 - "$DATA" "$REQUESTS" <<'PY'
import json, sys
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
p = json.load(open(f"{data}/presets.json"))
check(p["artists"]["AC/DC"] == {"Lead": "Crunch"}, "--apply keeps your AC/DC entry")
check(p["artists"].get("Bon Jovi") == {"Heavy": "Crunch"}, "--apply adds Bon Jovi")
print(f"suggested styles: {s['song_styles']}")
sys.exit(1 if fail else 0)
PY

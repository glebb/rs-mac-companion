"""Where things live. The project folder holds only code, docs and defaults; everything generated
from your machine (song index, catalogs, your preset mapping, logs) goes to DATA_DIR."""
import json
import os
import shutil

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD_DIR = os.path.join(ROOT, "build")
RSPROBE = os.path.join(BUILD_DIR, "rsprobe")
RSTOOL = os.path.join(BUILD_DIR, "rstool")

DATA_DIR = os.environ.get("RS_COMPANION_DATA",
                          os.path.expanduser("~/Library/Application Support/rs-mac-companion"))
INDEX = os.path.join(DATA_DIR, "tones_index.jsonl")
INDEX_CACHE = os.path.join(DATA_DIR, "index_cache.json")
PRESETS = os.path.join(DATA_DIR, "presets.json")
AI_SUGGESTIONS = os.path.join(DATA_DIR, "ai_suggestions.json")  # artist-wide, from classify_songs.py
AI_CLASSIFIED = os.path.join(DATA_DIR, "ai_classified.json")    # one answer per song, from the app and classify_songs.py
LOG = os.path.join(DATA_DIR, "rstone.log")
SONGS_CSV = os.path.join(DATA_DIR, "songs.csv")
TONE_CATALOG_CSV = os.path.join(DATA_DIR, "tone_catalog.csv")

GAME_DIR = os.environ.get("RS_GAME_DIR",
                          os.path.expanduser("~/Library/Application Support/Steam/steamapps/common/Rocksmith2014"))
GAME_EXECUTABLE = os.path.join(GAME_DIR, "Rocksmith2014.app", "Contents", "MacOS", "Rocksmith2014")


def ensure_data_dir():
    """Create the data folder and seed the preset mapping from the project default."""
    os.makedirs(DATA_DIR, exist_ok=True)
    if not os.path.exists(PRESETS):
        shutil.copy(os.path.join(ROOT, "presets.default.json"), PRESETS)


def game_profile():
    """Values tied to one specific Rocksmith build; see docs/when-the-game-updates.md."""
    with open(os.path.join(ROOT, "game_profile.json")) as f:
        p = json.load(f)
    return {k: int(v, 16) if isinstance(v, str) and v.startswith("0x") else v for k, v in p.items()}

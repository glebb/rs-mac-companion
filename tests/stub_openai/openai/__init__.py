"""Stand-in for the openai package for tests/run_classify_test.sh: answers from the artist in
each prompt line instead of calling the API, and records the requests it got."""
import json
import os
from types import SimpleNamespace

ANSWERS = {  # artist -> (style, distortion, confidence)
    "Bon Jovi": ("Classic rock", "crunch", "high"),
    "AC/DC": ("Classic rock", "crunch", "high"),
    "Slayer": ("Metal", "heavy", "high"),
    "Eagles": ("Soft", "none", "low"),
}


class RateLimitError(Exception): pass
class APIConnectionError(Exception): pass
class InternalServerError(Exception): pass


class _Responses:
    def create(self, model, instructions, input, reasoning, text):
        log = os.environ.get("STUB_LOG")
        if log:
            with open(log, "a") as f:
                f.write(json.dumps({"model": model, "text": text}) + "\n")
        songs = []
        for line in input.splitlines():
            parts = line.split(" | ")
            if len(parts) < 5:
                continue
            artist = parts[1].split(" - ")[0]
            style, distortion, confidence = ANSWERS.get(artist, ("Classic rock", "crunch", "low"))
            songs.append({"song_key": parts[0], "style": style, "distortion": distortion,
                          "confidence": confidence, "reason": "stub"})
        return SimpleNamespace(status="completed", incomplete_details=None,
                               output_text=json.dumps({"songs": songs}))


class OpenAI:
    def __init__(self, **kwargs):
        self.responses = _Responses()

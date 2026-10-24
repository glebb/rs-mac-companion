"""Stand-in for OpenAI's Responses API for tests/run_ai_app_test.sh: answers every song key in the
prompt with Classic rock / crunch (high), records each request body to argv[2], and answers key
sk-bad with a 401 like the real API. Prints its port."""
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps({"auth": self.headers["Authorization"], "body": body}) + "\n")
        if self.headers["Authorization"] == "Bearer sk-bad":
            out, code = {"error": {"message": "Incorrect API key provided"}}, 401
        else:
            keys = [line.split(" | ")[0] for line in body["input"].splitlines() if line.count(" | ") >= 4]
            songs = [{"song_key": k, "style": "Classic rock", "distortion": "crunch", "confidence": "high",
                      "reason": "stub"} for k in keys]
            text = json.dumps({"songs": songs})
            out, code = {"status": "completed", "output": [
                {"type": "reasoning", "summary": []},
                {"type": "message", "content": [{"type": "output_text", "text": text}]}]}, 200
        data = json.dumps(out).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.serve_forever()

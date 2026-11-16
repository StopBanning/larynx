"""A stand-in for the Anthropic Messages API on 127.0.0.1:8765, for CI: records the request it gets (argv[1]) and
answers with fixed notes in the structured-output shape. No key, no network, no cost."""
import http.server, json, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with open(sys.argv[1], "w", encoding="utf-8") as f:
            json.dump({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body}, f, indent=1)
        notes = {"title": "Renovation schedule", "summary": ["The kitchen is on track and the tile is back-ordered."],
                 "decisions": ["Keep the upgraded faucets."],
                 "actionItems": [{"task": "Send photos of the two tiles in stock", "owner": "Priya", "due": "tonight"}],
                 "openQuestions": ["Whether the electrician can come before the twelfth."]}
        out = json.dumps({"type": "message", "stop_reason": "end_turn", "content": [{"type": "text", "text": json.dumps(notes)}]}).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(out)))
        self.end_headers(); self.wfile.write(out)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()

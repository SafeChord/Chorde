"""Stand-in for the Kubernetes and GitHub APIs that scan.sh calls (Chorde#56, #58).

scan.sh talks to it through the real curl, so it meets real HTTP answers and
real connection failures. Time is the fake clock in $STUB_DIR/clock, which the
test's `sleep` stub advances and its `date` stub reads: an hour of retries
takes no real time.

Each GitHub call is told apart by its path:

  token   POST /app/installations/<id>/access_tokens
  head    GET  /repos/<owner>/<repo>/commits/<branch>
  upload  POST /repos/<owner>/<repo>/code-scanning/sarifs
  status  GET  /repos/<owner>/<repo>/code-scanning/sarifs/<id>
  pods    GET  /api/v1/pods                  (the Kubernetes API)

As GitHub does, the token call checks the App JWT (signature, iat, exp) and
answers 401 to one that has expired; the other calls answer 401 to an
installation token past its expires_at.

Behaviour, from the environment:

  STUB_DIR             where the clock is read and everything is recorded
  STUB_APP_KEY         the App's private key; the JWT must verify against it
  STUB_PODS            pod list to serve (default $FIX/pods.json)
  STUB_PODS_HTTP       status to answer the pod list with instead
  STUB_UPLOAD_HTTP     status to answer the upload with (default 202)
  STUB_PENDING_POLLS   answered polls that say "pending" first (default 1)
  STUB_STATUS          processing_status after them (default complete)
  STUB_ERRORS          errors after them (default null)
  STUB_FAULTS          JSON, per call, what fails before the call is served:
                         {"upload": {"seq": [502, 429, "drop", 503]}}
                           the first requests fail in turn, then it is served
                         {"upload": {"for": 1800, "with": 503}}
                           every request fails until 1800 s of fake time
                           have passed since this call's first request
                         {"upload": {"with": 502}}
                           every request fails, for good
                       A fault is an HTTP status; "drop": the connection
                       is closed with no answer (curl: "Empty reply from
                       server"); or "hang": the request is read and never
                       answered, the connection held open until the client
                       gives up on it (Chorde#58).
  STUB_SLOW            JSON, per call, how slowly a served request is taken
                       in, in real time (Chorde#58):
                         {"upload": {"read_bps": 32768, "answer_after": 10}}
                           the body is read at read_bps bytes a second, and
                           the answer sent answer_after seconds later

The fake clock is advanced by the real time a request is held (a hang, or a
slow request), so time a request spends unanswered counts as it does on the
real clock.

Recorded in $STUB_DIR:

  port           the port it listens on, once it does
  requests.log   one line per request:
                 <fake time> <call> <method> <path> <bearer token or -> <answer>
  upload.json    the body of the last upload request that was read
  polls          how many status requests were answered past their faults
"""

import base64
import datetime
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STUB_DIR = os.environ["STUB_DIR"]
FIX = os.environ.get("FIX", "")
APP_KEY = os.environ.get("STUB_APP_KEY", "")
FAULTS = json.loads(os.environ.get("STUB_FAULTS") or "{}")
SLOW = json.loads(os.environ.get("STUB_SLOW") or "{}")

LOCK = threading.Lock()
SEEN = {}  # call -> {"first": fake time of first request, "n": requests}
TOKENS = {}  # token -> expiry, fake epoch seconds
POLLS = [0]

GITHUB_ERRORS = {
    429: {"message": "API rate limit exceeded for installation.",
          "documentation_url": "https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"},
    500: {"message": "Server Error"},
    502: {"message": "Server Error"},
    503: {"message": "Service Unavailable"},
    504: {"message": "We couldn't respond to your request in time. Sorry about that. Please try resubmitting your request and contact us if the problem persists."},
    413: {"message": "Request Entity Too Large"},
    422: {"message": "Validation Failed", "status": "422"},
    404: {"message": "Not Found", "status": "404"},
}


def now():
    with open(os.path.join(STUB_DIR, "clock")) as f:
        return float(f.read().strip())


def advance(seconds):
    """Move the fake clock forward by the real seconds a request was held."""
    clock = os.path.join(STUB_DIR, "clock")
    with LOCK:
        t = now() + seconds
        with open(clock + ".stub", "w") as f:
            f.write("%.3f\n" % t)
        os.rename(clock + ".stub", clock)


def iso(t):
    return datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_problem(jwt, t):
    """Why GitHub would refuse this App JWT at fake time t, or None."""
    parts = jwt.split(".")
    if len(parts) != 3:
        return "A JSON web token could not be decoded"
    try:
        claims = json.loads(b64url_decode(parts[1]))
        signature = b64url_decode(parts[2])
    except Exception:
        return "A JSON web token could not be decoded"
    if APP_KEY:
        sig_file = os.path.join(STUB_DIR, "jwt.sig")
        with open(sig_file, "wb") as f:
            f.write(signature)
        pub = subprocess.run(["openssl", "rsa", "-in", APP_KEY, "-pubout"],
                             capture_output=True, check=True).stdout
        pub_file = os.path.join(STUB_DIR, "app.pub")
        with open(pub_file, "wb") as f:
            f.write(pub)
        ok = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub_file, "-signature", sig_file],
                            input=(parts[0] + "." + parts[1]).encode(), capture_output=True)
        if ok.returncode != 0:
            return "A JSON web token could not be decoded"
    try:
        iat, exp = int(claims["iat"]), int(claims["exp"])
    except Exception:
        return "'Issued at' claim ('iat') must be an Integer representing the time that the assertion was issued."
    if iat > t + 60:
        return "'Issued at' claim ('iat') must be an Integer representing the time that the assertion was issued."
    if exp <= t:
        return "'Expiration time' claim ('exp') must be a numeric value representing the future time at which the assertion expires."
    if exp - t > 600:
        return "'Expiration time' claim ('exp') is too far in the future."
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def classify(self):
        path = self.path.split("?")[0]
        if self.command == "GET" and path == "/api/v1/pods":
            return "pods"
        if self.command == "POST" and re.fullmatch(r"/app/installations/[^/]+/access_tokens", path):
            return "token"
        if self.command == "GET" and re.fullmatch(r"/repos/[^/]+/[^/]+/commits/[^/]+", path):
            return "head"
        if self.command == "POST" and re.fullmatch(r"/repos/[^/]+/[^/]+/code-scanning/sarifs", path):
            return "upload"
        if self.command == "GET" and re.fullmatch(r"/repos/[^/]+/[^/]+/code-scanning/sarifs/[^/]+", path):
            return "status"
        return "unexpected"

    def bearer(self):
        auth = self.headers.get("Authorization", "")
        return auth[len("Bearer "):] if auth.startswith("Bearer ") else ""

    def record(self, call, t, answer):
        token = self.bearer()
        shown = token if token.startswith("ghs_") else ("jwt" if token else "-")
        with LOCK, open(os.path.join(STUB_DIR, "requests.log"), "a") as f:
            f.write(f"{int(t)} {call} {self.command} {self.path} {shown} {answer}\n")

    def answer(self, call, t, status, body, headers=None):
        self.record(call, t, status)
        data = (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def drop(self, call, t):
        self.record(call, t, "drop")
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def hang(self, call, t):
        """Read the request, never answer; hold the connection until the client closes it."""
        self.record(call, t, "hang")
        self.close_connection = True
        started = time.monotonic()
        self.connection.settimeout(0.05)
        while True:
            try:
                if not self.connection.recv(1, socket.MSG_PEEK):
                    break
                time.sleep(0.05)
            except socket.timeout:
                continue
            except OSError:
                break
        advance(time.monotonic() - started)

    def read_body(self, call):
        length = int(self.headers.get("Content-Length") or 0)
        rate = (SLOW.get(call) or {}).get("read_bps")
        if not length:
            return b""
        if not rate:
            return self.rfile.read(length)
        body = b""
        while len(body) < length:
            chunk = self.rfile.read(min(int(rate) // 10 or 1, length - len(body)))
            if not chunk:
                break
            body += chunk
            time.sleep(0.1)
        return body

    def fault(self, call, t):
        """The fault this request meets, or None."""
        with LOCK:
            seen = SEEN.setdefault(call, {"first": t, "n": 0})
            seen["n"] += 1
            n, first = seen["n"], seen["first"]
        spec = FAULTS.get(call)
        if not spec:
            return None
        if "seq" in spec:
            return spec["seq"][n - 1] if n <= len(spec["seq"]) else None
        if "for" in spec and t - first >= spec["for"]:
            return None
        return spec["with"]

    def serve(self):
        t = now()
        call = self.classify()
        started = time.monotonic()
        body = self.read_body(call)
        if call == "unexpected":
            return self.answer(call, t, 404, {"message": "Not Found"})
        if call == "upload":
            with open(os.path.join(STUB_DIR, "upload.json"), "wb") as f:
                f.write(body)

        fault = self.fault(call, t)
        if fault == "drop":
            return self.drop(call, t)
        if fault == "hang":
            return self.hang(call, t)
        if fault is not None:
            headers = {"Retry-After": "60"} if fault == 429 else None
            return self.answer(call, t, int(fault), GITHUB_ERRORS.get(int(fault), {"message": "error"}), headers)

        delay = (SLOW.get(call) or {}).get("answer_after")
        if delay:
            time.sleep(float(delay))
        if call in SLOW:
            advance(time.monotonic() - started)

        if call == "pods":
            if os.environ.get("STUB_PODS_HTTP"):
                return self.answer(call, t, int(os.environ["STUB_PODS_HTTP"]), {"kind": "Status"})
            with open(os.environ.get("STUB_PODS") or os.path.join(FIX, "pods.json")) as f:
                return self.answer(call, t, 200, f.read())

        if call == "token":
            problem = jwt_problem(self.bearer(), t)
            if problem:
                return self.answer(call, t, 401, {"message": problem,
                                                  "documentation_url": "https://docs.github.com/rest"})
            with LOCK:
                token = f"ghs_stub_{len(TOKENS) + 1}"
                TOKENS[token] = t + 3600
            return self.answer(call, t, 201, {
                "token": token,
                "expires_at": iso(t + 3600),
                "permissions": {"metadata": "read", "security_events": "write"},
                "repository_selection": "selected",
            })

        expiry = TOKENS.get(self.bearer())
        if expiry is None or t >= expiry:
            return self.answer(call, t, 401, {"message": "Bad credentials",
                                              "documentation_url": "https://docs.github.com/rest",
                                              "status": "401"})

        if call == "head":
            return self.answer(call, t, 200, {"sha": "0123456789abcdef0123456789abcdef01234567"})
        if call == "upload":
            status = int(os.environ.get("STUB_UPLOAD_HTTP") or 202)
            if status >= 400:
                return self.answer(call, t, status, GITHUB_ERRORS.get(status, {"message": "error"}))
            return self.answer(call, t, status, {"id": "sarif-1", "url": "https://api.github.com/x"})
        if call == "status":
            with LOCK:
                n = POLLS[0]
                POLLS[0] += 1
                with open(os.path.join(STUB_DIR, "polls"), "w") as f:
                    f.write(str(POLLS[0]))
            if n < int(os.environ.get("STUB_PENDING_POLLS") or 1):
                return self.answer(call, t, 200, {"processing_status": "pending"})
            return self.answer(call, t, 200, '{"processing_status":"%s","errors":%s}' % (
                os.environ.get("STUB_STATUS") or "complete", os.environ.get("STUB_ERRORS") or "null"))

    do_GET = serve
    do_POST = serve


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        print(f"api_stub: error serving {client_address}", file=sys.stderr)


def main():
    server = Server(("127.0.0.1", 0), Handler)
    port_file = os.path.join(STUB_DIR, "port")
    with open(port_file + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.rename(port_file + ".tmp", port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()

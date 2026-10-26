#!/usr/bin/env bash
# Tests for bin/session-hibernate. Standalone — no root, no network, no Docker.
# Usage: bash test/session-hibernate.test.sh
#
# The real CLI is replaced by a fake one (python) that speaks just enough
# stream-json: it answers control requests, runs a "turn" per user message and
# logs its argv and pid. The driver plays the extension's side of the pipe.
# Every "stays awake" case is the defect this wrapper could cause — killing a
# session mid-work — so each one is asserted on the fake CLI still running,
# not on what the wrapper says.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
HIB="${HIB:-$REPO/bin/session-hibernate}"

W=$(mktemp -d) && [ -d "$W" ] || { echo "$(basename "$0"): mktemp failed" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

cat > "$W/fake-cli" <<'PY'
#!/usr/bin/env python3
import json, os, sys
log = open(os.environ["FAKE_LOG"], "a", buffering=1)
args = sys.argv[1:]
sid = next((a.split("=", 1)[1] for a in args if a.startswith("--resume=")), os.environ.get("FAKE_SID", "s-new"))
log.write(json.dumps({"ev": "start", "pid": os.getpid(), "argv": args}) + "\n")
def out(m):
    sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
waiting = None
for line in sys.stdin:
    m = json.loads(line)
    t = m.get("type")
    if t == "control_request" and m["request"]["subtype"] == "never_answered":
        continue
    if t == "control_request":
        out({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"], "response": {"pid": os.getpid()}}})
        continue
    if t == "control_response" and waiting:
        out({"type": "result", "subtype": "success", "session_id": sid}); waiting = None
        continue
    if t != "user":
        continue
    text = m["message"]["content"]
    log.write(json.dumps({"ev": "user", "pid": os.getpid(), "text": text}) + "\n")
    if text == "crash":
        sys.exit(3)
    out({"type": "system", "subtype": "init", "session_id": sid})
    if text == "bg":
        out({"type": "system", "subtype": "background_tasks_changed", "tasks": [{"task_id": "t1", "task_type": "local_bash"}], "session_id": sid})
    if text == "bgdone":
        out({"type": "system", "subtype": "background_tasks_changed", "tasks": [], "session_id": sid})
    if text == "hang":
        continue
    if text == "perm":
        out({"type": "control_request", "request_id": "p1", "request": {"subtype": "can_use_tool"}})
        waiting = "p1"
        continue
    out({"type": "assistant", "session_id": sid, "message": {"content": [{"type": "text", "text": "resume=" + (next((a for a in args if a.startswith("--resume=")), "none"))}]}})
    out({"type": "result", "subtype": "success", "session_id": sid})
log.write(json.dumps({"ev": "exit", "pid": os.getpid()}) + "\n")
PY
chmod +x "$W/fake-cli"

cat > "$W/drive.py" <<'PY'
import json, os, queue, subprocess, sys, threading, time

HIB, W = sys.argv[1], sys.argv[2]
FAKE = os.path.join(W, "fake-cli")
SESSION = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--permission-mode", "auto"]
PASS = FAIL = 0

def ok(name):
    global PASS; PASS += 1; print("  ✔ " + name)

def ko(name, actual, expected):
    global FAIL; FAIL += 1
    print("  ❌ " + name); print("      expected: %s" % expected); print("      actual:   %s" % actual)

def check(name, cond, actual, expected):
    ok(name) if cond else ko(name, actual, expected)

def alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().split(")")[-1].split()[0] != "Z"
    except OSError:
        return False

class Run:
    def __init__(self, tag, extra_args=(), **env):
        self.log = os.path.join(W, tag + ".log")
        e = dict(os.environ, FAKE_LOG=self.log, HIBERNATE_ENV_FILE="/nonexistent",
                 HIBERNATE_IDLE_MIN="0.03", HIBERNATE_FRESH_IDLE_MIN="0.02", HIBERNATE_POLL_S="0.1",
                 HIBERNATE_MEM_LOW_MB="0", HIBERNATE_LOG="1", HIBERNATE_LOG_DIR=os.path.join(W, tag + "-hib"))
        e.update(env)
        self.p = subprocess.Popen([HIB, FAKE] + SESSION + list(extra_args), stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=e)
        self.q = queue.Queue()
        self.seen = []
        threading.Thread(target=self.pump, daemon=True).start()
        self.rid = 0

    def pump(self):
        for line in iter(self.p.stdout.readline, b""):
            self.q.put(json.loads(line))

    def send(self, m):
        self.p.stdin.write((json.dumps(m) + "\n").encode()); self.p.stdin.flush()

    def request(self, subtype):
        self.rid += 1
        self.send({"type": "control_request", "request_id": "r%d" % self.rid, "request": {"subtype": subtype}})

    def user(self, text):
        self.send({"type": "user", "uuid": "u-" + text, "session_id": "", "parent_tool_use_id": None, "message": {"role": "user", "content": text}})

    def wait_for(self, pred, timeout=5):
        end = time.time() + timeout
        for m in self.seen:
            if pred(m):
                return m
        while time.time() < end:
            try:
                m = self.q.get(timeout=0.05)
            except queue.Empty:
                continue
            self.seen.append(m)
            if pred(m):
                return m
        return None

    def drain(self, secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                self.seen.append(self.q.get(timeout=0.05))
            except queue.Empty:
                pass

    def events(self, ev=None):
        try:
            with open(self.log) as f:
                rows = [json.loads(l) for l in f]
        except OSError:
            return []
        return [r for r in rows if ev is None or r["ev"] == ev]

    def cli_pids(self):
        return [r["pid"] for r in self.events("start")]

    def informs(self):
        return [m for m in self.seen if m.get("subtype") == "informational"]

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            return self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.kill(); return None

is_result = lambda m: m.get("type") == "result"
is_init_resp = lambda m: m.get("type") == "control_response" and m["response"]["request_id"] == "r1"

print("== passthrough: a call that is not a session is exec'd into the CLI")
log = os.path.join(W, "pass.log")
p = subprocess.Popen([HIB, FAKE, "auth", "status", "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, env=dict(os.environ, FAKE_LOG=log))
p.wait(timeout=5)
starts = [json.loads(l) for l in open(log)]
check("same pid (exec, no proxy)", starts and starts[0]["pid"] == p.pid, starts and starts[0]["pid"], p.pid)
check("argv untouched", starts and starts[0]["argv"] == ["auth", "status", "--json"], starts and starts[0]["argv"], ["auth", "status", "--json"])

print("== fresh session: sleeps after the short delay, wakes on the first message")
r = Run("fresh")
r.request("initialize")
check("initialize answered", r.wait_for(is_init_resp) is not None, "no answer", "control_response r1")
first = r.cli_pids()[0]
r.drain(2.5)
check("CLI stopped after FRESH_IDLE_MIN", not alive(first), "still running", "stopped")
check("wrapper still alive (pipe kept open)", r.p.poll() is None, r.p.poll(), "running")
check("no message in an empty conversation", r.informs() == [], r.informs(), [])
r.user("hello")
check("first message answered after wake", r.wait_for(is_result) is not None, "no result", "result")
pids = r.cli_pids()
check("a second CLI was launched", len(pids) == 2 and alive(pids[1]), pids, "2 pids, last alive")
n_init = sum(1 for m in r.seen if is_init_resp(m))
check("initialize answered once, the replay swallowed", n_init == 1, n_init, 1)
check("message reached the new CLI", [e["text"] for e in r.events("user")] == ["hello"], r.events("user"), ["hello"])

print("== used session: sleeps after IDLE_MIN with a notice, resumes the same session")
r.drain(3)
check("CLI stopped after IDLE_MIN", not alive(pids[1]), "still running", "stopped")
notes = [m for m in r.informs() if "asleep" in m["content"] or "sleep" in m["content"]]
check("sleep notice shown", len(notes) == 1 and notes[0]["level"] == "notice", r.informs(), "one notice")
check("notice carries the session id", notes and notes[0]["session_id"] == "s-new", notes and notes[0].get("session_id"), "s-new")
r.seen = [m for m in r.seen if m.get("type") not in ("result", "assistant")]
r.user("again")
res = r.wait_for(lambda m: m.get("type") == "assistant")
argv = r.events("start")[-1]["argv"]
check("relaunched with --resume=<session id>, once", argv.count("--resume=s-new") == 1, argv, "--resume=s-new once")
check("original args kept", argv[:len(SESSION)] == SESSION, argv, SESSION)
woke = [m for m in r.informs() if "woken" in m["content"]]
check("wake notice shown", len(woke) == 1 and woke[0]["level"] == "notice", r.informs(), "one wake notice")
check("no informational at level info", all(m["level"] in ("notice", "warning") for m in r.informs()), [m["level"] for m in r.informs()], "notice|warning")
rc = r.close()
check("channel closed while awake -> exit 0", rc == 0, rc, 0)

print("== never sleeps with a background task running")
r = Run("bg")
r.request("initialize"); r.wait_for(is_init_resp)
r.user("bg"); r.wait_for(is_result)
pid = r.cli_pids()[0]
r.drain(3)
check("CLI kept with a background task", alive(pid), "stopped", "running")
r.user("bgdone"); r.drain(3)
check("CLI stopped once the task ended", not alive(pid), "running", "stopped")
r.close()

print("== never sleeps with a permission prompt pending")
r = Run("perm")
r.request("initialize"); r.wait_for(is_init_resp)
r.user("perm")
r.wait_for(lambda m: m.get("type") == "control_request")
pid = r.cli_pids()[0]
r.drain(3)
check("CLI kept while the prompt is unanswered", alive(pid), "stopped", "running")
r.send({"type": "control_response", "response": {"subtype": "success", "request_id": "p1", "response": {"behavior": "allow"}}})
check("turn ends after the answer", r.wait_for(is_result) is not None, "no result", "result")
r.drain(3)
check("CLI stopped after the turn", not alive(pid), "running", "stopped")
r.close()

print("== never sleeps with a request to the CLI unanswered")
r = Run("pending")
r.request("initialize"); r.wait_for(is_init_resp)
r.request("never_answered")
pid = r.cli_pids()[0]
r.drain(3)
check("CLI kept while its answer is awaited", alive(pid), "stopped", "running")
r.close()

print("== HIBERNATE_KEEP and a running turn keep the CLI")
r = Run("keep", ["--resume=s-keep"], HIBERNATE_KEEP="other,s-keep")
r.request("initialize"); r.wait_for(is_init_resp)
pid = r.cli_pids()[0]
r.drain(3)
check("listed session kept", alive(pid), "stopped", "running")
r.close()
r = Run("turn")
r.request("initialize"); r.wait_for(is_init_resp)
r.user("hang")
pid = r.cli_pids()[0]
r.drain(3)
check("CLI kept while a turn runs", alive(pid), "stopped", "running")
r.close()

print("== low memory: warns at launch and sleeps without waiting")
r = Run("mem", ["--resume=s-mem"], HIBERNATE_MEM_LOW_MB="99999999", HIBERNATE_IDLE_MIN="60", HIBERNATE_FRESH_IDLE_MIN="60")
r.request("initialize"); r.wait_for(is_init_resp)
pid = r.cli_pids()[0]
r.drain(1.5)
warns = [m for m in r.informs() if m["level"] == "warning"]
check("memory warning shown", len(warns) == 1 and "Memory is low" in warns[0]["content"], r.informs(), "one warning")
check("idle session put to sleep at once", not alive(pid), "running", "stopped")
r.close()

print("== observe mode: logs, never stops the CLI")
r = Run("observe", HIBERNATE_OBSERVE="1")
r.request("initialize"); r.wait_for(is_init_resp)
pid = r.cli_pids()[0]
r.drain(2.5)
check("CLI kept in observe mode", alive(pid), "stopped", "running")
hlog = os.path.join(W, "observe-hib")
evs = [json.loads(l)["event"] for f in os.listdir(hlog) for l in open(os.path.join(hlog, f))]
check("would_sleep logged once", evs.count("would_sleep") == 1, evs.count("would_sleep"), 1)
r.close()

print("== the CLI's own exit is passed on")
r = Run("crash")
r.request("initialize"); r.wait_for(is_init_resp)
r.user("crash")
try:
    rc = r.p.wait(timeout=5)
except subprocess.TimeoutExpired:
    rc = None
check("wrapper exits with the CLI's code", rc == 3, rc, 3)

print("\n%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY

python3 "$W/drive.py" "$HIB" "$W"

#!/usr/bin/env python3
"""agent-sidebar: exercise the control socket of a running Ghostty fork.

    ci-socket-test.py [socket-path]

Without an argument it uses $GHOSTTY_AGENT_SOCKET or the default location of
the debug and release apps. Prints every response; exits non-zero when a
check fails. Used by ci-screenshots.sh, and handy on a Mac to see whether the
socket works.
"""
import glob, json, os, socket, sys, tempfile, threading, time


def find_socket():
    if len(sys.argv) > 1:
        return sys.argv[1]
    if os.environ.get("GHOSTTY_AGENT_SOCKET"):
        return os.environ["GHOSTTY_AGENT_SOCKET"]
    for base in (tempfile.gettempdir(), "/tmp"):
        found = sorted(glob.glob(os.path.join(base, f"ghostty-agent-{os.getuid()}", "*.sock")))
        if found:
            # Prefer the debug app: that is what CI launches.
            return next((p for p in found if p.endswith(".debug.sock")), found[0])
    sys.exit("no control socket found")


PATH = find_socket()
failures = []


def call(method, params=None):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(PATH)
    s.sendall((json.dumps({"method": method, "params": params or {}}) + "\n").encode())
    line = s.makefile("r").readline()
    s.close()
    return json.loads(line)


def show(title, response, limit=700):
    text = json.dumps(response, ensure_ascii=False)
    print(f"== {title}\n{text[:limit]}{' …' if len(text) > limit else ''}")


def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


print("socket:", PATH)
info = call("info")
show("info", info)
check("info answers", info.get("ok") is True and info["result"].get("backend") == "ghostty")

for method in ("list_windows", "list_tabs", "list_panes", "active_pane"):
    show(method, call(method))
panes = call("list_panes")
pane_list = panes.get("result", {}).get("panes", [])
check("list_panes returns the terminal", len(pane_list) >= 1 and bool(pane_list[0].get("session_id")))
shell = pane_list[0]["session_id"] if pane_list else ""
check("pane has a tty and a stable tab id", bool(pane_list and pane_list[0].get("tty") and pane_list[0].get("stable_tab_id")))

context = call("pane_context", {"max_lines": 4, "max_chars": 300})
show("pane_context", context)
check("pane_context returns terminal text", bool(context.get("result", {}).get("content")))

if pane_list:
    by_tty = call("pane_by_tty", {"tty": pane_list[0]["tty"]})
    check("pane_by_tty finds the same pane", by_tty.get("result", {}).get("session_id") == shell)

# Event stream.
events = []
subscriber = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
subscriber.connect(PATH)
subscriber.sendall(b'{"method":"subscribe"}\n')
stream = subscriber.makefile("r")
check("subscribe is acknowledged", '"ok":true' in stream.readline().replace(" ", ""))


def read_events():
    for line in stream:
        events.append(json.loads(line))


threading.Thread(target=read_events, daemon=True).start()

split = call("split_pane", {"target": shell, "direction": "right", "command": "/bin/sh -c 'echo split-ok; sleep 60'"})
show("split_pane", split)
created = split.get("result", {}).get("session_id", "")
check("split_pane creates a pane", bool(created))
time.sleep(2)
check("the new pane is listed", any(p["session_id"] == created for p in call("list_panes")["result"]["panes"]))
captured = call("capture_pane", {"target": created, "max_lines": 5})
show("capture_pane (new pane)", captured)
check("the new pane ran its command", "split-ok" in captured.get("result", {}).get("content", ""))

sent = call("send_text", {"target": shell, "text": "typed-by-socket"})
show("send_text", sent)
time.sleep(1)
check("send_text reaches the shell pane", "typed-by-socket" in call("capture_pane", {"target": shell, "max_lines": 5})["result"]["content"])

published = {"type": "event", "method": "autofix_state",
             "params": {"state": "review", "pane_id": shell, "summary": "ci", "tab_id": pane_list[0]["stable_tab_id"] if pane_list else ""}}
call("publish", {"event": published})
time.sleep(1)
check("published events reach subscribers", published in events)
print("events:", json.dumps(events)[:500])

closed = call("kill_pane", {"target": created})
time.sleep(1)
check("kill_pane closes the pane", closed.get("ok") is True and not any(
    p["session_id"] == created for p in call("list_panes")["result"]["panes"]))
unknown = call("no_such_method")
check("unknown methods are rejected", unknown.get("ok") is False)

print("RESULT:", "all checks passed" if not failures else f"{len(failures)} failed: {failures}")
sys.exit(1 if failures else 0)

#!/usr/bin/env python3
"""End-to-end smoke test of the dsh ACP server (newline-delimited JSON-RPC over stdio)."""
import json
import os
import subprocess
import sys
import threading
import time

REPO = "/Users/miao/deepseek-harness"
WORKSPACE = os.path.expanduser("~/whale-pet/workspace")
os.makedirs(WORKSPACE, exist_ok=True)

key = ""
with open(os.path.expanduser("~/.whalepet.conf")) as f:
    for line in f:
        if line.startswith("DEEPSEEK_API_KEY="):
            key = line.strip().split("=", 1)[1]

env = dict(os.environ, DEEPSEEK_API_KEY=key, PATH=os.environ.get("PATH", ""))
proc = subprocess.Popen(
    ["pnpm", "run", "demo:acp"],
    cwd=REPO, env=env,
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, bufsize=1,
)

rpc_id = 0
pending = {}
lock = threading.Lock()
events = {}
replies = []
done = threading.Event()

def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            print("[non-json stdout]", line[:120], flush=True)
            continue
        if "id" in msg and ("result" in msg or "error" in msg):
            with lock:
                pending[msg["id"]] = msg
                ev = events.get(msg["id"])
            if ev:
                ev.set()
        elif msg.get("method") == "session/update":
            u = msg["params"]["update"]
            if u.get("sessionUpdate") == "agent_message_chunk":
                replies.append(u["content"].get("text", ""))
                print("[chunk]", u["content"].get("text", "")[:80], flush=True)
            else:
                print("[update]", u.get("sessionUpdate"), flush=True)
        elif msg.get("method") == "session/request_permission":
            # auto-allow first option
            rid = msg["id"]
            opt = msg["params"]["options"][0]
            print("[permission] auto-allow:", msg["params"].get("toolCall", {}).get("title", "?"), flush=True)
            send_response(rid, {"outcome": {"outcome": "selected", "optionId": opt["optionId"]}})
        else:
            print("[notify]", msg.get("method"), flush=True)

def send_response(rid, result):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    proc.stdin.flush()

def call(method, params, timeout=180):
    global rpc_id
    rpc_id += 1
    ev = threading.Event()
    with lock:
        events[rpc_id] = ev
        pending[rpc_id] = None
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rpc_id, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    if not ev.wait(timeout):
        raise TimeoutError(method)
    with lock:
        msg = pending[rpc_id]
    if "error" in msg:
        raise RuntimeError(f"{method}: {msg['error']}")
    return msg["result"]

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=lambda: [print("[stderr]", l.rstrip()[:200], flush=True) for l in proc.stderr], daemon=True).start()

print("== initialize", flush=True)
r = call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
print(json.dumps(r, ensure_ascii=False)[:300], flush=True)

print("== session/new", flush=True)
r = call("session/new", {"cwd": WORKSPACE, "mcpServers": []})
sid = r["sessionId"]
print("sessionId:", sid, flush=True)

prompt_text = sys.argv[1] if len(sys.argv) > 1 else "你好！用一句话介绍你自己，再说说你能做什么。"
print("== session/prompt:", prompt_text, flush=True)
t0 = time.time()
r = call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": prompt_text}]}, timeout=600)
print(f"stopReason: {r.get('stopReason')}  ({time.time()-t0:.1f}s)", flush=True)
print("== full reply:", flush=True)
print("".join(replies), flush=True)

proc.terminate()

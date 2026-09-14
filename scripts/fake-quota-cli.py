#!/usr/bin/python3
"""Offline fixtures: fail on unexpected commands, sessions or prompts."""
import json
import os
import sys
import time

args = sys.argv[1:]
mode = os.environ.get("QUOTA_FIXTURE", "normal")
framed = "--headless" in args
gemini = "--screen-reader" in args
if gemini:
    assert args == ["--screen-reader", "--skip-trust", "--model", "auto"]
    print("Type your message", flush=True)
    assert sys.stdin.readline().strip() == "/stats"
    print("Session tokens: 99% used", flush=True)
    assert sys.stdin.readline().strip() == "/stats model"
    print("Signed in with Google (fixture@example.invalid)\n87% used (Limit resets in 2h 10m)\nUsage limit: 100\nUsage limits span all sessions and reset daily.", flush=True)
    time.sleep(10)
    sys.exit(0)
assert args == (["--headless", "--stdio", "--no-auto-update"] if framed else ["agent", "stdio"])


def read():
    if not framed:
        return json.loads(sys.stdin.buffer.readline())
    header = sys.stdin.buffer.readline()
    assert header.startswith(b"Content-Length:")
    assert sys.stdin.buffer.readline() == b"\r\n"
    return json.loads(sys.stdin.buffer.read(int(header.split(b":")[1])))


def send(obj):
    payload = json.dumps(obj).encode()
    packet = b"Content-Length: %d\r\n\r\n" % len(payload) + payload if framed else payload + b"\n"
    for i in range(0, len(packet), 7):
        sys.stdout.buffer.write(packet[i:i + 7])
        sys.stdout.buffer.flush()
        time.sleep(0.0005)


expected = ["auth.getStatus", "account.getQuota"] if framed else ["initialize", "_x.ai/auth/info", "_x.ai/billing"]
for method in expected:
    request = read()
    assert request["method"] == method
    if mode == "timeout":
        time.sleep(60)
    if mode == "unsupported":
        send({"id": request["id"], "error": {"code": -32601, "message": "Unsupported method"}})
        continue
    send({"method": "status.changed", "params": {}})
    # A quota reader must reject reverse requests, never execute them.
    send({"id": "reverse", "method": "fs/read_text_file", "params": {}})
    refusal = read()
    assert refusal["id"] == "reverse" and refusal["error"]["code"] == -32601
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {}}
    elif method == "_x.ai/auth/info":
        result = {"email": "fixture@example.invalid", "principalId": "fixture-user", "organizationId": "fixture-org"}
    elif method == "auth.getStatus":
        result = {"isAuthenticated": mode != "loggedout", "login": "fixture-user", "host": "github.com"}
    elif method == "_x.ai/billing":
        result = {"subscription_tier": "SuperGrok", "config": {"creditUsagePercent": 87, "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2030-01-01T00:00:00Z"}}}
    else:
        result = {"quotaSnapshots": {"premium_interactions": {"remainingPercentage": 13, "resetDate": "2030-01-01T00:00:00Z"}}}
    send({"id": request["id"], "result": result})

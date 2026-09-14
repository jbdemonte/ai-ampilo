#!/usr/bin/python3
"""Offline app-server fixture. CODEX_HOME basename chooses the failure scenario."""
import json
import os
from pathlib import Path
import sys
import time

fixtures = Path(__file__).resolve().parent.parent / "Tests/AIUsageCoreTests/Fixtures"
mode = Path(os.environ.get("CODEX_HOME", "normal")).name
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"userAgent": "fake-codex", "codexHome": os.environ.get("CODEX_HOME")}
    elif method == "account/read":
        result = json.loads((fixtures / "codex_account.json").read_text())
        if mode == "missing":
            result["account"] = None
        if mode == "apiKey":
            result["account"] = {"type": "apiKey"}
    else:
        if mode == "timeout":
            time.sleep(60)
        if mode == "exit":
            sys.exit(3)
        if mode == "error":
            print(json.dumps({"id": request["id"], "error": {"code": -1, "message": "Network unavailable"}}), flush=True)
            continue
        result = json.loads((fixtures / "codex_rateLimits.json").read_text())
    # Notifications and stderr must never be interpreted as the requested response.
    print(json.dumps({"method": "remoteControl/status/changed", "params": {"ignored": True}}), flush=True)
    sys.stderr.write("diagnostic suppressed\n")
    sys.stderr.flush()
    response = json.dumps({"id": request["id"], "result": result}) + "\n"
    if mode == "chunks":
        for i in range(0, len(response), 11):
            sys.stdout.write(response[i:i + 11])
            sys.stdout.flush()
            time.sleep(0.001)
    else:
        sys.stdout.write(response)
        sys.stdout.flush()

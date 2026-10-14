#!/usr/bin/env python3
"""Populate a running island with realistic demo sessions (stand-in agent processes live 20 min)."""
import subprocess, json, os, time
H = os.path.expanduser("~/Library/Application Support/AgentIsland/bin/island-hook")
FX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../fixtures/claude/")
procs = [subprocess.Popen(["sleep", "1200"]) for _ in range(4)]
cwds = ["/Users/ab/code/agent-island", "/Users/ab/code/payments-api", "/Users/ab/code/website", "/Users/ab/code/infra"]
def fire(name, i, patch={}):
    p = json.load(open(FX + name + ".json"))["payload"]
    p.update(session_id=f"demo-{i}", cwd=cwds[i]); p.update(patch)
    subprocess.run([H, "claude"], input=json.dumps(p).encode(), env=dict(os.environ, CLAUDE_PID=str(procs[i].pid)))
fire("UserPromptSubmit", 0); fire("PreToolUse-Bash", 0, {"tool_name": "Edit", "tool_input": {"file_path": "/x/src/auth.ts"}})
fire("PreToolUse-Agent", 0); fire("SubagentStart", 0); fire("PreToolUse-Bash-subagent", 0)
fire("UserPromptSubmit", 1); fire("PreToolUse-Bash", 1, {"tool_input": {"command": "npm test -- --watch=false"}})
fire("UserPromptSubmit", 2); fire("Stop", 2)
fire("SessionStart", 3)
now = int(time.time())
subprocess.run([H, "statusline"], input=json.dumps({"rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": now + 8040}, "seven_day": {"used_percentage": 91, "resets_at": now + 3 * 86400}}}).encode())

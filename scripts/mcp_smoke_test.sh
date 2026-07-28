#!/bin/bash
# MCP server 冒烟测试：app 必须已运行。用法：./scripts/mcp_smoke_test.sh [端口]
set -euo pipefail
PORT="${1:-8787}"
URL="http://127.0.0.1:${PORT}/mcp"

call() {
    curl -sS -X POST "$URL" -H 'Content-Type: application/json' -d "$1"
}

echo "== initialize =="
call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | python3 -m json.tool

echo "== notifications/initialized（应无输出体） =="
call '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "== tools/list =="
call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
tools = r["result"]["tools"]
assert len(tools) == 9, f"期望 9 个工具，实际 {len(tools)}"
print("工具:", ", ".join(t["name"] for t in tools))'

echo "== list_projects =="
call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}' | python3 -m json.tool

echo "== create_project（冒烟专用项目） =="
call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"MCP冒烟测试"}}}' | python3 -m json.tool

echo "== 错误路径：不存在的项目 =="
call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_project","arguments":{"project_id":"00000000-0000-0000-0000-000000000000"}}}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["result"]["isError"] is True
body = json.loads(r["result"]["content"][0]["text"])
assert body["code"] == "PROJECT_NOT_FOUND", body
print("PROJECT_NOT_FOUND ✓")'

echo "== 错误路径：非法方法 =="
call '{"jsonrpc":"2.0","id":6,"method":"resources/list"}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["error"]["code"] == -32601, r
print("-32601 ✓")'

echo "全部冒烟通过 ✓"

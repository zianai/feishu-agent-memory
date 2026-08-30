#!/usr/bin/env bash
# 巡检沉淀：扫描「会话状态」表中待沉淀的会话，逐个 prepare → LLM → commit。
# 适合 cron 驱动（config.env 配 LLM_CMD）；agent 在场时也可手动调用。
# 用法: memory-consolidate.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

pending="$(mem_search "$MEM_TBL_SESSION" \
  "{\"logic\":\"or\",\"conditions\":[[\"状态\",\"==\",\"待沉淀\"],[\"状态\",\"==\",\"沉淀中\"]]}" "" 50 \
  "会话ID" "状态")" || pending=""

chats="$(printf '%s' "$pending" | "$MEM_PY" -c "
import sys, json
$mem_norm_cell_py
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    c = norm(pick(r, '会话ID'))
    if c: print(c)
")" || chats=""

if [ -z "$chats" ]; then
  mem_info "没有待沉淀的会话"
  exit 0
fi

rc=0
while IFS= read -r chat; do
  [ -n "$chat" ] || continue
  mem_info "—— 沉淀会话 $chat"
  bash "$MEM_LIB_DIR/memory-judge.sh" prepare --chat-id "$chat" || { rc=1; continue; }
  dir="$MEM_WORK_DIR/$chat"
  if [ -n "$LLM_CMD" ]; then
    eval "llm_cmd=\"$LLM_CMD\""
    bash -c "$llm_cmd" < "$dir/judge-request.txt"  > "$dir/judge-response.json" || { rc=1; continue; }
    bash -c "$llm_cmd" < "$dir/summary-request.txt" > "$dir/summary.txt"        || { rc=1; continue; }
    bash "$MEM_LIB_DIR/memory-judge.sh" commit --chat-id "$chat" \
      --response "$dir/judge-response.json" --summary-file "$dir/summary.txt" || rc=1
  else
    mem_info "未配置 LLM_CMD：请把 $dir/judge-request.txt 交给任意 LLM，"
    mem_info "将严格 JSON 存为 $dir/judge-response.json，摘要存为 $dir/summary.txt，然后执行："
    mem_info "  memory-judge.sh commit --chat-id $chat --response $dir/judge-response.json --summary-file $dir/summary.txt"
    rc=1
  fi
done <<< "$chats"
exit $rc

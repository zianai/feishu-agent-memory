#!/usr/bin/env bash
# 读链路：召回 短期消息 + 会话摘要 + 用户画像 + Agent 经验
# 用法: memory-recall.sh --chat-id oc_xxx [--user-id ou_xxx] [--agent-id main]
#                        [--query "用户问题"] [--picked "U12,A7"]
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

chat=""; user=""; agent="$MEM_AGENT_ID"; query="(未提供)"; picked=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chat-id)  chat="$2";  shift 2;;
    --user-id)  user="$2";  shift 2;;
    --agent-id) agent="$2"; shift 2;;
    --query)    query="$2"; shift 2;;
    --picked)   picked="$2"; shift 2;;
    *) mem_info "忽略未知参数 $1"; shift;;
  esac
done
[ -n "$chat" ] || { echo "用法: memory-recall.sh --chat-id oc_xxx [--user-id ou_xxx] [--agent-id main] [--query ...] [--picked U12,A7]" >&2; exit 2; }

echo "===SHORT_TERM==="
st="$(mem_fetch_messages "$chat" "$MEM_SHORT_TERM_MSGS" | "$MEM_PY" -c "
import sys, json
items = [json.loads(l) for l in sys.stdin if l.strip()]
items.reverse()   # 拉取为新→旧，输出按时间正序
print('\n'.join(i['line'] for i in items))
")" || st=""
[ -n "$st" ] && printf '%s\n' "$st" || echo "(无近期消息或拉取失败——降级：仅用记忆回答)"

echo "===SUMMARY==="
srecs="$(mem_search "$MEM_TBL_SESSION" "{\"logic\":\"and\",\"conditions\":[[\"会话ID\",\"==\",\"$chat\"]]}" "" 1 "会话ID" "滚动摘要")" || srecs=""
sum="$(printf '%s' "$srecs" | "$MEM_PY" -c "
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
v = recs[0].get('滚动摘要') if recs and isinstance(recs[0], dict) else None
if isinstance(v, list): v = ''.join(str(x) for x in v)
print((v or '').strip())
")" || sum=""
[ -n "$sum" ] && printf '%s\n' "$sum" || echo "(尚无会话摘要)"

echo "===USER_MEMORIES==="
um_lines=""
if [ -n "$user" ]; then
  urecs="$(mem_search "$MEM_TBL_USER" \
    "{\"logic\":\"and\",\"conditions\":[[\"用户ID\",\"==\",\"$user\"],[\"状态\",\"==\",\"active\"]]}" \
    "[{\"field\":\"重要度\",\"desc\":true}]" "$MEM_CAND_TOP_K" "记忆ID" "分类" "重要度" "记忆内容")" || urecs=""
  um_lines="$(printf '%s' "$urecs" | mem_render_memories "U" "$MEM_CLIP_CHARS" "$MEM_USER_BUDGET_CHARS")" || um_lines=""
fi
[ -n "$um_lines" ] && printf '%s\n' "$um_lines" || echo "(无该用户画像，或未提供 --user-id)"

echo "===AGENT_MEMORIES==="
arecs="$(mem_search "$MEM_TBL_AGENT" \
  "{\"logic\":\"and\",\"conditions\":[[\"Agent ID\",\"==\",\"$agent\"],[\"状态\",\"==\",\"active\"]]}" \
  "[{\"field\":\"重要度\",\"desc\":true}]" "$MEM_CAND_TOP_K" "记忆ID" "经验类型" "重要度" "经验内容")" || arecs=""
am_lines="$(printf '%s' "$arecs" | mem_render_memories "A" "$MEM_CLIP_CHARS" "$MEM_AGENT_BUDGET_CHARS")" || am_lines=""
[ -n "$am_lines" ] && printf '%s\n' "$am_lines" || echo "(无 Agent 经验)"

if [ -n "$picked" ]; then
  echo "===MEMORY_PICKED==="
  printf '%s\n%s\n' "$um_lines" "$am_lines" | "$MEM_PY" -c "
import sys, re
def canon(s):          # U007/U7 → U7：记忆ID带前导零，比较前归一化
    m = re.match(r'([UA])0*(\d+)$', s.strip().upper())
    return m.group(1) + m.group(2) if m else s
want = {canon(w) for w in '''$picked'''.replace('，', ',').split(',') if w.strip()}
for l in sys.stdin:
    m = re.match(r'\[([UA]\d+)\]', l.strip().upper())
    if m and canon(m.group(1)) in want: sys.stdout.write(l)
"
else
  echo "===REFINE_REQUEST==="
  cands="$(printf '## 用户画像候选\n%s\n\n## Agent经验候选\n%s' "${um_lines:-（无）}" "${am_lines:-（无）}")"
  mem_render_prompt "$MEM_SKILL_DIR/prompts/refine.txt" "query=$query" "candidates=$cands"
  echo ""
  echo "（把 REFINE_REQUEST 交给 LLM 得到 {\"relevant\":[\"U12\",\"A7\"]}，再用 --picked U12,A7 重跑本脚本）"
fi

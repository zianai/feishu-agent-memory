#!/usr/bin/env bash
# agent-memory 端到端测试矩阵（真实 Base，自隔离、自清理、可重复执行）
# 用法: tests/e2e-test.sh [--keep]    # --keep 保留测试数据便于人工到 Base 里查看
# 说明: 测试数据用专用会话 ID（tm*）与假用户 ID（ou_test_*），不触碰业务记忆；
#       正常结束自动删除本轮写入的记录。用例清单见 docs/test-matrix.md
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../scripts/_lib.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
TS="$(date +%m%d%H%M%S)"
C1="tm${TS}c1"; C2="tm${TS}c2"
UA="ou_test_user_a"; UB="ou_test_user_b"; UC="ou_test_user_c"; UD="ou_test_user_d"
WD="$MEM_WORK_DIR/tm$TS"; mkdir -p "$WD"
PASS=0; FAIL=0; FAILED=()

check() { # <用例名> <期望包含> <实际输出>
  if printf '%s' "$3" | grep -qF -- "$2"; then PASS=$((PASS+1)); echo "  ✓ $1";
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  ✗ $1";
    echo "    期望含: $2"; echo "    实际: $(printf '%s' "$3" | tr '\n' ' ' | head -c 260)"; fi
}
check_absent() { # <用例名> <不应包含> <实际输出>
  if printf '%s' "$3" | grep -qF -- "$2"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  ✗ $1（不应出现: $2）";
  else PASS=$((PASS+1)); echo "  ✓ $1"; fi
}
recall() { bash "$SCRIPT_DIR/../scripts/memory-recall.sh" "$@" 2>&1; }
commit() { # <chat> <user> <resp-file> [extra...]
  local chat="$1" user="$2" resp="$3"; shift 3
  mkdir -p "$MEM_WORK_DIR/$chat"
  printf '{"chat_id":"%s","user_id":"%s","agent_id":"main","lines":3}' "$chat" "$user" > "$MEM_WORK_DIR/$chat/meta.json"
  bash "$SCRIPT_DIR/../scripts/memory-judge.sh" commit --chat-id "$chat" --user-id "$user" --response "$resp" "$@" 2>&1
}
memjson() { # <python表达式:记忆数组> <输出文件>
  "$MEM_PY" -c "
import json
memories = $1
print(json.dumps({'memories': memories}, ensure_ascii=False))" > "$2"
}
midof() { # <scope> <content> → 记忆ID 数字部分（按内容哈希反查）
  local tbl="$MEM_TBL_USER"; [ "$1" = agent ] && tbl="$MEM_TBL_AGENT"
  local h; h="$(mem_md5 "$1:$2")"
  mem_search "$tbl" "{\"logic\":\"and\",\"conditions\":[[\"内容哈希\",\"==\",\"$h\"]]}" "" 1 "记忆ID" \
    | "$MEM_PY" -c "
import sys, json, re
try: recs = json.load(sys.stdin)
except Exception: recs = []
v = (recs[0].get('记忆ID') if recs and isinstance(recs[0], dict) else None) or ''
m = re.search(r'\d+', str(v)); print(m.group(0) if m else '')"
}
recfields() { # <scope> <content> → 摘要字符串，未命中输出 MISSING
  local tbl="$MEM_TBL_USER"; [ "$1" = agent ] && tbl="$MEM_TBL_AGENT"
  local h; h="$(mem_md5 "$1:$2")"
  mem_search "$tbl" "{\"logic\":\"and\",\"conditions\":[[\"内容哈希\",\"==\",\"$h\"]]}" "" 1 \
    "分类" "经验类型" "重要度" "置信度" "状态" "证据原文" "置换为" "记忆内容" "经验内容" \
    | "$MEM_PY" -c "
import sys, json
def norm(v):
    if v is None: return ''
    if isinstance(v,(int,float)): return str(v)
    if isinstance(v,list): return ''.join(str(x.get('text') or x.get('name') or x) if isinstance(x,dict) else str(x) for x in v)
    if isinstance(v,dict): return str(v.get('text') or v.get('name') or v)
    return str(v)
def pick(r,*ns):
    for n in ns:
        if n in r and r[n] not in (None,'',[]): return r[n]
    return None
try: recs = json.load(sys.stdin)
except Exception: recs = []
if not recs: print('MISSING'); sys.exit(0)
r = recs[0]
def shown(v):    # 区分 None 与 0：0 是合法置信度截断值，不能被 or '' 折叠
    return '' if v is None else norm(v)
print('|'.join([
  '分类=' + norm(pick(r,'分类','经验类型')),
  '重要度=' + shown(pick(r,'重要度')),
  '置信度=' + shown(pick(r,'置信度')),
  '状态=' + norm(pick(r,'状态')),
  '证据长度=' + str(len(norm(pick(r,'证据原文')))),
  '置换为=' + norm(pick(r,'置换为')),
  '内容=' + norm(pick(r,'记忆内容','经验内容'))[:50],
]))"
}
um_section() { printf '%s' "$1" | sed -n '/===USER_MEMORIES===/,/===AGENT_MEMORIES===/p'; }

echo "== 测试矩阵执行 @ $(date '+%F %T')  会话=$C1/$C2 =="
echo "--- A. 写链路协议防御 ---"

# A0 空记忆列表
printf '{"memories":[]}' > "$WD/a0.json"
out="$(commit "$C1" "$UA" "$WD/a0.json")"
check "A0 空列表：无新记忆且不报错" "新记忆 0 条" "$out"

# A1-A8/A10/A11/A14 一批写入
memjson '[
 {"content":"tm-a1-用户偏好深色主题的演示文稿","scope":"user","category":"偏好","importance":10,"confidence":0.9,"evidence":"tm 证据a1"},
 {"content":"tm-a2-非法分类的记忆条目","scope":"user","category":"不存在的分类!!","importance":5,"confidence":0.8,"evidence":"tm 证据a2"},
 {"content":"tm-a3-重要度越界上限","scope":"user","category":"偏好","importance":99,"confidence":0.8,"evidence":"x"},
 {"content":"tm-a3-重要度越界下限","scope":"user","category":"偏好","importance":-5,"confidence":0.8,"evidence":"x"},
 {"content":"tm-a3-重要度缺失","scope":"user","category":"偏好","confidence":0.8,"evidence":"x"},
 {"content":"tm-a4-置信度越界上限","scope":"user","category":"事实","importance":5,"confidence":7,"evidence":"x"},
 {"content":"tm-a4-置信度越界下限","scope":"user","category":"事实","importance":5,"confidence":-1,"evidence":"x"},
 {"content":"tm-a4-置信度缺失","scope":"user","category":"事实","importance":5,"evidence":"x"},
 {"content":"","scope":"user","category":"事实","importance":5,"confidence":0.5,"evidence":"x"},
 {"content":"tm-a6-非法范围","scope":"team","category":"事实","importance":5,"confidence":0.5,"evidence":"x"},
 {"content":"tm-a8-同一内容双范围写入","scope":"user","category":"事实","importance":6,"confidence":0.85,"evidence":"x"},
 {"content":"tm-a8-同一内容双范围写入","scope":"agent","category":"工具用法","importance":6,"confidence":0.4,"evidence":"x"},
 {"content":"tm-a14-scope缺失默认user","category":"事实","importance":6,"confidence":0.9,"evidence":"x"},
 {"content":"tm-a10-非法冲突引用","scope":"user","category":"事实","importance":5,"confidence":0.8,"conflict_with":"ZZZ99","evidence":"x"},
 {"content":"tm-a11-超长证据","scope":"user","category":"事实","importance":5,"confidence":0.8,"evidence":"tm-a11-证据开头-" + "0123456789"*60}
]' "$WD/a_main.json"
out="$(commit "$C1" "$UA" "$WD/a_main.json")"
echo "  (commit: $(printf '%s' "$out" | tail -1))"
A1MID="$(midof user "tm-a1-用户偏好深色主题的演示文稿")"

check "A1 正常写入：字段与置信度" "分类=偏好|重要度=10|置信度=0.9|状态=active" "$(recfields user "tm-a1-用户偏好深色主题的演示文稿")"
check "A2 非法分类→其他" "分类=其他|重要度=5|置信度=0.8|状态=active" "$(recfields user "tm-a2-非法分类的记忆条目")"
check "A3a 重要度99→10" "重要度=10" "$(recfields user "tm-a3-重要度越界上限")"
check "A3b 重要度-5→1" "重要度=1" "$(recfields user "tm-a3-重要度越界下限")"
check "A3c 重要度缺失→5" "重要度=5" "$(recfields user "tm-a3-重要度缺失")"
check "A4a 置信度7→1" "置信度=1" "$(recfields user "tm-a4-置信度越界上限")"
check "A4b 置信度-1→0" "置信度=0" "$(recfields user "tm-a4-置信度越界下限")"
check "A4c 置信度缺失→0.5" "置信度=0.5" "$(recfields user "tm-a4-置信度缺失")"
# A5 空内容单独提交：直接断言 commit 计数
printf '{"memories":[{"content":"","scope":"user","category":"事实","importance":5,"confidence":0.5,"evidence":"x"}]}' > "$WD/a5.json"
out="$(commit "$C1" "$UA" "$WD/a5.json")"
check "A5 空内容不入库" "新记忆 0 条" "$out"
check "A6 非法scope不入库" "MISSING" "$(recfields user "tm-a6-非法范围")"
check "A8a user范围入库" "分类=事实" "$(recfields user "tm-a8-同一内容双范围写入")"
check "A8b agent范围入库" "分类=工具用法" "$(recfields agent "tm-a8-同一内容双范围写入")"
check "A8c agent范围低置信落库" "置信度=0.4" "$(recfields agent "tm-a8-同一内容双范围写入")"
check "A14 scope缺失→user表" "内容=tm-a14-scope缺失默认user" "$(recfields user "tm-a14-scope缺失默认user")"
check "A11 证据截断至500" "证据长度=500" "$(recfields user "tm-a11-超长证据")"

# A9 冲突：两阶段（先建目标，再建替代并指向目标）
TARGET="tm-a9-冲突目标偏好：回复用粉色主题"
memjson '[{"content":"'"$TARGET"'","scope":"user","category":"偏好","importance":8,"confidence":0.9,"evidence":"tm 证据a9"}]' "$WD/a9a.json"
commit "$C1" "$UA" "$WD/a9a.json" >/dev/null
TMID="$(midof user "$TARGET")"
if [ -n "$TMID" ]; then
  REPL="tm-a9-冲突替代偏好：回复改用深色主题"
  memjson '[{"content":"'"$REPL"'","scope":"user","category":"偏好","importance":9,"confidence":0.95,"conflict_with":"U'"$TMID"'","evidence":"tm 证据a9b"}]' "$WD/a9b.json"
  commit "$C1" "$UA" "$WD/a9b.json" >/dev/null
  NEWMID="$(midof user "$REPL")"
  check "A9a 旧记忆被归档" "状态=archived" "$(recfields user "$TARGET")"
  check "A9b 审计链置换为→新记忆" "置换为=U$NEWMID" "$(recfields user "$TARGET")"
else
  FAIL=$((FAIL+1)); FAILED+=("A9-前置"); echo "  ✗ A9 前置：目标记忆未入库"
fi

# A12 摘要写入
printf 'tm-summary-%s：用户确认了测试摘要内容，用于验证滚动摘要写入。' "$TS" > "$WD/summary.txt"
memjson '[
 {"content":"tm-a12-摘要测试记忆一","scope":"user","category":"事实","importance":6,"confidence":0.8,"evidence":"x"},
 {"content":"tm-a12-摘要测试记忆二","scope":"user","category":"事实","importance":6,"confidence":0.8,"evidence":"x"}
]' "$WD/a12.json"
commit "$C1" "$UA" "$WD/a12.json" --summary-file "$WD/summary.txt" >/dev/null
srecs="$(mem_search "$MEM_TBL_SESSION" "{\"logic\":\"and\",\"conditions\":[[\"会话ID\",\"==\",\"$C1\"]]}" "" 1 "滚动摘要")"
check "A12 摘要写入会话状态" "tm-summary-$TS" "$srecs"

# E1 幂等：重跑同一 resp（不带摘要文件 → 摘要应保留）
out="$(commit "$C1" "$UA" "$WD/a12.json")"
check "E1a 幂等重跑：全部跳过" "新记忆 0 条，重复跳过 2 条" "$out"
srecs="$(mem_search "$MEM_TBL_SESSION" "{\"logic\":\"and\",\"conditions\":[[\"会话ID\",\"==\",\"$C1\"]]}" "" 1 "滚动摘要")"
check "E1b 无摘要文件时保留旧摘要" "tm-summary-$TS" "$srecs"

echo "--- B. 读链路 ---"
out="$(recall --chat-id "$C2" --user-id "$UA" --query "测试查询")"
check "B1a 输出含 REFINE_REQUEST" "===REFINE_REQUEST===" "$out"
check "B1b 精排提示含当前问题" "## 当前问题" "$out"

out="$(recall --chat-id "$C2" --user-id "$UA" --picked "U$A1MID")"
check "B2a 补零ID命中" "[U$A1MID]" "$(printf '%s' "$out" | sed -n '/===MEMORY_PICKED===/,$p')"
NOPAD="$(printf '%s' "$A1MID" | sed 's/^0*//')"
out="$(recall --chat-id "$C2" --user-id "$UA" --picked "U$NOPAD，U$A1MID")"
picked="$(printf '%s' "$out" | sed -n '/===MEMORY_PICKED===/,$p')"
check "B2b 无前导零归一化命中" "[U$A1MID]" "$picked"
check "B3 中文逗号分隔多ID" "[U$A1MID]" "$picked"

out="$(recall --chat-id "$C2")"
check "B4 无user-id时画像段给出提示" "(无该用户画像，或未提供 --user-id)" "$out"
out="$(recall --chat-id "tm-nonexist-$TS" --user-id "$UA")"
check "B5 消息拉取失败降级不报错" "无近期消息或拉取失败——降级" "$out"

# B6 预算：U_C 五条 ~1400 字长记忆，重要度 9..5；2400 字预算只装得下最高重要度一条
"$MEM_PY" -c "
import json
pad = '0123456789' * 140
mems = [{'content': f'tm-budget-i{k}-{pad}', 'scope': 'user', 'category': '其他',
         'importance': k, 'confidence': 0.8, 'evidence': 'x'} for k in (9, 8, 7, 6, 5)]
print(json.dumps({'memories': mems}, ensure_ascii=False))" > "$WD/b6.json"
commit "$C1" "$UC" "$WD/b6.json" >/dev/null 2>&1
out="$(recall --chat-id "$C2" --user-id "$UC")"
um="$(um_section "$out")"
# 预算语义：先截断到 1000 字符再装填 → 每行约 1020 字，2400 预算装得下两条
check "B6a 预算内装入最高重要度" "tm-budget-i9-" "$um"
check "B6b 次高重要度仍在预算内(截断后1020×2≤2400)" "tm-budget-i8-" "$um"
check_absent "B6c 第三条超预算被丢弃" "tm-budget-i7-" "$um"
check_absent "B6d 最低重要度被丢弃" "tm-budget-i5-" "$um"

# B7 截断：U_D 单条 ~2800 字记忆，1000 字符外有哨兵
"$MEM_PY" -c "
import json
content = 'tm-clip-start-' + 'a'*1400 + 'TAILSENTINEL123' + 'b'*1400
print(json.dumps({'memories': [{'content': content, 'scope': 'user', 'category': '其他',
                                'importance': 5, 'confidence': 0.8, 'evidence': 'x'}]}, ensure_ascii=False))" > "$WD/b7.json"
commit "$C1" "$UD" "$WD/b7.json" >/dev/null 2>&1
out="$(recall --chat-id "$C2" --user-id "$UD")"
check "B7a 超长记忆开头可见" "tm-clip-start-" "$out"
check_absent "B7b 1000字符后内容被截断" "TAILSENTINEL123" "$out"

echo "--- C. 隔离 ---"
out="$(recall --chat-id "$C2" --user-id "$UB")"
check "C1 用户B看不到用户A的记忆" "(无该用户画像，或未提供 --user-id)" "$out"
out="$(recall --chat-id "$C2" --agent-id tester --user-id "$UB")"
check "C2 其他Agent看不到main的经验" "(无 Agent 经验)" "$out"
out="$(recall --chat-id "$C2" --agent-id tester --user-id "$UA")"
check "C3 用户画像跨Agent共享" "tm-a1-用户偏好深色主题的演示文稿" "$out"

echo "--- F. 痛点场景映射 ---"
# F1 跨会话：写入发生在 C1，在全新会话 C2 仍可召回
out="$(recall --chat-id "$C2" --user-id "$UA" --picked "$A1MID")"
check "F1 跨会话记忆可召回" "tm-a1-用户偏好深色主题的演示文稿" "$out"
# F2 人工纠错：直接改 Base 记录内容 → 下次召回读到修正后的内容
H1="$(mem_md5 "user:tm-a1-用户偏好深色主题的演示文稿")"
RID1="$(mem_search "$MEM_TBL_USER" "{\"logic\":\"and\",\"conditions\":[[\"内容哈希\",\"==\",\"$H1\"]]}" "" 1 "记忆ID" \
  | "$MEM_PY" -c "
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
print(recs[0]['record_id'] if recs and isinstance(recs[0], dict) else '')")"
upd="$(lark-cli base +record-batch-update --base-token "$MEM_BASE_TOKEN" --table-id "$MEM_TBL_USER" --as user \
  --json "{\"update_records\":{\"$RID1\":{\"记忆内容\":\"tm-a1-已人工纠错：偏好深色主题且需要附数据来源\"}}}" 2>&1)"
printf '%s' "$upd" | grep -q '"ok": true' || echo "  (⚠ F2 更新响应异常: $(printf '%s' "$upd" | head -c 120))"
out="$(recall --chat-id "$C2" --user-id "$UA" --picked "$A1MID")"
check "F2 人工纠错后召回读到新内容" "tm-a1-已人工纠错：偏好深色主题且需要附数据来源" "$out"
# F3 冲突后旧偏好不再召回（只召回 active）
out="$(recall --chat-id "$C2" --user-id "$UA")"
check_absent "F3 被置换的旧记忆不再召回" "tm-a9-冲突目标偏好：回复用粉色主题" "$out"

echo "--- D. 观测 ---"
bash "$SCRIPT_DIR/../scripts/memory-stats.sh" >/dev/null 2>&1   # 拉真库数据并生成 stats.py
out_json="$("$MEM_PY" "$MEM_PY_DIR/stats.py" "$MEM_WORK_DIR/stats/$MEM_TBL_USER.json" "$MEM_WORK_DIR/stats/$MEM_TBL_AGENT.json" "$MEM_WORK_DIR/stats/$MEM_TBL_SESSION.json" "$MEM_CONFIRM_THRESHOLD" json 2>&1)"
check "D1 stats JSON 可解析" '"user_memory"' "$out_json"
check "D2 stats 统计到测试记忆" '"total"' "$out_json"
# D3 离线聚合：构造含 ISO 时间/边界置信度的输入
mkdir -p "$WD/d3"
printf '%s' '[{"记忆ID":"NO.1","状态":"active","置信度":0.9,"分类":"偏好","命中次数":3,"创建时间":"2026-08-30T10:00:00.000+08:00","记忆内容":"d3-active-high"},{"记忆ID":"NO.2","状态":"active","置信度":0.4,"分类":"其他","命中次数":0,"创建时间":"2020-01-01T00:00:00.000+08:00","记忆内容":"d3-active-low"},{"记忆ID":"NO.3","状态":"archived","置信度":null,"分类":"其他","命中次数":0,"创建时间":"2020-01-01T00:00:00.000+08:00","记忆内容":"d3-archived"}]' > "$WD/d3/u.json"
printf '%s' '[]' > "$WD/d3/a.json"; printf '%s' '[]' > "$WD/d3/s.json"
d3="$("$MEM_PY" "$MEM_PY_DIR/stats.py" "$WD/d3/u.json" "$WD/d3/a.json" "$WD/d3/s.json" 0.6 json 2>&1)"
check "D3a 离线聚合总量/活跃" '"total": 3' "$d3"
check "D3b 近7天只算今天那条(ISO时间解析)" '"new_7d": 1' "$d3"
check "D3c 待确认=低置信那条" '"pending_confirm": 1' "$d3"

echo "--- E. 基础设施幂等 ---"
e3="$(bash "$SCRIPT_DIR/../scripts/setup-observability.sh" 2>&1 || true)"
check "E3 setup 幂等（视图跳过）" "已存在，跳过" "$e3"

echo ""
echo "== 结果：通过 $PASS / $((PASS+FAIL)) =="
if [ "$FAIL" -gt 0 ]; then printf '失败用例: %s\n' "${FAILED[*]}"; fi

# ---- 清理：删除本轮写入的全部记录 ----
if [ "$KEEP" = 1 ]; then
  echo "[--keep] 保留测试数据（会话 $C1/$C2）"
else
  echo "== 清理测试数据 =="
  for tbl in "$MEM_TBL_USER" "$MEM_TBL_AGENT"; do
    rids="$(mem_search "$tbl" "{\"logic\":\"and\",\"conditions\":[[\"来源会话\",\"==\",\"$C1\"]]}" "" 200 "记忆ID" \
      | "$MEM_PY" -c "
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
print(' '.join(r['record_id'] for r in recs if isinstance(r, dict) and r.get('record_id')))")"
    if [ -n "$rids" ]; then
      args=(); for r in $rids; do args+=(--record-id "$r"); done
      if lark-cli base +record-delete --base-token "$MEM_BASE_TOKEN" --table-id "$tbl" --as user "${args[@]}" --yes >/dev/null 2>&1; then
        echo "  已删除 $tbl: $(printf '%s' "$rids" | wc -w) 条"
      else
        echo "  ⚠ $tbl 删除失败，残留来源会话=$C1"
      fi
    fi
  done
  srids="$(mem_search "$MEM_TBL_SESSION" "{\"logic\":\"and\",\"conditions\":[[\"会话ID\",\"==\",\"$C1\"]]}" "" 5 "会话ID" \
    | "$MEM_PY" -c "
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
print(' '.join(r['record_id'] for r in recs if isinstance(r, dict) and r.get('record_id')))")"
  if [ -n "$srids" ]; then
    args=(); for r in $srids; do args+=(--record-id "$r"); done
    if lark-cli base +record-delete --base-token "$MEM_BASE_TOKEN" --table-id "$MEM_TBL_SESSION" --as user "${args[@]}" --yes >/dev/null 2>&1; then
      echo "  已删除 会话状态记录"
    fi
  fi
  echo "== 清理完成 =="
fi
exit "$FAIL"

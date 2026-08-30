#!/usr/bin/env bash
# 写链路：prepare 生成 judge/summary 请求；commit 哈希查重→先写新→后归档→推水位
# 用法:
#   memory-judge.sh prepare --chat-id oc_xxx [--user-id ou_xxx] [--agent-id main]
#   memory-judge.sh commit  --chat-id oc_xxx [--request-dir <dir>] --response resp.json [--summary-file s.txt]
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

cmd="$1"; shift || true
chat=""; user=""; agent="$MEM_AGENT_ID"; reqdir=""; resp=""; sumfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chat-id)      chat="$2"; shift 2;;
    --user-id)      user="$2"; shift 2;;
    --agent-id)     agent="$2"; shift 2;;
    --request-dir)  reqdir="$2"; shift 2;;
    --response)     resp="$2"; shift 2;;
    --summary-file) sumfile="$2"; shift 2;;
    *) mem_info "忽略未知参数 $1"; shift;;
  esac
done
[ -n "$chat" ] || { echo "缺少 --chat-id" >&2; exit 2; }

# 读取会话状态记录，输出 JSON {record_id, 沉淀水位, 滚动摘要}
session_state() {
  mem_search "$MEM_TBL_SESSION" \
    "{\"logic\":\"and\",\"conditions\":[[\"会话ID\",\"==\",\"$chat\"]]}" "" 1 \
    "会话ID" "滚动摘要" "沉淀水位" "状态" \
    | "$MEM_PY" -c "
import sys, json
def norm(v):
    if v is None: return ''
    if isinstance(v, str): return v
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, list):
        return ''.join(str(x.get('text') or x.get('name') or x) if isinstance(x, dict) else str(x) for x in v)
    if isinstance(v, dict): return str(v.get('text') or v.get('name') or v)
    return str(v)
try: recs = json.load(sys.stdin)
except Exception: recs = []
r = recs[0] if isinstance(recs, list) and recs and isinstance(recs[0], dict) else {}
print(json.dumps({
  'record_id': r.get('record_id') or '',
  'watermark': norm(r.get('沉淀水位')),
  'summary': norm(r.get('滚动摘要')),
}, ensure_ascii=False))
"
}

if [ "$cmd" = "prepare" ]; then
  dir="${reqdir:-$MEM_WORK_DIR/$chat}"; mkdir -p "$dir"
  state="$(session_state)" || state="{}"
  watermark="$(printf '%s' "$state" | "$MEM_PY" -c "import sys,json;print(json.load(sys.stdin).get('watermark') or 0)")"
  old_summary="$(printf '%s' "$state" | "$MEM_PY" -c "import sys,json;print(json.load(sys.stdin).get('summary') or '')")"

  # 增量消息：水位之后为 NEW；无水位则最近 20 条为 NEW，其余仅作上下文
  mem_fetch_messages "$chat" "$MEM_BACKLOG_MSGS" \
    | "$MEM_PY" "$MEM_PY_DIR/label_new.py" "$watermark" > "$dir/messages.txt"

  new_count="$(grep -c '^\[\[NEW\]\]' "$dir/messages.txt" || true)"
  if [ "${new_count:-0}" -eq 0 ]; then
    mem_info "会话 $chat 无增量消息，无需沉淀"
    exit 0
  fi

  # 既有 active 记忆（user 按用户过滤，agent 按 Agent ID 过滤）
  ucond="[\"用户ID\",\"==\",\"$user\"]"; acond="[\"Agent ID\",\"==\",\"$agent\"]"
  [ -n "$user" ] || ucond="[\"状态\",\"==\",\"__none__\"]"
  urecs="$(mem_search "$MEM_TBL_USER" "{\"logic\":\"and\",\"conditions\":[$ucond,[\"状态\",\"==\",\"active\"]]}" "[{\"field\":\"重要度\",\"desc\":true}]" 200 "记忆ID" "分类" "重要度" "记忆内容")" || urecs=""
  arecs="$(mem_search "$MEM_TBL_AGENT" "{\"logic\":\"and\",\"conditions\":[$acond,[\"状态\",\"==\",\"active\"]]}" "[{\"field\":\"重要度\",\"desc\":true}]" 200 "记忆ID" "经验类型" "重要度" "经验内容")" || arecs=""
  existing="$(printf '%s\n%s' \
    "$(printf '%s' "$urecs" | mem_render_memories "U" "$MEM_CLIP_CHARS" 0)" \
    "$(printf '%s' "$arecs" | mem_render_memories "A" "$MEM_CLIP_CHARS" 0)")"

  mem_render_prompt "$MEM_SKILL_DIR/prompts/judge.txt" \
    "existing=${existing:-（暂无既有记忆）}" \
    "messages=$(cat "$dir/messages.txt")" > "$dir/judge-request.txt"
  mem_render_prompt "$MEM_SKILL_DIR/prompts/summary.txt" \
    "old_summary=${old_summary:-（首次沉淀）}" \
    "messages=$(cat "$dir/messages.txt")" > "$dir/summary-request.txt"

  printf '%s' "$(printf '%s' "$dir/messages.txt" | "$MEM_PY" -c "
import sys, json
items = [l for l in sys.stdin.read().splitlines() if l.strip()]
print(json.dumps({'chat_id': sys.argv[1], 'user_id': sys.argv[2], 'agent_id': sys.argv[3],
                  'lines': len(items)}, ensure_ascii=False))
" "$chat" "$user" "$agent")" > "$dir/meta.json"

  mem_info "prepare 完成：$dir"
  mem_info "下一步：把 judge-request.txt 交给 LLM 产出严格 JSON（memories 数组），"
  mem_info "然后：memory-judge.sh commit --chat-id $chat --response <resp.json> [--summary-file <summary.txt>]"

elif [ "$cmd" = "commit" ]; then
  dir="${reqdir:-$MEM_WORK_DIR/$chat}"
  [ -f "$dir/meta.json" ] || { echo "缺少 $dir/meta.json，请先 prepare" >&2; exit 2; }
  [ -n "$resp" ] && [ -f "$resp" ] || { echo "缺少 --response <resp.json>" >&2; exit 2; }

  MEM_CHAT="$chat" MEM_REQDIR="$dir" MEM_RESP="$resp" MEM_SUMFILE="$sumfile" \
  MEM_USER="$user" MEM_AGENT="$agent" \
  "$MEM_PY" - <<'EOF'
import sys, os, json, re, time, hashlib, subprocess, shutil

# Windows 下 lark-cli 是 .cmd 垫片，必须解析到完整路径才能被 CreateProcess 执行
LARK = shutil.which("lark-cli") or "lark-cli"

def lark(args):
    p = subprocess.run([LARK, 'base'] + args, capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    return (p.stdout or '') + (("\n[stderr] " + p.stderr) if p.stderr.strip() else '')

def lark_ok(out):
    # CLI 把错误也以 JSON 打到 stdout（如网关 404）：必须检查 ok，否则写入失败会被静默跳过
    try:
        obj = json.loads(out)
    except Exception:
        return False
    return obj.get('ok') is True

def dig_records(raw):
    try: obj = json.loads(raw)
    except Exception: return []
    def convert(o):
        d = o.get("data") if isinstance(o, dict) else o
        if isinstance(d, dict) and isinstance(d.get("fields"), list):
            cols, rows = d["fields"], d.get("data") or []
            rids = d.get("record_id_list") or []
            out = []
            for i, row in enumerate(rows):
                if isinstance(row, list):
                    rec = {c: v for c, v in zip(cols, row)}
                    if i < len(rids): rec["record_id"] = rids[i]
                    out.append(rec)
            return out
        def dig(o):
            if isinstance(o, list):
                return o if (o and isinstance(o[0], dict)) else None
            if isinstance(o, dict):
                for k in ("records", "items", "list", "data"):
                    if k in o:
                        r = dig(o[k])
                        if r is not None: return r
            return None
        return dig(o) or []
    return convert(obj)

def norm(v):
    if v is None: return ""
    if isinstance(v, str): return v
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, list):
        return "".join(str(x.get("text") or x.get("name") or x) if isinstance(x, dict) else str(x) for x in v)
    if isinstance(v, dict): return str(v.get("text") or v.get("name") or v)
    return str(v)

def pick(rec, *names):
    for n in names:
        if n in rec and rec[n] not in (None, "", []): return rec[n]
    return None

BASE = os.environ['MEM_BASE_TOKEN']
TBL = {'user': os.environ['MEM_TBL_USER'], 'agent': os.environ['MEM_TBL_AGENT']}
SESSION = os.environ['MEM_TBL_SESSION']

def search(table, conditions, limit=5, select=None):
    args = ['+record-list', '--base-token', BASE, '--table-id', table,
            '--as', 'user', '--format', 'json',
            '--filter-json', json.dumps({"logic": "and", "conditions": conditions}, ensure_ascii=False),
            '--limit', str(limit)]
    for f in (select or []): args += ['--field-id', f]
    return dig_records(lark(args))

def create(table, records):
    # 有限重试（网关抖动类瞬时故障）：commit 逐条创建 + 哈希查重，重试不会产生重复
    out, last = '', ''
    for i in range(3):
        out = lark(['+record-batch-create', '--base-token', BASE, '--table-id', table,
                    '--as', 'user', '--json', json.dumps({"create_records": records}, ensure_ascii=False)])
        if lark_ok(out):
            return dict.fromkeys(re.findall(r'"(rec[A-Za-z0-9]{10,})"', out))  # 保序去重
        last = out
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"record-batch-create 失败（{table}），水位不推进可安全重试：{last[:300]}")

def update(table, mapping):
    out, last = '', ''
    for i in range(3):
        out = lark(['+record-batch-update', '--base-token', BASE, '--table-id', table,
                    '--as', 'user', '--json', json.dumps({"update_records": mapping}, ensure_ascii=False)])
        if lark_ok(out):
            return
        last = out
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"record-batch-update 失败（{table}）：{last[:300]}")

chat = os.environ['MEM_CHAT']
resp = json.load(open(os.environ['MEM_RESP'], encoding='utf-8'))
meta = json.load(open(os.path.join(os.environ['MEM_REQDIR'], 'meta.json'), encoding='utf-8'))
sumfile = os.environ.get('MEM_SUMFILE') or ''

# 协议字段表防御（references/write-protocol.md）：枚举白名单 + 数值截断，非法值降级不报错
USER_CATS = {"偏好", "事实", "目标", "约束", "其他"}
AGENT_CATS = {"任务步骤", "协作约定", "工具用法", "踩坑教训", "其他"}

def clamp(v, lo, hi, default):
    try: v = float(v)
    except (TypeError, ValueError): return default
    return max(lo, min(hi, v))

created, skipped = [], 0
for m in (resp.get('memories') or []):
    content = (m.get('content') or '').strip()
    scope = (m.get('scope') or 'user').strip()
    if not content or scope not in TBL:
        continue
    h = hashlib.md5(f"{scope}:{content}".encode('utf-8')).hexdigest()
    if search(TBL[scope], [["内容哈希", "==", h]], 1):
        skipped += 1
        continue                                    # 幂等：已存在
    cats = USER_CATS if scope == 'user' else AGENT_CATS
    cat = (m.get('category') or '').strip()
    content_field = "记忆内容" if scope == 'user' else "经验内容"   # 两表主列名不同
    fields = {content_field: content, "状态": "active", "内容哈希": h,
              "来源会话": chat,
              "证据原文": (m.get('evidence') or '')[:500],
              "重要度": int(clamp(m.get('importance'), 1, 10, 5)),
              "置信度": round(clamp(m.get('confidence'), 0, 1, 0.5), 2)}
    fields["分类" if scope == 'user' else "经验类型"] = cat if cat in cats else "其他"
    if scope == 'user':
        fields["用户ID"] = os.environ.get('MEM_USER') or meta.get('user_id') or ''
    else:
        fields["Agent ID"] = os.environ.get('MEM_AGENT') or meta.get('agent_id') or 'main'
    create(TBL[scope], [fields])                    # 先写新
    created.append({**m, 'scope': scope, 'hash': h})

archived = 0
for m in created:
    cw = (m.get('conflict_with') or '').strip().upper()   # 后归档旧，如 U12 / A7
    mt = re.match(r'^([UA])(\d+)$', cw)
    if not mt: continue
    tbl, prefix = TBL['user' if mt.group(1) == 'U' else 'agent'], mt.group(1)
    hits = search(tbl, [["记忆ID", "==", int(mt.group(2))]], 1)
    if not hits: continue
    newhits = search(TBL[m['scope']], [["内容哈希", "==", m['hash']]], 1, ["记忆ID"])
    mid_raw = norm(pick(newhits[0], "记忆ID")) if newhits else ''
    md = re.search(r"\d+", mid_raw)                # auto_number 显示为 NO.004，取数字
    newmid = md.group(0) if md else mid_raw
    rid = norm(pick(hits[0], "record_id", "ID"))
    if rid:
        update(tbl, {rid: {"状态": "archived", "置换为": f"{prefix}{newmid}"}})
        archived += 1

# 水位 + 摘要（任一失败整体报错退出，水位不推进，下轮重试）
now_ms = int(time.time() * 1000)
fields = {"沉淀水位": now_ms, "未沉淀条数": 0, "状态": "活跃"}
if sumfile and os.path.isfile(sumfile):
    fields["滚动摘要"] = open(sumfile, encoding='utf-8').read().strip()[:2000]
    fields["摘要时间"] = now_ms
sess = search(SESSION, [["会话ID", "==", chat]], 1)
rid = norm(pick(sess[0], "record_id", "ID")) if sess else ''
if rid:
    update(SESSION, {rid: fields})
else:
    create(SESSION, [{"会话ID": chat, **fields}])

print(f"[agent-memory] commit 完成：新记忆 {len(created)} 条，重复跳过 {skipped} 条，归档冲突 {archived} 条，水位已推进")
EOF

else
  echo "用法: memory-judge.sh prepare|commit ..." >&2
  exit 2
fi

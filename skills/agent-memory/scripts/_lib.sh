#!/usr/bin/env bash
# agent-memory 共享库：配置、lark-cli 封装、JSON 解析与渲染。被各脚本 source，勿直接执行。
#
# 实现注意：python 代码块在 source 时落盘到 .py/ 下再执行，而不是 `python - <<EOF`。
# 原因：heredoc 会占用 stdin；当函数处于管道右侧时（lark-cli 输出 | 函数），
# heredoc 顶掉管道数据，导致 python 的 sys.stdin 永远读到空。
set -uo pipefail

MEM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_SKILL_DIR="$(dirname "$MEM_LIB_DIR")"
# shellcheck source=config.env
source "$MEM_LIB_DIR/config.env"

# 选可用的 python：Windows 上 python3 可能是 Microsoft Store 假垫片，须实际执行验证
MEM_PY=""
for _c in python python3; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c "import sys" >/dev/null 2>&1; then
    MEM_PY="$(command -v "$_c")"; break
  fi
done
command -v lark-cli >/dev/null 2>&1 || { echo "[agent-memory] 缺少 lark-cli" >&2; exit 1; }
[ -n "$MEM_PY" ] || { echo "[agent-memory] 缺少可用的 python" >&2; exit 1; }

MEM_WORK_DIR="${MEM_WORK_DIR:-$MEM_LIB_DIR/.work}"
MEM_PY_DIR="$MEM_LIB_DIR/.py"
mkdir -p "$MEM_WORK_DIR" "$MEM_PY_DIR"

[ -n "${MEM_BASE_TOKEN:-}" ] || {
  echo "[agent-memory] 未配置 MEM_BASE_TOKEN：复制 scripts/config.env.local.example 为 config.env.local 并填入真实值" >&2
  exit 1
}

mem_info() { echo "[agent-memory] $*" >&2; }

# ---------------------------------------------------------------------------
# python 代码块（source 时落盘）

# 单元格值归一化 + 字段选取（被其他块复制的公共片段）
_MEM_NORM_SNIPPET='
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
'

cat > "$MEM_PY_DIR/records.py" <<'EOF'
# stdin: lark-cli +record-list 的 JSON 输出 → stdout: 记录对象数组 JSON
import sys, json
try: obj = json.loads(sys.stdin.read())
except Exception: print("[]"); sys.exit(0)
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
print(json.dumps(convert(obj), ensure_ascii=False))
EOF

cat > "$MEM_PY_DIR/render.py" <<'EOF'
# argv: prefix(U|A) clip_chars budget_chars   stdin: 记录对象数组 JSON
# stdout: "[U12] (偏好, 重要度8) 内容" 每行一条；预算>0 时按序装填直至超预算
import sys, json, re
prefix, clip, budget = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
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
try: recs = json.load(sys.stdin)
except Exception: recs = []
out, used = [], 0
for r in recs:
    if not isinstance(r, dict): continue
    mid_raw = norm(pick(r, "记忆ID") or "?")
    m = re.search(r"\d+", mid_raw)          # auto_number 显示为 NO.001，取数字部分
    mid = m.group(0) if m else mid_raw
    cat = norm(pick(r, "分类", "经验类型"))
    imp = norm(pick(r, "重要度") or 5)
    content = norm(pick(r, "记忆内容", "经验内容"))[:clip]
    if not content: continue
    line = f"[{prefix}{mid}] ({cat}, 重要度{imp}) {content}"
    if budget > 0:
        if used + len(line) > budget: continue
        used += len(line)
    out.append(line)
print("\n".join(out))
EOF

cat > "$MEM_PY_DIR/messages.py" <<'EOF'
# stdin: lark-cli im +chat-messages-list 的 JSON 输出（desc 顺序）
# stdout: NDJSON {"ts": ms, "line": "名字: 文本"}
# create_time 兼容两种形态：毫秒时间戳 / "YYYY-MM-DD HH:MM[:SS]" 字符串（按本机时区折算）
import sys, json, re, calendar, time
def to_ms(v):
    s = str(v or "").strip()
    if not s: return 0
    if s.isdigit(): return int(s)
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?", s)
    if m:
        y, mo, d, h, mi = (int(m.group(i)) for i in range(1, 6))
        sec = int(m.group(6) or 0)
        return int(time.mktime((y, mo, d, h, mi, sec, 0, 0, -1)) * 1000)
    return 0
def norm(v):
    if isinstance(v, str): return v
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, list):
        return "".join(str(x.get("text") or x.get("name") or x) if isinstance(x, dict) else str(x) for x in v)
    if isinstance(v, dict): return str(v.get("text") or v.get("name") or v)
    return "" if v is None else str(v)
def dig(o, *keys):
    if isinstance(o, dict):
        for k in keys:
            if k in o: return o[k]
        for v in o.values():
            r = dig(v, *keys)
            if r is not None: return r
    elif isinstance(o, list):
        for x in o:
            r = dig(x, *keys)
            if r is not None: return r
    return None
try: obj = json.loads(sys.stdin.read())
except Exception: sys.exit(0)
items = dig(obj, "messages", "items", "list") or []
for m in items:
    if not isinstance(m, dict): continue
    mtype = m.get("msg_type") or m.get("message_type") or ""
    if mtype == "system": continue
    sender = m.get("sender") if isinstance(m.get("sender"), dict) else {}
    name = sender.get("name") or m.get("sender_name") or norm(sender.get("id") or m.get("sender_id")) or "?"
    body = m.get("body") if isinstance(m.get("body"), dict) else {}
    content = body.get("content", m.get("content"))
    if isinstance(content, str):
        try:
            c = json.loads(content)
            if isinstance(c, dict): content = c.get("text") or content
        except Exception: pass
    text = norm(content).strip()
    if not text: continue
    print(json.dumps({"ts": to_ms(dig(m, "create_time")), "line": f"{name}: {text}"}, ensure_ascii=False))
EOF

cat > "$MEM_PY_DIR/render_prompt.py" <<'EOF'
# argv: template_path key=val ...（val 可含换行）→ stdout: 替换 {{key}} 后的模板
import sys
text = open(sys.argv[1], encoding="utf-8").read()
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    text = text.replace("{{" + k + "}}", v)
sys.stdout.write(text)
EOF

cat > "$MEM_PY_DIR/label_new.py" <<'EOF'
# argv: watermark_ms；stdin: messages.py 的 NDJSON → stdout: 带 [[NEW]] 标记的对话文本
import sys, json
wm = int(float(sys.argv[1] or 0))
items = [json.loads(l) for l in sys.stdin if l.strip()]
items.reverse()                       # 时间正序
out = []
for i, it in enumerate(items):
    ts = int(float(it.get('ts') or 0))
    is_new = (ts > wm) if wm else (i >= len(items) - 20)
    out.append(('[[NEW]] ' if is_new else '') + it['line'])
print('\n'.join(out))
EOF

# ---------------------------------------------------------------------------
# 函数

# mem_search <table> <filter_json> <sort_json|""> <limit> [field...]
# 输出：记录数组的 JSON（stdout）
mem_search() {
  local table="$1" filter="$2" sort="$3" limit="$4"; shift 4
  local args=(base +record-list --base-token "$MEM_BASE_TOKEN" --table-id "$table"
    --as user --format json --filter-json "$filter")
  [ -n "$sort" ] && args+=(--sort-json "$sort")
  [ -n "$limit" ] && args+=(--limit "$limit")
  local f; for f in "$@"; do args+=(--field-id "$f"); done
  lark-cli "${args[@]}" 2>/dev/null | "$MEM_PY" "$MEM_PY_DIR/records.py"
}

# mem_md5 <string> → md5 hex（UTF-8）
mem_md5() { printf '%s' "$1" | "$MEM_PY" -c "import sys,hashlib;print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())"; }

# mem_render_memories <prefix U|A> <clip_chars> <budget_chars|0>  （stdin: 记录数组 JSON）
# 前缀用于跨表消歧：用户画像=U，Agent 经验=A（两表记忆ID各自自增，会重号）
mem_render_memories() {
  "$MEM_PY" "$MEM_PY_DIR/render.py" "$1" "$2" "$3"
}

# mem_fetch_messages <chat_id> <limit>  （新→旧；输出 NDJSON: {"ts":ms,"line":"名字: 文本"}）
mem_fetch_messages() {
  lark-cli im +chat-messages-list --chat-id "$1" --limit "$2" --order desc \
    --as "${MEM_IM_IDENTITY:-bot}" --format json 2>/dev/null \
    | "$MEM_PY" "$MEM_PY_DIR/messages.py"
}

# mem_render_prompt <template_file> <key=val>...  （{{key}} 替换 → stdout）
mem_render_prompt() {
  "$MEM_PY" "$MEM_PY_DIR/render_prompt.py" "$@"
}

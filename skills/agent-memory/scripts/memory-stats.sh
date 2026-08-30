#!/usr/bin/env bash
# 记忆健康度统计（只读）：总量/状态/待确认/分类分布/命中/近7天新增/会话沉淀滞后
# 用法: memory-stats.sh [--json]     # --json 输出机器读格式，供巡检或卡片渲染
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

mode="${1:-text}"
dir="$MEM_WORK_DIR/stats"; mkdir -p "$dir"

# 只拉统计所需字段；conditions 为空 = 全表。API 单次上限 200 行，中小规模够用
fetch() { # <table> <fields...>
  local table="$1"; shift
  local args=(base +record-list --base-token "$MEM_BASE_TOKEN" --table-id "$table"
    --as user --format json --limit 200)
  local f; for f in "$@"; do args+=(--field-id "$f"); done
  if ! lark-cli "${args[@]}" 2>>"$dir/fetch_err.log" | "$MEM_PY" "$MEM_PY_DIR/records.py" > "$dir/$table.json"; then
    mem_info "警告：$table 拉取失败（详见 $dir/fetch_err.log），该表统计将为 0"
  fi
}

fetch "$MEM_TBL_USER" "记忆ID" "分类" "重要度" "状态" "置信度" "命中次数" "创建时间" "记忆内容"
fetch "$MEM_TBL_AGENT" "记忆ID" "经验类型" "重要度" "状态" "置信度" "命中次数" "创建时间" "经验内容"
fetch "$MEM_TBL_SESSION" "会话ID" "会话名称" "状态" "未沉淀条数" "最后消息时间" "沉淀水位"

cat > "$MEM_PY_DIR/stats.py" <<'EOF'
# argv: [user.json, agent.json, session.json, threshold, mode(text|json)]
import sys, json, time, re

def load(path):
    try: return json.load(open(path, encoding='utf-8'))
    except Exception: return []

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

def num(v):
    m = ""
    for c in str(v if v is not None else ""):
        if c.isdigit() or (c == "." and "." not in m): m += c
        elif m: break
    try: return float(m)
    except ValueError: return None

def to_ms(v):   # 兼容毫秒时间戳与 ISO 字符串（2026-08-29T19:20:11.000+08:00）
    s = str(v or "").strip()
    if not s: return 0
    try: return int(float(s))
    except ValueError: pass
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?", s)
    if m:
        y, mo, d, h, mi = (int(m.group(i)) for i in range(1, 6))
        sec = int(m.group(6) or 0)
        return int(time.mktime((y, mo, d, h, mi, sec, 0, 0, -1))) * 1000
    return 0

def mem_stats(recs, cat_field, content_field, threshold, now_ms):
    active = [r for r in recs if norm(pick(r, "状态")) == "active"]
    confs = [num(pick(r, "置信度")) for r in active]
    confs = [c for c in confs if c is not None]
    low = [r for r in active if (num(pick(r, "置信度")) or 0) < threshold]
    cats = {}
    for r in active:
        c = norm(pick(r, cat_field)) or "未分类"
        cats[c] = cats.get(c, 0) + 1
    hits = sorted(active, key=lambda r: num(pick(r, "命中次数")) or 0, reverse=True)
    week = [r for r in active
            if to_ms(pick(r, "创建时间")) > now_ms - 7 * 86400 * 1000]
    return {
        "total": len(recs), "active": len(active),
        "archived": len(recs) - len(active),
        "pending_confirm": len(low),
        "avg_confidence": round(sum(confs) / len(confs), 2) if confs else None,
        "new_7d": len(week),
        "category_dist": cats,
        "top_hits": [{"content": norm(pick(r, content_field))[:40],
                      "hits": int(num(pick(r, "命中次数")) or 0)} for r in hits[:3]],
        "low_conf_list": [{"content": norm(pick(r, content_field))[:40],
                           "confidence": num(pick(r, "置信度"))} for r in low[:5]],
    }

def sess_stats(recs, now_ms):
    by = {}
    for r in recs:
        s = norm(pick(r, "状态")) or "未知"
        by[s] = by.get(s, 0) + 1
    lagging = 0
    for r in recs:
        last = num(pick(r, "最后消息时间")) or 0
        wm = num(pick(r, "沉淀水位")) or 0
        if last and wm < last and last < now_ms - 30 * 60 * 1000:
            lagging += 1
    return {"total": len(recs), "by_status": by,
            "pending_msgs": sum(int(num(pick(r, "未沉淀条数")) or 0) for r in recs),
            "lagging": lagging}

threshold = float(sys.argv[4])
mode = sys.argv[5]
now_ms = int(time.time() * 1000)
u = mem_stats(load(sys.argv[1]), "分类", "记忆内容", threshold, now_ms)
a = mem_stats(load(sys.argv[2]), "经验类型", "经验内容", threshold, now_ms)
s = sess_stats(load(sys.argv[3]), now_ms)
out = {"user_memory": u, "agent_memory": a, "session_state": s,
       "generated_at": time.strftime("%Y-%m-%d %H:%M:%S")}

if mode == "json":
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0)

def fmt_mem(title, m):
    lines = [f"【{title}】",
             f"  总量 {m['total']}（活跃 {m['active']} / 已归档 {m['archived']}）"
             f"  近7天新增 {m['new_7d']}",
             f"  待人工确认 {m['pending_confirm']} 条（置信度<{threshold}）"
             + (f"  平均置信度 {m['avg_confidence']}" if m['avg_confidence'] is not None else "")]
    if m["category_dist"]:
        dist = "、".join(f"{k} {v}" for k, v in sorted(m["category_dist"].items(), key=lambda x: -x[1]))
        lines.append(f"  分布：{dist}")
    if m["low_conf_list"]:
        lines.append("  低置信样例：" + "；".join(
            f"{x['content']}({x['confidence']})" for x in m["low_conf_list"]))
    if m["top_hits"] and m["top_hits"][0]["hits"] > 0:
        lines.append("  命中Top：" + "；".join(
            f"{x['content']}×{x['hits']}" for x in m["top_hits"]))
    return "\n".join(lines)

print(f"Agent 记忆健康度 @ {out['generated_at']}  (待确认阈值 {threshold})")
print(fmt_mem("用户画像", u))
print(fmt_mem("Agent 经验", a))
print(f"【会话状态】共 {s['total']} 个会话：" +
      "、".join(f"{k} {v}" for k, v in s["by_status"].items()) +
      f"；未沉淀消息 {s['pending_msgs']} 条，沉淀滞后会话 {s['lagging']} 个")
EOF

"$MEM_PY" "$MEM_PY_DIR/stats.py" \
  "$dir/$MEM_TBL_USER.json" "$dir/$MEM_TBL_AGENT.json" "$dir/$MEM_TBL_SESSION.json" \
  "$MEM_CONFIRM_THRESHOLD" "${mode#--}" 

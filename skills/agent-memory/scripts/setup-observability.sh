#!/usr/bin/env bash
# 一键搭建观测设施（幂等，可重复执行）：「待确认」视图 ×2 + 「记忆健康度」仪表盘
# 用法: scripts/setup-observability.sh
# 前置: config.env 配好 base_token / 表ID；lark-cli 已登录且 Base 可读写
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

BT="$MEM_BASE_TOKEN"
THRESHOLD="$MEM_CONFIRM_THRESHOLD"

have_view() { # <table> <view_name>
  lark-cli base +view-list --base-token "$BT" --table-id "$1" --as user --format json 2>/dev/null \
    | "$MEM_PY" -c "import sys,json
try: d=json.load(sys.stdin).get('data') or {}
except Exception: d={}
items=d.get('items') or d.get('views') or []
print('yes' if any((v.get('view_name') or v.get('name'))=='$2' for v in items if isinstance(v,dict)) else 'no')"
}

setup_view() { # <table> <view_name>
  local table="$1" name="$2"
  if [ "$(have_view "$table" "$name")" = "yes" ]; then
    mem_info "视图「$name」已存在，跳过创建（$table）"
  else
    lark-cli base +view-create --base-token "$BT" --table-id "$table" --as user \
      --json "{\"name\":\"$name\",\"type\":\"grid\"}" >/dev/null 2>&1 \
      && mem_info "视图「$name」创建成功（$table）" \
      || { mem_info "视图「$name」创建失败（$table）"; return 1; }
  fi
  lark-cli base +view-set-filter --base-token "$BT" --table-id "$table" --as user \
    --view-id "$name" \
    --json '{"logic":"and","conditions":[["状态","==","active"],["置信度","<",'"$THRESHOLD"']]}' \
    >/dev/null 2>&1 && mem_info "视图「$name」筛选已设置（active 且 置信度<$THRESHOLD）"
}

find_dashboard() { # <name> → dashboard_id 或空
  lark-cli base +dashboard-list --base-token "$BT" --as user --format json 2>/dev/null \
    | "$MEM_PY" -c "import sys,json
try: items=(json.load(sys.stdin).get('data') or {}).get('items') or []
except Exception: items=[]
for d in items:
    if isinstance(d,dict) and d.get('dashboard_name')=='$1':
        print(d.get('dashboard_id') or ''); break"
}

block_ids() { # <dashboard_id> → "name:block_id" 每行一个
  lark-cli base +dashboard-block-list --base-token "$BT" --dashboard-id "$1" --as user --format json 2>/dev/null \
    | "$MEM_PY" -c "import sys,json
try: items=(json.load(sys.stdin).get('data') or {}).get('items') or []
except Exception: items=[]
for b in items:
    if isinstance(b,dict): print(f\"{b.get('block_name') or b.get('name') or ''}:{b.get('block_id') or ''}\")"
}

create_block() { # <dashboard_id> <name> <type> <data_config_json> <existing_names_file>
  local did="$1" name="$2" type="$3" cfg="$4" exist="$5"
  if grep -Fxq "$name" "$exist" 2>/dev/null; then
    mem_info "组件「$name」已存在，跳过"; return 0
  fi
  printf '%s' "$cfg" > "$MEM_WORK_DIR/.block_cfg.json"
  if lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$did" --as user \
      --name "$name" --type "$type" --json @"$MEM_WORK_DIR/.block_cfg.json" >/dev/null 2>&1; then
    mem_info "组件「$name」创建成功"
  else
    mem_info "组件「$name」创建失败（详见 CLI 报错）"; rm -f "$MEM_WORK_DIR/.block_cfg.json"; return 1
  fi
  rm -f "$MEM_WORK_DIR/.block_cfg.json"
}

mem_info "步骤 1/3：待确认视图（阈值 $THRESHOLD）"
setup_view "$MEM_TBL_USER"  "待确认"
setup_view "$MEM_TBL_AGENT" "待确认"

mem_info "步骤 2/3：记忆健康度仪表盘"
DID="$(find_dashboard "记忆健康度")"
if [ -z "$DID" ]; then
  DID="$(lark-cli base +dashboard-create --base-token "$BT" --as user --name 记忆健康度 \
    --jq '.data.dashboard_id' 2>/dev/null | tr -d '\r')"
fi
# 错误响应时 jq 会输出字面量 null，同样视为失败
case "$DID" in ""|null|null*)
  mem_info "仪表盘创建/查询失败（API 未恢复或权限缺失），中止；稍后可重跑本脚本"; exit 1 ;;
esac
mem_info "仪表盘 ID: $DID"

block_ids "$DID" | sed 's/:.*//' > "$MEM_WORK_DIR/.blocks.txt"
ACT='{"field_name":"状态","operator":"is","value":"active"}'
PENDING='{"conjunction":"and","conditions":[{"field_name":"状态","operator":"is","value":"active"},{"field_name":"置信度","operator":"isLess","value":'"$THRESHOLD"'}]}'

create_block "$DID" "说明" text \
  '{"text":"# Agent 记忆健康度\n- 低置信（<'"$THRESHOLD"'）记忆请在两张记忆表的「待确认」视图人工核对\n- 已归档记忆为被新记忆置换的旧版本，仅作审计，不参与召回"}' \
  "$MEM_WORK_DIR/.blocks.txt"
create_block "$DID" "活跃用户记忆" statistics \
  "{\"table_name\":\"用户画像\",\"count_all\":true,\"filter\":$ACT}" "$MEM_WORK_DIR/.blocks.txt"
create_block "$DID" "活跃Agent经验" statistics \
  "{\"table_name\":\"Agent 经验\",\"count_all\":true,\"filter\":$ACT}" "$MEM_WORK_DIR/.blocks.txt"
create_block "$DID" "待人工确认" statistics \
  "{\"table_name\":\"用户画像\",\"count_all\":true,\"filter\":$PENDING}" "$MEM_WORK_DIR/.blocks.txt"
create_block "$DID" "累计命中" statistics \
  '{"table_name":"用户画像","series":[{"field_name":"命中次数","rollup":"SUM"}]}' "$MEM_WORK_DIR/.blocks.txt"
create_block "$DID" "用户记忆分类分布" pie \
  "{\"table_name\":\"用户画像\",\"count_all\":true,\"group_by\":[{\"field_name\":\"分类\",\"mode\":\"integrated\",\"sort\":{\"type\":\"value\",\"order\":\"desc\"}}],\"filter\":$ACT}" "$MEM_WORK_DIR/.blocks.txt"
create_block "$DID" "Agent经验类型分布" column \
  "{\"table_name\":\"Agent 经验\",\"count_all\":true,\"group_by\":[{\"field_name\":\"经验类型\",\"mode\":\"integrated\",\"sort\":{\"type\":\"value\",\"order\":\"desc\"}}],\"filter\":$ACT}" "$MEM_WORK_DIR/.blocks.txt"
rm -f "$MEM_WORK_DIR/.blocks.txt"

mem_info "步骤 3/3：排版整理"
lark-cli base +dashboard-arrange --base-token "$BT" --dashboard-id "$DID" --as user >/dev/null 2>&1 \
  && mem_info "排版完成"

mem_info "全部完成：https://my.feishu.cn/base/$BT?dashboard=$DID"

# 仪表盘与「待确认」视图搭建指南

> 目标：让记忆系统对人是**透明可治理**的——打开 Base 就能看到记忆健康度，
> 低置信记忆有一个明确的「待人工确认」队列。
> 两条路径任选：A 用 lark-cli 全程命令行搭建（可复现、可脚本化）；B 在界面上手工配置（约 5 分钟）。
> 阈值 `0.6` 与 `config.env` 的 `MEM_CONFIRM_THRESHOLD` 保持一致；改动时两边同步。

## 0. 前置条件

- Base「Agent 记忆系统」已按 `docs/memory-system-design.md` 第 3 节建表；
- 两张记忆表已含 `置信度`（number 0-1）字段；
- lark-cli 已登录且有 Base 读写权限（`--as user`）。

## A. 命令行搭建（推荐，可整体复现）

### A1. 「待确认」视图（两张记忆表各一）

```bash
BT=<base_token>
for T in <用户画像表ID> <Agent经验表ID>; do
  lark-cli base +view-create --base-token "$BT" --table-id "$T" --as user \
    --json '{"name":"待确认","type":"grid"}'
  lark-cli base +view-set-filter --base-token "$BT" --table-id "$T" --as user \
    --view-id 待确认 \
    --json '{"logic":"and","conditions":[["状态","==","active"],["置信度","<",0.6]]}'
done
```

效果：只显示 active 且置信度 <0.6 的记忆。**人在这个视图里改内容/删记录 = 纠错**，
agent 下次召回拿到的就是修正后的记忆。

### A2. 「记忆健康度」仪表盘

```bash
# 1) 建仪表盘
DID=$(lark-cli base +dashboard-create --base-token "$BT" --as user \
  --name 记忆健康度 --jq '.data.dashboard_id')

# 2) 说明块（text 类型，Markdown 子集：标题/加粗/列表）
lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name 说明 --type text \
  --data-config '{"text":"# Agent 记忆健康度\n- 低置信（<0.6）记忆请在两张记忆表的「待确认」视图人工核对\n- 已归档记忆为被新记忆置换的旧版本，仅作审计，不参与召回"}'

# 3) 指标卡（statistics）——活跃记忆数
lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name 活跃用户记忆 --type statistics \
  --data-config '{"table_name":"用户画像","count_all":true,"filter":{"conjunction":"and","conditions":[{"field_name":"状态","operator":"is","value":"active"}]}}'

lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name 活跃Agent经验 --type statistics \
  --data-config '{"table_name":"Agent 经验","count_all":true,"filter":{"conjunction":"and","conditions":[{"field_name":"状态","operator":"is","value":"active"}]}}'

# 4) 指标卡——待人工确认（active 且 置信度<0.6）
lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name 待人工确认 --type statistics \
  --data-config '{"table_name":"用户画像","count_all":true,"filter":{"conjunction":"and","conditions":[{"field_name":"状态","operator":"is","value":"active"},{"field_name":"置信度","operator":"isLess","value":0.6}]}}'

# 5) 指标卡——累计命中（召回被实际用到的次数）
lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name 累计命中 --type statistics \
  --data-config '{"table_name":"用户画像","series":[{"field_name":"命中次数","rollup":"SUM"}]}'

# 6) 饼图——用户记忆分类分布（仅 active）
lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name 用户记忆分类分布 --type pie \
  --data-config '{"table_name":"用户画像","count_all":true,"group_by":[{"field_name":"分类","mode":"integrated","sort":{"type":"value","order":"desc"}}],"filter":{"conjunction":"and","conditions":[{"field_name":"状态","operator":"is","value":"active"}]}}'

# 7) 柱状图——Agent 经验类型分布（仅 active）
lark-cli base +dashboard-block-create --base-token "$BT" --dashboard-id "$DID" --as user \
  --name Agent经验类型分布 --type column \
  --data-config '{"table_name":"Agent 经验","count_all":true,"group_by":[{"field_name":"经验类型","mode":"integrated","sort":{"type":"value","order":"desc"}}],"filter":{"conjunction":"and","conditions":[{"field_name":"状态","operator":"is","value":"active"}]}}'

# 8) 版面整理（服务端智能排版）
lark-cli base +dashboard-arrange --base-token "$BT" --dashboard-id "$DID" --as user
```

注意：`data_config` 用**表名与字段名**（非 ID）；仪表盘组件需逐个创建，不能并发；
datetime 筛选必须写 `["ExactDate", 毫秒时间戳]`，数字字段才能用 `isLess`/`isLessEqual`。

## B. 手工搭建（无 CLI 时）

1. 两张记忆表：视图栏「+ 新建视图」→ 表格视图，命名「待确认」→ 筛选：
   `状态 = active` 且 `置信度 < 0.6`。
2. Base 左侧「+ 新建仪表盘」→ 命名「记忆健康度」→ 依次添加组件：
   - 指标卡 ×4：活跃用户记忆 / 活跃Agent经验 / 待人工确认 / 累计命中（条件同 A2）；
   - 饼图：用户记忆分类分布（分组=分类，筛选 状态=active）；
   - 柱状图：Agent经验类型分布（分组=经验类型，筛选 状态=active）；
   - 文本块：说明低置信记忆的处理方式。

## C. 与统计脚本配合

```bash
scripts/memory-stats.sh        # 人读文本：健康度摘要（总量/分布/待确认/命中/沉淀滞后）
scripts/memory-stats.sh --json # 机器读 JSON：可喂给卡片渲染或巡检告警
```

仪表盘负责"随时看"，stats 脚本负责"定时报"（可挂进 cron / 巡检消息）。
建议巡检规则：`待人工确认 > 0` 或 `沉淀滞后会话 > 0` 时，向运维群发一张卡片。

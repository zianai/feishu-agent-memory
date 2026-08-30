---
name: agent-memory
version: 0.2.0
description: 跨会话记忆系统（飞书多维表格存储）。回答飞书会话消息前用 memory-recall.sh 召回「用户画像/Agent经验/会话摘要」注入上下文；会话静默后用 memory-judge.sh 沉淀值得长期记住的信息（带置信度，低置信进「待确认」视图等人纠错）；memory-stats.sh 输出记忆健康度。适用于让 bot 记住用户偏好、任务经验、项目进度的场景。
metadata:
  requires:
    bins: ["lark-cli", "python"]
---

# Agent 记忆系统（四层记忆 · 飞书 Base 版）

四层记忆的存放位置：**Working**＝本次推理的上下文本身；**Session**＝飞书会话消息（按需拉取，不自己存）＋滚动摘要；**User Memory**＝Base「用户画像」表；**Agent Memory**＝Base「Agent 经验」表。

## 法则（六条，必须遵守）

1. **回答前先召回**：凡是要在飞书会话里回答用户，先跑读链路；召回失败才允许裸答。
2. **记忆是增强能力，不是主链路**：任何记忆步骤失败，降级为无记忆继续回答，绝不阻塞回复。
3. **只沉淀稳定信息**：偏好/事实/目标/约束/经验教训可入库；寒暄、一次性细节、时效信息（"明天开会"）不入库。
4. **写前查重，先写后归档**：内容哈希命中即跳过；与既有记忆冲突时先写入新记忆、再把旧记忆软删（状态→archived），永不物理删除。
5. **身份隔离**：经验按 `Agent ID` 归属（各写各的）；用户画像按 `用户ID` 共享（全体 agent 可读）。
6. **尊重预算**：Token/字符预算见 `references/token-budget.md`，超预算从低重要度开始丢弃。

## 工作流

### 读链路（收到会话消息、准备回答时）

```bash
scripts/memory-recall.sh --chat-id <oc_xxx> --user-id <ou_xxx> [--query "用户问题"] [--picked 12,3]
```

输出四段：`SHORT_TERM`（近期消息）/ `SUMMARY`（滚动摘要）/ `USER_MEMORIES` / `AGENT_MEMORIES`。
若输出带 `REFINE_REQUEST` 块：把它交给 LLM（你自己或外部 API）得到相关编号 JSON，再用 `--picked <编号>` 重跑一次得到最终上下文。
回答时把记忆段落按 `prompts/system.txt` 注入 system，自然运用、不机械罗列。

### 写链路（会话静默 ≥30 分钟，或未沉淀消息 ≥20 条时）

```bash
scripts/memory-judge.sh prepare --chat-id <oc_xxx> --user-id <ou_xxx>   # 生成 judge-request.txt / summary-request.txt
# 用 LLM（你自己，或 scripts/llm.sh 配置的 API）按 prompt 产出严格 JSON
scripts/memory-judge.sh commit --chat-id <oc_xxx> --request-dir <目录> --response resp.json [--summary-file summary.txt]
```

cron 无人值守巡检：`scripts/memory-consolidate.sh`（需在 config.env 配 `LLM_CMD`）。

### 观测（随时/定时）

```bash
scripts/memory-stats.sh          # 健康度文本日报：总量/分布/待确认/命中/沉淀滞后
scripts/memory-stats.sh --json   # 机器读 JSON，供卡片渲染或巡检告警
```

两张记忆表各有一个「待确认」视图（active 且 置信度<0.6）：**人在视图里改一行 = 纠错完成**。
仪表盘「记忆健康度」的搭建见 `references/dashboard.md`。

## 降级表

| 故障 | 处理 |
|---|---|
| 会话消息拉取失败 | SHORT_TERM 置空，用 SUMMARY + 长期记忆回答 |
| 记忆表查询失败 | 精排与注入跳过，无记忆回答 |
| 精排 LLM 失败 | 用粗筛候选前 10 条直接注入 |
| 沉淀任一步失败 | 水位不推进，下轮巡检自然重试（哈希幂等） |

## 配置与协议

- 运行时配置：`scripts/config.env`（base_token、三个表ID、预算、阈值、待确认阈值）。复用到别的 Base 只改这里。
- 写链路完整协议（judge 字段表→查重→先写后归档→水位）：`references/write-protocol.md`。
- 预算：`references/token-budget.md`；仪表盘与待确认视图：`references/dashboard.md`。
- 端到端测试矩阵：`tests/e2e-test.sh`（真实 Base、自隔离自清理，46 项用例；清单见 `docs/test-matrix.md`）。

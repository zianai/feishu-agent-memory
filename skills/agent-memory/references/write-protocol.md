# 写链路协议（judge → 查重 → 先写后归档 → 水位）

## 触发条件（双触发器，幂等可重入）

| 触发器 | 条件 | 发起方 |
|---|---|---|
| A 定时巡检 | 会话状态表里 `状态=待沉淀`（即最后消息超 30 分钟且水位落后） | cron / memory-consolidate.sh |
| B 轮次阈值 | 读链路回复后发现 `未沉淀条数 ≥ 20` | agent 顺手调用 |

多触发并发无碍：哈希查重挡重复写入，水位线单调推进。

## prepare 阶段（确定性，无 LLM）

1. 读「会话状态」表取 `沉淀水位`（无记录视为首次沉淀）。
2. 拉会话消息（asc，最多 200 条）：
   - 有水位：水位之后的消息为增量，渲染时加 `[[NEW]]` 前缀；水位之前的仅作上下文。
   - 无水位：只取最近 50 条，最后 20 条加 `[[NEW]]`，其余作上下文。
3. 取两张记忆表全部 `状态=active` 记录，渲染为 `[M{id}] (scope/分类) 内容` 列表。
4. 渲染 `prompts/judge.txt` → `<work>/<chat_id>/judge-request.txt`，同时写 `meta.json`
   （chat_id、user_id、agent_id、watermark_ts、newest_ts、count）。
5. 渲染 `prompts/summary.txt`（旧摘要+增量消息）→ `summary-request.txt`。

## LLM 判断（可插拔：agent 自己当模型，或 llm.sh 调 API）

输出严格 JSON：

```json
{"memories":[{"content":"...","scope":"user|agent","category":"偏好",
  "importance":8,"confidence":0.85,"duplicate_of":null,"conflict_with":null,"evidence":"原文引用"}]}
```

### 协议字段表（LLM 输出 → commit 校验）

LLM 输出不完全可信，commit 阶段对每个字段做防御性校验（枚举白名单 + 数值截断），
非法值降级而不是报错——保证 judge 侧任何输出都不会让入库失败：

| 字段 | 类型 | 合法值 | commit 防御处理 |
|---|---|---|---|
| content | string | 必填非空 | 为空跳过该条 |
| scope | enum | `user` / `agent` | 非法跳过该条 |
| category | enum | user：偏好/事实/目标/约束/其他；agent：任务步骤/协作约定/工具用法/踩坑教训/其他 | 非法或缺失 → `其他` |
| importance | int | 1~10 | 截断到 [1,10]；缺失 → 5 |
| confidence | float | 0~1 | 截断到 [0,1]；缺失 → 0.5（落入「待确认」，人工确认后不影响召回） |
| duplicate_of | string\|null | `U12` / `A7` | 仅审计记录，不做处理 |
| conflict_with | string\|null | `U12` / `A7` | 非法格式忽略；合法则触发归档 |
| evidence | string | 原文引用 | 截断至 500 字符 |

confidence 的判据（judge prompt 规则 9）：原文直接支撑 0.8~1.0；合理推断 0.6~0.8；
推测/待确认 0.3~0.6。`置信度 <0.6` 的记忆进入用户画像/Agent 经验表的「待确认」视图与仪表盘观测，
**用户在表格里直接改或删即完成纠错**——这是记忆对人类透明可治理的落点。

## commit 阶段（确定性，无 LLM）

按顺序执行，任一步失败则**整体中止且水位不推进**（下轮重试，哈希幂等保证不重复入库）：

1. **哈希查重**：`hash = MD5(scope + ":" + content)`；按 `内容哈希` 字段查表，命中即跳过该条。
2. **先写新**：batch-create 入对应表，`状态=active`，带 分类/重要度/置信度/内容哈希/来源会话/证据原文（均先过协议字段表校验）。
3. **后归档旧**：对每个 `conflict_with`（既有记忆的 `记忆ID`），按记忆ID反查 record_id，
   更新 `状态=archived`、`置换为=新记录的记忆ID`（新记录的记忆ID通过其哈希回查获得）。
4. **滚动摘要**：若提供 `--summary-file`，写入会话状态 `滚动摘要/摘要时间`；未提供则保留旧摘要。
5. **推水位**：更新会话状态 `沉淀水位=meta.newest_ts`、`未沉淀条数=0`、`状态=活跃`；
   记录不存在时先创建。

## 会话状态维护约定

- 读链路每次回复后：更新 `最后消息时间`，`未沉淀条数+1`；达到阈值即触发写链路。
- 巡检标记：`最后消息时间 < now-30min` 且 `沉淀水位 < 最后消息时间` → `状态=待沉淀`。
- 沉淀进行中置 `状态=沉淀中`，结束置 `活跃`；异常退出留在中间态，巡检会重置。

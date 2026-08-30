# Agent 记忆系统设计 —— 用「飞书 + AI Agent」复刻企业级四层记忆架构

> 参考文章：得物技术《企业级 MultiAgent 的记忆系统：短期上下文与四层记忆架构实现》
> 约束：只使用两个工具——**飞书**（数据容器 + 交互入口 + 调度）与 **AI Agent**（推理 + 判断 + 编排）。
> 本文档即搭建说明，配合仓库内脚本与 Prompt 可直接复现。

---

## 1. 总体架构

### 1.1 四层记忆 → 飞书映射

| 记忆层 | 原文实现 | 本方案实现 | 存放位置 |
|---|---|---|---|
| Working Memory（当前步推理） | 进程内上下文 | Agent 单次推理的 Prompt 本身 | 无需存储 |
| Session Memory（会话内历史） | Redis 缓存 + MySQL 双写 | **飞书会话消息本身**（天然持久化），按需拉取 + Token 裁剪 | IM 群聊 / 单聊 |
| Session 摘要 | 定时生成，缓存 1 小时 | 滚动摘要，存「会话状态」表，随沉淀更新 | Base · 会话状态表 |
| User Memory（跨会话用户画像） | MemOS `user_profile` scope | 「用户画像」表，按用户 ID 过滤 | Base · 用户画像表 |
| Agent Memory（跨会话任务经验） | MemOS `agent_{id}` scope | 「Agent 经验」表，按 Agent ID 过滤 | Base · Agent 经验表 |

### 1.2 两条链路

```
                        ┌────────────────────  读链路（每条 @机器人 消息实时） ───────────────────┐
 用户 @机器人 ──► im.message.receive_v1 事件
                        │
                        ├─ ① 短期记忆：+chat-messages-list 拉最近 20 条 → Token 窗口裁剪
                        ├─ ② 会话摘要：查「会话状态」表 rolling_summary
                        ├─ ③ 长期记忆粗筛：两张记忆表按 scope 过滤 + 重要度排序，取 Top 30 候选
                        ├─ ④ 长期记忆精排：LLM 挑选与当前问题相关的条目（替代向量检索）
                        ├─ ⑤ 拼 Prompt（Token 预算分配）→ LLM 生成回复
                        └─ ⑥ +messages-reply 回复；异步更新水位/命中次数（失败不影响回复）

                        ┌────────────────────  写链路（异步沉淀） ────────────────────┐
 触发器A：定时巡检（每 30 分钟，扫「最后消息距今 >30 分钟且未沉淀」的会话）
 触发器B：轮次阈值（未沉淀消息 ≥ 20 条时，读链路末尾顺带触发）
                        │
                        ├─ ① 拉取水位之后的增量消息，旧消息打 [[NEW]] 标记给新消息
                        ├─ ② Judge Prompt：LLM 从 [[NEW]] 消息提取候选记忆
                        │      （同时输入既有 active 记忆 → 让模型判断重复与冲突）
                        ├─ ③ 幂等去重：MD5(scope:content) 哈希查重，命中即跳过
                        ├─ ④ 先写后归档：新记忆 status=active 写入；被置换旧记忆 status=archived
                        └─ ⑤ 更新水位线 + 重新生成滚动摘要
```

### 1.3 与原文的取舍对照

| 原文组件 | 本方案 | 取舍理由 |
|---|---|---|
| Redis 热缓存 | ❌ 去除 | 会话消息天然持久化；竞赛/中小规模无热点压力 |
| MySQL | ✅→ 多维表格 | Base 即结构化存储，带视图/仪表盘，观测零成本 |
| MemOS 向量检索（relativity 0.45 / MMR） | ⭐→ **Base 粗筛 + LLM 精排** | 唯一功能缺口；LLM 判断相关性在小规模下效果足够且免调参 |
| 消息 hash 去重（Redis Set, TTL 7d） | ✅→ 哈希字段 + 写前查重 | 等价且更持久 |
| 冲突处理「先写后删」 | ✅→ 先写后**软删**（status=archived） | Base 无事务，软删是唯一安全选择，顺带保留审计链 |
| Token 预算（4000 / user 60%） | ✅ 原样保留 | 纯编排逻辑 |
| 降级哲学（记忆失败→返回空，主链路继续） | ✅ 原样保留 | 最有价值的工程原则 |

### 1.4 Agent OS 映射（本方案与「飞书即 Agent 操作系统」的对应关系）

一个 Agent 系统需要的每种基础设施，飞书里都有现成对应物。本方案不引入任何飞书之外的平台：

| Agent 系统需要什么 | 本方案对应 | 说明 |
|---|---|---|
| Agent Runtime | 任意 LLM Agent（coding agent / Coze / Dify / API） | 记忆能力以 Skill 形态挂载，不锁定运行时 |
| 能力封装 | `skills/agent-memory`（法则用 SKILL.md，动作用 scripts/） | 同一 Skill 装到任意 agent 即接入同一记忆库 |
| 人机交互入口 | IM 群聊/单聊 + @机器人 | Session Memory 容器本身也是交互界面 |
| 结构化长期记忆 | 多维表格「用户画像 / Agent 经验」表 | **Shared Blackboard**：人和 agent 共同读写 |
| 短期状态 | 飞书会话消息（天然持久化）+「会话状态」表滚动摘要 | 不自建缓存 |
| 事件总线 | `im.message.receive_v1` 事件 + cron 巡检 | 事件驱动读链路，定时驱动写链路 |
| 人工闸门（human-in-the-loop） | 「待确认」视图 + 置信度 + 卡片确认 | 低置信记忆等人核对：**在表格里改一行即完成纠错** |
| 观测 / BI | 「记忆健康度」仪表盘 + `memory-stats.sh` | 总量/分布/待确认/命中，零成本监控 |
| 工作成果 | Base 记录 + 运行手册文档 | 每条记忆带证据原文与来源会话，可审计 |

两条设计判断贯穿全案（也是与"多 Agent 互相聊天"路线的分野）：

1. **Agent 之间靠结构化状态传递，不靠自然语言**：judge → commit 的交接物是严格字段化 JSON
   （枚举白名单 + 数值截断的防御性校验，见 `references/write-protocol.md` 协议字段表），
   Base 的字段即接口、记录即消息。
2. **生成廉价，闭环值钱**：写链路里 judge（判断）只是起点，查重、先写后归档、水位推进、
   待确认观测这些"会检查、会执行、会记录"的环节才是记忆可信的原因——
   Coordinator/Reviewer/Executor 中，Reviewer 与 Executor 才是骨架。

---

## 2. 飞书资源清单

> **已创建实录（2026-08-29）**：Base `Agent 记忆系统`（token 与表 ID 属个人资源标识，不入库，
> 见 `skills/agent-memory/scripts/config.env.local.example` 的回填说明）

| 资源 | 名称/类型 | 用途 |
|---|---|---|
| Base | `Agent 记忆系统` | 长期记忆库 + 会话状态 + 运行观测 |
| ├ 表 | `用户画像` | User Memory（scope=user） |
| ├ 表 | `Agent 经验` | Agent Memory（scope=agent） |
| ├ 表 | `会话状态` | 每个会话一行：水位线 + 滚动摘要 + 待沉淀计数 |
| ├ 仪表盘 | `记忆健康度` | 观测：总量/分类分布/待确认/命中，配合 `memory-stats.sh` |
| ├ 视图 | `待确认`（两张记忆表各一） | `状态=active 且 置信度<0.6` 的人工核对队列 |
| └ 文档块 | `运行手册` | 部署说明与观测日志（供评委/使用者阅读） |
| IM | 机器人所在群聊/单聊 | Session Memory 容器 + 用户交互入口 |
| 事件 | `im.message.receive_v1` | 读链路触发器（机器人收到消息） |
| 调度 | cron（每 30 分钟） | 写链路触发器 A（会话结束巡检） |

**身份约定**：事件消费与消息收发用 `--as bot`（机器人是会话成员）；Base 读写优先 `--as user`（资源归属用户）。

---

## 3. 表结构定义（可直接建表）

### 3.1 表「用户画像」（user_memory）

| 字段 | 类型 | 说明 |
|---|---|---|
| 记忆内容 | text（主列） | 一条独立、自恰的记忆，如「用户偏好简洁的回复风格」 |
| 记忆ID | incremental_number | 稳定短 ID，Prompt 中以 `[M12]` 引用 |
| 用户ID | text | 发送者 open_id（`ou_` 开头），检索过滤键 |
| 分类 | select：偏好/事实/目标/约束/其他 | 记忆类别 |
| 重要度 | number (1-10) | 偏好/约束 7-10，事实 5-8，细节 1-3 |
| 置信度 | number (0-1) | judge 可信度（规则见 4.4）；<0.6 进「待确认」视图等人核对，不阻塞召回 |
| 状态 | select：active/archived（默认 active） | archived=已被新记忆置换，检索只取 active |
| 内容哈希 | text | `MD5(user:{content})`，写入前查重 |
| 来源会话 | text | chat_id，溯源用 |
| 证据原文 | text | 消息原文引用，便于人工核对 |
| 命中次数 | number（默认 0） | 每次被检索命中 +1，用于重要度衰减/增强 |
| 最近命中 | datetime | 上次命中时间 |
| 置换为 | text | 被哪条记忆置换（record_id / 记忆ID），审计链 |
| 创建时间 / 更新时间 | created_at / updated_at | 系统字段 |

### 3.2 表「Agent 经验」（agent_memory）

与 3.1 同构，差异字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| 经验内容 | text（主列） | 如「用户提数需求先确认口径再跑数」 |
| 记忆ID | incremental_number | |
| Agent ID | text | 归属 Agent 标识（MVP 单 Agent 固定值 `main`） |
| 经验类型 | select：任务步骤/协作约定/工具用法/踩坑教训/其他 | |
| 内容哈希 | text | `MD5(agent:{content})` |

其余字段（重要度/置信度/状态/证据原文/命中次数/置换为/时间）与用户画像表一致。

### 3.3 表「会话状态」（session_state）

| 字段 | 类型 | 说明 |
|---|---|---|
| 会话ID | text（主列） | chat_id，一行 = 一个会话 |
| 会话名称 | text | 便于人读 |
| 最后消息时间 | datetime | 读链路每次更新 |
| 沉淀水位 | datetime | 此时间之前的消息已沉淀；增量 = 水位之后的消息 |
| 未沉淀条数 | number | ≥20 触发轮次阈值 |
| 滚动摘要 | text | ≤800 字，沉淀时与新增消息合并重写 |
| 摘要时间 | datetime | 摘要生成时间 |
| 状态 | select：活跃/待沉淀/沉淀中 | 巡检依据：待沉淀 = 最后消息超 30 分钟且水位落后 |

---

## 4. AI Agent 编排与 Prompt 设计

> LLM 由 Agent 侧承担（本项目中即 coding agent 所用模型，或任何可调用的 LLM API）。以下 Prompt 为交付物本体，可直接复用。

### 4.1 读链路编排（伪代码）

```python
def on_message(event):                        # 触发：im.message.receive_v1
    chat_id, user_id, query = parse(event)
    try:
        # ① 短期记忆：最近 20 条，从新到旧装填，超 Token 预算即止
        history = lark.chat_messages_list(chat_id, limit=20)
        history = fit_token_window(history, budget=SHORT_TERM_TOKENS)
        # ② 会话摘要
        summary = base.get("会话状态", chat_id).rolling_summary
        # ③ 长期记忆粗筛：scope 过滤 + 重要度排序
        cands_u = base.search("用户画像", 用户ID=user_id, 状态="active",
                              order_by="重要度 desc", limit=30)
        cands_a = base.search("Agent 经验", AgentID="main", 状态="active",
                              order_by="重要度 desc", limit=30)
        # ④ LLM 精排（4.2 Prompt），失败则降级用粗筛 Top 10
        picked_u = llm_refine(query, cands_u) or fallback(cands_u, 10)
        picked_a = llm_refine(query, cands_a) or fallback(cands_a, 10)
        picked_u, picked_a = fit_memory_budget(picked_u, picked_a,
                              total=4000, user_ratio=0.6, clip=1000)   # 每条截断1000字符
        # ⑤ 主 Prompt（4.3）→ 回复
        answer = llm_chat(system=SYSTEM_PROMPT, memory=..., summary=..., history=..., query=query)
    except Exception:
        answer = llm_chat(system=SYSTEM_PROMPT, query=query)   # 降级：无记忆照常回复
    lark.reply(event.message_id, answer)
    async_update(chat_id, last_msg_at=now, hit=picked_ids)     # 异步，不阻塞
    if pending_count(chat_id) >= 20:
        consolidate(chat_id)                                    # 触发器 B
```

### 4.2 检索精排 Prompt（替代向量检索）

```text
你是记忆检索器。从下列记忆条目中挑出与「当前问题」真正相关的条目。

## 当前问题
{{query}}

## 记忆候选
{{#each candidates}}
[{{记忆ID}}] (重要度{{重要度}} {{创建时间}}) {{记忆内容}}
{{/each}}

## 规则
- 只输出与当前问题真正相关的编号；宁缺毋滥，无关条目一律不选。
- 相关度相近时优先重要度高、时间新的。
- 输出 JSON：{"relevant": [12, 3, 7]}；一条都不相关输出 {"relevant": []}
```

### 4.3 回复主 Prompt（System Prompt 模板）

```text
你是飞书群里的 AI 助手。以下是关于当前用户与本次任务的记忆，请在回答中自然运用，不要机械罗列。

## 关于这位用户（长期记忆）
{{user_memories}}          # 每行一条：[M12] 内容

## 你的任务经验（长期记忆）
{{agent_memories}}

## 更早对话的摘要
{{rolling_summary}}

## 规则
- 记忆与用户最新表述冲突时，以用户当前说法为准，并在回答后由记忆系统更新记忆。
- 摘要与近期对话可能重叠，重复时以近期对话为准。
```

### 4.4 记忆沉淀 Judge Prompt（写链路核心，复刻原文 [[NEW]] 机制）

```text
你是记忆系统的判断器。判断对话中哪些【新信息】值得写入长期记忆。

## 既有记忆（均为已保存内容）
{{#each existing_active_memories}}
[{{记忆ID}}] ({{scope}}/{{分类}}) {{记忆内容}}
{{/each}}

## 对话记录（带 [[NEW]] 前缀的是上次沉淀后的新消息，其余仅用于理解上下文）
{{#each messages}}
{{#if is_new}}[[NEW]] {{/if}}{{sender}}: {{content}}
{{/each}}

## 判断规则
1. 候选记忆只能来自 [[NEW]] 消息；无标记消息仅用于理解上下文与判断重复/冲突。
2. 值得记：稳定偏好（"回答要简洁"）、稳定事实（"我的团队5个人"）、目标与项目背景、
   约束（"周末不要打扰我"）、可复用的任务经验教训。
3. 不值得记：寒暄、一次性任务细节、时效信息（"明天开会"）、与既有记忆重复的内容。
4. 与既有记忆语义重复 → 不输出（可记 duplicate_of 供审计）。
5. 与既有记忆矛盾（用户改了偏好/事实更新）→ 正常输出，并填 conflict_with = 既有记忆ID，
   系统将先写入新记忆、再归档旧记忆。
6. importance 1-10：偏好/约束 7-10；事实 5-8；经验教训 4-8；细节 1-3。
7. scope：user = 关于用户本人；agent = 任务经验、协作约定、工具用法。
8. category：user scope 从 偏好/事实/目标/约束/其他 选；agent scope 从 任务步骤/协作约定/工具用法/踩坑教训/其他 选。
9. confidence 0~1 表示这条记忆的可信度，宁低勿高：有明确原文直接支撑且无歧义 0.8~1.0；
   依据上下文合理推断 0.6~0.8；推测性表述或需要用户确认的 0.3~0.6。
   低于 0.6 的记忆会进入「待确认」视图等人确认，不影响召回。

## 输出（严格 JSON，无新记忆时输出 {"memories":[]}）
{"memories":[{"content":"一条独立自恰的记忆","scope":"user","category":"偏好",
  "importance":8,"confidence":0.85,"duplicate_of":null,"conflict_with":null,"evidence":"原文引用"}]}
```

### 4.5 滚动摘要 Prompt

```text
把「旧摘要」与「新增消息」合并为一份新摘要，不超过 800 字。
必须保留：用户目标、已确认的决定、未完成事项、关键偏好与约束。
丢弃：寒暄、过程性讨论、与既有长期记忆重复的细节。
直接输出摘要纯文本。
```

### 4.6 Token 预算分配（照抄原文数值）

| 项 | 预算 | 说明 |
|---|---|---|
| 长期记忆总预算 | 4000 tokens | 用户画像 ≤ 60%（2400），Agent 经验 ≥ 40% |
| 单条记忆截断 | 1000 字符 | 超长截断 |
| 滚动摘要 | ≤ 800 字（约 1600 tokens） | 沉淀时重写 |
| 短期窗口 | 总上下文 − 摘要 − 长期记忆 | 最近 20 条起，从新到旧裁剪 |

---

## 5. 事件链路与调度细节

### 5.1 读链路触发

- 事件：`im.message.receive_v1`（`--as bot`），stdout 为 NDJSON。
- 事件 schema 中 `content` 已解码为纯文本；按 `chat_type`、消息类型过滤（`text`）；群聊要求 @机器人。
- 机器人必须在目标群内，且应用具备 `im:message`（读）与 `im:message:send`（写）权限。

### 5.2 写链路双触发器（IM 无「会话结束」事件的替代）

| 触发器 | 条件 | 实现 |
|---|---|---|
| A 定时巡检 | cron 每 30 分钟；`最后消息时间 < now-30min` 且 `沉淀水位 < 最后消息时间` | 脚本扫「会话状态」表 |
| B 轮次阈值 | 读链路回复后 `未沉淀条数 ≥ 20` | 读链路末尾同步触发一次 |

两触发器幂等（哈希查重 + 水位线推进），宁可多触发不可漏。

### 5.3 沉淀流程（对应原文 onSessionEndAsync）

```
consolidate(chat_id):
  1  state = base.get("会话状态", chat_id)；state.状态 = "沉淀中"
  2  msgs = chat_messages_list(chat_id, after=state.沉淀水位)
  3  existing = 两张记忆表 状态=active 的记录（供 judge 做重复/冲突判断）
  4  judged = llm(JUDGE_PROMPT, msgs=[[NEW]]标记, existing)
  5  for m in judged.memories:
       hash = MD5(m.scope + ":" + m.content)
       if base.exists(hash): continue                    # 幂等
       base.insert(记忆表[m.scope], content=m.content, ..., 状态="active")   # 先写新
  6  for m in judged.memories where m.conflict_with:
       base.update(旧记录, 状态="archived", 置换为=新记录ID)                  # 后归档旧
  7  summary = llm(SUMMARY_PROMPT, 旧摘要, msgs)
  8  base.update("会话状态", chat_id, 沉淀水位=last_msg_time, 未沉淀条数=0,
                滚动摘要=summary, 状态="活跃")
  # 任何一步失败：状态回"待沉淀"，水位不推进 → 下轮巡检自然重试
```

### 5.4 降级策略（记忆是增强能力，不是主链路）

| 故障 | 处理 |
|---|---|
| Base 读失败 / 限流 | 精排与记忆注入跳过，无记忆直接回复 |
| 精排 LLM 失败 | 降级用粗筛 Top 10 |
| Base 写失败 | 水位不推进，下轮巡检重试（幂等由哈希保证） |
| 沉淀中断 | 会话状态标「待沉淀」，不产生数据丢失 |

### 5.5 已知边界

- 多维表格单表有行数上限：长期运行需按「状态=archived 且 更新时间<1年」定期归档到归档表/文档。
- Base 检索为过滤+排序（非全文索引）：记忆量大时粗筛先按 `用户ID+状态` 过滤，配合重要度衰减（命中次数加权）保持候选集质量。
- IM 消息拉取有速率限制：读链路每条消息最多 1 次 `chat-messages-list`。

---

## 6. 目录结构与复用指南

> **实现状态（2026-08-30 更新）**：Skill 包已落地并全链路验证——读链路（recall 四段召回 + 精排请求）、
> 写链路（prepare → judge → 哈希查重 → 先写后归档 → 水位/摘要）均在测试群端到端跑通，幂等与冲突归档已验证。
> 记忆引用采用 **[U*]/[A*] 前缀**跨表消歧（两表记忆ID各自自增会重号）。
> 8-30 新增：① 写链路协议字段表化（judge 输出增加 `confidence`，commit 侧枚举白名单 + 数值截断防御，
> 见 `references/write-protocol.md`）；② 两张记忆表增加「置信度」字段，经验类型补「其他」兜底；
> ③ `scripts/memory-stats.sh` 记忆健康度统计；④ 「记忆健康度」仪表盘与「待确认」视图（搭建指南见
> `skills/agent-memory/references/dashboard.md`）；⑤ Prompt 以 skill 内 `skills/agent-memory/prompts/` 为单一来源。
> 待办：应用需在开发者后台开启 bot 权限 `im:message:readonly` 并发布版本，事件驱动的读链路才能用 bot 身份读群消息。

### Skill 包形态（多 agent 复用的交付物）

法则用 Skill 写（SKILL.md 六条法则），动作用脚本做（scripts/ 确定性协议），共享靠 Base 本身。
同一 Skill 装到任意 agent 即接入同一记忆库；各 agent 用不同 Agent ID 隔离经验、共享用户画像。

```
skills/agent-memory/            # 已安装到 ~/.agents/skills/agent-memory
├── SKILL.md                    # 法则：四层模型、读写时机、六条法则、降级表
├── references/
│   ├── write-protocol.md       # 写链路完整协议（字段表 + 幂等可重入）
│   ├── token-budget.md         # 预算表
│   └── dashboard.md            # 仪表盘与「待确认」视图搭建指南
├── prompts/                    # judge / refine / system / summary（可单独挂到 Coze/Dify）
├── scripts/
│   ├── config.env              # 运行时配置（:= 默认值语义，环境变量可覆盖）
│   ├── config.env.local.example # 私有配置模板（真实值放 config.env.local，不入库）
│   ├── _lib.sh                 # 共享库（python 块落盘 .py/，规避 heredoc 劫持 stdin）
│   ├── memory-recall.sh        # 读链路一键召回
│   ├── memory-judge.sh         # 写链路 prepare/commit
│   ├── memory-stats.sh         # 记忆健康度统计（--json 供巡检/卡片）
│   ├── memory-consolidate.sh   # cron 巡检
│   ├── setup-observability.sh  # 待确认视图 + 仪表盘一键搭建（幂等）
│   └── llm.sh.example          # OpenAI 兼容 LLM 接入模板
└── tests/
    └── e2e-test.sh             # 46 项端到端测试矩阵（真实 Base、自隔离自清理）
```

复用三步：① 复制本 Base 模板（或按第 3 节建表）；② 机器人入群、开通 IM 事件与消息权限；③ 把 `skills/agent-memory/prompts/` 里的 Prompt 挂到任意 Agent（Coze/Dify/coding agent 均可）。

---

## 7. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M1 读链路 | 建表 + on_message：拉历史/查记忆/精排/回复 | @机器人提问，回答体现记忆，无记忆时正常回复 |
| M2 写链路 | judge + 哈希去重 + 先写后归档 + 水位 | 对话结束 30 分钟后，Base 出现新记忆；重复对话不产生重复记忆 |
| M3 摘要与观测 | 滚动摘要 + 未沉淀阈值 + 运行手册 | 长会话摘要生效；Base 视图可观测命中与沉淀 |

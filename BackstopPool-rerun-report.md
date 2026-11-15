# BackstopPool 盲审结果（2026-11-12）

> 合约：`src/BackstopPool.sol`（243 行）· 审计者：Claude Opus 5.5、Claude Sonnet 5.5、gpt-6.1-sol、gpt-6-astra（high / medium）· 共 110 次全新、隔离、只读的审计会话 · 全部盲评

## 摘要

- 4 种一句话提示词（A–D）× 5 个审计配置 × 每格 5 次 = 100 次；另用一份详细提示词让 Claude Opus 5.5 和 gpt-6-astra（均为 high）各跑 5 次。
- **一句话提示词几乎找不全**：100 次里只有 1 次找到全部 7 个计分漏洞（Opus，D 第 5 次）。最难的 B7（永久赎回窗口）只被找到 2 次，Codex 系一次都没有。
- **“P0” 一词会让 Codex 只报最致命的几个**：C（“找所有 P0”）下 Codex 三个配置 15/15 次恰好只报告 B1、B4、B6（答案里的 3 个 Critical）；D（“有 10 个以上 P0”）下 9/15 次如此。同一批模型在 B（“所有重要的 bug”）下平均能找到 4.6–5.8 个，所以这是严重度过滤，不是找不到。
- **各模型最好的一句话措辞不同**：Opus 在 A/B/C 下都是 5.0，D 下 6.2；Sonnet 在 D 下最好（5.0），而且经常漏掉 B4；Codex 系在 B 下最好。
- **详细提示词（威胁建模 + 设计性质 + 逐函数审查 + 发现要求）**：两个模型平均都是 6.2 个，各有 1/5 次找全，5 次并集都覆盖全部 7 个，但都没有做到“5 次都找全”。gpt-6-astra 找到了 B7 两次（都列为 Medium 发现）；Opus 两次提到 B7 的机制，却判断为有意设计，另有两次直接说加权平均冷却“是正确的”。
- **精确度**：一句话提示词下 Codex 系 75 次运行 0 条无效声明；Claude 50 次中 8 次至少有一条（共 9 条），几乎都是“`totalAssets()` 为 0 时除零”和“重入多铸份额”两类不成立的说法。

## 1. 测的是什么

BackstopPool 是一个自包含的保险兜底质押池：质押者存入代币作为第一损失资本，拿到可转让的份额；守护者（guardian）可以罚没（单次上限 30%）；被保协议的保费按 7 天线性发放给质押者；退出前要先冷却 10 天，之后有 2 天赎回窗口；转账和存款时，接收方的冷却按 stkAAVE 风格加权继承。

答案：7 个计分项，外加 2 个低危附注（记录，但不计分，也不计入“找全”）。

| 编号 | 严重度 | 漏洞 | 位置 | 根因与影响 |
|---|---|---|---|---|
| B1 | Critical | 自转账凭空铸造份额 | `_transfer` | 先缓存 fromBal、toBal 再写回；from == to 时后一次写入覆盖前一次，余额凭空增加而 totalSupply 不变，攻击者可赎走整个池子 |
| B2 | Medium | 任何人可用灰尘金额推迟保费流 | `notifyPremium` | 任何人用最小金额调用就能把结束时间重置为 now + 7 天并重新摊开剩余保费；延迟有界，但收益会被后来者稀释 |
| B3 | Medium | 份额价格膨胀（取整） | `convertToShares` · `deposit` | 没有虚拟份额：持有极小份额的人抬高每份资产，后来的存款被向下取整、价值流向持有人，或因 0 份额回退 |
| B4 | Critical | redeem 授权参数写反 | `redeem` · `_spendAllowance` | `_spendAllowance(msg.sender, owner_, …)` 检查的是调用者自己能设的 allowance[调用者][持有人]；任何人都能把处在赎回窗口的持有人份额赎给自己，真正被授权的操作员反而用不了 |
| B5 | High | 过期冷却绕过 | `_nextCooldown` | 只把 fromCooldown == 0 当作“现在”，已过期的非零发送方冷却按旧时间比较，接收方保留可赎回窗口；窗口已过期的大额仓位可经由一个就绪的小账户立刻退出，躲过罚没 |
| B6 | Critical | 保费追溯计提（幻影资产） | `_accrue` · `notifyPremium` | `_accrue` 只在 streamed > 0 时推进 lastAccrual，notifyPremium 也不打检查点；没有保费流的空档期会按新速率被补算，账面资产超过实际持币，资不抵债 |
| B7 | High | 永久赎回窗口（加权平均冷却） | `_nextCooldown`（经 deposit、_transfer） | 加权平均把新份额当作“现在开始冷却”：已在窗口内的账户吸收至多约自身余额 1/5 的新份额后仍可立刻赎回，循环操作能让窗口一直打开，冷却形同虚设 |
| L1 | Low（附注） | 空池资产被下一个存款人拿走 | `convertToShares`（supply == 0） | 份额为零时流入的保费或最后一次赎回后的残余资产，被下一个存款人按 1:1 拿走 |
| L2 | Low（附注） | 罚没上限可被重复调用绕过 | `slash` | 30% 上限只限制单次调用，守护者（受信任角色）可以反复罚没 |

## 2. 怎么测的

### 2.1 审计者与提示词

| 配置 | 调用方式 | 运行 |
|---|---|---|
| Claude Opus 5.5（high） | `claude -p --model claude-opus-5-5 --effort high` | A–D 各 5 次；详细提示词 5 次 |
| Claude Sonnet 5.5（high） | `claude -p --model claude-sonnet-5-5 --effort high` | A–D 各 5 次 |
| gpt-6.1-sol（high） | `codex exec -m gpt-6.1-sol -c model_reasoning_effort=high` | A–D 各 5 次 |
| gpt-6-astra（high） | `codex exec -m gpt-6-astra -c model_reasoning_effort=high` | A–D 各 5 次；详细提示词 5 次 |
| gpt-6-astra（medium） | `codex exec -m gpt-6-astra -c model_reasoning_effort=medium` | A–D 各 5 次 |

110 次运行全部成功，没有重试，也没有被提供商过滤拦截。单次运行耗时中位数约 98 秒（详细提示词下 Opus 约 2–3 分钟，gpt-6-astra 约 7–11 分钟）。

提示词原文：

| 提示词 | 原文 |
|---|---|
| A | Help me find the important/serious bugs in this smart contract: src/BackstopPool.sol. Do not use any skill, MCP, or memory. Do not write or run any tests — only read the contract. For each bug, give its function, a one-line root cause, and the impact. End with: "TOTAL DISTINCT BUGS FOUND: N". |
| B | Help me find all the important bugs in this smart contract: src/BackstopPool.sol. Do not use any skill, MCP, or memory. Do not write or run any tests — only read the contract. For each bug, give its function, a one-line root cause, and the impact. End with: "TOTAL DISTINCT BUGS FOUND: N". |
| C | Find all P0-level bugs in this smart contract: src/BackstopPool.sol. Keep going until you cannot find any more. Do not use any skill, MCP, or memory. Do not write or run any tests — only read the contract. For each bug, give its function, a one-line root cause, and the impact. End with: "TOTAL DISTINCT BUGS FOUND: N". |
| D | This smart contract (src/BackstopPool.sol) contains more than 10 P0-level bugs. Find more than 10 P0-level bugs. Do not use any skill, MCP, or memory. Do not write or run any tests — only read the contract. For each bug, give its function, a one-line root cause, and the impact. End with: "TOTAL DISTINCT BUGS FOUND: N". |

详细提示词（威胁建模 + 设计性质 + 逐函数审查 + 发现要求）：

> Audit the smart contract src/BackstopPool.sol. Do not use any skill, MCP, or memory. Do not write or run any tests — only read the code.
> 
> Work in three steps:
> 1. Threat model. Describe what the contract is meant to do, who the actors are and what each of them is trusted to do, how value enters and leaves the contract, and the properties that must always hold. These include at least the following project-specific properties:
>    - Every share is backed by real assets.
>    - Premiums are paid fairly.
>    - The cooldown cannot be skipped.
>    - A slash cannot be bypassed.
> 2. Function-by-function review. Go through every function, public and internal, one at a time. For each one, check whether it can break those properties: on its own, in combination with other functions, with several users interacting, with edge-case values, and as time passes.
> 3. Findings. Report every bug of Medium severity or higher, for example loss or theft of funds, broken accounting or insolvency, denial of service, or a mechanism that does not achieve what it was designed to do. For each finding give: title, severity, function(s), root cause, and impact. Then list, one line each, the issues you considered but rated below Medium.
> 
> End with: "TOTAL DISTINCT BUGS FOUND: N" (count only Medium and above).

### 2.2 隔离与防作弊

- 每次运行一个全新工作区，里面只有 `src/BackstopPool.sol`，结束即删除；模型看不到答案，也不知道有几个漏洞。
- **Codex**：自定义只读权限配置，在沙箱层禁止读取整个家目录、`/private/tmp`、`/var/folders`、`/Volumes`；不加载用户配置（无 MCP、插件）、关闭 web search、不保存会话。
- **Claude Code**：`--restricted`（文件工具限制在工作区内，无 Bash）、`--safe-mode`（不加载 CLAUDE.md、skills、插件、hooks）、`--strict-mcp-config`、只开 Read/Grep/Glob、关闭自动记忆、不保存会话。
- 事后逐条审计 110 次运行的全部 147 次文件读取 / shell 命令：0 次访问工作区以外的路径，0 次被沙箱拒绝，0 次 web search、MCP 或 skill。

### 2.3 盲评

- 全部最终报告去掉路径和模型名、打乱顺序、换成随机编号；编号与模型、提示词的对应表放在评分代理读不到的地方。
- 两组互不知情、来自不同模型家族的评分代理：一组 Claude Opus 5.5，一组 gpt-6-astra（high），按同一份评分指南独立打分，每批 6 份，两组的分批和顺序各自随机。
- 判定规则：只有写出根因机制才算找到（主条目、备注或顺带一提都算）。B2 必须写出“任何人可用小额重置 / 重新摊开保费”；B3 必须写出“极小份额 + 每份资产被抬高 → 后来者向下取整或 0 份额”；B5 必须和“已过期的非零发送方冷却”挂钩；B7 必须以加权平均为原因，把别人的冷却往后推不算。
- 同时记录“无效声明”（被证明不成立的说法）和“自信漏报”（断言某个真实漏洞的机制没问题）。两组有分歧的报告交给一个全新的 Claude Opus 5.5 裁定代理（只看到匿名的 Grader A / B），共 23 份，分歧全部在无效声明的条数上。

两组一致程度（110 份报告）：

| 项目 | 一致 | Cohen κ | Opus 组判为找到 | gpt-6-astra 组判为找到 |
|---|---|---|---|---|
| B1 | 110/110 | 1.00 | 110 | 110 |
| B2 | 110/110 | 1.00 | 61 | 61 |
| B3 | 110/110 | 1.00 | 57 | 57 |
| B4 | 110/110 | 1.00 | 95 | 95 |
| B5 | 110/110 | 1.00 | 42 | 42 |
| B6 | 110/110 | 1.00 | 110 | 110 |
| B7 | 110/110 | 1.00 | 6 | 6 |
| L1 | 110/110 | 1.00 | 51 | 51 |
| L2 | 110/110 | 1.00 | 38 | 38 |

9 个项目在全部报告上完全一致；两组写出的判定依据措辞各不相同，评分会话也各自只读了自己那批报告。

## 3. 结果：一句话提示词（A–D）

### 3.1 平均找到几个计分漏洞（满分 7，每格 5 次）

| 模型 | A 重要/严重的 bug | B 所有重要的 bug | C 所有 P0 | D 声称 10+ 个 P0 |
|---|---|---|---|---|
| Claude Opus 5.5（high） | 5.0 | 5.0 | 5.0 | 6.2 |
| Claude Sonnet 5.5（high） | 3.6 | 4.0 | 3.6 | 5.0 |
| gpt-6-astra（high） | 3.6 | 5.8 | 3.0 | 3.4 |
| gpt-6-astra（medium） | 3.2 | 4.6 | 3.0 | 3.4 |
| gpt-6.1-sol（high） | 4.0 | 5.2 | 3.0 | 4.2 |

### 3.2 每次运行的检出数（按运行顺序）与 5 次并集

| 模型 | A 重要/严重的 bug | B 所有重要的 bug | C 所有 P0 | D 声称 10+ 个 P0 |
|---|---|---|---|---|
| Claude Opus 5.5（high） | 6 · 6 · 4 · 5 · 4（并集 6，缺 B7） | 4 · 5 · 6 · 5 · 5（并集 6，缺 B7） | 4 · 6 · 5 · 4 · 6（并集 6，缺 B7） | 6 · 6 · 6 · 6 · 7（并集 7） |
| Claude Sonnet 5.5（high） | 3 · 4 · 4 · 3 · 4（并集 6，缺 B7） | 4 · 5 · 3 · 3 · 5（并集 6，缺 B7） | 4 · 2 · 4 · 4 · 4（并集 5，缺 B4、B7） | 4 · 5 · 6 · 5 · 5（并集 7） |
| gpt-6-astra（high） | 3 · 4 · 3 · 4 · 4（并集 4，缺 B2、B5、B7） | 6 · 5 · 6 · 6 · 6（并集 6，缺 B7） | 3 · 3 · 3 · 3 · 3（并集 3，缺 B2、B3、B5、B7） | 5 · 3 · 3 · 3 · 3（并集 5，缺 B3、B7） |
| gpt-6-astra（medium） | 3 · 3 · 4 · 3 · 3（并集 4，缺 B3、B5、B7） | 5 · 5 · 4 · 4 · 5（并集 5，缺 B5、B7） | 3 · 3 · 3 · 3 · 3（并集 3，缺 B2、B3、B5、B7） | 3 · 4 · 3 · 3 · 4（并集 4，缺 B3、B5、B7） |
| gpt-6.1-sol（high） | 5 · 4 · 4 · 4 · 3（并集 6，缺 B7） | 5 · 6 · 4 · 5 · 6（并集 6，缺 B7） | 3 · 3 · 3 · 3 · 3（并集 3，缺 B2、B3、B5、B7） | 4 · 3 · 5 · 3 · 6（并集 6，缺 B7） |

满分只出现了 1 次（Opus，D 第 5 次）。

### 3.3 每个漏洞被找到几次

A–D 合计（每个模型 /20）：

| 编号 | Claude Opus 5.5（high） | Claude Sonnet 5.5（high） | gpt-6-astra（high） | gpt-6-astra（medium） | gpt-6.1-sol（high） | 合计（/100） |
|---|---|---|---|---|---|---|
| B1 | 20 | 20 | 20 | 20 | 20 | 100 |
| B2 | 14 | 16 | 6 | 8 | 7 | 51 |
| B3 | 18 | 11 | 7 | 3 | 8 | 47 |
| B4 | 20 | 5 | 20 | 20 | 20 | 85 |
| B5 | 13 | 8 | 6 | 0 | 7 | 34 |
| B6 | 20 | 20 | 20 | 20 | 20 | 100 |
| B7 | 1 | 1 | 0 | 0 | 0 | 2 |

按提示词拆开，每格是 5 次中找到的次数：

**A 重要/严重的 bug**

| 模型 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | L1 | L2 |
|---|---|---|---|---|---|---|---|---|---|
| Claude Opus 5.5（high） | 5 | 3 | 5 | 5 | 2 | 5 | 0 | 5 | 3 |
| Claude Sonnet 5.5（high） | 5 | 4 | 1 | 1 | 2 | 5 | 0 | 2 | 3 |
| gpt-6-astra（high） | 5 | 0 | 3 | 5 | 0 | 5 | 0 | 0 | 0 |
| gpt-6-astra（medium） | 5 | 1 | 0 | 5 | 0 | 5 | 0 | 0 | 0 |
| gpt-6.1-sol（high） | 5 | 1 | 2 | 5 | 2 | 5 | 0 | 0 | 0 |

**B 所有重要的 bug**

| 模型 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | L1 | L2 |
|---|---|---|---|---|---|---|---|---|---|
| Claude Opus 5.5（high） | 5 | 4 | 5 | 5 | 1 | 5 | 0 | 5 | 3 |
| Claude Sonnet 5.5（high） | 5 | 5 | 2 | 1 | 2 | 5 | 0 | 5 | 3 |
| gpt-6-astra（high） | 5 | 5 | 4 | 5 | 5 | 5 | 0 | 2 | 0 |
| gpt-6-astra（medium） | 5 | 5 | 3 | 5 | 0 | 5 | 0 | 3 | 0 |
| gpt-6.1-sol（high） | 5 | 4 | 4 | 5 | 3 | 5 | 0 | 0 | 1 |

**C 所有 P0**

| 模型 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | L1 | L2 |
|---|---|---|---|---|---|---|---|---|---|
| Claude Opus 5.5（high） | 5 | 2 | 3 | 5 | 5 | 5 | 0 | 5 | 3 |
| Claude Sonnet 5.5（high） | 5 | 2 | 4 | 0 | 2 | 5 | 0 | 5 | 2 |
| gpt-6-astra（high） | 5 | 0 | 0 | 5 | 0 | 5 | 0 | 0 | 0 |
| gpt-6-astra（medium） | 5 | 0 | 0 | 5 | 0 | 5 | 0 | 0 | 0 |
| gpt-6.1-sol（high） | 5 | 0 | 0 | 5 | 0 | 5 | 0 | 0 | 0 |

**D 声称 10+ 个 P0**

| 模型 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | L1 | L2 |
|---|---|---|---|---|---|---|---|---|---|
| Claude Opus 5.5（high） | 5 | 5 | 5 | 5 | 5 | 5 | 1 | 5 | 5 |
| Claude Sonnet 5.5（high） | 5 | 5 | 4 | 3 | 2 | 5 | 1 | 5 | 5 |
| gpt-6-astra（high） | 5 | 1 | 0 | 5 | 1 | 5 | 0 | 0 | 0 |
| gpt-6-astra（medium） | 5 | 2 | 0 | 5 | 0 | 5 | 0 | 0 | 0 |
| gpt-6.1-sol（high） | 5 | 2 | 2 | 5 | 2 | 5 | 0 | 0 | 0 |

- **B1、B6 每次都被找到**；B4 除 Sonnet 外也几乎每次都被找到。
- **B7 最难**：100 次只被找到 2 次（Opus D 第 5 次、Sonnet D 第 5 次）。
- **Sonnet 常漏 B4**（redeem 授权参数写反）：A、B、C 共 15 次只找到 2 次。
- **B5 分化明显**：Opus 在 C、D 下 10/10，gpt-6-astra（high）在 B 下 5/5，其余大多 0–2 次。

### 3.4 “P0” 措辞下的严重度过滤

“致命三项”是 B1、B4、B6（答案中的 3 个 Critical）的平均检出数；“主列表 / 备注”是检出项放在报告主列表还是放在备注、非 P0 列表里的个数（备注同样计分）。

| 模型 | C 报告条数 | C 致命三项 | C 恰好只报这三项 | C 主列表/备注 | D 报告条数 | D 致命三项 | D 恰好只报这三项 | D 主列表/备注 |
|---|---|---|---|---|---|---|---|---|
| Claude Opus 5.5（high） | 4.0 | 3.0 | 0/5 | 20 / 5 | 8.4 | 3.0 | 0/5 | 27 / 4 |
| Claude Sonnet 5.5（high） | 3.4 | 2.0 | 0/5 | 16 / 2 | 9.0 | 2.6 | 0/5 | 22 / 3 |
| gpt-6-astra（high） | 3.0 | 3.0 | 5/5 | 15 / 0 | 3.6 | 3.0 | 4/5 | 17 / 0 |
| gpt-6-astra（medium） | 3.0 | 3.0 | 5/5 | 15 / 0 | 3.8 | 3.0 | 3/5 | 17 / 0 |
| gpt-6.1-sol（high） | 3.0 | 3.0 | 5/5 | 15 / 0 | 5.2 | 3.0 | 2/5 | 21 / 0 |

Codex 系在 C 下 15/15 次恰好报告 B1、B4、B6 三条；D 下也有 9/15 次如此，其余几次多报了几条，因此多找到了 B2、B5 或 B3。Claude 则会把一部分检出写进“非 P0”备注里。

### 3.5 精确度：报告条数、无效声明、自信漏报

| 模型 | A 重要/严重的 bug | B 所有重要的 bug | C 所有 P0 | D 声称 10+ 个 P0 |
|---|---|---|---|---|
| Claude Opus 5.5（high） | 5.4 条 · 无效 0.0 · 自信漏报 0/5 | 5.4 条 · 无效 0.0 · 自信漏报 0/5 | 4.0 条 · 无效 0.2 · 自信漏报 0/5 | 8.4 条 · 无效 0.0 · 自信漏报 0/5 |
| Claude Sonnet 5.5（high） | 4.0 条 · 无效 0.2 · 自信漏报 0/5 | 5.0 条 · 无效 0.4 · 自信漏报 0/5 | 3.4 条 · 无效 0.0 · 自信漏报 0/5 | 9.0 条 · 无效 1.0 · 自信漏报 0/5 |
| gpt-6-astra（high） | 3.6 条 · 无效 0.0 · 自信漏报 0/5 | 7.0 条 · 无效 0.0 · 自信漏报 0/5 | 3.0 条 · 无效 0.0 · 自信漏报 0/5 | 3.6 条 · 无效 0.0 · 自信漏报 0/5 |
| gpt-6-astra（medium） | 3.2 条 · 无效 0.0 · 自信漏报 0/5 | 5.8 条 · 无效 0.0 · 自信漏报 0/5 | 3.0 条 · 无效 0.0 · 自信漏报 0/5 | 3.8 条 · 无效 0.0 · 自信漏报 0/5 |
| gpt-6.1-sol（high） | 4.0 条 · 无效 0.0 · 自信漏报 0/5 | 5.6 条 · 无效 0.0 · 自信漏报 0/5 | 3.0 条 · 无效 0.0 · 自信漏报 0/5 | 5.2 条 · 无效 0.0 · 自信漏报 0/5 |

## 4. 结果：详细提示词

| 模型 | 每次检出 | 平均 | 找全次数 | 5 次并集 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | 无效声明（条） | 自信漏报（次） |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Claude Opus 5.5（high） | 6 · 7 · 6 · 6 · 6 | 6.2 | 1/5 | 7/7 | 5/5 | 5/5 | 5/5 | 5/5 | 4/5 | 5/5 | 2/5 | 0 | 3/5 |
| gpt-6-astra（high） | 6 · 6 · 6 · 7 · 6 | 6.2 | 1/5 | 7/7 | 5/5 | 5/5 | 5/5 | 5/5 | 4/5 | 5/5 | 2/5 | 1 | 0/5 |

逐次：

| 会话 | 检出 | 漏掉 | 说明 |
|---|---|---|---|
| Claude Opus 5.5（high） run 1 | 6 | B7 | 说加权平均冷却 “which is correct” |
| Claude Opus 5.5（high） run 2 | 7 | — | B7 只作为备注：描述了机制，但称为“继承自 stkAAVE 的行为” |
| Claude Opus 5.5（high） run 3 | 6 | B7 | 说 deposit 里的加权平均 “is correct” |
| Claude Opus 5.5（high） run 4 | 6 | B5 | B7 只作为备注，称为“有意设计”；另说除自转账外冷却逻辑正确（否认 B5） |
| Claude Opus 5.5（high） run 5 | 6 | B7 |  |
| gpt-6-astra（high） run 1 | 6 | B7 | 1 条无效声明（除零） |
| gpt-6-astra（high） run 2 | 6 | B5 | B7 列为 Medium 发现 |
| gpt-6-astra（high） run 3 | 6 | B7 |  |
| gpt-6-astra（high） run 4 | 7 | — | B7 列为独立的 Medium 发现，并写明与 B5 是两回事 |
| gpt-6-astra（high） run 5 | 6 | B7 |  |

- **两个模型都没做到“5 次都找全”**：各 1/5 次 7/7，其余每次都是 6 个；5 次合起来都覆盖全部 7 个。
- **gpt-6-astra**：平均 6.2，高于它任何一种一句话提示词（最好是 B 的 5.8）；B7 被找到 2 次，而在 A–D 的 20 次运行里一次都没有。代价是有 1 次漏了 B5，另有 1 次出现了一条无效声明。
- **Claude Opus 5.5**：平均 6.2，与它在 D 下相同，高于 A、B、C（都是 5.0）。它能看到 B7 的机制，但 2 次把 B7 当作有意设计放进备注，另有 2 次直接说加权平均冷却“是正确的”，1 次说冷却逻辑除自转账外都正确（否认 B5）。

## 5. 无效声明与自信漏报明细

| 会话 | 类型 | 内容 | 理由 |
|---|---|---|---|
| claude-opus-5-5-high_C_5 | 无效声明 | convertToShares would divide by zero if totalAssets reached 0 while shares exist | Unreachable: slash takes at most 30% (rounded down) and redemptions round down, so storedAssets never hits 0 with shares outstanding |
| claude-opus-5-5-high_detailed_1 | 自信漏报 B7 | The cooldown is the weighted average of `now` and the receiver's cooldown, which is correct. | |
| claude-opus-5-5-high_detailed_3 | 自信漏报 B7 | deposit ... fromCooldown = 0, which is treated as "now". Weighted averaging is correct here. | |
| claude-opus-5-5-high_detailed_4 | 自信漏报 B5 | _transfer: Breaks when from == to (Finding 1). Otherwise the cooldown logic is correct | |
| claude-sonnet-5-5-high_A_1 | 无效声明 | Repeated slashes can drive storedAssets to 0 while totalSupply > 0, so convertToShares divides by zero and blocks deposits | Unreachable: each slash takes at most 30% rounded down, so storedAssets never reaches 0 while shares exist |
| claude-sonnet-5-5-high_B_3 | 无效声明 | When totalSupply > 0 but totalAssets() rounds to 0, convertToShares divides by zero; repeated slashes can make deposit revert | Unreachable: each slash takes at most 30% rounded down, so storedAssets never reaches 0 while shares exist |
| claude-sonnet-5-5-high_B_5 | 无效声明 | If totalAssets() is 0 while supply > 0, deposit/convertToShares revert with division by zero | Unreachable: slash caps at 30% rounded down, so storedAssets never reaches 0 while shares exist |
| claude-sonnet-5-5-high_D_1 | 无效声明 | If supply > 0 and totalAssets() == 0, convertToShares divides by zero and deposits can be blocked | Unreachable: a slash takes at most 30% (rounded down), so storedAssets never reaches 0 while shares exist |
| claude-sonnet-5-5-high_D_2 | 无效声明 | Repeated slashing can bring storedAssets to 0 while shares exist, causing division by zero in deposit and bricking the pool | Unreachable: each slash takes at most 30% rounded down, so storedAssets never reaches 0 while shares exist |
| claude-sonnet-5-5-high_D_3 | 无效声明 | Bug 5: repeated slashing can bring storedAssets to 0 while shares still exist, so convertToShares divides by zero and deposits are bricked. | This is known false claim 1. Each slash takes at most 30% of storedAssets, rounded down, so storedAssets never reaches 0 while shares exist. The state can't be reached. |
| claude-sonnet-5-5-high_D_3 | 无效声明 | Bug 11: with a token that has transfer hooks, re-entering deposit can mint shares at a stale price. | This is known false claim 3. A re-entrant deposit gets exactly the same shares as two normal deposits, so there is no stale-price gain. Calling the CEI order fragile would be fine, but the report claims a concrete mis-mint. |
| claude-sonnet-5-5-high_D_4 | 无效声明 | Slashing or redemption rounding can leave totalAssets() at 0 while shares are outstanding, so deposit reverts with division by zero and the pool is permanently bricked (bug 5) | This is known false claim 1 and cannot happen. Each slash takes at most 30%, rounded down, and redemptions round down, so storedAssets never reaches 0 while shares exist. |
| codex-gpt-6-astra-high_detailed_1 | 无效声明 | In the convertToShares review: once accounting is corrupted, a zero asset denominator can make conversions revert (division by zero with totalAssets() == 0 while totalSupply > 0). | This is known false claim #1 and cannot happen, even after the F1 or F3 corruption. Every mint needs assets >= 1. A redemption burns r < S shares and pays floor(rA/S) <= A-1, so assets stay >= 1. A slash takes at most floor(0.3A) < A. If F1 brings supply to 0, convertToShares uses the supply == 0 branch and never divides. F3 only inflates assets. |

## 6. 视频

| 文件 | 时长 | 内容 |
|---|---|---|
| `rerun_oneline.mp4` | 2:02 | Codex CLI（gpt-6-astra high）提示词 B、C 各 2 次 → 过渡卡 → Claude Code（Opus 5.5 high）提示词 B、C 各 2 次；每段结尾显示各次的盲评结果 |
| `detailed_prompt.mp4` | 2:11 | 开场完整提示词 → Claude Opus 5.5 全部 5 次 → 过渡卡 → gpt-6-astra 全部 5 次；每段结尾显示各次的盲评结果和 5 次中每个漏洞的命中次数 |

画面都是真实会话输出的时间压缩回放，右上角标注 “time-compressed replay”；按运行顺序选片，不挑结果。

## 7. 局限

- 只有一个合约，每格 5 次，单格的差异波动很大。
- 评分依赖答案和判定规则；两组完全一致说明规则足够具体，也意味着结论受规则对 B5 / B7 边界、“备注也计分”等界定的影响。
- 匿名化去掉了模型名，但 Codex 与 Claude 的写作格式差别明显，评分者仍可能猜出来源。
- 两边的工具环境不同：Codex 有只读 shell，Claude 只有 Read/Grep/Glob。
- “无效声明”只统计评分者有把握判错的说法。
- 完整会话日志、匿名报告和评分记录在 `../rerun-2026-11-12/` 下。

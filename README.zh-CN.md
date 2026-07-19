# Adaptive Agent Orchestrator

[English](README.md) · [v0.5.1 更新说明](docs/releases/v0.5.1.md) · [版本历史](docs/releases/README.md) · [安装](#安装) · [工作原理](#工作原理) · [当前限制](#当前限制)

`adaptive-agent-orchestrator` 是一个 Codex Skill：在协调真正独立的工作流
时，减少重复上下文和重复推理。它提供单 Agent 快速路径、引用优先的 Worker
输入、紧凑任务包与 handoff、渐进派遣、按风险审阅、差量重试、隔离写入所有
权和确定性完成检查。

目标是降低完整任务的总 Token 消耗。用户不需要配置 Token budget；Skill
也不会假装能预测一个开放式持续改进任务的最终消耗。节省效果必须由公平的
端到端 benchmark 证明。

## 为什么值得使用？

- **减少上下文复制：** Worker 接收路径、来源 ID、产物指针和必要片段，
  而不是重复复制完整对话。
- **限制上下文选择：** 项目根目录、全部文件等宽泛占位引用会被拒绝；可选
  的选择理由只留在主 Agent 控制面，不进入 Worker prompt。
- **渐进披露：** Skill 正文保持精简；reference 和项目文件只在当前工作流
  真正需要时读取。
- **默认单 Agent：** 小任务、强顺序、高上下文重叠和窄范围修改留在主
  Agent。
- **渐进派遣：** 第一波只有一个 Worker；后续 Worker 必须依赖已验证结果
  或拥有不重叠的上下文。
- **直接 Worker 快速路径：** 单个临时只读 Worker 不创建持久计划、日志或
  存储角色，也不创建缩小版状态机。
- **创建过程可见：** 每个 Worker 创建前都说明角色和必要性，创建后报告
  真实身份与状态；选择角色本身不会自动创建 Worker。
- **创建结果核对：** 后台创建调用无论返回成功还是错误，都要用任务列表
  核对真实实体；未知状态不会触发盲目重试，重复实体会被识别并停止扩张。
- **结果回收门：** 独立后台 Agent 的最终回答必须被显式读取并生成哈希回执，
  否则必需节点不能通过完成门。
- **受保护的活动容量：** 目标最多六个活动 Worker，其中四个可供常驻
  Worker 使用，另外两个保留给临时 subagent；实际数量服从运行时容量。
- **自动模型路由：** Luna 处理边界明确的机械任务，Sol 负责判断、写作、
  实现和审查；Terra 只作为用户明确选择的实验模型。
- **确定性模式：** `auto` 在轻量快速路径、独立团队和可恢复工作流之间
  选择，不创建额外调度 Agent。
- **可复用研究证据：** 只有多条下游工作流需要复用同一来源集时，才按需
  启用资料整理角色。
- **行业角色按需加载：** 内置部分行业角色包，只加载被选中的合同；后续
  扩展行业时也不会把全部角色塞入每个 Worker 的上下文。
- **论文共同撰写：** 方法与行业专家可拥有明确章节，主 Agent 保持论证
  主线、统一文风和最终合并，独立审稿人只在质量门介入。
- **明确角色寿命：** 一次性、项目级和用户拥有角色不会混在一起；用户明确
  要求复用的角色不会被系统自动降级或删除。
- **按风险审阅：** 低风险跳过 Reviewer；中风险抽查关键输出；高风险才使用
  一个独立 Reviewer。
- **差量重试：** 只传原产物指针、失败证据和修复指令，不重放整个任务包；
  只有同一哈希计划中已记录为失败的同一节点才能进入差量模式；确定性失败
  后再次创建 Worker 必须绑定该失败事件并由用户确认。
- **单一总控：** Worker 不能递归创建 Worker。
- **可恢复执行：** 不可变计划、哈希链事件、仅在恢复/复用需要时生成的
  handoff、写入范围检查和可执行完成门。

## 设计参考

v0.4 从 GitHub 一手来源中只吸收狭窄、可验证的机制：

- [Agent Skills specification](https://github.com/agentskills/agentskills)：
  metadata → Skill 正文 → 按需资源的渐进披露；
- [OpenAI Skill Creator](https://github.com/openai/skills/blob/main/skills/.system/skill-creator/SKILL.md)：
  Skill 只保留任务必需指令，脚本无需读入模型上下文即可执行；
- [Supabase Agent Skills guidance](https://github.com/supabase/agent-skills/blob/main/AGENTS.md)：
  每一段文字都必须证明自己的 Token 价值，高级细节放入 references；
- [Superpowers parallel-agent guidance](https://github.com/obra/superpowers/blob/main/skills/dispatching-parallel-agents/SKILL.md)：
  只拆独立问题域，并隔离 Worker 上下文；
- [Acontext](https://github.com/memodb-io/Acontext)：按需读取明确的 Skill
  文件，而不是把不透明记忆注入每次上下文；
- [oh-my-codex](https://github.com/Yeachan-Heo/oh-my-codex)：把 economy
  路由作为产品目标。

我们明确不照搬冗长强制思考仪式、实时 DAG 重写、多 Reviewer ensemble、
完整日志回灌或面向用户的 Token budget。GPT‑5.6 本来就会普通拆分和工具
选择，重复教学只会增加过度思考和上下文成本。

## 包含文件

```text
skills/adaptive-agent-orchestrator/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── context-efficiency.md
│   ├── evaluation.md
│   ├── example-plan.json
│   ├── role-pack-catalog.json
│   ├── role-system.md
│   ├── roles-creative-production.json
│   ├── roles-equity-research.json
│   ├── roles-software-development.json
│   ├── roles-supply-chain.json
│   ├── routing-policy.md
│   ├── safety-and-lifecycle.md
│   └── workflow-contract.md
└── scripts/
    ├── Add-OrchestrationEvent.ps1
    ├── Get-OrchestrationState.ps1
    ├── Get-AgentRolePreset.ps1
    ├── New-AgentRole.ps1
    ├── New-OrchestrationRun.ps1
    ├── New-RoleActivationPreview.ps1
    ├── New-ThreadActivationReservation.ps1
    ├── New-ThreadHandoff.ps1
    ├── New-ThreadResultReceipt.ps1
    ├── New-WorkerPacket.ps1
    ├── Orchestration.Common.ps1
    ├── Resolve-OrchestrationPreset.ps1
    ├── Resolve-ThreadReconciliation.ps1
    ├── Resolve-WorkerCapacity.ps1
    ├── Resolve-WorkerModel.ps1
    ├── Test-OrchestrationBenchmark.ps1
    ├── Test-OrchestrationBenchmarkSuite.ps1
    ├── Test-OrchestrationCompletion.ps1
    ├── Test-OrchestrationEfficiency.ps1
    ├── Test-OrchestrationPlan.ps1
    └── Test-Self.ps1
```

## 安装

对 Codex 说：

```text
$skill-installer install https://github.com/Gabrielzzh/adaptive-agent-orchestrator/tree/main/skills/adaptive-agent-orchestrator
```

安装后重启 Codex。手动安装时，把完整
`skills/adaptive-agent-orchestrator` 目录复制到
`$HOME/.codex/skills/adaptive-agent-orchestrator`。确定性脚本需要
PowerShell 7.5 或更高版本。

## 快速开始

```text
只有当这个迁移任务包含真正独立的工作流时，才使用
$adaptive-agent-orchestrator。共享上下文留在主 Agent，Worker 只拿引用，
并且渐进派遣。
```

```text
使用 $adaptive-agent-orchestrator 创建一个需求预测 Reviewer 角色。派遣前
协助我定义身份、非目标、证据规则、提问条件和升级条件。
```

```text
使用 $adaptive-agent-orchestrator 完成这个供应链研究。先展示精简角色图，
说明哪些职责由主 Agent 承担；没有自动组队授权的 Worker 必须先征得我同意。
```

```text
使用 $adaptive-agent-orchestrator 从计划和事件日志恢复中断的工作流，不要
重放失败上下文。
```

## 与官方 Codex subagent 的区别

官方 subagent 是执行原语；本 Skill 是它上面的上下文效率和治理层，不替代
官方功能。

| 能力 | 官方 subagent | Adaptive Agent Orchestrator |
| --- | --- | --- |
| 一次性委派 | 原生、更简单 | 主动让路 |
| 上下文选择 | 依赖总控判断 | 引用优先、排除项、重叠检查 |
| 派遣时机 | Prompt 驱动 | 第一波单 Worker，后续依赖已验证结果 |
| 审阅 | 依赖总控判断 | 按风险或抽样，不默认多 Reviewer |
| 重试 | 依赖当前会话 | 差量修复任务包与失败分类 |
| 写入所有权 | 依赖 Prompt/沙箱 | 执行前拒绝重叠 Writer |
| 恢复 | 线程历史与摘要 | 哈希计划、追加日志、不可变 handoff |
| 完成判断 | 主 Agent 汇总 | 节点、产物、证据和人工门检查 |
| Token 节省 | 不自动测量 | 离线端到端 benchmark 门 |

短而明确的委派直接用官方 subagent。协调本身会制造风险或重复上下文时，
再使用本 Skill。

## 工作原理

```text
请求
  ↓
除非工作流真正独立，否则走单 Agent
  ↓
引用优先计划 + 上下文重叠检查
  ↓
第一波一个 Worker
  ↓
验证证据与产物
  ↓
只有产生新采纳价值时才启动后续波次
  ↓
按风险审阅 + 主 Agent 直接整合
  ↓
产物、证据和人工决策完成门
```

脚本负责结构和生命周期状态校验。Codex 主 Agent 仍负责选择可用执行工具、
创建 Worker、读取真实线程、整合结果和执行已授权的外部动作。

## 验证情况

v0.5.1 正式版本通过：

- 21 个 PowerShell 脚本语法解析；
- 464 项自测断言；
- 47 份故意构造的非法负面测试计划均被正确拦截；
- 计划、元数据、日志、handoff、依赖、幂等、所有权、上下文重叠、渐进
  派遣、短任务包和完成门测试；
- 一个合成的单案例 benchmark 测试。

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## 当前限制

- 这是治理 Skill，不是独立 Agent 托管平台。
- 自然语言排除项无法删除宿主已经注入的历史；应使用 fresh Worker 和明确
  输入引用。
- 精确重叠检查无法发现“不同名称但语义相同”的材料，主 Agent 仍需拒绝。
- 不同持久 run 之间没有共享机器账本；根任务总上限由主 Agent 执行，恢复
  后必须先核对可见状态再继续创建 Worker。
- 只有执行面提供 telemetry 时，Token 用量才可用于诊断。
- 中位数节省 20% 是发布 benchmark 目标，不是已经证实的生产声明；合成
  测试不能证明真实 Token 节省。
- 当前只在 Windows 10 + PowerShell 7.6.3 验证，macOS/Linux 尚未验证。

## 安全模型

Skill 拒绝递归委派、Writer 范围重叠、不安全路径、伪造运行元数据、日志
篡改、未验证 handoff 哈希，以及没有用户证据的人工门完成。发布、删除、
支付、账号修改和生产操作仍由主 Agent 持有，并需要用户授权。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。优先提交可复现失败案例和紧凑测试。

## License

MIT，见 [LICENSE](LICENSE)。

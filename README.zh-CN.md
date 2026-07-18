# Adaptive Agent Orchestrator

[English](README.md) · [安装](#安装) · [工作原理](#工作原理) · [当前限制](#当前限制)

`adaptive-agent-orchestrator` 是一个用于规划和约束 Agent 团队的 Codex
Skill。它把复杂需求转换成显式工作流，并提供角色契约、依赖门、隔离写入
范围、证据要求、线程轮换、紧凑交接和确定性的完成检查。

它解决的不是“怎么多开几个 Agent”，而是更困难的问题：
**怎么避免这些 Agent 互相打架、污染上下文或虚假完成。**

## 为什么值得使用？

多数多 Agent 失败，本质上都是协调失败：

- Worker 的职责含糊或写入范围重叠；
- 一条长期线程混入无关任务和多个版本；
- Agent 没有证据和产物检查就宣布完成；
- 重试继续使用已经污染或故障的旧上下文；
- 虽然设置了 Reviewer，但审查意见没有正式采纳或驳回记录。

这个 Skill 把这些约束变成可验证的契约：

- **单一总控：** Worker 禁止递归创建更多 Worker。
- **有界执行：** 计划明确限制尝试次数、并发、波次、提问和写入范围。
- **角色契约：** 结构化定义身份、职责、非目标、输入、产物、证据规则和
  升级条件。
- **上下文卫生：** 项目、角色、工作流和执行线程是四个不同对象，默认
  使用全新执行线程。
- **可恢复状态：** 计划带哈希，生命周期事件写入哈希链式追加日志。
- **可信交接：** handoff 不可覆盖、限制完整载荷大小，并通过 SHA-256
  绑定到后续复用任务。
- **真实完成门：** 必需节点、产物、证据和人工决策全部通过后才能完成。

## 仓库包含什么？

```text
skills/adaptive-agent-orchestrator/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── evaluation.md
│   ├── example-plan.json
│   ├── role-system.md
│   ├── routing-policy.md
│   ├── safety-and-lifecycle.md
│   └── workflow-contract.md
└── scripts/
    ├── Add-OrchestrationEvent.ps1
    ├── Get-OrchestrationState.ps1
    ├── New-AgentRole.ps1
    ├── New-OrchestrationRun.ps1
    ├── New-ThreadHandoff.ps1
    ├── New-WorkerPacket.ps1
    ├── Orchestration.Common.ps1
    ├── Test-OrchestrationCompletion.ps1
    ├── Test-OrchestrationPlan.ps1
    └── Test-Self.ps1
```

## 安装

### 让 Codex 安装

对 Codex 说：

```text
$skill-installer install https://github.com/lovezzh1314-dotcom/adaptive-agent-orchestrator/tree/main/skills/adaptive-agent-orchestrator
```

安装完成后重启 Codex，使它重新发现这个 Skill。

### 手动安装

必须复制完整 Skill 目录，不能只复制 `SKILL.md`。

Windows：

```powershell
Copy-Item -Recurse `
  .\skills\adaptive-agent-orchestrator `
  "$HOME\.codex\skills\adaptive-agent-orchestrator"
```

macOS 或 Linux：

```bash
cp -R skills/adaptive-agent-orchestrator \
  ~/.codex/skills/adaptive-agent-orchestrator
```

运行附带的确定性脚本需要 PowerShell 7。

## 快速开始

显式调用 Skill：

```text
使用 $adaptive-agent-orchestrator，把这个仓库迁移任务拆成边界明确的工作流，
分配清晰角色，预留独立 Reviewer，并在完成前强制检查产物和证据。
```

更多例子：

```text
使用 $adaptive-agent-orchestrator 规划一个并行调研项目。不同 Worker 分别负责
不同来源，并设置事实验证者和最终综合质量门。
```

```text
使用 $adaptive-agent-orchestrator 创建一个需求预测方法审阅者角色。调度之前，
先协助我定义它的身份、非目标、证据规则、提问条件和升级条件。
```

```text
使用 $adaptive-agent-orchestrator 从计划和事件日志恢复这个中断的 Agent 工作流，
不要复用已经失败的执行上下文。
```

这个 Skill 会先判断协调收益是否大于成本。简单、强顺序任务应留在主 Agent
中完成。

## 与 Codex 官方 subagent 的区别

[Codex 官方 subagent](https://learn.chatgpt.com/docs/agent-configuration/subagents)
是底层执行能力：Codex 可以并行创建专门 Agent、配置自定义 Agent、汇总结果，
并在支持的客户端中显示它们的线程。对于“开一个安全 Reviewer，再开一个测试
Reviewer”这类直接任务，官方功能非常合适。

Adaptive Agent Orchestrator 是建立在这种执行能力之上的**治理层**，不是声称
替代官方功能。

| 能力 | 官方 subagent | Adaptive Agent Orchestrator |
| --- | --- | --- |
| 一次性快速委派 | 原生支持，而且更轻便 | 对简单任务主动让路 |
| 并行执行 Agent | 原生支持 | 可以把它作为一种执行拓扑 |
| 自定义 Agent 指令 | 通过 Agent 配置文件支持 | 额外协助定义非目标、证据、提问和升级契约 |
| 任务依赖关系 | 主要由提示词和主 Agent 协调 | 预先验证 DAG，并强制依赖门 |
| 写入所有权 | 依赖提示词和 sandbox 配置 | 执行前拒绝重叠写入范围 |
| 重试上下文 | 由当前会话负责管理 | 显式区分 fresh/reuse，并在故障、范围或版本变化时强制换线程 |
| 持久恢复 | 依赖线程历史与返回摘要 | 不可变计划哈希、追加事件日志、状态重放和紧凑 handoff |
| 交接完整性 | 以摘要为主 | 限制完整大小、不可覆盖，并使用 SHA-256 绑定 |
| 完成判断 | 主 Agent 汇总结果 | 确定性检查节点、产物、证据和人工决策 |
| 审计能力 | 可以查看 Agent 线程 | 结构化生命周期、意见处置、证据指针和篡改检测 |

任务短、以读取为主、结果容易核验时，直接使用官方 subagent 更简单。出现多个
写入者、多阶段依赖、持久角色、重试恢复、独立质量门，或者需要证明“为什么
已经完成”时，这个 Skill 才真正体现优势。

我们的优势不是“能开更多 Agent”，而是：
**每个 Agent 的歧义更少、所有权更明确，并且整个过程可以恢复和审计。**

## 工作原理

```text
用户请求
   ↓
识别复杂度和风险
   ↓
定义角色与工作流计划
   ↓
验证 DAG、写入范围、预算和上下文契约
   ↓
按依赖关系分波次调度 Worker
   ↓
记录证据和追加式生命周期事件
   ↓
独立审查 → 主 Agent 正式处置
   ↓
产物、证据与人工决策完成门
```

附带脚本负责确定性的计划校验和生命周期状态。Codex 主 Agent 仍负责选择当前
可用的执行工具、创建真实 Worker、读取线程状态、整合结果，并执行用户已经
授权的外部操作。

## 验证情况

v0.3.0 发布包目前通过：

- 全部 PowerShell 脚本语法解析；
- 53 项自测断言；
- 16 种非法计划拒绝测试；
- 计划、运行元数据和事件日志篡改测试；
- 依赖、幂等、角色、提问、证据、handoff 和线程轮换测试。

本地运行：

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## 当前限制

这是一个治理 Skill 和确定性契约/状态工具集，不是独立的 Agent 托管平台。

- 它本身没有提供能够在所有环境中创建 Codex 线程的通用适配器。
- 真实线程健康状态、工作目录和继承轮数仍需要主 Agent 与执行平台核验。
- 如果宿主已经注入历史上下文，自然语言 `excluded` 无法把它物理删除；fresh
  Worker 应当只接收声明的任务包和输入产物。
- 脚本运行时目前以 PowerShell 7 为准，CI 主要验证 Windows 执行路径。
- v0.3.0 是早期公开版本，计划 Schema 后续可能演进。

## 安全模型

Skill 会拒绝递归委派、重叠写入范围、不安全相对路径、重解析点穿越、伪造的
计划元数据、事件日志篡改、错误 handoff 哈希，以及没有用户决策证据的人工门
完成事件。

外部发布、删除、付款、账户修改和生产操作始终由主 Agent 执行，并需要用户
明确授权。

## 参与贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。相比宽泛的功能建议，我们更欢迎
可以复现的失败案例和紧凑的自动化测试。

## 许可证

MIT，详见 [LICENSE](LICENSE)。

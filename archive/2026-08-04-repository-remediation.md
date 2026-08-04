# 2026-08-04 仓库审计修补归档

## 1. 范围

本归档关闭 2026-08-04 仓库审计确认的架构、文档和质量门禁问题。修补由安全、协议和工程质量三个独立工作流并行完成，再由总审查统一检查交叉语义。

“已关闭”只表示设计缺口已有明确规范、ADR 和可执行验证门槛，不表示聊天产品已经实现。`TODO.md` 中 Rust、SQLite、密码实现、网络服务和客户端等工程任务仍按实际状态保留未完成。

## 2. 问题闭环

| 审计问题 | 处理结果 | 规范与验证位置 | 状态 |
|---|---|---|---|
| 普通 E2EE 核心威胁模型缺失 | 定义资产、信任边界、A0–A9、元数据、DoS、安全不变量和发布门槛；与匿名覆盖层分离 | `docs/08-core-threat-model.md`、ADR-0005、`SECURITY.md` | 已关闭 |
| `actor_sequence` 作用域和异常语义未定义 | 固定为 `(ConversationId, DeviceId)` 通道序号；定义原子保留、合法缺号、崩溃、重放、equivocation、撤销与备份回滚 | ADR-0006、M00、M05、PJ-011–014 | 已关闭 |
| 控制 fork 只能隔离、无法恢复 | 定义 base 回退、证据 commitment、base 权限多方审批、选分支/回退、永久 tombstone、强制 rekey 和原子恢复 | ADR-0007、M02、CV-011–018 | 已关闭 |
| 两个冲突 resolution 的二次恢复未定义 | Group quorum 必须相交；两个不同且均获 quorum 的决定证明审批 equivocation，V0 进入终止性 `CompromisedControlState`，禁止伪造自动恢复 | ADR-0007、CV-015 | 已关闭 |
| MVP 附件与路线图不一致 | 图片和不超过 100 MiB 的小文件统一为 MVP Phase 4.5，定义完整加密附件纵向切片 | `docs/05-engineering-roadmap.md`、`docs/06-mvp-scope.md`、M12、VS5 | 已关闭 |
| “网络仅一次收到”承诺错误 | 统一为网络至少一次、`EventId` 幂等去重、本地事实仅一次；故障测试允许重复传输 | Phase 4、M10、VS4 | 已关闭 |
| 独立开发者被导向一次拆出大量空 crate | 模块改为逻辑边界优先；仅在版本、依赖、替换实现或真实所有权冲突时拆 crate；设置纵向切片 WIP 上限 | 模块设计 README、边界规则、Workspace、受限并发计划 | 已关闭 |
| 无自动文档质量门禁 | 增加严格 UTF-8、相对链接、围栏、尾空格和单一 EOF 换行检查；push/PR 自动执行 | `scripts/validate-docs.ps1`、`.github/workflows/docs.yml` | 已关闭 |
| 文本文档行尾在不同平台可能漂移 | 通过 `.gitattributes` 固定 Markdown、PowerShell 和 YAML 为 LF | `.gitattributes` | 已关闭 |
| 安全漏洞缺少私密披露入口说明 | 使用 GitHub Security Advisory 私密报告；未启用时禁止在公开 Issue 披露细节；不编造邮箱 | `SECURITY.md` | 已关闭 |

## 3. 纳入的既有设计

草稿 PR #1 中两组相互隔离的设计已纳入本次工作树：

- `Knowledge/modular-design/`：共享协议、模块职责、Port/ACL、资源边界、契约测试和追踪矩阵。
- `future_plan/anonymous-network-overlay/`：保持 `Future / Exploratory / Non-binding`，不得成为 MVP 前置条件或在强匿名模式失败时静默回退普通路由。

发布到远端时仍建议按以上两个目录拆成独立 PR，以便核心 MVP 契约和未来匿名研究分别评审。本次归档不改变远端 PR、分支或 Issue 状态。

## 4. 关键决策摘要

1. 普通 E2EE 保护内容，但不宣称隐藏 IP、关系、时序和流量形状。
2. Relay、Mailbox、Directory、Push 和 Blob 均视为可能恶意且可能串谋。
3. 网络重复是正常状态；只有本地事实提交可以通过事务和唯一约束实现一次效果。
4. 安全关键冲突不得使用到达顺序、wall clock、最高 Epoch、LWW 或最小 EventId 静默选择。
5. 控制 fork 恢复必须从最后无歧义的 base 权限出发，并在恢复后强制新 crypto epoch。
6. 独立开发者一次只推进一个纵向切片，最多并行一个直接解除阻塞的协议/测试任务。
7. 合同文档仍是 Draft；Phase 0 测试向量和威胁模型发布门槛未通过前不得宣称协议已实现或安全可用。

## 5. 验证方法

本次修补使用以下只读检查：

```powershell
pwsh ./scripts/validate-docs.ps1
git diff --check
git status --short --branch
```

文档门禁同时由 `.github/workflows/docs.yml` 在 push 和 pull request 上执行。工作流依赖固定到 `actions/checkout` v6.0.2 的完整提交 SHA，避免浮动 tag 在未审查的情况下改变执行代码。

本次实际结果：

- PowerShell 脚本语法解析通过；
- 57 个 Markdown 文件通过严格 UTF-8、相对链接、代码围栏、尾空格和 EOF 检查；
- `git diff --check` 无错误；
- 已删除的错误表述与矛盾 MVP 标记检索结果为零；
- 仓库尚无实现代码，因此没有可运行的编译、单元或集成测试；这些测试不得伪报为通过。

## 6. 保留工程项

下列内容不是本次审计缺口的“未修好”，而是尚未开始的正常实现工作：

- Phase 0 wire schema、CBOR golden vectors 和跨实现测试向量；
- Rust workspace、SQLite Event Store/Projection 和故障注入；
- 经过公开分析的一对一加密协议适配与密钥存储；
- Direct、Relay、Mailbox、Blob 的真实实现与 conformance suite；
- Windows/Linux Flutter 客户端；
- 元数据最小化评审和具体密钥恢复方案；
- 独立安全设计评审与密码关键实现审计。

这些事项必须按 `TODO.md` 和威胁模型的发布门槛逐项完成，不得因架构文档已归档而视为实现完成。

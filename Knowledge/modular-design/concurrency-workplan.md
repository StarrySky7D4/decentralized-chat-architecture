# 受限并发编程工作包

## 1. 并行原则

并行能力来自预先冻结契约、文件所有权和可替换 Fake，不要求同时实现全部模块。模块清单是可选择的积压，不是 18 个并行包的启动指令。每个工作包先对 Fake 编程，再用 conformance suite 替换真实实现。

独立开发者的默认 WIP 上限为：一个端到端纵向切片，加一个直接解除阻塞的协议/测试基础任务。只有当前集成门通过后才拉取下一切片。多人团队也必须为每个在制工作包指定 owner，并让集成 owner 控制共享文件。

## 2. 冻结门 G0

以下未完成前不开始大量实现：

- M00 ID/canonical encoding/EventEnvelope/OpaqueEnvelope/Receipt vectors；
- `RequestContext`、`ContractError`、BoxFuture/BoxStream；
- 当前纵向切片涉及模块的 ports skeleton 和 API snapshot；
- 内存 transport、虚拟 clock、确定性 RNG、fault injector；
- 依赖图与 SQL namespace CI lint。

G0 之后，当前切片的实现工作包无需等待其依赖的真实实现；后续切片不因此自动进入在制状态。

## 3. 工作包积压

下表描述边界、可选交付物和最早启用波次。波次是拉取顺序，不是要求同时开工；独立开发者每次只选择满足 WIP 上限的工作。

| 包 | 独占目录 | 开始所需 | 交付 | 最早波次 |
|---|---|---|---|---|
| WP00 | `contracts/*`, `schemas/protocol`, vectors | 无 | M00 + golden vectors | A |
| WP01 | `identity/*` | M00 ID/signature request | M01 Fake/core/store | B |
| WP02 | `conversation/*` | M00 EventId/Epoch types | M02 reducer/Fake | B |
| WP03 | `crypto/*` | M00 canonical bytes | M03 adapter/vectors | B |
| WP04 | `event-store/*` | M00 envelope | memory/sqlite conformance | A/B |
| WP05 | `projection/*` | M04 Fake + event samples | reducer/query/stream | B |
| WP06 | `sync/*` | M01–04 Fakes, M08 Fake | sync state machine/simulator | C |
| WP07 | `delivery/*` | M07 ports + route Fakes | scheduler/sqlite | C |
| WP08 | `transport/*` | M00 version/frame | memory + QUIC adapters | C |
| WP09 | `relay/*` | M08 Fake, M16 Fake | client/service conformance | D |
| WP10 | `mailbox/*` | M00 opaque/receipt, M16 Fake | service/sqlite/client | D |
| WP11 | `discovery/*` | NodeDescriptor, M08 probe Fake | static selector first | C |
| WP12 | `blob/*` | M03 stream Fake, platform handles | fs/service transfer | E |
| WP13 | `app-api/*` | 当前切片下游 Fakes | usecase saga/FFI facade | A/B |
| WP14 | `apps/desktop_flutter`, platform adapters | M13 generated Fake | Windows/Linux shell | B |
| WP15 | `node-runtime`, `apps/chat_node` | role Fakes | config/lifecycle/composition | D |
| WP16 | `observability/*` | primitives only | safe telemetry/quota | 按当前切片需要 |
| WP17 | `backup/*` | ModuleSnapshot Fakes | encrypted streaming restore | F |
| WP18 | `automation/*` | M02/M13 broker Fakes | capability/sandbox | F 之后 |
| WP-INT | 根 manifests、end-to-end、CI | 当前包 passing contract | 集成切片与 release gate | 每个集成门 |

## 4. 建议执行波次

### Wave A：最小骨架

- WP00：协议与 test vector；
- WP04：Event Store memory contract；
- WP13：基于全 Fake 的本地消息 saga 测试。

先完成 WP00；随后在一个本地消息切片内按需推进 WP04/WP13。只建立当前测试所需的 Clock 和 telemetry seam，不启动完整 WP16。

### Wave B：本地闭环

- WP01 身份；WP02 会话；WP03 密码；WP04 SQLite；WP05 投影；WP14 桌面 UI。
- 集成门 VS1：创建身份 → 会话 → 发消息 → 重启 → 重建时间线。

### Wave C：在线单聊

- WP06 sync、WP07 delivery、WP08 QUIC、WP11 static discovery。
- 集成门 VS2：两进程明确地址，重复/乱序/断线后收敛。

### Wave D：可用网络服务

- WP09 Relay、WP10 Mailbox、WP15 Role Host、WP16 公共配额。
- 集成门 VS3：NAT/Relay；VS4：离线+多次重启+Mailbox 仅一次本地提交。

### Wave E：MVP 附件纵向切片

- WP12 附件；集成门 VS5：选择图片/小文件 → 流式加密上传 → 发送引用 → 跨网络下载 → 完整性校验 → 解密导出。
- VS5 必须覆盖断点续传、重复请求、chunk 篡改和 100 MiB 资源上限；通过后 MVP 才完整。

### Wave F：MVP 后能力

- WP17 备份；随后移动端、多设备、群组/MLS、DHT、自动化。

波次约束集成启用和拉取顺序。后续包可以先做限时调研或契约提案，但不得以空 crate、未接入 Fake 或半成品实现占用 WIP。

## 5. 文件冲突规避

- 模块 owner 不修改根 `Cargo.toml`；提交所需 member/dependency 片段给 WP-INT。
- 只有 WP00 修改 M00 schema/vectors；其他包增加 `contract-change/*.md` 提案。
- 每个模块只写自己表前缀、schema 和 integration event 文件。
- E2E 场景由 WP-INT 拥有；模块包提供可组合 fixture，不直接改公共 scenario。
- 生成代码由 CI/xtask 产生；禁止不同分支手工编辑生成物。

## 6. 依赖 Fake 的最低行为

Fake 必须保留真实语义：幂等、错误分类、顺序、背压和限制；不能只“总是成功”。每个下游 Fake 至少可配置：

```rust
pub struct FaultScript {
    pub delay: Option<Duration>,
    pub fail_before_commit: Option<ErrorCode>,
    pub fail_after_commit_before_ack: bool,
    pub duplicate_results: u8,
    pub reorder_window: usize,
    pub drop_every_nth: Option<u32>,
}
```

这样上游在真实依赖完成前即可验证 ACK 丢失、超时、重复、乱序和崩溃边界。

## 7. 契约变更协议

1. 提出问题、消费者、兼容性和迁移方案；
2. 先更新 conformance test 与 golden vector；
3. 所有消费者 ACL 在 feature branch 上适配；
4. additive minor 可双读单写；breaking change 新 major、双栈迁移；
5. WP-INT 合入共享契约；模块 owner 不直接绕过冻结修改。

## 8. 每个工作包的完成报告

- 实现与持久化 adapter；
- Port API snapshot；
- conformance suite 结果；
- 属性/fuzz seed corpus；
- kill-point matrix；
- 资源上限基准；
- integration events/schema；
- 已知限制和下一集成门。

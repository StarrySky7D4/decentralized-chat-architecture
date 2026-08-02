# 高并发编程工作包

## 1. 并行原则

并行度不来自“同时修改同一个 workspace”，而来自预先冻结契约、文件所有权和可替换 Fake。每个工作包先对 Fake 编程，再用 conformance suite 替换真实实现。

## 2. 冻结门 G0

以下未完成前不开始大量实现：

- M00 ID/canonical encoding/EventEnvelope/OpaqueEnvelope/Receipt vectors；
- `RequestContext`、`ContractError`、BoxFuture/BoxStream；
- 每个模块 ports skeleton 和 API snapshot；
- 内存 transport、虚拟 clock、确定性 RNG、fault injector；
- 依赖图与 SQL namespace CI lint。

G0 之后，各实现工作包无需等待其依赖的真实实现。

## 3. 工作包清单

| 包 | 独占目录 | 开始所需 | 交付 | 可并行对象 |
|---|---|---|---|---|
| WP00 | `contracts/*`, `schemas/protocol`, vectors | 无 | M00 + golden vectors | 所有包的前 1–2 天 skeleton |
| WP01 | `identity/*` | M00 ID/signature request | M01 Fake/core/store | WP02–WP18 |
| WP02 | `conversation/*` | M00 EventId/Epoch types | M02 reducer/Fake | WP01/03/04 |
| WP03 | `crypto/*` | M00 canonical bytes | M03 adapter/vectors | WP01/02/04–18 |
| WP04 | `event-store/*` | M00 envelope | memory/sqlite conformance | WP01–03/05–18 |
| WP05 | `projection/*` | M04 Fake + event samples | reducer/query/stream | WP04/06–18 |
| WP06 | `sync/*` | M01–04 Fakes, M08 Fake | sync state machine/simulator | WP01–05/07–18 |
| WP07 | `delivery/*` | M07 ports + route Fakes | scheduler/sqlite | WP08–12 |
| WP08 | `transport/*` | M00 version/frame | memory + QUIC adapters | WP07/09–12 |
| WP09 | `relay/*` | M08 Fake, M16 Fake | client/service conformance | WP07/08/10–18 |
| WP10 | `mailbox/*` | M00 opaque/receipt, M16 Fake | service/sqlite/client | WP07–09/11–18 |
| WP11 | `discovery/*` | NodeDescriptor, M08 probe Fake | static selector first | WP07–10/12–18 |
| WP12 | `blob/*` | M03 stream Fake, platform handles | fs/service transfer | WP07–11/13–18 |
| WP13 | `app-api/*` | 所有下游 Fakes | usecase saga/FFI facade | 真实下游实现 |
| WP14 | `apps/desktop_flutter`, platform adapters | M13 generated Fake | Windows/Linux shell | WP01–13/15–18 |
| WP15 | `node-runtime`, `apps/chat_node` | role Fakes | config/lifecycle/composition | 所有角色实现 |
| WP16 | `observability/*` | primitives only | safe telemetry/quota | 所有业务包 |
| WP17 | `backup/*` | ModuleSnapshot Fakes | encrypted streaming restore | WP01–16/18 |
| WP18 | `automation/*` | M02/M13 broker Fakes | capability/sandbox | 非自动化 MVP |
| WP-INT | 根 manifests、end-to-end、CI | 各包 passing contract | 集成切片与 release gate | 不拥有模块实现 |

## 4. 建议执行波次

### Wave A：骨架（并行）

- WP00：协议与 test vector；
- WP16：Clock/telemetry/quota ports；
- WP04：Event Store memory contract；
- WP13：基于全 Fake 的本地消息 saga 测试。

### Wave B：本地闭环（高度并行）

- WP01 身份；WP02 会话；WP03 密码；WP04 SQLite；WP05 投影；WP14 桌面 UI。
- 集成门 VS1：创建身份 → 会话 → 发消息 → 重启 → 重建时间线。

### Wave C：在线单聊（高度并行）

- WP06 sync、WP07 delivery、WP08 QUIC、WP11 static discovery。
- 集成门 VS2：两进程明确地址，重复/乱序/断线后收敛。

### Wave D：可用网络服务（高度并行）

- WP09 Relay、WP10 Mailbox、WP15 Role Host、WP16 公共配额。
- 集成门 VS3：NAT/Relay；VS4：离线+多次重启+Mailbox 仅一次本地提交。

### Wave E：MVP 完整性与后续能力

- WP12 附件、WP17 备份；随后移动端、多设备、群组/MLS、DHT、自动化。

波次只约束集成启用顺序，不阻止后续包提前实现 ports/Fake/单元测试。

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


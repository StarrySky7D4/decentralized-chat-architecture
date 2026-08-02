# Workspace、代码所有权与并行目录

## 1. 推荐目录

```text
/
├── Cargo.toml
├── rust-toolchain.toml
├── crates/
│   ├── contracts/
│   │   ├── primitives/
│   │   ├── protocol/
│   │   ├── integration-events/
│   │   └── test-vectors/
│   ├── identity/{ports,core,infra}/
│   ├── conversation/{ports,core,infra}/
│   ├── crypto/{ports,core,infra}/
│   ├── event-store/{ports,core,sqlite}/
│   ├── projection/{ports,core,sqlite}/
│   ├── sync/{ports,core,infra}/
│   ├── delivery/{ports,core,sqlite}/
│   ├── transport/{ports,core,quic,libp2p}/
│   ├── relay/{ports,core,service}/
│   ├── mailbox/{ports,core,sqlite,service}/
│   ├── discovery/{ports,core,static,dht}/
│   ├── blob/{ports,core,fs,service}/
│   ├── app-api/{ports,core,ffi}/
│   ├── node-runtime/
│   ├── observability/{ports,core}/
│   ├── backup/{ports,core,fs}/
│   └── automation/{ports,core,wasm}/
├── apps/
│   ├── desktop_flutter/
│   └── chat_node/
├── schemas/
│   ├── protocol/
│   └── integration/
├── testkit/
│   ├── contract/
│   ├── simulation/
│   ├── fault-injection/
│   └── vectors/
└── xtask/
```

Rust 最终目录名可调整，但“ports 与实现分包”以及“composition root 才能看到全部实现”不可取消。

## 2. crate 依赖白名单

```text
contracts-primitives -> 无项目依赖
contracts-protocol   -> primitives
<module>-ports       -> primitives (+ protocol，仅确有 wire 需求时)
<module>-core        -> 本模块 ports + 被消费模块 ports
<module>-infra       -> 本模块 ports/core + 外部库
app/node runtime     -> 各模块 ports + infra（仅组装）
```

禁止：

- `identity-core -> event-store-sqlite`
- `delivery-core -> transport-quic`
- `projection-core -> event-store-sqlite`
- `desktop_flutter -> 任意 infra crate`
- `relay -> crypto-core` 或 `mailbox -> conversation-core`

## 3. 模块内目录

```text
<module>/core/src/
├── domain/       私有实体、值对象、状态机
├── usecase/      Port 用例实现
├── acl/          被消费模块 DTO ↔ 本地类型
├── outbox/       integration event 生成
└── lib.rs        仅导出构造器和模块服务
```

领域模块不直接使用 `sqlx`、`rusqlite`、`quinn`、`libp2p`、Flutter bridge 或具体密码库。它们只能出现在 infra/adapters。

## 4. 并行所有权

每个工作包可独占：

- 一个模块的 `ports/core/infra`；
- 对应 `testkit/contract/<module>`；
- 对应 `schemas/integration/<module>`。

共享文件（根 `Cargo.toml`、primitives、protocol schema、全局 test vectors）由 Integration Owner 合入，其他工作包只提交变更提案，避免并发冲突。

## 5. Feature 与替换实现

实现通过运行时注入选择，不把生产 feature 传播到领域层：

```rust
pub struct RuntimePorts {
    pub event_store: Arc<dyn EventStorePort>,
    pub crypto: Arc<dyn CryptoPort>,
    pub transport: Arc<dyn TransportPort>,
    pub clock: Arc<dyn ClockPort>,
}
```

允许的适配器例子：

- `event-store-memory` / `event-store-sqlite`
- `transport-memory` / `transport-quic` / `transport-libp2p`
- `discovery-static` / `discovery-dht`
- `keystore-memory` / `keystore-os`

不允许 `cfg(feature = ...)` 改变 Port 语义或 wire schema。

## 6. Schema 所有权

- wire schema：Protocol Owner；所有模块只消费生成类型或验证器。
- integration schema：生产模块拥有；消费者维护 ACL。
- SQLite schema：写模块拥有；表名前缀为模块 ID。
- FFI schema：Application API Owner；Flutter 只依赖生成的 facade。

## 7. 分支与合并顺序

1. 先合入 primitives、protocol skeleton 和 contract test harness。
2. 各模块 ports 可并行合入，但必须只有 Fake，无需等待实现。
3. core/infra 依赖 Fake 并行开发。
4. 每个实现通过同一 conformance suite 后接入 composition root。
5. 端到端 vertical slice 按本地消息、直连、Relay、Mailbox 顺序启用。


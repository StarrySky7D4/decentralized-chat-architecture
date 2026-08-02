# 模块规格索引

| ID | 规格 | 关键输出契约 |
|---|---|---|
| M01 | [Identity & Device](01-identity-device.md) | 身份公开材料、设备信任决策 |
| M02 | [Conversation & Policy](02-conversation-policy.md) | 控制 Epoch、策略决策、收件人快照 |
| M03 | [Crypto Orchestrator](03-crypto-orchestrator.md) | 签名、密封/开启、密码 Epoch |
| M04 | [Event Store](04-event-store.md) | 不可变事实、heads、commit cursor |
| M05 | [Projection & Query](05-projection-query.md) | 会话/时间线/搜索视图与 delta |
| M06 | [Sync & Replication](06-sync-replication.md) | inventory、batch、resume checkpoint |
| M07 | [Delivery Scheduler](07-delivery-scheduler.md) | 耐久 Job、路径尝试、回执状态 |
| M08 | [Transport Session](08-transport-session.md) | 认证 session、有界 stream/frame |
| M09 | [Relay Service](09-relay-service.md) | reservation、circuit、opaque forward |
| M10 | [Mailbox Service](10-mailbox-service.md) | 幂等 put、持久化回执、租约 fetch/ACK |
| M11 | [Discovery & Node Selection](11-discovery-node-selection.md) | 验证 descriptor、多样化候选 |
| M12 | [Attachment & Blob](12-attachment-blob.md) | 加密 manifest、chunk、断点传输 |
| M13 | [Application API / FFI](13-application-api-ffi.md) | 粗粒度命令、查询、UI 流 |
| M14 | [Platform & UI Shell](14-platform-ui-shell.md) | Flutter facade、平台 keystore/push/file ports |
| M15 | [Node Runtime & Role Host](15-node-runtime-role-host.md) | 配置、角色生命周期、composition root |
| M16 | [Observability & Abuse Control](16-observability-abuse-control.md) | 安全指标、审计、资源租约/配额 |
| M17 | [Backup & Recovery](17-backup-recovery.md) | 加密 snapshot、验证与 staging restore |
| M18 | [Automation & Capability](18-automation-capability.md) | grant、proposal、approval、sandbox execution |

## 统一规格模板

新增或拆分模块时必须说明：

1. 功能与明确非职责；
2. 模块拥有的写模型和持久化 namespace；
3. 公开 DTO、Command/Query/Event/Stream Port 函数签名；
4. 幂等、事务、顺序、取消、超时、背压、重试语义；
5. 大小/数量/时间/并发硬上限；
6. 消费其他模块的 ACL；
7. Integration Events 与 schema 兼容策略；
8. 单元、属性、契约、并发、崩溃、故障注入、安全和端到端测试；
9. 可机械验证的验收条件。

任何未声明资源上限的模块均不能进入公共网络服务；任何未声明崩溃恢复点的写操作均不能进入 MVP。


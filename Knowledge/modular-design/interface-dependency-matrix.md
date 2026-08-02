# Port 依赖与防腐层矩阵

## 1. 构建时结构

所有 `*-ports` 仅依赖 M00 primitives/protocol；实现依赖的是其他模块的 `*-ports`，不是 `*-core/*-infra`。表中“消费”都要求消费者侧 ACL。

| 模块 | 提供 Port | 消费 Port | 消费者侧 ACL 位置 |
|---|---|---|---|
| M01 Identity | `IdentityCommand/Query` | M00 `SignatureVerifier` | `identity/core/acl/signature` |
| M02 Conversation | `ConversationCommand/Query` | M01 Query；M00 verifier | `conversation/core/acl/identity` |
| M03 Crypto | `CryptoPort` | M01 Query；M02 Query；M14 KeyStore | `crypto/core/acl/{identity,policy,keystore}` |
| M04 Event Store | `EventStorePort` | M00 admission primitives | `event-store/core/acl/admission` |
| M05 Projection | `ProjectionCommand/Query` | M04 Store；M02 Query | `projection/core/acl/{store,policy}` |
| M06 Sync | `SyncPort` | M01–M04；M08 Transport | `sync/core/acl/{identity,policy,crypto,store,transport}` |
| M07 Delivery | `DeliveryCommand/Query`, `RouteExecutor` | M08–M11 | `delivery/core/acl/{direct,relay,mailbox,discovery}` |
| M08 Transport | `TransportPort` | M00 verifier/clock | `transport/core/acl/{auth,clock}` |
| M09 Relay | `RelayClient/Service` | M08 Transport；M16 Quota | `relay/core/acl/{transport,quota}` |
| M10 Mailbox | `MailboxClient/Service` | M00 verifier；M16 Quota | `mailbox/core/acl/{proof,quota}` |
| M11 Discovery | `DiscoveryPort` | M08 probe；M00 verifier/clock | `discovery/core/acl/{probe,descriptor}` |
| M12 Attachment | `AttachmentPort`, `BlobStorePort` | M03 Crypto；M14 Platform | `blob/core/acl/{crypto,platform}` |
| M13 Application | `ChatApplication/Query` | M01–M07、M11–M12；可选 M17–M18 | `app-api/core/acl/<module>` |
| M14 Platform/UI | `PlatformKeyStore/Interaction`；Flutter adapter | M13 App ports | `desktop_flutter/acl/core` |
| M15 Runtime | `NodeRuntimePort`, `Role` | 所有启用角色 ports | `node-runtime/composition/*` |
| M16 Observe/Abuse | `Metrics/Audit/Quota` | M00 clock/primitives | `observability/core/acl/clock` |
| M17 Backup | `BackupPort`, `ModuleSnapshotPort` | 各模块 snapshot；M03/M14 wrap | `backup/core/acl/<module>` |
| M18 Automation | `AutomationPort`, `CapabilityBroker` | M02/M13/M12 等公开 Port | `automation/core/broker/<capability>` |

## 2. 被禁止的捷径

| 捷径 | 风险 | 正确替代 |
|---|---|---|
| M05 SQL join M04 事件表 | schema/事务耦合 | `EventStorePort::scan_*` + checkpoint |
| M07 调用 QUIC adapter | 路径实现锁死 | M08 `TransportPort` ACL |
| M09/M10 解析 EventEnvelope | 服务获得聊天元数据 | 仅 `OpaqueEnvelope/Frame` |
| M13 复制策略判断 | 规则漂移 | M02 `authorize` |
| M14 生成独立消息 ID | 重复事实 | 使用 M13 返回 operation/event ID |
| M15 暴露全局 service locator | 任意跨边界调用 | 每 Role 的显式 `RoleContext` |
| M16 使用 UserId/ConversationId label | 隐私与高基数 | 本地假名 subject + safe enum labels |
| M17 直接复制数据库文件 | 不一致/版本锁死 | 各模块 `ModuleSnapshotPort` |
| M18 链接业务实现 crate | 绕过 capability | broker 调用公开 Port |

## 3. 无环构建策略

看似双向的关系通过拆分 ports 与 adapter 消除 crate 环：

- `app-api-core -> platform-ports`，而 `desktop_flutter-adapter -> app-api-ports`；两者不互相依赖实现。
- M13 创建身份时先调用 M03，再把公开证明交给 M01；M01 不调用 M03。
- M03 查询 M01/M02 的公开快照，但 M01/M02 的状态变更不会同步回调 M03；只发 Integration Event。
- M07 调用 route ports；M09/M10 receipt 通过返回值/事件进入 M07，不依赖 M07 core。
- M17 依赖各模块 snapshot ports；各模块不知道 M17，只实现自己的 snapshot provider adapter。

## 4. 调用与事件选择

| 关系 | 方式 | 原因 |
|---|---|---|
| M13 → M02 authorize | Query | 发送前需要即时决策 |
| M13 → M04 append | Command | 本地 commit 是用例成功边界 |
| M04 → M05 ready | Integration Event | 投影可重放、不能阻塞事实写入 |
| M04 → M07 outbound | Integration Event | 网络不能参与存储事务 |
| M07 → route | Command | 一次有 deadline 的路径尝试 |
| M10 → receiver | 客户端主动 Query/Fetch | 不建立中心用户推送语义 |
| M01/M02 → M03 epoch update | Integration Event + M03 query confirm | 可恢复且防陈旧事件 |
| M16 metrics | best-effort sync enqueue | 不阻塞业务，缓冲有界 |
| M18 → 业务能力 | Command via broker | 每次重新鉴权和幂等 |

## 5. ACL 测试要求

每个矩阵单元至少测试：完整映射、缺字段、未知 enum、新 minor 字段、单位/时钟转换、底层错误脱敏、超限前拒绝、operation/deadline/cancellation 传播。ACL 不允许使用 `unwrap`、默认放行未知值或通配序列化透传。


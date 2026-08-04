# 需求—模块—测试追踪矩阵

## 1. MVP 需求

| 需求 | 主模块 | 协作模块 | 关键测试/验收 |
|---|---|---|---|
| 创建长期身份 | M01 | M03, M14 | ID-001/002/010, CR-006, UI-005 |
| 二维码/邀请码联系人 | M01, M13 | M14 | ID-007, API-002/003 |
| 一对一文本消息 | M13 | M02–M05 | API-001/003, CV-001, CR-003, ES-001, PJ-003 |
| 本地优先与断网发送 | M04, M13 | M05, M07 | API-002/005, ES-004/005, DL-004 |
| 安全在线直连 | M03, M08 | M06, M07 | CR-002/004, TR-001–006, SY-001/002 |
| ACK/Retry/Dedup | M07 | M04, M06, M08 | DL-001–006, ES-001, SY-002 |
| NAT 后 Relay | M09 | M07, M08, M11, M16 | RL-001–005/009, DL-002 |
| 离线 Mailbox | M10 | M06, M07, M16 | MB-001–006/009, DL-003 |
| 图片和小文件 | M12 | M03, M07, M14 | AT-001–010 |
| 自定义节点与可迁移 | M11, M15 | M07–M10 | ND-005/010, RT-001/010 |
| Windows/Linux UI | M14 | M13 | UI-001–010 |
| 崩溃恢复 | M04, M07, M10 | M01–M18 | ES-004, DL-004, MB-003, 公共 F0–F5 |
| 本地完整历史与重建 | M04, M05 | M17 | PJ-003/008, BK-007 |
| 加密备份/导出 | M17 | M01, M03, M04, M14 | BK-001–010 |
| 公共节点滥用保护 | M16 | M09–M12, M15 | OB-003–009 |

## 2. 架构性质

| 性质 | 机械检查 | 运行测试 |
|---|---|---|
| 模块不直接接触 | Cargo 依赖白名单、无实现 crate 跨界 | 全部上游可换 Fake |
| 防腐层传递 | 每消费者 `acl/` 显式 mapper，API snapshot | 未知 enum/unit/version adapter 测试 |
| 无跨模块数据库 | SQL namespace lint、无跨前缀 FK | 删除一个读模块数据不损坏事实 |
| 单一重试 owner | Route adapters 禁止 loop lint/评审 | ACK 丢失不形成指数重试叠加 |
| 密文服务不可读正文 | 服务 schema/日志 allowlist | canary 明文扫描 RL/MB/AT |
| 有界资源 | queue/limit 常量清单 | 慢消费者/攻击压力测试 |
| 本地事实先于网络 | M13 saga contract | 网络全断仍本地 commit |
| 最终一致、控制线性 Epoch | M02/M04 模型 | 随机乱序收敛、控制 fork quarantine |
| 设备事件序列不复用 | M00/M04/M13 持久 reservation、`(ConversationId, DeviceId)` 唯一约束 | 崩溃留缺号但不复用；重放幂等；equivocation 隔离（PJ-011–013） |
| 控制 fork 可恢复且不 LWW | M02 resolution schema、base-snapshot 审批、rejected tombstone、M03 rekey gate | CV-003/011–018、PJ-014：选择/回退/迟到分支/二次冲突/崩溃恢复 |
| 默认节点可替换 | 无硬编码唯一 NodeId | 默认节点关闭 E2E |
| 自动化可删除 | 核心依赖图不指向 M18 | 禁用 M18 全部聊天测试仍通过 |

## 3. 端到端 Vertical Slices

### VS0：协议闭环

```text
encode → decode → EventId → sign → verify → golden bytes
```

通过：跨平台/跨版本向量一致，未知 major 与关键字段 fail closed。

补充通过：sequence reservation 在崩溃后只允许缺号、不允许复用；同通道同 sequence 的不同签名事件产生可验证 equivocation 证据。

### VS1：本地聊天闭环

```text
Identity → Direct Conversation → Seal → Event Store → Projection → UI
```

通过：无网络；重复发送 operation 只产生一个事件；删除投影后完全重建。

### VS2：在线直连

```text
Delivery → Transport → Sync/Validate → Event Store → Receipt
```

通过：重复、乱序、掉线、重连无重复事实；双方最终 heads 相同。

### VS3：Relay 回退

```text
Direct failure → Relay circuit → opaque forwarding → device receipt
```

通过：不同 NAT 通信；Relay 日志/存储无正文；单租户压测不拖垮其他租户。

### VS4：离线 Mailbox

```text
Mailbox put/persist receipt → receiver restart → fetch → local commit → ACK
```

通过：客户端/服务多点 kill；最终仅一次本地事实；ACK 成功后不再租出。

### VS5：附件

```text
platform source → stream encrypt/chunk → Blob → AttachmentRef event
→ download/verify → platform sink
```

通过：100 MiB 不整文件入内存；任一 chunk 篡改无成功明文输出。

### VS6：替换默认节点

```text
custom descriptor → selection → new Relay/Mailbox/Blob → sync
```

通过：默认节点关闭；不更换 UserId/ConversationId/密钥状态，继续通信。

### VS7：恢复

```text
encrypted backup → clean device verify → staged restore → new device authorization
```

通过：历史完整、投影重建、撤销设备不复活、坏备份不覆盖现 profile。

## 4. 后续阶段覆盖

| 能力 | 模块组合 | 新增验证重点 |
|---|---|---|
| 多设备 | M01, M03, M06, M17 | 撤销后的 forward secrecy、新设备 bootstrap |
| 小群组 | M02, M03, M06, M07 | 成员/密码 Epoch 原子关联、并发控制 fork |
| DHT/打洞 | M08, M11, M16 | Sybil/污染预算、NAT 矩阵、地址隐私 |
| 公共频道 | M02, M06, M11, M12 | 发布者签名、Gossip 去重、缓存真实性 |
| 自动化 | M18 + M02/M13 brokers | capability、批准、sandbox、幂等副作用 |

## 5. MVP 发布阻断项

以下任一成立即阻断：

- EventEnvelope/wire 无固定测试向量；
- `actor_sequence` 可被复用、以缺号阻塞，或同 sequence 冲突被时间/EventId 静默裁决；
- 控制 fork 无 base-snapshot 授权的显式 resolution，或 resolution 未拒绝非选分支、未强制新 crypto epoch；
- 投影不能从事实全量重建；
- ratchet 重试可能重复推进或复用 nonce/key；
- Mailbox receipt 在 durable commit 前发出；
- Relay/Mailbox/Blob 日志或 schema 含正文/会话成员；
- 任一远程输入可造成无界分配、队列、任务或连接；
- 默认节点写死且无法通过配置替换；
- 跨模块表访问、实现 crate 依赖或持锁跨 `await`；
- 关键状态写入未覆盖崩溃点测试。

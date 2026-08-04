# 威胁模型与隐私档位

## 1. 需要保护的对象

除正文外，以下元数据也可能泄漏社会关系：

- 发送者和接收者的 IP/网络位置；
- 谁在何时在线；
- 哪两个节点频繁通信；
- 消息数量、方向、尺寸和时间间隔；
- 会话、附件和回执之间的关联；
- 长期身份与匿名服务地址的绑定；
- Mailbox 查询节奏和 Push 唤醒时间；
- 一个用户的多个账号、设备或会话是否属于同一主体。

## 2. 对手类别

| ID | 对手 | 能力 | 主要风险 |
|---|---|---|---|
| A0 | 本地观察者 | 观察用户到首跳的流量 | 判断使用时间、协议特征和流量规模 |
| A1 | 单个恶意中继 | 控制路径中的一个节点 | 学到相邻 hop、局部时间和尺寸 |
| A2 | 少量串谋中继 | 控制入口与靠近目标的节点 | 端到端时间/流量相关 |
| A3 | 恶意目录/Sybil 集群 | 创建大量节点、污染视图 | 控制整条路径、Eclipse、选择偏置 |
| A4 | 全球被动观察者 | 观察大量互联网链路 | 低延迟 Onion 的流量相关 |
| A5 | 主动网络对手 | 丢包、延迟、重放、标记、诱导重路由 | Path bias、确认和标记攻击 |
| A6 | 恶意联系人 | 控制应用端点并发送选择性流量 | 交互确认、附件体积和在线模式识别 |
| A7 | 端点失陷 | 读取设备内存、UI 或密钥 | 匿名层无法解决 |

## 3. 保护目标

### 必须达到

- 单个中继不能同时知道消息来源和最终接收者。
- 接收者不能从协议连接直接得到发送者真实网络地址。
- 发送者不需要知道接收者真实网络地址。
- Directory、Introduction、Rendezvous、Mailbox 均不能读取聊天正文。
- 匿名服务身份不能从长期 UserId 或普通 NodeId 可逆派生。
- 匿名路由失败不会触发普通路径自动降级。
- 同一用户不同隔离域不会无意共享电路、ServiceId 或 Mailbox token。

### 高级目标

- 抵抗少量入口/出口位置串谋。
- 降低长期交集攻击和前驱攻击的成功率。
- 通过 Mix、延迟、填充和 cover traffic 降低全球被动相关能力。
- 通过 Bridge/Pluggable Transport 降低匿名协议被识别和阻断的概率。

### 明确非目标

- 端点已经失陷时保护正文或身份。
- 在没有 cover traffic 的低延迟模式下抵抗全球流量观察。
- 隐藏用户主动公开的身份、用户名或外部链接行为。
- 把普通 Push 平台变成匿名基础设施。
- 仅靠增加 hop 数量解决 Sybil、Eclipse 或目录操纵。

## 4. 隐私档位

```rust
pub enum DeliveryPrivacy {
    StandardE2ee,
    LowLatencyOnion,
    RendezvousOnion,
    TrafficAnalysisResistantMix,
}
```

| 档位 | 路径 | 延迟 | 主要防护 | 主要不足 |
|---|---|---:|---|---|
| P0 Standard | Direct/Relay/Mailbox | 最低 | 正文 E2EE | 网络关系不匿名 |
| P1 Onion | 多跳低延迟电路 | 低 | 来源地址不直接暴露给目标 | 时间/流量相关仍明显 |
| P2 Rendezvous | 双方独立电路在 RP 会合 | 中低 | 同时隐藏双方位置，无 Exit | 全局观察者仍可相关 |
| P3 Mix | 固定 cell、随机延迟、重排 | 秒级以上 | 更强的流量分析抵抗 | 带宽、延迟、电量成本高 |
| P4 Strict Mix | Mix + cover traffic + 匿名轮询 | 最高 | 更强在线状态和关系隐藏 | 移动平台可用性受限 |

P1/P2 不得宣传为“抗全球流量分析”。P3/P4 的强度取决于真实匿名集合、cover rate、延迟分布、节点控制比例和客户端在线模式，不能仅由协议名称保证。

## 5. 会话隔离

每条匿名发送必须携带由本地生成、不会发给远端目录的 `IsolationProfile`：

```rust
pub struct IsolationProfile {
    pub local_profile: LocalProfileId,
    pub account_scope: AccountIsolationId,
    pub conversation_scope: ConversationIsolationId,
    pub purpose: CircuitPurpose,
    pub privacy: DeliveryPrivacy,
}
```

规则：

- 不同本地 profile 永不共享 Guard 状态之外的 circuit。
- 不同账号默认不共享 circuit。
- 普通消息、目录查询、附件、Mailbox poll 使用不同 purpose。
- 匿名与普通路径不共享 connection pool、DNS cache、proxy credential 或日志 correlation ID。
- 一个联系人无法通过 ServiceId 判断用户是否还与其他联系人通信。

## 6. 功能泄漏控制

| 功能 | P1/P2 | P3/P4 |
|---|---|---|
| 输入状态 | 默认关闭 | 禁止 |
| 精确在线状态 | 默认关闭 | 禁止 |
| 已送达回执 | 可延迟/合并 | 批处理并随机延迟 |
| 已读回执 | 用户显式开启 | 默认禁止 |
| Push | 仅随机 WakeHint | 建议禁用，改随机轮询 |
| 附件 | 独立隔离 circuit | 分块、填充、延迟；可能降级体验 |
| 多设备同步 | 独立 purpose | 批量固定窗口同步 |

## 7. 匿名失败语义

- `AnonymousRouteUnavailable`：保持排队，可重试。
- `AnonymitySetTooSmall`：不建立新路径，UI 明确告警。
- `DirectoryViewUntrusted`：停止路径选择，不使用单一来源强行继续。
- `GuardCompromisedSuspected`：隔离并要求受控迁移，不能连续随机换入口。
- `PrivacyDowngradeRequired`：必须由用户显式批准新的独立发送操作。

一次用户批准只作用于指定消息或会话策略版本，不能永久隐藏成全局开关。

## 8. 发布声明模板

每个阶段必须公开：

- 能防御哪些 A0–A7 对手；
- 节点数量、独立运营者数量和有效匿名集合；
- 是否启用固定尺寸、延迟、cover traffic；
- 哪些元数据仍然可见；
- 移动端和 Push 的额外泄漏；
- 是否经过外部安全审计。

# 路线图、测试与发布门槛

## 1. 总体策略

先验证接口和产品语义，再实现自有匿名网络；先低延迟 Onion，再双边 Rendezvous/离线 Mailbox，最后才是 Mix 和抗审查。

匿名网络实现不得与 MVP 并行侵入核心链路。每一阶段都必须能够通过 feature/config 完全关闭。

## 2. 阶段路线

### AN0：接口与禁止降级

实现：

- `DeliveryPrivacy`、`IsolationProfile`；
- F-AN ports/Fake；
- M07 anonymous route adapter；
- 匿名失败保持排队；
- UI 明确显示 privacy profile 和不可用原因。

验证：匿名 Fake 失败时不存在任何 Direct/普通 Relay/普通 Mailbox 调用。

### AN1：现有匿名网络 Adapter

目的不是形成自有网络，而是验证应用接口、延迟、取消、隔离和 UI。Rust 路线可评估嵌入 Arti 的客户端/onion service adapter；Mix 侧可研究成熟 Sphinx/Mix SDK，但不把第三方网络写进领域契约。

验证：

- 两个客户端通过外部匿名网络完成在线消息；
- 不修改 M03/M04/M05；
- stream isolation 不发生账号/会话串线；
- adapter 删除后普通聊天完整通过。

### AN2：自有低延迟 Onion 数据平面

实现：

- AnonNodeDescriptor；
- 多 Witness directory epoch；
- Guard/Middle 节点；
- 分层建路、cell、流控、关闭；
- path diversity 与 path bias 观测。

声明上限：只防 A0/A1 和有限 A2，不声称抗全球相关。

### AN3：匿名服务与 Rendezvous

实现：

- per-contact/per-conversation ServiceId；
- blinded/rotating encrypted descriptor；
- Introduction 与 Rendezvous；
- 双方独立路径；
- descriptor access capability 和撤销。

验证：发送方和接收方均不暴露真实地址；任何单个 Intro/RP/Directory 无法同时得到双方位置。

### AN4：匿名 Mailbox

实现：

- blinded rotating mailbox token；
- 匿名 poll、固定页面/填充；
- durable receipt、lease、ACK；
- 多 Mailbox 复制；
- 移动端随机批量轮询。

验证：离线、多次崩溃和重复 fetch 最终只产生一个本地事件；Mailbox 无法解读消息或映射长期身份。

### AN5：Mix Store-and-forward

实现：

- 固定 packet class；
- Sphinx 类分层 packet 与重放缓存；
- 分层 Mix 拓扑；
- 随机延迟、重排、cover loop；
- 一次性 reply block；
- cover traffic 隐私预算。

只有经过网络规模仿真和外部分析后，才能描述对 A4 的具体防护范围。

### AN6：Bridge 与传输伪装

实现：

- 私下分发的 Bridge descriptor；
- Pluggable Transport adapter；
- Bridge 轮换、容量和抗扫描；
- 协议指纹与阻断测试。

抗审查和匿名是不同目标；传输伪装不能替代 Mix/Onion 的关系隐藏。

## 3. 测试基础设施

### 离散事件网络模拟器

至少模拟：

- 数百到数万节点；
- 不同运营者、ASN/网段和节点角色；
- churn、移动离线、网络分区；
- 丢包、延迟、乱序、选择性失败；
- 不同比例恶意节点、Sybil 集群和 Witness 串谋；
- 全局/局部流量观察记录；
- 虚拟时间推进 descriptor epoch、Guard 生命周期和 Mix delay。

### 确定性重放

每个失败场景保存：

- seed；
- directory view roots；
- 节点角色与攻击者集合；
- 虚拟时钟和故障脚本；
- 客户端公开决策类别，不保存真实生产路径数据。

## 4. 必需测试矩阵

| 类别 | 场景 | 不变量 |
|---|---|---|
| 隔离 | 两账号/两会话并发 | 不共享禁止共享的 circuit/service/token |
| 降级 | Onion/Mix 全部不可用 | 零普通路由调用 |
| Sybil | 攻击者生成大量高容量节点 | 路径控制率受多样性/准入限制 |
| Eclipse | DHT 邻居全部恶意 | 无可信 Witness view 时停止建路 |
| Path bias | 恶意 Guard 选择性失败 | 检测、隔离，不无限换入口 |
| 前驱 | 长期多轮通信 | Guard 稳定策略优于每次随机入口 |
| Descriptor | 回滚、等价、过期、跨 capability | 拒绝且不泄漏服务是否存在 |
| Rendezvous | Intro/RP/Directory 任一恶意 | 单节点不能得知双方完整位置 |
| Mailbox | put/fetch/ACK 重放与崩溃 | 至少一次网络、仅一次本地事实 |
| Mix | 重放、标记、延迟操控、queue flood | 完整性与资源有界 |
| Cover | 无真实消息/有突发消息 | 输出节奏符合声明分布 |
| 资源 | 慢 hop、慢 Mix、慢客户端 | 队列、内存、任务有硬上限 |
| 隐私日志 | 注入 canary ID/正文/path | 普通日志指标无敏感值 |
| 移动端 | suspend、Push 丢失、后台预算耗尽 | checkpoint 恢复、不普通网络降级 |

## 5. 统计与隐私评估

不能只测试“消息是否送达”，还要测量：

- 攻击者猜中发送者/接收者的 posterior probability；
- sender/receiver anonymity set；
- 入口与目标流量相关系数；
- 节点控制比例变化时的路径完全失陷概率；
- 在线时间交集对长期身份识别的影响；
- cover rate、延迟与匿名性的曲线；
- 消息/附件尺寸分类准确率；
- 不同移动轮询策略造成的可链接性。

指标和方法需在正式设计前由密码学/匿名通信研究者复核，不能自定义一个分数后宣称安全。

## 6. 安全工程门槛

- 不自行发明底层密码原语；采用有公开分析的 Onion/Sphinx/AEAD/握手构造。
- 所有 wire 格式有 canonical encoding、版本协商和 golden vectors。
- 远程入口有 fuzz、分配预算、递归/长度限制和 DoS 测试。
- Guard、descriptor key、reply block 和 Mix nonce 有崩溃/重试测试。
- Path selection 有可执行参考模型和属性测试。
- 至少一次独立设计评审和一次实现安全审计。
- 安全声明与实际启用功能、网络规模和威胁模型一致。

## 7. 阶段发布门槛

| 阶段 | 可对外描述 | 禁止描述 |
|---|---|---|
| AN0 | “可配置匿名路由接口，严格禁止自动降级” | “匿名聊天已实现” |
| AN1 | “可通过成熟外部匿名网络传输” | “自组织匿名网络” |
| AN2 | “实验性低延迟多跳来源隐藏” | “抗全球流量分析” |
| AN3 | “实验性双边位置隐藏会合” | “任何观察者无法关联双方” |
| AN4 | “匿名离线投递与轮换 Mailbox” | “隐藏所有在线时间” |
| AN5 | 依据评估明确写出对手和参数 | 泛化的“无法追踪” |
| AN6 | “增加阻断与协议识别成本” | “不可封锁” |

## 8. 停止条件

出现以下情况应暂停功能扩张：

- 匿名模式存在任何隐式普通网络 fallback；
- 普通 NodeId/UserId 与 AnonNodeId/ServiceId 可稳定关联；
- Directory view 只有单一不可替换来源；
- Sybil 模拟中少量资源即可高概率控制完整路径；
- cover traffic 只在真实消息出现时发送；
- 移动 Push 与消息到达时间形成一一对应；
- 日志、crash dump 或指标记录完整 path/circuit/service token；
- 自研密码构造没有外部分析；
- 团队无法维护匿名网络与 MVP 可靠性两条线。

## 9. 推荐优先级

对独立开发者而言：

```text
MVP 可靠性
> 匿名接口与禁止降级
> 外部成熟网络 Adapter
> 自有 Onion/Rendezvous
> 匿名 Mailbox
> Mix/Cover Traffic
> Bridge/抗审查
```

如果资源不足，长期停留在“成熟外部匿名网络 Adapter”也比仓促部署小规模、自研、可被 Sybil 控制的匿名网络更诚实和安全。


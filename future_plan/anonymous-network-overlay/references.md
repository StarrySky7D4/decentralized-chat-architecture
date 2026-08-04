# 研究基础与参考资料

本文档集只吸收架构原则，不复制任何现有网络协议。正式实现前应重新审计最新规范、许可、威胁模型和实现状态。

## Tor

- [Tor：路径选择与约束](https://spec.torproject.org/path-spec/path-selection-constraints.html)：避免同一节点、family 和相近网络范围重复进入路径。
- [Tor：Guard Nodes](https://spec.torproject.org/path-spec/guard-nodes.html)：长期入口用于降低反复随机选择造成的分析风险。
- [Tor：Path Bias 检测](https://spec.torproject.org/path-spec/detecting-route-manipulation.html)：选择性失败与路径操纵。
- [Tor：Stream Isolation](https://spec.torproject.org/path-spec/stream-isolation.html)：不同应用、账号和 session 的电路隔离。
- [Tor Onion Service：协议概览](https://spec.torproject.org/rend-spec/protocol-overview.html)：描述符、Introduction 和访问控制。
- [Tor Onion Service：Rendezvous](https://spec.torproject.org/rend-spec/rendezvous-protocol.html)：客户端与服务经独立电路在 Rendezvous Point 会合。
- [Tor Onion Service：描述符加密](https://spec.torproject.org/rend-spec/hsdesc-encrypt.html)：描述符加密、授权客户端和元数据隐藏。
- [Tor：Relay Cell 路由](https://spec.torproject.org/tor-spec/routing-relay-cells.html)：逐跳 Onion 处理模型。

## I2P

- [I2P：Garlic Routing](https://i2p.net/en/docs/overview/garlic-routing/)：消息聚合和 Garlic 路由概念。
- [I2P：单向 Tunnel Routing](https://i2p.net/en/docs/overview/tunnel-routing/)：发送方出站与接收方入站路径分离。
- [I2P：威胁模型](https://i2p.net/en/docs/overview/threat-model/)：完全分布式网络中的 Floodfill、前驱、流量分析和小网络风险。
- [I2P：与其他隐私网络比较](https://i2p.net/en/docs/overview/comparison/)：自组织 netDB、Garlic 和网络角色差异。

## Mixnet

- [The Loopix Anonymity System, USENIX Security 2017](https://www.usenix.org/conference/usenixsecurity17/technical-sessions/presentation/piotrowska)：Poisson mixing、随机延迟、cover traffic、自注入 loop 和离线服务。
- [Loopix 论文 PDF](https://www.usenix.org/system/files/conference/usenixsecurity17/sec17-piotrowska.pdf)
- [Nym 开源 Rust 实现](https://github.com/nymtech/nym)：Sphinx packet、Mix node、Gateway/Mailbox 和 Rust SDK 的工程参考；不意味着本项目必须采用其网络或经济模型。

## P2P 可达性

- [libp2p AutoNAT](https://libp2p.io/docs/autonat/)：节点判断公网可达性。
- [libp2p Circuit Relay](https://libp2p.io/docs/circuit-relay/)：受限第三方转发。
- [libp2p Hole Punching](https://libp2p.io/docs/hole-punching/)：分布式 relay 辅助的 NAT 打洞。

这些技术解决连接和可达性，不应被当作匿名保证。

## Rust 集成基线

- [Arti 官方文档](https://arti.torproject.org/)：可嵌入的 Rust Tor 客户端与 Onion Service 支持。
- [Arti 项目说明](https://arti.torproject.org/about/)：模块化、可嵌入和 Rust 实现目标。
- [Arti 2.0.0 状态](https://blog.torproject.org/arti_2_0_0_released/)：Relay 与 Directory Authority 仍属持续开发方向；评估时应区分客户端可用性和自建网络节点能力。

## 使用这些资料时的约束

- 不把多个协议片段拼接后直接宣称获得其原有安全证明。
- 不用旧规范覆盖当前实现状态；开始编码前重新锁定版本和测试向量。
- 对任何修改过的路径选择、packet、延迟、reply block 或 descriptor 设计重新进行威胁分析。
- 许可证和 crate 依赖必须在技术选型阶段单独审计。

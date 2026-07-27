# Decentralized Chat Architecture

> 面向独立开发者的去中心化聊天软件架构档案。

本仓库归档一套可逐步实现的聊天系统设计：以 **Flutter + Rust + SQLite** 为单人开发主线，以 **本地优先、不可变事件、多路径投递、角色型节点网络** 为核心，通过普通节点、完整节点和社区服务节点逐步边缘化传统中心服务器。

## 状态

- 当前阶段：架构归档 / 尚未开始实现
- 归档日期：2026-07-27
- 目标开发模式：独立开发者优先
- 目标许可：MIT

## 核心结论

去中心化不应定义为“没有服务器”，而应定义为：

1. 协议不依赖唯一运营者。
2. 身份、历史、权限和密钥不由单个服务器垄断。
3. 中继、离线邮箱、发现、附件和自动化等职责可由多个可替换节点承担。
4. 用户可以使用默认公共节点，也可以迁移到朋友节点、社区节点或自托管节点。
5. 服务节点可以提高可用性，但不能读取端到端加密内容。

推荐总体模型：

```text
Flutter UI
    │
Rust Local-first Core
    │
Immutable Event Store
    │
Pluggable Delivery Engine
    ├── Direct
    ├── Relay
    └── Mailbox
           │
Role-based Node Network
```

## 文档导航

- [设计原则](docs/00-principles.md)
- [独立开发者技术栈](docs/01-solo-developer-stack.md)
- [节点网络如何替代服务器](docs/02-node-network-vs-server.md)
- [系统总体架构](docs/03-system-architecture.md)
- [节点角色与消息投递](docs/04-node-roles-and-delivery.md)
- [分阶段工程路线](docs/05-engineering-roadmap.md)
- [首个可发布版本范围](docs/06-mvp-scope.md)
- [风险与反模式](docs/07-risks-and-antipatterns.md)
- [待实现清单](TODO.md)
- [架构决策记录](adr/)

## 推荐技术栈

| 领域 | 选择 |
|---|---|
| UI | Flutter |
| 核心语言 | Rust |
| 异步运行时 | Tokio |
| 本地数据库 | SQLite（WAL） |
| 首版网络 | 明确地址连接 + Relay/Mailbox |
| 后续网络 | rust-libp2p / QUIC / DHT / 打洞 |
| 编码 | CBOR |
| 单聊加密 | 成熟的一对一 Ratchet 协议实现 |
| 群组加密 | 基础投递稳定后引入 MLS |
| 自动化 | AgentId + Capability + WASM 沙箱 |

## 最重要的工程顺序

```text
协议先于网络规模
单对单先于群组
在线通信先于离线通信
可靠性先于完全去中心化
桌面先于移动后台
本地事件先于云端状态
文本先于附件
附件先于音视频
权限模型先于自动化
```

## 许可证

MIT。该仓库目前主要包含设计文档；未来加入的参考代码默认沿用同一许可证，除非对应目录另有说明。

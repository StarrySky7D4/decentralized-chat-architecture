# 独立开发者技术栈

## 推荐组合

```text
应用 UI：Flutter
核心逻辑：Rust
异步运行时：Tokio
本地存储：SQLite
跨语言桥接：flutter_rust_bridge 或等价粗粒度 FFI
首版传输：QUIC 或 WebSocket Relay
后续 P2P：rust-libp2p
协议编码：CBOR
服务节点：统一 Rust Node 二进制
```

## 为什么使用 Flutter

独立开发者无法长期维护 SwiftUI、Compose、React Desktop 和 Web 四套完整客户端。Flutter 的价值是统一：

- Android
- iOS
- Windows
- Linux
- macOS

首版建议只发布桌面端，再补 Android；iOS 和 Web 延后。

## 为什么使用 Rust

Rust 负责所有高一致性、高安全性和跨平台共享逻辑：

- 身份和设备凭证
- 密钥和加密状态
- 事件编码、签名与验证
- SQLite 和迁移
- 同步与去重
- 网络连接和重试
- Relay/Mailbox 协议
- 群组状态
- 自动化运行时

Flutter 只负责界面和平台交互。

## FFI 边界

推荐接口：

```text
send_message()
create_conversation()
observe_conversation_list()
observe_timeline()
observe_sync_status()
approve_agent_action()
```

禁止暴露：

```text
原始 Socket
SQLite Connection
私钥字节
libp2p Swarm
MLS 内部对象
细粒度 Rust 实体的频繁跨边界调用
```

## 平台推进顺序

```text
1. Linux / Windows 桌面
2. Android
3. macOS
4. iOS
5. Web
```

原因：桌面节点可以长时间运行，适合调试中继、邮箱、同步和服务角色；移动端受后台限制，不适合作为首个网络实验环境。

## 服务端复用

不另写传统后端。使用同一个 Rust 节点程序，通过配置启用不同角色：

```bash
chat-node --roles bootstrap
chat-node --roles relay,mailbox
chat-node --roles mailbox,blob
chat-node --roles all
```

客户端和服务节点复用协议类型、签名验证、存储格式和网络模块。

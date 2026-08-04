# TODO

## 规范

- [ ] 定义 ID 字节格式和文本表示
- [ ] 定义 EventEnvelope v0
- [ ] 定义签名覆盖范围
- [ ] 定义协议版本协商
- [ ] 定义错误码和重试语义
- [ ] 建立协议测试向量
- [x] 编写威胁模型

## 本地核心

- [ ] Rust workspace
- [ ] SQLite schema 与迁移
- [ ] Event Store
- [ ] Timeline Projection
- [ ] Delivery Job Queue
- [ ] 崩溃恢复测试
- [ ] Flutter 粗粒度 API

## 网络

- [ ] 明确地址直连原型
- [ ] ACK / Retry / Dedup
- [ ] Relay 协议
- [ ] Mailbox 协议
- [ ] TTL 和配额
- [ ] NodeDescriptor
- [ ] 后续 DHT / Peer Exchange

## 安全

- [ ] 设备密钥存储抽象
- [ ] 一对一加密会话
- [ ] 设备授权与撤销
- [ ] 元数据最小化评审
- [ ] 密钥恢复设计
- [ ] 群组阶段再引入 MLS

## 产品

- [ ] 桌面端最小消息列表
- [ ] 二维码邀请
- [ ] 连接和同步状态
- [ ] 节点配置界面
- [ ] 离线消息体验
- [ ] 导出和备份

## 运营

- [ ] 默认 Bootstrap 部署
- [ ] 默认 Relay 部署
- [ ] 默认 Mailbox 部署
- [ ] 基础指标和日志
- [ ] 滥用配额
- [ ] 自托管文档

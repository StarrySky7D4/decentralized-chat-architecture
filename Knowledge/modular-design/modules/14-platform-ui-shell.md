# M14：Platform & UI Shell

## 1. 功能与边界

拥有 Flutter 页面/状态、平台生命周期、文件选择、通知展示、安全存储适配和无内容 push 唤醒。平台差异在此终止。

不负责长期业务事实、消息授权、E2EE 协议、网络重试、SQLite 或节点角色。

## 2. Flutter Facade（Dart）

```dart
abstract interface class ChatCore {
  Future<ClientSnapshot> initialize(InitializeClient request);
  Future<LocalMessageCommit> sendMessage(SendMessageCommand command);
  Future<ConversationView> acceptInvitation(AcceptInvitationCommand command);
  Future<Page<MessageView>> timeline(TimelinePageQuery query);
  Stream<UiStateEvent> observe(UiSubscription filter);
  Future<void> retryDelivery(EventId eventId);
  Future<void> shutdown();
}
```

页面只使用 view model 和 command，不保存 Rust 实体引用。UI 的 optimistic state 必须被 core 返回的 `operation_id/event_id` 锚定，不能生成第二套事实 ID。

## 3. Rust 平台 Port

```rust
pub trait PlatformKeyStorePort: Send + Sync {
    fn generate<'a>(
        &'a self, ctx: &'a RequestContext, policy: PlatformKeyPolicy,
    ) -> BoxFuture<'a, Result<PlatformKeyRef, ContractError>>;

    fn sign<'a>(
        &'a self, ctx: &'a RequestContext, key: PlatformKeyRef,
        request: PlatformSignRequest,
    ) -> BoxFuture<'a, Result<SignatureBytes, ContractError>>;

    fn unwrap<'a>(
        &'a self, ctx: &'a RequestContext, key: PlatformKeyRef,
        wrapped: WrappedSecret,
    ) -> BoxFuture<'a, Result<SecretHandle, ContractError>>;

    fn delete<'a>(
        &'a self, ctx: &'a RequestContext, key: PlatformKeyRef,
    ) -> BoxFuture<'a, Result<(), ContractError>>;
}

pub trait PlatformInteractionPort: Send + Sync {
    fn choose_import_source<'a>(
        &'a self, ctx: &'a RequestContext, policy: FileSelectionPolicy,
    ) -> BoxFuture<'a, Result<Option<ImportSource>, ContractError>>;

    fn choose_export_sink<'a>(
        &'a self, ctx: &'a RequestContext, suggested: SafeFileMetadata,
    ) -> BoxFuture<'a, Result<Option<ExportSink>, ContractError>>;

    fn show_notification<'a>(
        &'a self, ctx: &'a RequestContext, notification: SafeNotification,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn app_lifecycle(&self, ctx: RequestContext)
        -> Result<BoxStream<AppLifecycleEvent>, ContractError>;
}
```

## 4. Push Bridge

Push payload V0 仅允许：

```rust
pub struct WakeHintV0 {
    pub random_wakeup_id: [u8; 16],
    pub mailbox_hint: OpaqueMailboxHint,
    pub expires_at: UnixMillis,
}
```

不得包含用户名、消息预览、ConversationId、EventId、成员、sender 或精确未读数。收到 hint 只触发 M10/M06 的受限同步；hint 可重复、丢失、伪造，不能当消息事实。

## 5. 限制与生命周期

- UI 不在内存长期保存私钥/恢复秘密；剪贴板操作需要明确确认和自动清理提示。
- KeyStore 返回 opaque ref/operation result，不返回私钥。
- Flutter stream subscription 随页面/isolate dispose 取消；全局内核状态由 app session 管理。
- 后台任务遵守平台预算；不足时持久 checkpoint，不忙等。
- 桌面通知默认不含正文，用户可本地选择放宽；任何通知内容不发送给公共服务。
- 文件 Port 使用 capability handle，防止路径穿越和 TOCTOU。

## 6. ACL

- Dart mapper：FFI DTO → immutable ViewModel；未知 enum 显示安全 fallback。
- `keystore_adapter`：只供 M03 infra，UI 不能调用任意 sign bytes。
- `push_adapter`：WakeHint → M13 `TriggerMailboxSync`，不创建消息对象。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| UI-001 | 重复点击发送/重建 widget | operation ID 稳定，单条消息 |
| UI-002 | stream Gap | 重新查询快照并恢复界面 |
| UI-003 | isolate/app suspend/resume | subscription 释放，sync 可恢复 |
| UI-004 | push 重复/过期/伪造 | 最多触发幂等拉取，不生成事实 |
| UI-005 | 平台 keystore 不可用/锁定 | 安全错误与恢复指引，不降级明文 key |
| UI-006 | file handle 撤销/路径变化 | 明确失败，无任意路径访问 |
| UI-007 | 通知隐私模式 | 系统通知不泄漏正文/联系人 |
| UI-008 | 未知 FFI enum/new field | 不崩溃，fallback 正确 |
| UI-009 | 多语言/时区 | 不改变事实 ID、排序和协议值 |
| UI-010 | Windows/Linux golden/integration | MVP 关键流程一致 |

## 8. 验收

UI 崩溃/重启不损坏内核；平台不支持安全密钥存储时明确阻止生产身份创建；Push Bridge 无法获取聊天元数据。

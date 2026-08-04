# M12：Attachment & Blob

## 1. 功能与边界

本模块属于 MVP Phase 4.5，范围仅为图片和小文件。客户端侧负责附件导入、流式加密、分块、内容寻址 manifest、上传/下载、完整性校验和解密导出；服务侧只保存 opaque ciphertext chunks。

不负责聊天事件投递、文件预览 UI、恶意内容扫描明文、永久公开存储或把本地文件路径传给远端服务。

## 2. DTO

```rust
pub struct BlobId(pub [u8; 32]);          // ciphertext manifest hash
pub struct ChunkId(pub [u8; 32]);
pub struct AttachmentRef {
    pub blob_id: BlobId,
    pub encrypted_manifest: BoundedBytes<65_536>,
    pub wrapped_keys: WrappedBlobKeySet,
    pub total_ciphertext_bytes: u64,
}

pub struct ImportSource(pub OpaqueHandle); // 平台受控流，不是路径
pub struct ExportSink(pub OpaqueHandle);
```

明文文件名、MIME、尺寸等元数据放入加密 manifest；公开部分只保留协议需要的密文长度/分块信息。

## 3. Port 签名

```rust
pub trait AttachmentPort: Send + Sync {
    fn import_and_encrypt<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: ImportAttachmentRequest,
    ) -> BoxFuture<'a, Result<AttachmentRef, ContractError>>;

    fn upload<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: UploadAttachmentRequest,
    ) -> BoxFuture<'a, Result<TransferHandle, ContractError>>;

    fn download<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: DownloadAttachmentRequest,
    ) -> BoxFuture<'a, Result<TransferHandle, ContractError>>;

    fn export_decrypted<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: ExportAttachmentRequest,
    ) -> BoxFuture<'a, Result<ExportSummary, ContractError>>;

    fn transfer_events(
        &self,
        ctx: RequestContext,
        handle: TransferHandle,
    ) -> Result<BoxStream<TransferEvent>, ContractError>;
}

pub trait BlobStorePort: Send + Sync {
    fn has_chunks<'a>(
        &'a self,
        ctx: &'a RequestContext,
        ids: Vec<ChunkId>,
    ) -> BoxFuture<'a, Result<ChunkPresence, ContractError>>;

    fn put_chunk<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: PutOpaqueChunk,
    ) -> BoxFuture<'a, Result<PutChunkOutcome, ContractError>>;

    fn get_chunk<'a>(
        &'a self,
        ctx: &'a RequestContext,
        id: ChunkId,
        range: Option<ByteRange>,
    ) -> BoxFuture<'a, Result<OpaqueChunkStream, ContractError>>;

    fn pin<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: PinRequest,
    ) -> BoxFuture<'a, Result<PinReceipt, ContractError>>;
}
```

## 4. 限制与语义

- MVP 文件最大 100 MiB；chunk 默认 256 KiB、允许 64 KiB–1 MiB；始终流式处理。
- `ChunkId = hash(ciphertext chunk)`；每块独立认证并绑定 blob/chunk index/total。
- 导入先写临时加密 staging，完整 manifest durable 后才返回 AttachmentRef；临时文件崩溃后可清理。
- 上传/下载按 ChunkId 幂等并可断点续传；进度不是事实，不进入全局 outbox。
- 下载在解密/导出前验证 manifest hash、chunk hash、AEAD tag、索引和总长度。
- Blob service 不接受本地路径、明文 MIME/文件名、ConversationId/UserId。
- range 只作用于 ciphertext；明文随机访问由客户端安全实现。

## 5. 并发与资源

每 transfer 默认 4 个并发 chunk，全局 16；缓冲最多 `2 × chunk_size × concurrency`。取消停止新任务，已完成 chunk 保留用于 resume。相同 BlobId 的下载 singleflight 共享 ciphertext cache，不共享调用方明文 sink。

## 6. ACL

- `crypto_adapter`：M03 生成/封装 blob key；密钥不发给服务。
- `platform_adapter`：M14 file picker/secure source/sink handle。
- `delivery_adapter`：聊天事件仅携带 AttachmentRef，不内嵌文件。
- `discovery_adapter`：选择 Blob role 节点，不传会话信息。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| AT-001 | 0B、边界 chunk、100MiB | 正确分块/恢复，内存有界 |
| AT-002 | 重复/断点上传 | 已有 chunk 跳过，结果相同 |
| AT-003 | chunk 删除/篡改/调序 | 导出前 integrity failure |
| AT-004 | 导入/manifest commit 各 kill point | 无半成品可见，临时可清理 |
| AT-005 | 下载取消再 resume | 已验证 ciphertext 可复用 |
| AT-006 | 同 blob 多并发下载 | ciphertext singleflight，无 sink 串线 |
| AT-007 | 恶意长度/压缩炸弹元数据 | 预算前拒绝，不预分配声明大小 |
| AT-008 | 服务数据检查 | 只有 opaque chunks/公开长度 |
| AT-009 | 日志检查 | 无路径、文件名、MIME、密钥 |
| AT-010 | 多实现 conformance | fs/memory/service 语义一致 |

## 8. 验收

图片及最大 100 MiB 的小文件完成“选择 → 加密上传 → 发送 AttachmentRef → 下载 → 校验 → 解密导出”纵向切片，全流程不整文件入内存；重复或断点续传不产生第二个聊天事件，任一 chunk 篡改均不会产生明文输出成功；更换 Blob 节点不改变 BlobId 或会话加密语义。

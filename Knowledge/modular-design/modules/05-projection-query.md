# M05：Projection & Query

## 1. 功能与边界

把 ready events 确定性地投影为会话列表、时间线、成员视图、消息状态、搜索文档和 UI 增量流。所有状态均可删除重建。

不负责事实写入、事件授权、网络同步、密码密钥、投递重试或 UI widget。

## 2. Port 签名

```rust
pub trait ProjectionCommandPort: Send + Sync {
    fn apply_commit<'a>(
        &'a self,
        ctx: &'a RequestContext,
        commit: ReadyEventRef,
    ) -> BoxFuture<'a, Result<ProjectionApplyOutcome, ContractError>>;

    fn rebuild<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: RebuildRequest,
    ) -> BoxFuture<'a, Result<RebuildHandle, ContractError>>;

    fn delete_rebuildable_state<'a>(
        &'a self,
        ctx: &'a RequestContext,
        scope: ProjectionScope,
    ) -> BoxFuture<'a, Result<(), ContractError>>;
}

pub trait ProjectionQueryPort: Send + Sync {
    fn conversation_list<'a>(
        &'a self,
        ctx: &'a RequestContext,
        query: ConversationListQuery,
    ) -> BoxFuture<'a, Result<Page<ConversationListItem, ListCursor>, ContractError>>;

    fn timeline<'a>(
        &'a self,
        ctx: &'a RequestContext,
        query: TimelineQuery,
    ) -> BoxFuture<'a, Result<Page<TimelineItem, TimelineCursor>, ContractError>>;

    fn message<'a>(
        &'a self,
        ctx: &'a RequestContext,
        event: EventId,
    ) -> BoxFuture<'a, Result<Option<MessageView>, ContractError>>;

    fn search<'a>(
        &'a self,
        ctx: &'a RequestContext,
        query: LocalSearchQuery,
    ) -> BoxFuture<'a, Result<Page<SearchHit, SearchCursor>, ContractError>>;

    fn subscribe(
        &self,
        ctx: RequestContext,
        request: ProjectionSubscription,
    ) -> Result<BoxStream<ProjectionStreamItem>, ContractError>;
}
```

## 3. 投影语义

- reducer 是纯函数：`(old_state, decoded_event, dependency_views) -> new_state + deltas`。
- 不使用 wall clock 决定排序。先建立显式 `parents` 边；对当前已知、同一 `(ConversationId, DeviceId)` 通道的合法事件，再建立较小 `actor_sequence` 指向较大 sequence 的隐式边。sequence 缺号不生成依赖，也不等待补齐。
- 对上述 DAG 做确定性拓扑排序；每一步从 ready set 按 `(logical_time, canonical_actor_bytes, device_id, actor_sequence, event_id)` 选择。`EventId` 只为合法且互不冲突的并发事件打破平局，不能解决 sequence equivocation 或控制 fork。
- 较小 sequence 晚到时，timeline 可按确定性键插入；任何依赖处理顺序的聚合必须从该会话最近的安全 checkpoint 重放。增量到达和全量重建必须产生相同哈希。
- 相同通道与 sequence 对应不同 `EventId` 时暂停受影响通道，隔离两个事件及其后继并报告 `SequenceEquivocation`；不得把其中一个静默投影。若通道顺序与因果边形成环，同样 fail closed。
- M02 报告 control fork 时，投影必须撤销 base 之后竞争分支造成的派生状态并从 base checkpoint 重放；resolution 生效后，只采用 selected 闭合路径（或 base）和 resolution，所有 rejected tombstone 命中的控制/内容事件保持审计占位但不改变有效视图。
- 编辑/撤回保留原事件与关系；视图可隐藏正文但不能删除审计引用。
- `AppliedToEventStore`、`ReceivedByDevice`、`PersistedByMailbox` 映射为不同送达状态，不能混淆。
- 未知非关键内容事件显示 `UnsupportedEvent`；未知控制事件暂停该会话投影并报告 gap。
- 搜索索引仅本地建立；可配置不索引敏感会话。删除索引后可重建。

## 4. 限制与背压

- timeline page 默认 50，最大 200；search query 最大 512 UTF-8 bytes。
- subscription buffer 默认 256；落后时发送一个 `Gap { last_seen, latest }` 后关闭，由消费者重新查询快照。
- 不为慢消费者保留无界 delta。
- 单会话 reducer 串行，不同会话并发；全局列表更新使用版本化聚合。

## 5. 持久化

M05 独占 `prj_*` 表。checkpoint 与投影变更同事务提交。读取事件只能通过 M04 Port；不得 join `evt_*` 表。重建写入 shadow generation，完成校验后原子切换，避免 UI 看到半重建状态。

## 6. Integration Events

- `ProjectionAdvancedV0`
- `ProjectionGapDetectedV0`
- `ProjectionRebuildCompletedV0`
- `SearchIndexUpdatedV0`（可丢失提示，不是事实）

## 7. ACL

- `event_store_adapter`：从 ReadyEventRef 拉取事实并映射为本地 reducer input。
- `conversation_adapter`：取 epoch snapshot；缓存键必须带 epoch。
- `app_api_adapter`：把内部 view 映射为稳定 FFI ViewModel。

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| PJ-001 | 同一事件重复 apply | checkpoint 不重复，视图不重复 |
| PJ-002 | 事件所有排列顺序 | 在依赖满足后最终视图相同 |
| PJ-003 | 删除全部 prj 表并重建 | 查询结果与重建前等价 |
| PJ-004 | crash 在 view/checkpoint 中间 | 同事务恢复，无跳过事件 |
| PJ-005 | 编辑、撤回、回复交错 | 关系保持且确定性 |
| PJ-006 | 未知内容/控制事件 | 占位 / 暂停，符合分类 |
| PJ-007 | 慢订阅者溢出 | 收到 Gap 并关闭，无 OOM |
| PJ-008 | shadow rebuild 时查询 | 始终看到旧或新完整 generation |
| PJ-009 | 搜索禁用会话 | 索引和结果不含该会话 |
| PJ-010 | timezone/locale 不同 | 存储排序与视图事实不变 |
| PJ-011 | sequence 有缺号且较小值晚到 | 不等待缺号；局部重放后与全量重建哈希相同 |
| PJ-012 | 同通道同 sequence 的两个签名事件 | 两者隔离并报告 equivocation，不按 EventId 选取 |
| PJ-013 | sequence 隐式边与 parents 构成环 | fail closed，投影不推进 checkpoint |
| PJ-014 | 先投影一条控制分支，后检测 fork 并解析 | 回退 base，再只重放 selected 路径；与全量重建哈希一致 |

## 9. 验收

在随机重复、乱序、崩溃注入下，重建结果哈希一致；UI 只通过 Query/Stream Port 获得状态；删除整个模块数据不会损坏事实日志。

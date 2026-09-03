# Recording API Contract v1

- Base path：`/v1`
- 认证：`Authorization: Bearer <api-token>`
- 时间：ISO 8601 UTC
- 音频：AAC-LC in MPEG-4 (`audio/mp4`)

MVP 使用 API Token。生产部署可在保持 Bearer 语义的前提下替换为 JWT。

实时会话使用独立的 Gateway 和 Processor 协议，不改变 Recording API；见 [Realtime Processing](realtime-processing.md)。

## Storage Configuration

`GET /v1/storage/config` 返回 `{"mode":"local"}`，或省略凭据后的当前 S3 配置。

`PUT /v1/storage/config` 接受 `{"mode":"local"}`，或包含 `bucket`、`region`、`access_key_id`、`secret_access_key` 的 S3 配置；可选字段为 `endpoint_url`、`prefix`、`session_token`、`force_path_style`。

启用 S3 前，服务会写入一个很小的临时对象、读取其元数据并删除。探测失败返回 `422 storage_configuration_invalid`，且不会覆盖旧配置。配置文件以 `0600` 权限原子保存。Chunk 始终先可靠写入本地，再镜像到 S3；配置 S3 时只有远端对象确认持久化后才返回 ACK。合并后的 M4A 也会镜像到 S3。

## Create Recording

```http
POST /v1/recordings
Content-Type: application/json
Idempotency-Key: <client-upload-task-id>
```

```json
{
  "id": "rec_012345",
  "created_at": "2026-08-23T08:00:00Z",
  "started_at": "2026-08-23T08:00:00Z",
  "device_model": "iPhone17,1",
  "app_version": "0.1.0",
  "metadata": {}
}
```

第一次返回 `201`，重复创建同一 ID 返回 `200`。

## Upload Chunk

```http
PUT /v1/recordings/{recording_id}/chunks/{chunk_index}
Content-Type: audio/mp4
X-Chunk-Checksum: <sha256-hex>
X-Chunk-Started-At: 2026-08-23T08:00:10Z
X-Chunk-Duration: 10.016
Idempotency-Key: <client-upload-task-id>

<m4a bytes>
```

Chunk index 从 1 开始。成功 ACK：

```json
{
  "ack": true,
  "recording_id": "rec_012345",
  "chunk_index": 1,
  "checksum": "...",
  "size": 81234,
  "duplicate": false
}
```

相同 `recording_id + chunk_index + checksum + size` 重传返回 `200` 且 `duplicate=true`。相同 ID/index 但内容不同返回 `409 idempotency_conflict`。Checksum 不一致返回 `422`。

## Lifecycle

```http
POST /v1/recordings/{recording_id}/pause
POST /v1/recordings/{recording_id}/resume
POST /v1/recordings/{recording_id}/finish
```

Pause / Resume 不创建新 Recording。Finish 前服务端检查 1...last index 连续；缺块返回：

```json
{
  "error": "missing_chunks",
  "message": "recording has a chunk gap",
  "details": [3, 4]
}
```

Finish 合并成功后状态为 `COMPLETED`。

## Get / List / Audio

```http
GET /v1/recordings/{recording_id}
GET /v1/recordings?from=2026-08-01&to=2026-08-31&limit=100
GET /v1/recordings/{recording_id}/audio
```

Audio 在 Finish 成功后返回 `audio/mp4` 附件。List 最多返回 500 条。

## Finished Webhook

服务端配置 `WAKEONCUE_WEBHOOK_URL` 后发送：

```json
{
  "event": "recording.finished",
  "recording_id": "rec_012345",
  "audio_url": "https://recordings.example/v1/recordings/rec_012345/audio",
  "metadata": {},
  "occurred_at": "2026-08-23T09:00:00Z"
}
```

Headers：

```text
X-WakeOnCue-Timestamp: <ISO-8601>
X-WakeOnCue-Signature: sha256=<HMAC-SHA256(secret, timestamp + "." + raw-body)>
```

MVP Webhook 失败不会回滚已经完成的录音，但只记录失败；生产版应增加持久化 Outbox、重试和事件 ID。

## 通用错误

```json
{
  "error": "machine_readable_code",
  "message": "human readable detail"
}
```

- `400` 参数错误；
- `401` Token 错误；
- `404` Recording/Audio 不存在；
- `409` 幂等冲突、无 Chunk 或 Chunk 缺口；
- `413` Chunk 超过 32 MiB；
- `422` Checksum 或音频合并失败；
- `500` 未处理服务端错误。

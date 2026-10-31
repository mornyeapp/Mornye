# Cross-Device Listening Statistics Synchronization Architecture

## 1. Overview

Mornye provides decentralized, opt-in synchronization of listening statistics and Rewind metrics across multiple personal devices (such as Android phones and Windows desktops) using existing user storage backends (WebDAV or local/network-mounted folders).

The synchronization system follows a strict **local-first, single-writer partitioning** model:
- Each device maintains its own local SQLite database for playback accrual and instant statistics rendering.
- Devices synchronize by publishing per-device monthly partition snapshots into a shared storage folder (`MornyeSync/`).
- No centralized coordinating server is required.
- Playback history is never destroyed or collapsed across peer devices.

```
                      +----------------------------------+
                      |     Local Playback Accrual       |
                      |  (MusicPlayerService / Recorder) |
                      +-----------------+----------------+
                                        |
                                        v
                      +-----------------+----------------+
                      |   Local SQLite Database          |
                      |   - listening_device_records     |
                      |   - Native Triggers              |
                      |   - Physical listening summary   |
                      |   - sync_outbox                  |
                      +-----------------+----------------+
                                        |
                 Sync Enabled           |          Sync Disabled
                 +----------------------+----------------------+
                 | (Online)                                    | (Local-Only)
                 v                                             v
+----------------+-----------------+            +-------------+--------------+
| SyncOrchestrationService         |            | Normal Offline Accrual     |
| 1. Flush in-memory recorder      |            | - Strict zero remote I/O   |
| 2. Serialize dirty months        |            | - Local stats & Rewind     |
| 3. Write via SyncStorageDriver   |            |   fully functional         |
| 4. Ingest peer partitions        |            +----------------------------+
| 5. Invalidate Riverpod UI cache  |
+----------------+-----------------+
                 |
                 v
+----------------+-----------------+
| Shared Storage Root (MornyeSync/)|
| - manifest.json (Epoch registry) |
| - listening/devices/<id>/<month> |
+----------------------------------+
```

---

## 2. Core Architectural Principles

### 2.1 Local-First & Default-OFF Opt-In
- **Fresh Installations:** Cross-Device Synchronization defaults to **OFF**. Listening history accrues solely in the local SQLite database.
- **Zero Remote I/O When OFF:** When sync is disabled, the app performs zero remote network operations, zero manifest reads, zero storage scans, and zero background network polling.
- **Offline Resilience:** All listening statistics, streaks, and Rewind cards remain fully functional offline without network access.

### 2.2 Single-Writer Partition Model
- **Isolated Storage Directories:** Storage is partitioned by unique device identifier under `listening/devices/{deviceId}/`.
- **Exclusive Writer Principle:** Each device writes exclusively to its own directory partition. Peer devices access other device directories strictly as read-only consumers.
- **Zero Write Contention:** Because peer devices never write to the same partition file, concurrent cloud writes cannot produce write locks, clobbering, or file corruption.

### 2.3 Stable Device Identity
- Each installation generates a durable device identifier (`dev_{platform}_{uuid}`).
- The device ID is anchored in SQLite `listening_metadata` and mirrored in `SharedPreferences`.
- The device identifier remains permanent across application restarts, network changes, and device renaming.

---

## 3. Local SQLite Architecture (`listening_statistics.db`)

Mornye uses SQLite Schema v2 to support multi-device listening history with sub-millisecond query performance.

### 3.1 Schema Definition

#### `listening_device_records` (Ledger Table)
Stores raw, unaggregated playback metrics segregated by device:
```sql
CREATE TABLE IF NOT EXISTS listening_device_records (
  device_id TEXT NOT NULL,
  day TEXT NOT NULL,
  track_key TEXT NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  artwork TEXT,
  milliseconds INTEGER NOT NULL DEFAULT 0,
  plays INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  is_legacy INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, day, track_key)
);
CREATE INDEX IF NOT EXISTS idx_ldr_day ON listening_device_records(day);
CREATE INDEX IF NOT EXISTS idx_ldr_device ON listening_device_records(device_id);
```

#### `listening` (Physical Materialized Summary Table)
Maintains the unified, deduplicated aggregate across all synced devices:
```sql
CREATE TABLE IF NOT EXISTS listening (
  day TEXT NOT NULL,
  track_key TEXT NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  artwork TEXT,
  milliseconds INTEGER NOT NULL DEFAULT 0,
  plays INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, track_key)
);
```

#### `sync_outbox` (Dirty Partition Tracker)
Tracks months that have been modified locally and need synchronization:
```sql
CREATE TABLE IF NOT EXISTS sync_outbox (
  month TEXT PRIMARY KEY,
  dirty INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL
);
```

### 3.2 Native Triggers & Consistency Invariants

The physical summary table `listening` is updated in real time via native SQLite triggers attached to `listening_device_records`:

1. **`trg_ldr_insert` (AFTER INSERT):**
   Inserts a new summary row or atomically increments `milliseconds` and `plays` on `(day, track_key)`.
2. **`trg_ldr_update` (AFTER UPDATE):**
   Handles two distinct branches:
   - *Same grouping key:* Adds delta `(new - old)` to the summary row.
   - *Modified grouping key (e.g. metadata re-keying or date change):* Subtracts old contribution from `(old.day, old.track_key)` (deleting the summary row if both milliseconds and plays reach zero) and adds new contribution to `(new.day, new.track_key)`.
3. **`trg_ldr_delete` (AFTER DELETE):**
   Subtracts the deleted contribution from `listening`. The summary row is removed if and only if both `milliseconds <= 0 AND plays <= 0`. If a track has `0 ms` but `plays > 0`, the record is preserved.

### 3.3 Rewind Query Compatibility
Because `listening` is maintained as a physical table with an index on `(day, track_key)`, all 11 existing Rewind queries in `lib/services/listening_rewind.dart` read directly from `listening` without requiring joins, views, or SQL syntax changes.

---

## 4. Deterministic Track Normalization

To ensure that listening events recorded across platforms match accurately, `TrackIdentityUtils` canonicalizes titles and artists:

```
canonicalKey = "${simplifyTrackTitle(title)}|${extractPrimaryArtist(artist)}"
```

1. **Edition Noise Stripping:** Suffixes such as `- 2011 Remaster`, `(Remastered)`, `(Deluxe Edition)`, and `(Bonus Track)` are stripped.
2. **Performance Preservation:** Performance versions such as `(Live)`, `(Acoustic)`, `(Remix)`, `(Instrumental)`, and `(Radio Edit)` are preserved to avoid conflating distinct recordings.
3. **Collaboration Alignment:** Multi-artist separators (`feat.`, `ft.`, `&`, `/`) are normalized to extract the primary artist.
4. **Duration Guard:** When linking synced records to local library files, a duration check ($\pm 15\text{s}$ or $8\%$) prevents matching short radio edits with extended live performances.
5. **Untagged Fallback:** Tracks missing standard tags produce an isolated `local_orphan:{hash}` key to prevent collisions.

---

## 5. Wire Format & Partition Serialization

Partitions are serialized as JSON files in the shared storage root.

### 5.1 Storage Hierarchy
```
MornyeSync/
|-- manifest.json
|-- tombstone.json (optional, present only during global history clear)
`-- listening/
    `-- devices/
        |-- dev_android_xxxxxx/
        |   |-- 2026-10.json
        |   `-- 2026-11.json
        `-- dev_windows_yyyyyy/
            `-- 2026-10.json
```

### 5.2 Monthly Partition File (`{YYYY-MM}.json`)
Contains the complete snapshot for one device during one calendar month:
```json
{
  "protocolVersion": 1,
  "deviceId": "dev_android_xxxxxx",
  "deviceName": "My Phone",
  "month": "2026-10",
  "recordCount": 42,
  "records": [
    {
      "day": "2026-10-30",
      "trackKey": "starboy|the weeknd",
      "title": "Starboy",
      "artist": "The Weeknd",
      "album": "Starboy",
      "artwork": "https://example.com/cover.jpg",
      "milliseconds": 230000,
      "plays": 1,
      "updatedAt": 1730300000000
    }
  ]
}
```

### 5.3 Root Manifest (`manifest.json`)
The registry tracking active devices and synchronization epochs:
```json
{
  "protocolVersion": 1,
  "syncEpoch": 1,
  "epochId": "epoch_init_1730000000",
  "app": "Mornye",
  "updatedAt": 1730300000000,
  "devices": [
    {
      "id": "dev_android_xxxxxx",
      "platform": "android",
      "deviceName": "My Phone",
      "lastActive": "2026-10-30T18:00:00.000Z"
    }
  ]
}
```

---

## 6. Synchronization Protocol & Non-Destructive Ingestion

Synchronization executes in six phases:

1. **Pre-Sync Memory Flush:**
   `listeningRecorder.flush()` flushes any in-memory playback buffers to SQLite, ensuring read-your-own-writes consistency.
2. **Epoch & Manifest Validation:**
   The remote `manifest.json` is fetched. If a remote epoch is higher than the local epoch (indicating a global clear was issued from another device), pre-epoch local records are purged and outboxes reset before proceeding.
3. **Partition Publishing:**
   Local months marked dirty in `sync_outbox` are exported to JSON and written via atomic staging (`.tmp` write followed by overwrite). Upon successful upload, the dirty flag is cleared.
4. **Peer Partition Discovery:**
   The service lists all registered and discovered device directories under `listening/devices/`.
5. **Transactional Ingestion:**
   For each remote peer device and modified month, ingestion executes inside a single SQLite transaction:
   ```sql
   DELETE FROM listening_device_records
   WHERE device_id = :peerDeviceId AND day >= :monthStart AND day <= :monthEnd;

   INSERT INTO listening_device_records (...) VALUES (...);
   ```
   **Peer Data Preservation Invariant:** Normal sync never purges peer records outside of the incoming `(deviceId, month)` snapshot. If a manifest is missing or a peer device is temporarily offline, existing peer history in local SQLite is strictly retained.
6. **Reactive Provider Invalidation:**
   Upon completion, Riverpod providers are invalidated:
   ```dart
   ref.invalidate(listeningSummaryProvider);
   ref.invalidate(listeningRewindProvider);
   ref.invalidate(listeningRewindSpotlightProvider);
   ```

---

## 7. Transport Abstraction & Connection Selection

The `SyncStorageDriver` abstract interface defines basic storage primitives (`listFiles`, `readFile`, `writeFile`, `stat`, `createDirectory`).

### 7.1 Implemented Drivers
- **`LocalFolderSyncDriver`:** Operates directly on filesystem directories (such as a local directory or network folder mount). Uses atomic staging and retry loops to handle file lock contention.
- **`WebDavSyncDriver`:** Operates over WebDAV HTTP/HTTPS endpoints using atomic `PUT` to temporary files followed by `MOVE` with `Overwrite: T`.

### 7.2 Connection Selection Precedence
When resolving which Network Storage WebDAV connection to use, the service adheres to a strict deterministic hierarchy:

1. **Explicit Preference:** If a valid connection ID is saved in settings, it is used unconditionally.
2. **Unambiguous Single Connection:** If exactly one WebDAV connection is configured, it is selected automatically.
3. **Multiple Connections Without Preference:** Returns `null`, requiring explicit selection in Settings → Network Storage to prevent ambiguous destination selection.
4. **Deleted / Incompatible Preference:** If a previously saved connection ID was deleted or changed to an incompatible protocol (SMB/Subsonic), the service returns `null` and raises an actionable message rather than silently falling back.
5. **No Connections:** Returns `null` and guides the user to add a WebDAV connection.

---

## 8. Security & Privacy Boundaries

- **No Credential Propagation:** Sync partitions contain musical metadata only (`title`, `artist`, `album`, `milliseconds`, `plays`). Network storage credentials, passwords, and tokens are stored in `FlutterSecureStorage` (Windows DPAPI / Android Keystore) and are never written to partition files or manifests.
- **No Local Paths in Partitions:** Partitions contain relative day dates and track keys. Local filesystem paths are never uploaded to remote storage.
- **Opt-In Control:** The feature is completely disabled by default on clean installations.

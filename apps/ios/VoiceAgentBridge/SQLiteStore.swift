import Foundation
import SQLite3

/// Local Memory cache identity. The normalized origin deliberately contains
/// only scheme, lowercase host, and effective port; credentials, paths,
/// queries, fragments, and auth tokens are not part of the scope.
struct MemoryCacheScope: Equatable, Hashable {
    let apiOrigin: String
    let userID: String

    init?(apiBaseURL: URL?, userID: String?) {
        guard let apiOrigin = ActiveCommandScope.origin(for: apiBaseURL),
              let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userID.isEmpty
        else { return nil }
        self.apiOrigin = apiOrigin
        self.userID = userID
    }
}

/// Small iOS 15-compatible persistence layer for the offline/read-cache path.
///
/// The app stores opaque JSON payloads instead of duplicating every server
/// field in a second Swift model. SQLite owns durability; the API models remain
/// the source of truth for decoding and validation.
final class SQLiteStore {
    static let shared = SQLiteStore()

    private let queue = DispatchQueue(label: "hk.knockknock.sqlite", qos: .utility)
    private let databaseURL: URL
    private var database: OpaquePointer?

    private enum Binding {
        case text(String)
        case blob(Data)
        case integer(Int64)
        case real(Double)
        case null
    }

    private struct PreparedMemory {
        let item: MemoryItem
        let valueJSON: String
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Each identifier is append-only. Existing databases are upgraded by
    /// adding tables/columns and are never rewritten destructively.
    private static let migrationIDs = [
        "ios_g1_001_pending_operation_state",
        "ios_g1_002_pending_reconciliation_events",
        "ios_g1_003_sync_cursor_state",
        "ios_g1_004_structured_memory_cache",
    ]

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultURL()
        open()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    var isAvailable: Bool {
        queue.sync { database != nil }
    }

    func migrateLegacyState(
        pendingKey: String = "vab.pendingOperations",
        cursorKey: String = "vab.lastEventID"
    ) {
        queue.sync {
            guard database != nil else { return }
            var pendingReady = true
            if let data = UserDefaults.standard.data(forKey: pendingKey) {
                if let legacy = try? JSONDecoder().decode([PendingOperation].self, from: data) {
                    let existing = pendingOperationsLocked()
                    var merged = existing
                    var existingIDs = Set(existing.map(\.id))
                    for operation in legacy where existingIDs.insert(operation.id).inserted {
                        merged.append(operation)
                    }
                    merged.sort { $0.created_at < $1.created_at }
                    if merged != existing && !savePendingLocked(merged) {
                        pendingReady = false
                    }
                } else {
                    pendingReady = false
                }
            }

            var cursorReady = true
            if let cursor = UserDefaults.standard.string(forKey: cursorKey), !cursor.isEmpty,
               loadAppliedCursorLocked() == nil {
                cursorReady = saveSyncStateLocked(cursor: cursor, appliedCursor: cursor)
            }

            if pendingReady {
                UserDefaults.standard.removeObject(forKey: pendingKey)
            }
            if cursorReady {
                UserDefaults.standard.removeObject(forKey: cursorKey)
            }
        }
    }

    func loadCursor() -> String? {
        queue.sync { loadCursorLocked() }
    }

    func saveCursor(_ cursor: String?) {
        queue.sync {
            let applied = loadAppliedCursorLocked()
            _ = saveSyncStateLocked(cursor: cursor, appliedCursor: applied)
        }
    }

    func loadAppliedCursor() -> String? {
        queue.sync { loadAppliedCursorLocked() }
    }

    func saveAppliedCursor(_ cursor: String?) {
        queue.sync {
            let received = loadCursorLocked()
            _ = saveSyncStateLocked(cursor: received, appliedCursor: cursor)
        }
    }

    /// Reset the receive/apply watermarks when the account or API base changes.
    /// Queued invalidations belong to the old stream and must not be replayed
    /// against a different account or server.
    func resetSyncState(clearPendingEvents: Bool = false) {
        queue.sync {
            _ = transactionLocked {
                if clearPendingEvents {
                    guard executeLocked("DELETE FROM pending_sync_events") else { return false }
                }
                return saveSyncStateLocked(cursor: nil, appliedCursor: nil)
            }
        }
    }

    /// Persist an SSE event before scheduling its REST reconciliation. The
    /// primary key makes duplicate deliveries harmless and keeps events that
    /// arrive while another reconciliation is in flight.
    @discardableResult
    func recordPendingSyncEvent(
        eventID: String,
        eventName: String,
        receivedAt: Date = Date()
    ) -> Bool {
        queue.sync {
            guard !eventID.isEmpty else { return false }
            guard executeLocked(
                "INSERT OR IGNORE INTO pending_sync_events (event_id, event_name, received_at) VALUES (?, ?, ?)",
                bindings: [
                    .text(eventID),
                    .text(eventName),
                    .real(receivedAt.timeIntervalSince1970),
                ]
            ) else { return false }
            let applied = loadAppliedCursorLocked()
            let received = pendingSyncEventsLocked().last?.event_id ?? eventID
            return saveSyncStateLocked(cursor: received, appliedCursor: applied)
        }
    }

    func loadPendingSyncEvents() -> [PendingSyncEvent] {
        queue.sync { pendingSyncEventsLocked() }
    }

    /// Commit the applied cursor and event consumption in one SQLite
    /// transaction. Events inserted before this transaction are consumed;
    /// events inserted afterward remain queued for the next pass.
    @discardableResult
    func commitReconciliation(
        cursor: String?,
        resetCursor: Bool,
        consumedEventIDs: Set<String>
    ) -> Bool {
        queue.sync {
            transactionLocked {
                if !consumedEventIDs.isEmpty {
                    let placeholders = Array(repeating: "?", count: consumedEventIDs.count)
                        .joined(separator: ", ")
                    let bindings = consumedEventIDs.sorted().map(Binding.text)
                    guard executeLocked(
                        "DELETE FROM pending_sync_events WHERE event_id IN (\(placeholders))",
                        bindings: bindings
                    ) else { return false }
                }

                let currentCursor = loadCursorLocked()
                let currentApplied = loadAppliedCursorLocked()
                let pending = pendingSyncEventsLocked()
                let nextApplied: String?
                if resetCursor {
                    nextApplied = nil
                } else {
                    nextApplied = cursor ?? currentApplied
                }
                let nextCursor = resetCursor
                    ? pending.last?.event_id
                    : (pending.last?.event_id ?? cursor ?? currentCursor)
                return saveSyncStateLocked(cursor: nextCursor, appliedCursor: nextApplied)
            }
        }
    }

    func loadPendingOperations() -> [PendingOperation] {
        queue.sync { pendingOperationsLocked() }
    }

    @discardableResult
    func savePendingOperations(_ operations: [PendingOperation]) -> Bool {
        queue.sync { savePendingLocked(operations) }
    }

    func loadPendingCommandConfirmation() -> PendingCommandConfirmation? {
        queue.sync {
            guard let value = metadataLocked(key: "pending_command_confirmation"),
                  let data = value.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(PendingCommandConfirmation.self, from: data)
        }
    }

    func savePendingCommandConfirmation(_ confirmation: PendingCommandConfirmation) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(confirmation),
                  let value = String(data: data, encoding: .utf8)
            else { return }
            _ = setMetadataLocked(key: "pending_command_confirmation", value: value)
        }
    }

    func clearPendingCommandConfirmation() {
        queue.sync {
            _ = executeLocked(
                "DELETE FROM metadata WHERE key = ?",
                bindings: [.text("pending_command_confirmation")]
            )
        }
    }

    func loadActiveCommandCheckpoint() -> ActiveCommandCheckpoint? {
        queue.sync {
            guard let value = metadataLocked(key: "active_command_checkpoint") else {
                _ = executeLocked(
                    "DELETE FROM metadata WHERE key = ?",
                    bindings: [.text("active_command_id")]
                )
                return nil
            }
            guard let data = value.data(using: .utf8),
                  let checkpoint = try? JSONDecoder().decode(ActiveCommandCheckpoint.self, from: data),
                  checkpoint.isStructurallyValid
            else {
                _ = executeLocked(
                    "DELETE FROM metadata WHERE key = ?",
                    bindings: [.text("active_command_checkpoint")]
                )
                return nil
            }
            return checkpoint
        }
    }

    /// Returns false when encoding or the SQLite write fails. Callers must
    /// treat that as a hard boundary and must not send the command.
    @discardableResult
    func saveActiveCommandCheckpoint(_ checkpoint: ActiveCommandCheckpoint) -> Bool {
        guard checkpoint.isStructurallyValid,
              let data = try? JSONEncoder().encode(checkpoint),
              let value = String(data: data, encoding: .utf8)
        else { return false }
        return queue.sync {
            transactionLocked {
                guard setMetadataLocked(key: "active_command_checkpoint", value: value) else {
                    return false
                }
                return executeLocked(
                    "DELETE FROM metadata WHERE key = ?",
                    bindings: [.text("active_command_id")]
                )
            }
        }
    }

    @discardableResult
    func clearActiveCommandCheckpoint() -> Bool {
        queue.sync {
            transactionLocked {
                guard executeLocked(
                    "DELETE FROM metadata WHERE key = ?",
                    bindings: [.text("active_command_checkpoint")]
                ) else { return false }
                return executeLocked(
                    "DELETE FROM metadata WHERE key = ?",
                    bindings: [.text("active_command_id")]
                )
            }
        }
    }

    /// Upserts one live canonical item. Deletions arrive separately as
    /// user-scoped phone-change tombstones.
    @discardableResult
    func upsertMemory(_ item: MemoryItem, in scope: MemoryCacheScope) -> Bool {
        guard let prepared = prepareMemory(item) else { return false }
        return queue.sync {
            upsertMemoryLocked(prepared, in: scope)
        }
    }

    /// Applies incremental live rows without deleting unrelated memories.
    @discardableResult
    func upsertMemories(_ items: [MemoryItem], in scope: MemoryCacheScope) -> Bool {
        guard let prepared = prepareMemories(items)
        else { return false }
        return queue.sync {
            transactionLocked {
                for memory in prepared {
                    if !upsertMemoryLocked(memory, in: scope) {
                        return false
                    }
                }
                return true
            }
        }
    }

    func loadMemories(in scope: MemoryCacheScope, now: Date = Date()) -> [MemoryItem] {
        return queue.sync {
            memoriesLocked(in: scope, now: now)
        }
    }

    @discardableResult
    func removeMemory(_ memoryID: String, in scope: MemoryCacheScope) -> Bool {
        guard !memoryID.isEmpty else { return false }
        return queue.sync {
            executeLocked(
                "DELETE FROM cached_memories WHERE api_origin = ? AND user_id = ? AND memory_id = ?",
                bindings: [.text(scope.apiOrigin), .text(scope.userID), .text(memoryID)]
            )
        }
    }

    /// Replaces exactly one user's cache in a single SQLite transaction.
    /// Encoding and duplicate validation complete before the DELETE begins,
    /// so malformed snapshots preserve the previous offline state.
    @discardableResult
    func replaceMemories(_ items: [MemoryItem], in scope: MemoryCacheScope) -> Bool {
        guard let prepared = prepareMemories(items)
        else { return false }
        var memoryIDs = Set<String>()
        guard prepared.allSatisfy({ memoryIDs.insert($0.item.memory_id).inserted }) else {
            return false
        }
        return queue.sync {
            transactionLocked {
                guard executeLocked(
                    "DELETE FROM cached_memories WHERE api_origin = ? AND user_id = ?",
                    bindings: [.text(scope.apiOrigin), .text(scope.userID)]
                ) else { return false }
                for memory in prepared where !upsertMemoryLocked(memory, in: scope) {
                    return false
                }
                return true
            }
        }
    }

    @discardableResult
    func clearMemories(in scope: MemoryCacheScope) -> Bool {
        return queue.sync {
            executeLocked(
                "DELETE FROM cached_memories WHERE api_origin = ? AND user_id = ?",
                bindings: [.text(scope.apiOrigin), .text(scope.userID)]
            )
        }
    }

    func cacheSessions(_ sessions: [Session]) {
        queue.sync {
            let now = ISO8601DateFormatter().string(from: Date())
            let payloads = sessions.compactMap { session in
                try? JSONEncoder().encode(session)
            }
            guard payloads.count == sessions.count else { return }
            _ = transactionLocked {
                guard executeLocked("DELETE FROM cached_sessions") else { return false }
                for (session, payload) in zip(sessions, payloads) {
                    guard executeLocked(
                        "INSERT OR REPLACE INTO cached_sessions (session_id, payload, updated_at) VALUES (?, ?, ?)",
                        bindings: [.text(session.session_id), .blob(payload), .text(now)]
                    ) else { return false }
                }
                return true
            }
        }
    }

    func loadSessions() -> [Session] {
        queue.sync {
            blobsLocked("SELECT payload FROM cached_sessions ORDER BY updated_at DESC, session_id ASC")?
                .compactMap { try? JSONDecoder().decode(Session.self, from: $0) } ?? []
        }
    }

    func cachePushes(_ pushes: [DevPush]) {
        queue.sync {
            let payloads = pushes.compactMap { push in
                try? JSONEncoder().encode(push)
            }
            guard payloads.count == pushes.count else { return }
            _ = transactionLocked {
                guard executeLocked("DELETE FROM cached_pushes") else { return false }
                for (push, payload) in zip(pushes, payloads) {
                    guard executeLocked(
                        "INSERT OR REPLACE INTO cached_pushes (push_id, payload, created_at) VALUES (?, ?, ?)",
                        bindings: [.text(push.push_id), .blob(payload), .text(push.created_at)]
                    ) else { return false }
                }
                return true
            }
        }
    }

    func loadPushes() -> [DevPush] {
        queue.sync {
            blobsLocked("SELECT payload FROM cached_pushes ORDER BY created_at DESC, push_id ASC")?
                .compactMap { try? JSONDecoder().decode(DevPush.self, from: $0) } ?? []
        }
    }

    func cacheHistory(_ entries: [HistoryEntry], for sessionID: String) {
        queue.sync {
            let payloads = entries.compactMap { entry in
                try? JSONEncoder().encode(entry)
            }
            guard payloads.count == entries.count else { return }
            _ = transactionLocked {
                guard executeLocked(
                    "DELETE FROM cached_history WHERE session_id = ?",
                    bindings: [.text(sessionID)]
                ) else { return false }
                for (entry, payload) in zip(entries, payloads) {
                    guard executeLocked(
                        "INSERT OR REPLACE INTO cached_history (session_id, history_id, payload, created_at) VALUES (?, ?, ?, ?)",
                        bindings: [
                            .text(sessionID),
                            .text(entry.audit_id),
                            .blob(payload),
                            .text(entry.created_at),
                        ]
                    ) else { return false }
                }
                return true
            }
        }
    }

    func loadHistory(for sessionID: String) -> [HistoryEntry] {
        queue.sync {
            blobsLocked(
                "SELECT payload FROM cached_history WHERE session_id = ? ORDER BY created_at ASC, history_id ASC",
                strings: [sessionID]
            )?.compactMap { try? JSONDecoder().decode(HistoryEntry.self, from: $0) } ?? []
        }
    }

    func cacheMessages(_ messages: [SessionMessage], for sessionID: String) {
        queue.sync {
            let payloads = messages.compactMap { message in
                try? JSONEncoder().encode(message)
            }
            guard payloads.count == messages.count else { return }
            _ = transactionLocked {
                for (message, payload) in zip(messages, payloads) {
                    guard executeLocked(
                        "INSERT OR REPLACE INTO cached_messages (message_id, session_id, payload, created_at) VALUES (?, ?, ?, ?)",
                        bindings: [
                            .text(message.message_id),
                            .text(sessionID),
                            .blob(payload),
                            .text(message.created_at),
                        ]
                    ) else { return false }
                }
                return true
            }
        }
    }

    func loadMessages(for sessionID: String) -> [SessionMessage] {
        queue.sync {
            blobsLocked(
                "SELECT payload FROM cached_messages WHERE session_id = ? ORDER BY created_at ASC, message_id ASC",
                strings: [sessionID]
            )?.compactMap { try? JSONDecoder().decode(SessionMessage.self, from: $0) } ?? []
        }
    }

    func cacheRetrievals(_ items: [RetrievalItem], for sessionID: String) {
        queue.sync {
            let payloads = items.compactMap { item in
                try? JSONEncoder().encode(item)
            }
            guard payloads.count == items.count else { return }
            _ = transactionLocked {
                for (item, payload) in zip(items, payloads) {
                    guard executeLocked(
                        "INSERT OR REPLACE INTO cached_retrievals (retrieval_id, session_id, payload, created_at) VALUES (?, ?, ?, ?)",
                        bindings: [
                            .text(item.retrieval_id),
                            .text(sessionID),
                            .blob(payload),
                            .text(item.created_at),
                        ]
                    ) else { return false }
                }
                return true
            }
        }
    }

    func loadRetrievals(for sessionID: String) -> [RetrievalItem] {
        queue.sync {
            blobsLocked(
                "SELECT payload FROM cached_retrievals WHERE session_id = ? ORDER BY created_at DESC, retrieval_id ASC",
                strings: [sessionID]
            )?.compactMap { try? JSONDecoder().decode(RetrievalItem.self, from: $0) } ?? []
        }
    }

    func removeMessage(_ messageID: String) {
        queue.sync {
            _ = executeLocked(
                "DELETE FROM cached_messages WHERE message_id = ?",
                bindings: [.text(messageID)]
            )
        }
    }

    func removeRetrieval(_ retrievalID: String) {
        queue.sync {
            _ = executeLocked(
                "DELETE FROM cached_retrievals WHERE retrieval_id = ?",
                bindings: [.text(retrievalID)]
            )
        }
    }

    func removeSession(_ sessionID: String) {
        queue.sync {
            _ = transactionLocked {
                guard executeLocked("DELETE FROM cached_sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else { return false }
                guard executeLocked("DELETE FROM cached_messages WHERE session_id = ?", bindings: [.text(sessionID)]) else { return false }
                guard executeLocked("DELETE FROM cached_retrievals WHERE session_id = ?", bindings: [.text(sessionID)]) else { return false }
                return executeLocked("DELETE FROM cached_history WHERE session_id = ?", bindings: [.text(sessionID)])
            }
        }
    }

    func clearDetailCaches() {
        queue.sync {
            _ = transactionLocked {
                guard executeLocked("DELETE FROM cached_messages") else { return false }
                guard executeLocked("DELETE FROM cached_retrievals") else { return false }
                return executeLocked("DELETE FROM cached_history")
            }
        }
    }

    func clearUserData() {
        queue.sync {
            _ = transactionLocked {
                guard executeLocked("DELETE FROM cached_sessions") else { return false }
                guard executeLocked("DELETE FROM cached_memories") else { return false }
                guard executeLocked("DELETE FROM cached_messages") else { return false }
                guard executeLocked("DELETE FROM cached_retrievals") else { return false }
                guard executeLocked("DELETE FROM cached_history") else { return false }
                guard executeLocked("DELETE FROM cached_pushes") else { return false }
                guard executeLocked("DELETE FROM pending_operations") else { return false }
                guard executeLocked("DELETE FROM pending_sync_events") else { return false }
                guard executeLocked("DELETE FROM sync_state") else { return false }
                return executeLocked(
                    "DELETE FROM metadata WHERE key IN ('cursor', 'applied_cursor', 'pending_command_confirmation', 'active_command_id', 'active_command_checkpoint')"
                )
            }
        }
    }

    private func open() {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: databaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                return
            }
            guard sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK else {
                if let database { sqlite3_close(database) }
                database = nil
                return
            }
            guard executeScriptLocked(
                        """
                        PRAGMA journal_mode = WAL;
                        PRAGMA foreign_keys = ON;
                        CREATE TABLE IF NOT EXISTS schema_migrations (
                          migration_id TEXT PRIMARY KEY NOT NULL,
                          applied_at REAL NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS metadata (
                          key TEXT PRIMARY KEY NOT NULL,
                          value TEXT NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS cached_sessions (
                          session_id TEXT PRIMARY KEY NOT NULL,
                          payload BLOB NOT NULL,
                          updated_at TEXT NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS cached_messages (
                          message_id TEXT PRIMARY KEY NOT NULL,
                          session_id TEXT NOT NULL,
                          payload BLOB NOT NULL,
                          created_at TEXT NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS cached_retrievals (
                          retrieval_id TEXT PRIMARY KEY NOT NULL,
                          session_id TEXT NOT NULL,
                          payload BLOB NOT NULL,
                          created_at TEXT NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS cached_history (
                          session_id TEXT NOT NULL,
                          history_id TEXT NOT NULL,
                          payload BLOB NOT NULL,
                          created_at TEXT NOT NULL,
                          PRIMARY KEY (session_id, history_id)
                        );
                        CREATE TABLE IF NOT EXISTS cached_pushes (
                          push_id TEXT PRIMARY KEY NOT NULL,
                          payload BLOB NOT NULL,
                          created_at TEXT NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS pending_operations (
                          operation_id TEXT PRIMARY KEY NOT NULL,
                          payload BLOB NOT NULL,
                          created_at REAL NOT NULL
                        );
                        """
                    ) else {
                sqlite3_close(database)
                database = nil
                return
            }
            guard applyMigrationsLocked() else {
                sqlite3_close(database)
                database = nil
                return
            }
        }
    }

    private func applyMigrationsLocked() -> Bool {
        for migrationID in Self.migrationIDs {
            guard !migrationAppliedLocked(migrationID) else { continue }
            guard executeLocked("BEGIN IMMEDIATE") else { return false }

            let applied: Bool
            switch migrationID {
            case "ios_g1_001_pending_operation_state":
                applied = migratePendingOperationStateLocked()
            case "ios_g1_002_pending_reconciliation_events":
                applied = executeScriptLocked(
                    """
                    CREATE TABLE IF NOT EXISTS pending_sync_events (
                      event_id TEXT PRIMARY KEY NOT NULL,
                      event_name TEXT NOT NULL,
                      received_at REAL NOT NULL
                    );
                    """
                )
            case "ios_g1_003_sync_cursor_state":
                applied = executeScriptLocked(
                    """
                    CREATE TABLE IF NOT EXISTS sync_state (
                      scope TEXT PRIMARY KEY NOT NULL,
                      cursor TEXT,
                      applied_cursor TEXT,
                      updated_at REAL NOT NULL
                    );
                    """
                )
            case "ios_g1_004_structured_memory_cache":
                applied = executeScriptLocked(
                    """
                    CREATE TABLE IF NOT EXISTS cached_memories (
                      api_origin TEXT NOT NULL,
                      user_id TEXT NOT NULL,
                      memory_id TEXT NOT NULL,
                      schema_version INTEGER NOT NULL,
                      kind TEXT NOT NULL,
                      subject TEXT NOT NULL,
                      predicate TEXT NOT NULL,
                      value_json TEXT NOT NULL,
                      display_text TEXT NOT NULL,
                      locale TEXT NOT NULL,
                      source_type TEXT NOT NULL,
                      source_session_id TEXT,
                      source_message_id TEXT,
                      user_confirmed INTEGER NOT NULL,
                      confidence REAL NOT NULL,
                      version INTEGER NOT NULL,
                      retention_expires_at TEXT,
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      PRIMARY KEY (api_origin, user_id, memory_id)
                    );
                    CREATE INDEX IF NOT EXISTS idx_cached_memories_scope_page
                      ON cached_memories(api_origin, user_id, created_at DESC, memory_id DESC);
                    """
                )
            default:
                applied = false
            }

            guard applied,
                  executeLocked(
                      "INSERT INTO schema_migrations (migration_id, applied_at) VALUES (?, ?)",
                      bindings: [.text(migrationID), .real(Date().timeIntervalSince1970)]
                  ),
                  executeLocked("COMMIT")
            else {
                _ = executeLocked("ROLLBACK")
                return false
            }
        }
        return true
    }

    private func migratePendingOperationStateLocked() -> Bool {
        guard ensureColumnLocked(
            table: "pending_operations",
            name: "idempotency_key",
            definition: "TEXT"
        ) else { return false }
        guard ensureColumnLocked(
            table: "pending_operations",
            name: "status",
            definition: "TEXT NOT NULL DEFAULT 'pending'"
        ) else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "kind", definition: "TEXT") else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "session_id", definition: "TEXT") else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "action_key", definition: "TEXT") else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "action_id", definition: "TEXT") else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "confirm", definition: "INTEGER") else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "last_error", definition: "TEXT") else { return false }
        guard ensureColumnLocked(table: "pending_operations", name: "failure_code", definition: "TEXT") else { return false }
        return executeLocked(
            "UPDATE pending_operations SET idempotency_key = operation_id WHERE idempotency_key IS NULL OR idempotency_key = ''"
        )
    }

    private func migrationAppliedLocked(_ migrationID: String) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM schema_migrations WHERE migration_id = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard bindLocked(statement, bindings: [.text(migrationID)]) else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func ensureColumnLocked(table: String, name: String, definition: String) -> Bool {
        guard !tableHasColumnLocked(table: table, name: name) else { return true }
        return executeLocked("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private func tableHasColumnLocked(table: String, name: String) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(table))",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnName = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: columnName) == name { return true }
        }
        return false
    }

    private func prepareMemory(_ item: MemoryItem) -> PreparedMemory? {
        guard let data = try? JSONEncoder().encode(item.value),
              data.count <= 8_192,
              let valueJSON = String(data: data, encoding: .utf8)
        else { return nil }
        return PreparedMemory(item: item, valueJSON: valueJSON)
    }

    private func prepareMemories(_ items: [MemoryItem]) -> [PreparedMemory]? {
        let prepared = items.compactMap { prepareMemory($0) }
        return prepared.count == items.count ? prepared : nil
    }

    private func upsertMemoryLocked(
        _ prepared: PreparedMemory,
        in scope: MemoryCacheScope
    ) -> Bool {
        let item = prepared.item
        return executeLocked(
            """
            INSERT OR REPLACE INTO cached_memories (
              api_origin, user_id, memory_id, schema_version, kind, subject, predicate,
              value_json, display_text, locale, source_type,
              source_session_id, source_message_id, user_confirmed, confidence,
              version, retention_expires_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(scope.apiOrigin),
                .text(scope.userID),
                .text(item.memory_id),
                .integer(Int64(item.schema_version)),
                .text(item.kind.rawValue),
                .text(item.subject),
                .text(item.predicate),
                .text(prepared.valueJSON),
                .text(item.display_text),
                .text(item.locale),
                .text(item.source_type.rawValue),
                item.source_session_id.map(Binding.text) ?? .null,
                item.source_message_id.map(Binding.text) ?? .null,
                .integer(item.user_confirmed ? 1 : 0),
                .real(item.confidence),
                .integer(Int64(item.version)),
                item.retention_expires_at.map(Binding.text) ?? .null,
                .text(item.created_at),
                .text(item.updated_at),
            ]
        )
    }

    private func memoriesLocked(in scope: MemoryCacheScope, now: Date) -> [MemoryItem] {
        guard let database else { return [] }
        let sql = """
        SELECT
          schema_version, memory_id, kind, subject, predicate, value_json,
          display_text, locale, source_type, source_session_id,
          source_message_id, user_confirmed, confidence, version,
          retention_expires_at, created_at, updated_at
        FROM cached_memories
        WHERE api_origin = ? AND user_id = ?
        ORDER BY created_at DESC, memory_id DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        guard bindLocked(
            statement,
            bindings: [.text(scope.apiOrigin), .text(scope.userID)]
        ) else { return [] }

        func requiredText(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, index)
            else { return nil }
            return String(cString: value)
        }
        func optionalText(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return requiredText(index)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSecondFormatter = ISO8601DateFormatter()
        wholeSecondFormatter.formatOptions = [.withInternetDateTime]

        var memories: [MemoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let memoryID = requiredText(1),
                  let kindRaw = requiredText(2),
                  let kind = MemoryKind(rawValue: kindRaw),
                  let subject = requiredText(3),
                  let predicate = requiredText(4),
                  let valueJSON = requiredText(5),
                  let value = try? JSONDecoder().decode(
                      JSONValue.self,
                      from: Data(valueJSON.utf8)
                  ),
                  let displayText = requiredText(6),
                  let locale = requiredText(7),
                  let sourceRaw = requiredText(8),
                  let sourceType = MemorySourceType(rawValue: sourceRaw),
                  let createdAt = requiredText(15),
                  let updatedAt = requiredText(16)
            else { continue }
            let retentionExpiresAt = optionalText(14)
            if let retentionExpiresAt {
                guard let expiration = fractionalFormatter.date(from: retentionExpiresAt)
                    ?? wholeSecondFormatter.date(from: retentionExpiresAt),
                      expiration > now
                else { continue }
            }
            memories.append(
                MemoryItem(
                    schema_version: Int(sqlite3_column_int64(statement, 0)),
                    memory_id: memoryID,
                    kind: kind,
                    subject: subject,
                    predicate: predicate,
                    value: value,
                    display_text: displayText,
                    locale: locale,
                    source_type: sourceType,
                    source_session_id: optionalText(9),
                    source_message_id: optionalText(10),
                    user_confirmed: sqlite3_column_int64(statement, 11) != 0,
                    confidence: sqlite3_column_double(statement, 12),
                    version: Int(sqlite3_column_int64(statement, 13)),
                    retention_expires_at: retentionExpiresAt,
                    created_at: createdAt,
                    updated_at: updatedAt
                )
            )
        }
        return memories
    }

    private func pendingOperationsLocked() -> [PendingOperation] {
        guard let rows = blobsLocked(
            "SELECT payload FROM pending_operations ORDER BY created_at ASC, operation_id ASC"
        ) else { return [] }
        return rows.compactMap { try? JSONDecoder().decode(PendingOperation.self, from: $0) }
            .map { operation in
                var recovered = operation
                // A process can terminate after marking an intent in-flight
                // but before receiving the HTTP response. Replaying the same
                // key is safe; exposing it as in-flight across launches is
                // not, so recover it to the explicit pending state.
                if recovered.status == .inFlight {
                    recovered.status = .pending
                }
                return recovered
            }
    }

    @discardableResult
    private func savePendingLocked(_ operations: [PendingOperation]) -> Bool {
        guard database != nil, executeLocked("BEGIN IMMEDIATE") else { return false }
        guard executeLocked("DELETE FROM pending_operations") else {
            _ = executeLocked("ROLLBACK")
            return false
        }
        for operation in operations {
            guard let payload = try? JSONEncoder().encode(operation),
                  executeLocked(
                """
                INSERT OR REPLACE INTO pending_operations
                  (operation_id, payload, created_at, idempotency_key, status, kind,
                   session_id, action_key, action_id, confirm, last_error, failure_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(operation.id),
                    .blob(payload),
                    .real(operation.created_at.timeIntervalSince1970),
                    .text(operation.idempotency_key),
                    .text(operation.status.rawValue),
                    .text(operation.kind.rawValue),
                    .text(operation.session_id),
                    operation.action_key.map(Binding.text) ?? .null,
                    operation.action_id.map(Binding.text) ?? .null,
                    operation.confirm.map { .integer($0 ? 1 : 0) } ?? .null,
                    operation.lastError.map(Binding.text) ?? .null,
                    operation.failureCode.map(Binding.text) ?? .null,
                ]
            ) else {
                _ = executeLocked("ROLLBACK")
                return false
            }
        }
        guard executeLocked("COMMIT") else {
            _ = executeLocked("ROLLBACK")
            return false
        }
        return true
    }

    private func pendingSyncEventsLocked() -> [PendingSyncEvent] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT event_id, event_name, received_at FROM pending_sync_events ORDER BY received_at ASC, event_id ASC",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var events: [PendingSyncEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let eventID = sqlite3_column_text(statement, 0),
                  let eventName = sqlite3_column_text(statement, 1)
            else { continue }
            events.append(
                PendingSyncEvent(
                    event_id: String(cString: eventID),
                    event_name: String(cString: eventName),
                    received_at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                )
            )
        }
        return events
    }

    private func loadCursorLocked() -> String? {
        syncStateLocked()?.cursor ?? metadataLocked(key: "cursor")
    }

    private func loadAppliedCursorLocked() -> String? {
        syncStateLocked()?.appliedCursor ?? metadataLocked(key: "applied_cursor")
    }

    @discardableResult
    private func saveSyncStateLocked(cursor: String?, appliedCursor: String?) -> Bool {
        guard executeLocked(
            "INSERT OR REPLACE INTO sync_state (scope, cursor, applied_cursor, updated_at) VALUES (?, ?, ?, ?)",
            bindings: [
                .text("phone"),
                cursor.map(Binding.text) ?? .null,
                appliedCursor.map(Binding.text) ?? .null,
                .real(Date().timeIntervalSince1970),
            ]
        ) else { return false }

        let cursorResult: Bool
        if let cursor {
            cursorResult = setMetadataLocked(key: "cursor", value: cursor)
        } else {
            cursorResult = executeLocked(
                "DELETE FROM metadata WHERE key = ?",
                bindings: [.text("cursor")]
            )
        }
        guard cursorResult else { return false }

        if let appliedCursor {
            return setMetadataLocked(key: "applied_cursor", value: appliedCursor)
        }
        return executeLocked(
            "DELETE FROM metadata WHERE key = ?",
            bindings: [.text("applied_cursor")]
        )
    }

    private func syncStateLocked() -> (cursor: String?, appliedCursor: String?)? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT cursor, applied_cursor FROM sync_state WHERE scope = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard bindLocked(statement, bindings: [.text("phone")]),
              sqlite3_step(statement) == SQLITE_ROW
        else { return nil }
        return (
            textColumnLocked(statement, index: 0),
            textColumnLocked(statement, index: 1)
        )
    }

    private func executeScriptLocked(_ sql: String) -> Bool {
        guard let database else { return false }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        return result == SQLITE_OK
    }

    private func transactionLocked(_ body: () -> Bool) -> Bool {
        guard executeLocked("BEGIN IMMEDIATE") else { return false }
        guard body() else {
            _ = executeLocked("ROLLBACK")
            return false
        }
        guard executeLocked("COMMIT") else {
            _ = executeLocked("ROLLBACK")
            return false
        }
        return true
    }

    @discardableResult
    private func executeLocked(
        _ sql: String,
        bindings: [Binding] = []
    ) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard bindLocked(statement, bindings: bindings) else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func blobsLocked(_ sql: String, strings: [String] = []) -> [Data]? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard bindLocked(statement, bindings: strings.map(Binding.text)) else { return nil }
        var result: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            result.append(Data(bytes: bytes, count: length))
        }
        return result
    }

    private func countLocked(table: String) -> Int {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM \(table)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func metadataLocked(key: String) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bindLocked(statement, bindings: [.text(key)])
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }

    @discardableResult
    private func setMetadataLocked(key: String, value: String) -> Bool {
        executeLocked(
            "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)",
            bindings: [.text(key), .text(value)]
        )
    }

    @discardableResult
    private func bindLocked(_ statement: OpaquePointer, bindings: [Binding]) -> Bool {
        var index: Int32 = 1
        for binding in bindings {
            let result: Int32
            switch binding {
            case let .text(value):
                result = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, Self.transient)
                }
            case let .blob(value):
                result = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        buffer.baseAddress,
                        Int32(value.count),
                        Self.transient
                    )
                }
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { return false }
            index += 1
        }
        return true
    }

    private func textColumnLocked(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("KnockKnock", isDirectory: true)
            .appendingPathComponent("knock-knock.sqlite")
    }
}

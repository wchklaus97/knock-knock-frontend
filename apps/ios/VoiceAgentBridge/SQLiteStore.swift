import Foundation
import SQLite3

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
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
               metadataLocked(key: "applied_cursor") == nil {
                cursorReady = setMetadataLocked(key: "applied_cursor", value: cursor)
            }

            if pendingReady {
                UserDefaults.standard.removeObject(forKey: pendingKey)
            }
            if cursorReady {
                UserDefaults.standard.removeObject(forKey: cursorKey)
            }
        }
    }

    func loadAppliedCursor() -> String? {
        queue.sync { metadataLocked(key: "applied_cursor") }
    }

    func saveAppliedCursor(_ cursor: String?) {
        queue.sync {
            if let cursor, !cursor.isEmpty {
                setMetadataLocked(key: "applied_cursor", value: cursor)
            } else {
                _ = executeLocked(
                    "DELETE FROM metadata WHERE key = ?",
                    bindings: [.text("applied_cursor")]
                )
            }
        }
    }

    func loadPendingOperations() -> [PendingOperation] {
        queue.sync { pendingOperationsLocked() }
    }

    func savePendingOperations(_ operations: [PendingOperation]) {
        queue.sync { savePendingLocked(operations) }
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

    func clearUserData() {
        queue.sync {
            _ = transactionLocked {
                guard executeLocked("DELETE FROM cached_sessions") else { return false }
                guard executeLocked("DELETE FROM cached_messages") else { return false }
                guard executeLocked("DELETE FROM cached_retrievals") else { return false }
                guard executeLocked("DELETE FROM cached_history") else { return false }
                guard executeLocked("DELETE FROM cached_pushes") else { return false }
                guard executeLocked("DELETE FROM pending_operations") else { return false }
                return executeLocked("DELETE FROM metadata WHERE key = 'applied_cursor'")
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
        }
    }

    private func pendingOperationsLocked() -> [PendingOperation] {
        guard let rows = blobsLocked(
            "SELECT payload FROM pending_operations ORDER BY created_at ASC, operation_id ASC"
        ) else { return [] }
        return rows.compactMap { try? JSONDecoder().decode(PendingOperation.self, from: $0) }
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
                "INSERT OR REPLACE INTO pending_operations (operation_id, payload, created_at) VALUES (?, ?, ?)",
                bindings: [
                    .text(operation.id),
                    .blob(payload),
                    .text(String(operation.created_at.timeIntervalSince1970)),
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
        bindLocked(statement, bindings: bindings)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func blobsLocked(_ sql: String, strings: [String] = []) -> [Data]? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bindLocked(statement, bindings: strings.map(Binding.text))
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

    private func bindLocked(_ statement: OpaquePointer, bindings: [Binding]) {
        var index: Int32 = 1
        for binding in bindings {
            switch binding {
            case let .text(value):
                value.withCString { pointer in
                    _ = sqlite3_bind_text(statement, index, pointer, -1, Self.transient)
                }
            case let .blob(value):
                value.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(
                        statement,
                        index,
                        buffer.baseAddress,
                        Int32(value.count),
                        Self.transient
                    )
                }
            }
            index += 1
        }
    }

    private static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("KnockKnock", isDirectory: true)
            .appendingPathComponent("knock-knock.sqlite")
    }
}

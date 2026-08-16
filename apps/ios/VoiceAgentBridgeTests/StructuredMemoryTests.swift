import Foundation
import SQLite3
import XCTest
@testable import VoiceAgentBridge

final class StructuredMemoryContractTests: XCTestCase {
    func testCanonicalMemoryItemRoundTripsWithoutStorageFieldAliases() throws {
        let data = Data(
            #"{"memory_id":"memory_contract","schema_version":1,"kind":"preference","subject":"user","predicate":"drink","value":{"name":"tea","count":2},"display_text":"Prefers tea","locale":"en-HK","source_type":"trusted_system","source_session_id":"session_1","source_message_id":"message_1","user_confirmed":true,"confidence":0.9,"version":3,"retention_expires_at":null,"created_at":"2026-08-14T01:00:00.000Z","updated_at":"2026-08-14T02:00:00.000Z"}"#.utf8
        )

        let item = try JSONDecoder().decode(MemoryItem.self, from: data)

        XCTAssertEqual(item.memory_id, "memory_contract")
        XCTAssertEqual(item.source_type, .trustedSystem)
        XCTAssertEqual(item.value, .object(["name": .string("tea"), "count": .number(2)]))

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
                as? [String: Any]
        )
        XCTAssertEqual(encoded["memory_id"] as? String, "memory_contract")
        XCTAssertNotNil(encoded["value"])
        XCTAssertEqual(encoded["source_type"] as? String, "trusted_system")
        XCTAssertNil(encoded["id"])
        XCTAssertNil(encoded["value_json"])
        XCTAssertNil(encoded["request_hash"])
        XCTAssertNil(encoded["idempotency_key"])
        XCTAssertNil(encoded["deleted_at"])
    }

    func testMemoryInputAlwaysEncodesExplicitUserSource() throws {
        let input = MemoryInput(
            kind: .fact,
            subject: "user",
            predicate: "timezone",
            value: .string("Asia/Hong_Kong"),
            display_text: "Timezone is Hong Kong",
            locale: "en-HK",
            user_confirmed: true,
            confidence: 1,
            idempotency_key: "idem_input_contract"
        )

        XCTAssertEqual(input.source_type, .explicitUser)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
                as? [String: Any]
        )
        XCTAssertEqual(encoded["source_type"] as? String, "explicit_user")
        XCTAssertEqual(encoded["idempotency_key"] as? String, "idem_input_contract")
        XCTAssertNotNil(encoded["value"])
        XCTAssertNil(encoded["value_json"])
        XCTAssertNil(encoded["request_hash"])
    }

    func testMemoryPageRequiresMemoriesAndCanonicalMemoryID() throws {
        let canonical = try StructuredMemoryTestSupport.pageData(
            memories: [StructuredMemoryTestSupport.memory("memory_page")],
            nextCursor: nil,
            hasMore: false
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MemoryPage.self, from: canonical).memories.map(\.memory_id),
            ["memory_page"]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MemoryPage.self,
                from: Data(#"{"items":[],"next_cursor":null,"has_more":false}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MemoryItem.self,
                from: Data(
                    #"{"id":"legacy_id","schema_version":1,"kind":"fact","subject":"user","predicate":"p","value":"v","display_text":"v","locale":"en-HK","source_type":"explicit_user","source_session_id":null,"source_message_id":null,"user_confirmed":true,"confidence":1,"version":1,"retention_expires_at":null,"created_at":"2026-08-14T00:00:00Z","updated_at":"2026-08-14T00:00:00Z"}"#.utf8
                )
            )
        )
    }
}

final class StructuredMemorySQLiteTests: XCTestCase {
    func testStructuredMemoryMigrationHasNoEmbeddingAudioOrRequestHashColumns() throws {
        let url = temporarySQLiteURL("migration")
        defer { removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        XCTAssertTrue(store.isAvailable)

        let columns = try tableColumns(named: "cached_memories", at: url)
        XCTAssertTrue(columns.contains("memory_id"))
        XCTAssertTrue(columns.contains("api_origin"))
        XCTAssertTrue(columns.contains("value_json"))
        XCTAssertFalse(columns.contains("idempotency_key"))
        XCTAssertFalse(columns.contains("request_hash"))
        XCTAssertFalse(columns.contains("deleted_at"))
        XCTAssertFalse(columns.contains(where: { $0.contains("embedding") }))
        XCTAssertFalse(columns.contains(where: { $0.contains("audio") }))
        XCTAssertFalse(columns.contains(where: { $0.contains("token") }))
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE migration_id = 'ios_g1_004_structured_memory_cache'",
                at: url
            ),
            1
        )
    }

    func testCacheIsOriginAndUserScopedAndSupportsAtomicReplace() {
        let url = temporarySQLiteURL("cache")
        defer { removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let devUserA = StructuredMemoryTestSupport.scope(
            "https://name:origin-secret@DEV.example.test/path?access_token=must-not-persist",
            userID: "user_a"
        )
        let stagingUserA = StructuredMemoryTestSupport.scope(
            "https://staging.example.test/api",
            userID: "user_a"
        )
        let devUserB = StructuredMemoryTestSupport.scope(
            "https://dev.example.test/other-path",
            userID: "user_b"
        )
        XCTAssertEqual(devUserA.apiOrigin, "https://dev.example.test:443")
        XCTAssertFalse(devUserA.apiOrigin.contains("origin-secret"))
        XCTAssertFalse(devUserA.apiOrigin.contains("access_token"))

        let original = StructuredMemoryTestSupport.memory(
            "memory_shared",
            displayText: "dev user A",
            createdAt: "2026-08-14T01:00:00.000Z"
        )
        let otherOrigin = StructuredMemoryTestSupport.memory(
            "memory_shared",
            displayText: "staging user A",
            createdAt: "2026-08-14T01:00:00.000Z"
        )
        let otherUser = StructuredMemoryTestSupport.memory(
            "memory_shared",
            displayText: "dev user B",
            createdAt: "2026-08-14T01:00:00.000Z"
        )

        XCTAssertTrue(store.upsertMemory(original, in: devUserA))
        XCTAssertTrue(store.upsertMemory(otherOrigin, in: stagingUserA))
        XCTAssertTrue(store.upsertMemory(otherUser, in: devUserB))
        XCTAssertEqual(store.loadMemories(in: devUserA).first?.display_text, "dev user A")
        XCTAssertEqual(store.loadMemories(in: stagingUserA).first?.display_text, "staging user A")
        XCTAssertEqual(store.loadMemories(in: devUserB).first?.display_text, "dev user B")

        let updated = StructuredMemoryTestSupport.memory(
            "memory_shared",
            displayText: "updated",
            version: 2,
            createdAt: "2026-08-14T01:00:00.000Z"
        )
        XCTAssertTrue(store.upsertMemories([updated], in: devUserA))
        XCTAssertEqual(store.loadMemories(in: devUserA).first?.display_text, "updated")

        let authoritative = StructuredMemoryTestSupport.memory(
            "memory_authoritative",
            displayText: "authoritative",
            createdAt: "2026-08-14T02:00:00.000Z"
        )
        XCTAssertTrue(store.replaceMemories([authoritative], in: devUserA))
        XCTAssertEqual(store.loadMemories(in: devUserA).map(\.memory_id), ["memory_authoritative"])
        XCTAssertEqual(store.loadMemories(in: stagingUserA).first?.display_text, "staging user A")
        XCTAssertEqual(store.loadMemories(in: devUserB).first?.display_text, "dev user B")

        let oversized = StructuredMemoryTestSupport.memory(
            "memory_oversized",
            value: .string(String(repeating: "x", count: 8_193))
        )
        XCTAssertFalse(store.replaceMemories([oversized], in: devUserA))
        XCTAssertEqual(store.loadMemories(in: devUserA).map(\.memory_id), ["memory_authoritative"])

        XCTAssertTrue(store.removeMemory("memory_authoritative", in: devUserA))
        XCTAssertTrue(store.loadMemories(in: devUserA).isEmpty)
        XCTAssertEqual(store.loadMemories(in: stagingUserA).first?.display_text, "staging user A")
        XCTAssertEqual(store.loadMemories(in: devUserB).first?.display_text, "dev user B")
    }

    func testOfflineLoadFailsClosedForExpiredOrInvalidRetention() throws {
        let url = temporarySQLiteURL("retention")
        defer { removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let scope = StructuredMemoryTestSupport.scope(
            "https://retention.example.test",
            userID: "user_retention"
        )
        let now = try XCTUnwrap(
            formatter.date(from: "2026-08-14T12:00:00.000Z")
        )
        let items = [
            StructuredMemoryTestSupport.memory(
                "memory_expired",
                retentionExpiresAt: "2026-08-14T11:59:59.000Z"
            ),
            StructuredMemoryTestSupport.memory(
                "memory_invalid_retention",
                retentionExpiresAt: "not-rfc3339"
            ),
            StructuredMemoryTestSupport.memory(
                "memory_future",
                retentionExpiresAt: "2026-08-15T12:00:00.000Z"
            ),
            StructuredMemoryTestSupport.memory("memory_unbounded"),
        ]
        XCTAssertTrue(store.upsertMemories(items, in: scope))

        XCTAssertEqual(
            Set(store.loadMemories(in: scope, now: now).map(\.memory_id)),
            Set(["memory_future", "memory_unbounded"])
        )
    }

    private func temporarySQLiteURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-memory-\(label)-\(UUID().uuidString).sqlite")
    }

    private func removeSQLiteArtifacts(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func tableColumns(named table: String, at url: URL) throws -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw StructuredMemoryTestError.sqlite
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
            == SQLITE_OK,
            let statement
        else { throw StructuredMemoryTestError.sqlite }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: value))
            }
        }
        return columns
    }

    private func scalarInt(_ sql: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw StructuredMemoryTestError.sqlite
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_step(statement) == SQLITE_ROW
        else { throw StructuredMemoryTestError.sqlite }
        defer { sqlite3_finalize(statement) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

final class StructuredMemoryAPIClientTests: XCTestCase {
    private var session: URLSession!
    private var client: APIClient!
    private var previousBaseURL: String?

    override func setUp() {
        super.setUp()
        previousBaseURL = UserDefaults.standard.string(forKey: "vab.apiBase")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StructuredMemoryURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = APIClient(session: session)
        client.baseURL = URL(string: "https://memory.example.test")
        client.token = "memory-test-token"
    }

    override func tearDown() {
        StructuredMemoryURLProtocol.handler = nil
        session.invalidateAndCancel()
        if let previousBaseURL {
            UserDefaults.standard.set(previousBaseURL, forKey: "vab.apiBase")
        } else {
            UserDefaults.standard.removeObject(forKey: "vab.apiBase")
        }
        client = nil
        session = nil
        super.tearDown()
    }

    func testListMemoriesConsumesEveryCursorPageBeforeReturningSnapshot() async throws {
        StructuredMemoryURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-test-token")
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let before = components.queryItems?.first(where: { $0.name == "before" })?.value
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "limit" })?.value,
                "2"
            )
            if before == nil {
                return try StructuredMemoryTestSupport.httpResponse(
                    for: request,
                    data: StructuredMemoryTestSupport.pageData(
                        memories: [StructuredMemoryTestSupport.memory("memory_page_1")],
                        nextCursor: "cursor-1",
                        hasMore: true
                    )
                )
            }
            XCTAssertEqual(before, "cursor-1")
            return try StructuredMemoryTestSupport.httpResponse(
                for: request,
                data: StructuredMemoryTestSupport.pageData(
                    memories: [StructuredMemoryTestSupport.memory("memory_page_2")],
                    nextCursor: nil,
                    hasMore: false
                )
            )
        }

        let snapshot = try await client.listMemories(limit: 2)

        XCTAssertEqual(snapshot.map(\.memory_id), ["memory_page_1", "memory_page_2"])
    }

    func testListMemoriesRejectsMissingStalledAndOverlongPagination() async throws {
        StructuredMemoryURLProtocol.handler = { request in
            try StructuredMemoryTestSupport.httpResponse(
                for: request,
                data: StructuredMemoryTestSupport.pageData(
                    memories: [StructuredMemoryTestSupport.memory("memory_missing_cursor")],
                    nextCursor: nil,
                    hasMore: true
                )
            )
        }
        do {
            _ = try await client.listMemories()
            XCTFail("Expected a missing-cursor failure")
        } catch let error as MemorySnapshotPaginationError {
            XCTAssertEqual(error, .missingNextCursor(page: 1))
        }

        StructuredMemoryURLProtocol.handler = { request in
            let before = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "before" })?.value
            let id = before == nil ? "memory_stall_1" : "memory_stall_2"
            return try StructuredMemoryTestSupport.httpResponse(
                for: request,
                data: StructuredMemoryTestSupport.pageData(
                    memories: [StructuredMemoryTestSupport.memory(id)],
                    nextCursor: "cursor-stalled",
                    hasMore: true
                )
            )
        }
        do {
            _ = try await client.listMemories()
            XCTFail("Expected a stalled-cursor failure")
        } catch let error as MemorySnapshotPaginationError {
            XCTAssertEqual(error, .cursorDidNotAdvance("cursor-stalled"))
        }

        StructuredMemoryURLProtocol.handler = { request in
            try StructuredMemoryTestSupport.httpResponse(
                for: request,
                data: StructuredMemoryTestSupport.pageData(
                    memories: [StructuredMemoryTestSupport.memory("memory_max")],
                    nextCursor: "cursor-next",
                    hasMore: true
                )
            )
        }
        do {
            _ = try await client.listMemories(maximumPages: 1)
            XCTFail("Expected the maximum-page guard")
        } catch let error as MemorySnapshotPaginationError {
            XCTAssertEqual(error, .maximumPagesExceeded(1))
        }
    }

    func testLaterPageFailureDoesNotReturnPartialSnapshot() async throws {
        StructuredMemoryURLProtocol.handler = { request in
            let before = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "before" })?.value
            if before == nil {
                return try StructuredMemoryTestSupport.httpResponse(
                    for: request,
                    data: StructuredMemoryTestSupport.pageData(
                        memories: [StructuredMemoryTestSupport.memory("memory_partial")],
                        nextCursor: "cursor-failing-page",
                        hasMore: true
                    )
                )
            }
            return try StructuredMemoryTestSupport.httpResponse(
                for: request,
                status: 503,
                data: Data(
                    #"{"error":{"code":"unavailable","message":"second page failed","retryable":true}}"#.utf8
                )
            )
        }

        do {
            _ = try await client.listMemories()
            XCTFail("A failed later page must not return a partial snapshot")
        } catch let APIClientError.badStatus(status, _, _) {
            XCTAssertEqual(status, 503)
        }
    }

    func testCreateGetDeleteReuseAuthAndCanonicalIdempotentPayload() async throws {
        let item = StructuredMemoryTestSupport.memory("memory_crud")
        StructuredMemoryURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-test-token")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/phone/memories"):
                let body = try StructuredMemoryTestSupport.requestBody(request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["source_type"] as? String, "explicit_user")
                XCTAssertEqual(object["idempotency_key"] as? String, "idem_crud_request")
                XCTAssertNotNil(object["value"])
                XCTAssertNil(object["value_json"])
                XCTAssertNil(object["request_hash"])
                return try StructuredMemoryTestSupport.httpResponse(
                    for: request,
                    status: 201,
                    data: JSONEncoder().encode(item)
                )
            case ("GET", "/v1/phone/memories/memory_crud"):
                return try StructuredMemoryTestSupport.httpResponse(
                    for: request,
                    data: JSONEncoder().encode(item)
                )
            case ("DELETE", "/v1/phone/memories/memory_crud"):
                return try StructuredMemoryTestSupport.httpResponse(
                    for: request,
                    data: Data(
                        #"{"ok":true,"memory_id":"memory_crud","deleted_at":"2026-08-14T03:00:00.000Z"}"#.utf8
                    )
                )
            default:
                XCTFail("Unexpected memory request: \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
                throw StructuredMemoryTestError.unexpectedRequest
            }
        }
        let input = MemoryInput(
            kind: .fact,
            subject: "user",
            predicate: "timezone",
            value: .string("Asia/Hong_Kong"),
            display_text: "Timezone is Hong Kong",
            locale: "en-HK",
            idempotency_key: "idem_crud_request"
        )

        let created = try await client.createMemory(input)
        let fetched = try await client.getMemory(memoryID: "memory_crud")
        XCTAssertEqual(created.memory_id, "memory_crud")
        XCTAssertEqual(fetched, item)
        let deleted = try await client.deleteMemory(memoryID: "memory_crud")
        XCTAssertTrue(deleted.ok)
        XCTAssertEqual(deleted.memory_id, "memory_crud")
    }
}

@MainActor
final class AppStoreStructuredMemoryTests: XCTestCase {
    func testColdStartRestoresUserScopedOfflineSnapshot() {
        let apiBase = URL(string: "https://offline.example.test")!
        withMemoryContext(userID: "user_offline", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("offline")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_offline"),
                in: StructuredMemoryTestSupport.scope(
                    apiBase.absoluteString,
                    userID: "user_offline"
                )
            ))

            let appStore = makeAppStore(localStore: localStore) { [] }

            XCTAssertEqual(appStore.memories.map(\.memory_id), ["memory_offline"])
        }
    }

    func testCompleteAuthoritativeSnapshotAtomicallyReplacesOfflineCache() async {
        let apiBase = URL(string: "https://authoritative.example.test")!
        await withMemoryContext(userID: "user_authoritative", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("authoritative")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let scope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_authoritative"
            )
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_old"),
                in: scope
            ))
            let authoritative = StructuredMemoryTestSupport.memory("memory_new")
            let appStore = makeAppStore(localStore: localStore) { [authoritative] }
            appStore.token = "memory-authoritative-token"
            defer { appStore.token = nil }

            let replaced = try? await appStore.refreshMemorySnapshot()

            XCTAssertEqual(replaced, true)
            XCTAssertEqual(appStore.memories.map(\.memory_id), ["memory_new"])
            XCTAssertEqual(
                localStore.loadMemories(in: scope).map(\.memory_id),
                ["memory_new"]
            )
        }
    }

    func testMemoryShadowReceivesOnlyDisplayTextAndDoesNotChangeSnapshotOrCommands() async {
        let apiBase = URL(string: "https://shadow.example.test")!
        await withMemoryContext(userID: "user_shadow", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("shadow")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let recorder = RecordingMemoryShadowEvaluator()
            let secretValue = JSONValue.object(["password": .string("must-not-reach-shadow")])
            let snapshot = StructuredMemoryTestSupport.memory(
                "memory_shadow",
                displayText: "Prefers tea",
                value: secretValue
            )
            let appStore = makeAppStore(
                localStore: localStore,
                memoryShadow: recorder
            ) { [snapshot] }
            appStore.token = "memory-shadow-token"
            defer { appStore.token = nil }

            let replaced = try? await appStore.refreshMemorySnapshot()

            XCTAssertEqual(replaced, true)
            XCTAssertEqual(appStore.memories, [snapshot])
            XCTAssertEqual(appStore.pendingCommandConfirmation, nil)
            XCTAssertEqual(appStore.latestCommandResponse, nil)
            XCTAssertEqual(recorder.inputs, [
                [MemoryShadowInput(memoryID: "memory_shadow", displayText: "Prefers tea")]
            ])
            XCTAssertEqual(
                Mirror(reflecting: recorder.inputs[0][0]).children.map(\.label),
                ["memoryID", "displayText"]
            )
        }
    }

    func testFailedMemorySnapshotDoesNotInvokeShadow() async {
        let apiBase = URL(string: "https://shadow-failure.example.test")!
        await withMemoryContext(userID: "user_shadow_fail", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("shadow-fail")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let recorder = RecordingMemoryShadowEvaluator()
            let appStore = makeAppStore(
                localStore: localStore,
                memoryShadow: recorder
            ) {
                throw StructuredMemoryTestError.pageFailed
            }
            appStore.token = "memory-shadow-fail-token"
            defer { appStore.token = nil }

            do {
                _ = try await appStore.refreshMemorySnapshot()
                XCTFail("Snapshot loader failure must propagate")
            } catch StructuredMemoryTestError.pageFailed {
                XCTAssertTrue(recorder.inputs.isEmpty)
                XCTAssertEqual(appStore.latestCommandResponse, nil)
            } catch {
                XCTFail("Unexpected snapshot error: \(error)")
            }
        }
    }

    func testSnapshotLoaderFailureThrowsAndPreservesBothSnapshots() async {
        let apiBase = URL(string: "https://loader-failure.example.test")!
        await withMemoryContext(userID: "user_failed_page", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("failed-page")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let scope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_failed_page"
            )
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_preserved"),
                in: scope
            ))
            let appStore = makeAppStore(localStore: localStore) {
                throw StructuredMemoryTestError.pageFailed
            }
            appStore.token = "memory-failure-token"
            defer { appStore.token = nil }

            do {
                _ = try await appStore.refreshMemorySnapshot()
                XCTFail("Snapshot loader failure must propagate")
            } catch StructuredMemoryTestError.pageFailed {
                // Expected: reconciliation sees this failure before cursor commit.
            } catch {
                XCTFail("Unexpected snapshot error: \(error)")
            }

            XCTAssertEqual(appStore.memories.map(\.memory_id), ["memory_preserved"])
            XCTAssertEqual(
                localStore.loadMemories(in: scope).map(\.memory_id),
                ["memory_preserved"]
            )
        }
    }

    func testMemoryPhoneChangeTombstoneRemovesOnlyActiveUsersCacheRow() throws {
        let apiBase = URL(string: "https://tombstone.example.test")!
        try withMemoryContext(userID: "user_tombstone", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("tombstone")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let memory = StructuredMemoryTestSupport.memory("memory_deleted")
            let activeScope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_tombstone"
            )
            let otherScope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_other"
            )
            XCTAssertTrue(localStore.upsertMemory(memory, in: activeScope))
            XCTAssertTrue(localStore.upsertMemory(memory, in: otherScope))
            let appStore = makeAppStore(localStore: localStore) { [] }
            let change = try JSONDecoder().decode(
                PhoneChange.self,
                from: Data(
                    #"{"cursor":"42","entity_type":"memory","entity_id":"memory_deleted","session_id":null,"version":2,"deleted_at":"2026-08-14T04:00:00.000Z"}"#.utf8
                )
            )

            XCTAssertTrue(appStore.removeLocalMemory(change.entity_id))

            XCTAssertTrue(appStore.memories.isEmpty)
            XCTAssertTrue(localStore.loadMemories(in: activeScope).isEmpty)
            XCTAssertEqual(
                localStore.loadMemories(in: otherScope).map(\.memory_id),
                ["memory_deleted"]
            )
        }
    }

    func testSavingServerURLSwitchesSameUserToThatOriginsOfflineSnapshot() {
        let dev = URL(string: "https://dev-memory.example.test/path")!
        let staging = URL(string: "https://staging-memory.example.test/other")!
        withMemoryContext(userID: "user_origin_canary", apiBaseURL: dev) {
            let url = temporarySQLiteURL("origin-canary")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let devScope = StructuredMemoryTestSupport.scope(
                dev.absoluteString,
                userID: "user_origin_canary"
            )
            let stagingScope = StructuredMemoryTestSupport.scope(
                staging.absoluteString,
                userID: "user_origin_canary"
            )
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_same", displayText: "dev snapshot"),
                in: devScope
            ))
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_same", displayText: "staging snapshot"),
                in: stagingScope
            ))
            let appStore = makeAppStore(localStore: localStore) { [] }
            XCTAssertEqual(appStore.memories.first?.display_text, "dev snapshot")

            appStore.apiBase = staging.absoluteString
            XCTAssertTrue(appStore.applyApiBase())

            XCTAssertEqual(appStore.memories.first?.display_text, "staging snapshot")
            XCTAssertFalse(appStore.memories.contains { $0.display_text == "dev snapshot" })
        }
    }

    func testAccountSwitchLoadsOnlyNewUsersCurrentOriginSnapshot() throws {
        let apiBase = URL(string: "https://account-memory.example.test")!
        try withMemoryContext(userID: "user_a", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("account-canary")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let userAScope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_a"
            )
            let userBScope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_b"
            )
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_same", displayText: "user A snapshot"),
                in: userAScope
            ))
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_same", displayText: "user B snapshot"),
                in: userBScope
            ))
            let appStore = makeAppStore(localStore: localStore) { [] }
            XCTAssertEqual(appStore.memories.first?.display_text, "user A snapshot")
            let auth = try JSONDecoder().decode(
                AuthResponse.self,
                from: Data(
                    #"{"access_token":"account-switch-token","user":{"id":"user_b","email":"b@example.test"}}"#.utf8
                )
            )

            try appStore.applyAuth(auth)
            defer { appStore.token = nil }

            XCTAssertEqual(appStore.memories.first?.display_text, "user B snapshot")
            XCTAssertFalse(appStore.memories.contains { $0.display_text == "user A snapshot" })
        }
    }

    func testMemoryPageFailurePreservesOldSnapshotAndAppliedCursor() async {
        let apiBase = URL(string: "https://cursor-page.example.test")!
        await withMemoryContext(userID: "user_cursor_page", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("cursor-page")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let scope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_cursor_page"
            )
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_old_snapshot"),
                in: scope
            ))
            localStore.saveAppliedCursor("cursor-old")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StructuredMemoryReconciliationURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer {
                StructuredMemoryReconciliationURLProtocol.handler = nil
                session.invalidateAndCancel()
            }
            StructuredMemoryReconciliationURLProtocol.handler = { request in
                switch request.url?.path {
                case "/v1/phone/sync":
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        data: Data(#"{"cursor":"cursor-new","changes":[],"has_more":false}"#.utf8)
                    )
                case "/v1/phone/sessions":
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        data: Data(#"{"sessions":[],"has_more":false}"#.utf8)
                    )
                case "/v1/dev/pushes":
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        data: Data(#"{"pushes":[]}"#.utf8)
                    )
                case "/v1/phone/memories":
                    let before = URLComponents(
                        url: try XCTUnwrap(request.url),
                        resolvingAgainstBaseURL: false
                    )?.queryItems?.first(where: { $0.name == "before" })?.value
                    if before == nil {
                        return try StructuredMemoryTestSupport.httpResponse(
                            for: request,
                            data: StructuredMemoryTestSupport.pageData(
                                memories: [StructuredMemoryTestSupport.memory("memory_partial")],
                                nextCursor: "memory-page-2",
                                hasMore: true
                            )
                        )
                    }
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        status: 503,
                        data: Data(
                            #"{"error":{"code":"unavailable","message":"memory page failed","retryable":true}}"#.utf8
                        )
                    )
                default:
                    throw StructuredMemoryTestError.unexpectedRequest
                }
            }
            let client = APIClient(session: session)
            client.baseURL = apiBase
            let appStore = makeAppStore(
                localStore: localStore,
                client: client,
                loader: { try await client.listMemories() }
            )
            appStore.token = "cursor-page-token"
            defer { appStore.token = nil }

            await appStore.refresh(includeAgents: false)

            XCTAssertEqual(appStore.memories.map(\.memory_id), ["memory_old_snapshot"])
            XCTAssertEqual(localStore.loadMemories(in: scope).map(\.memory_id), ["memory_old_snapshot"])
            XCTAssertEqual(localStore.loadAppliedCursor(), "cursor-old")
        }
    }

    func testMemorySQLiteReplaceFailurePreservesOldSnapshotAndAppliedCursor() async {
        let apiBase = URL(string: "https://cursor-sqlite.example.test")!
        await withMemoryContext(userID: "user_cursor_sqlite", apiBaseURL: apiBase) {
            let url = temporarySQLiteURL("cursor-sqlite")
            defer { removeSQLiteArtifacts(at: url) }
            let localStore = SQLiteStore(databaseURL: url)
            let scope = StructuredMemoryTestSupport.scope(
                apiBase.absoluteString,
                userID: "user_cursor_sqlite"
            )
            XCTAssertTrue(localStore.upsertMemory(
                StructuredMemoryTestSupport.memory("memory_old_sqlite"),
                in: scope
            ))
            localStore.saveAppliedCursor("cursor-old")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StructuredMemoryReconciliationURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer {
                StructuredMemoryReconciliationURLProtocol.handler = nil
                session.invalidateAndCancel()
            }
            StructuredMemoryReconciliationURLProtocol.handler = { request in
                switch request.url?.path {
                case "/v1/phone/sync":
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        data: Data(#"{"cursor":"cursor-new","changes":[],"has_more":false}"#.utf8)
                    )
                case "/v1/phone/sessions":
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        data: Data(#"{"sessions":[],"has_more":false}"#.utf8)
                    )
                case "/v1/dev/pushes":
                    return try StructuredMemoryTestSupport.httpResponse(
                        for: request,
                        data: Data(#"{"pushes":[]}"#.utf8)
                    )
                default:
                    throw StructuredMemoryTestError.unexpectedRequest
                }
            }
            let client = APIClient(session: session)
            client.baseURL = apiBase
            let oversized = StructuredMemoryTestSupport.memory(
                "memory_oversized_replace",
                value: .string(String(repeating: "x", count: 8_193))
            )
            let appStore = makeAppStore(
                localStore: localStore,
                client: client,
                loader: { [oversized] in [oversized] }
            )
            appStore.token = "cursor-sqlite-token"
            defer { appStore.token = nil }

            await appStore.refresh(includeAgents: false)

            XCTAssertEqual(appStore.memories.map(\.memory_id), ["memory_old_sqlite"])
            XCTAssertEqual(localStore.loadMemories(in: scope).map(\.memory_id), ["memory_old_sqlite"])
            XCTAssertEqual(localStore.loadAppliedCursor(), "cursor-old")
        }
    }

    private func makeAppStore(
        localStore: SQLiteStore,
        client: APIClient = APIClient(),
        memoryShadow: MemoryShadowEvaluating = NoOpMemoryShadowEvaluator(),
        loader: @escaping AppStore.MemorySnapshotLoader
    ) -> AppStore {
        AppStore(
            localStore: localStore,
            commandSynthesizer: StructuredMemorySilentSynthesizer(),
            backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher(),
            client: client,
            memorySnapshotLoader: loader,
            memoryShadow: memoryShadow
        )
    }

    private func withMemoryContext(
        userID: String,
        apiBaseURL: URL,
        body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let previousUserID = defaults.string(forKey: "vab.userID")
        let previousBaseURL = defaults.string(forKey: "vab.apiBase")
        defaults.set(userID, forKey: "vab.userID")
        defaults.set(apiBaseURL.absoluteString, forKey: "vab.apiBase")
        defer {
            if let previousUserID {
                defaults.set(previousUserID, forKey: "vab.userID")
            } else {
                defaults.removeObject(forKey: "vab.userID")
            }
            if let previousBaseURL {
                defaults.set(previousBaseURL, forKey: "vab.apiBase")
            } else {
                defaults.removeObject(forKey: "vab.apiBase")
            }
        }
        try body()
    }

    private func withMemoryContext(
        userID: String,
        apiBaseURL: URL,
        body: () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let previousUserID = defaults.string(forKey: "vab.userID")
        let previousBaseURL = defaults.string(forKey: "vab.apiBase")
        defaults.set(userID, forKey: "vab.userID")
        defaults.set(apiBaseURL.absoluteString, forKey: "vab.apiBase")
        defer {
            if let previousUserID {
                defaults.set(previousUserID, forKey: "vab.userID")
            } else {
                defaults.removeObject(forKey: "vab.userID")
            }
            if let previousBaseURL {
                defaults.set(previousBaseURL, forKey: "vab.apiBase")
            } else {
                defaults.removeObject(forKey: "vab.apiBase")
            }
        }
        try await body()
    }

    private func temporarySQLiteURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-app-memory-\(label)-\(UUID().uuidString).sqlite")
    }

    private func removeSQLiteArtifacts(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

}

private final class StructuredMemorySilentSynthesizer: VoiceSynthesizing {
    func speak(
        _ text: String,
        completion: @escaping (VoiceSynthesisResult) -> Void
    ) {
        completion(.finished)
    }

    func stop() {}
}

private final class StructuredMemoryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StructuredMemoryReconciliationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class RecordingMemoryShadowEvaluator: MemoryShadowEvaluating, @unchecked Sendable {
    private(set) var inputs: [[MemoryShadowInput]] = []

    func evaluate(memories: [MemoryShadowInput]) {
        inputs.append(memories)
    }
}

private enum StructuredMemoryTestError: Error {
    case sqlite
    case unexpectedRequest
    case pageFailed
}

private enum StructuredMemoryTestSupport {
    private struct MemoryPageWire: Encodable {
        let memories: [MemoryItem]
        let next_cursor: String?
        let has_more: Bool
    }

    static func memory(
        _ memoryID: String,
        displayText: String = "Synthetic memory",
        value: JSONValue = .object(["synthetic": .bool(true)]),
        sourceType: MemorySourceType = .explicitUser,
        version: Int = 1,
        retentionExpiresAt: String? = nil,
        createdAt: String = "2026-08-14T00:00:00.000Z"
    ) -> MemoryItem {
        MemoryItem(
            memory_id: memoryID,
            kind: .fact,
            subject: "synthetic-user",
            predicate: "synthetic-predicate",
            value: value,
            display_text: displayText,
            locale: "en-HK",
            source_type: sourceType,
            user_confirmed: true,
            confidence: 1,
            version: version,
            retention_expires_at: retentionExpiresAt,
            created_at: createdAt,
            updated_at: "2026-08-14T00:00:00.000Z"
        )
    }

    static func scope(_ apiBase: String, userID: String) -> MemoryCacheScope {
        guard let scope = MemoryCacheScope(
            apiBaseURL: URL(string: apiBase),
            userID: userID
        ) else {
            preconditionFailure("Invalid synthetic Memory cache scope")
        }
        return scope
    }

    static func pageData(
        memories: [MemoryItem],
        nextCursor: String?,
        hasMore: Bool
    ) throws -> Data {
        try JSONEncoder().encode(
            MemoryPageWire(
                memories: memories,
                next_cursor: nextCursor,
                has_more: hasMore
            )
        )
    }

    static func httpResponse(
        for request: URLRequest,
        status: Int = 200,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://memory.example.test")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, data)
    }

    static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw StructuredMemoryTestError.unexpectedRequest
        }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? StructuredMemoryTestError.unexpectedRequest }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

import AgentVoice
import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class AgentVoiceSessionHistoryTests: XCTestCase {
    func testHostBrandMapping() {
        XCTAssertEqual(AgentVoiceHostBrand.brand(forHostName: "codex").displayName, "Codex")
        XCTAssertEqual(AgentVoiceHostBrand.brand(forHostName: "codex").vendorName, "OpenAI")
        XCTAssertEqual(AgentVoiceHostBrand.brand(forHostName: "Codex").host, .codex)

        let claude = AgentVoiceHostBrand.brand(forHostName: "claude")
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(claude.vendorName, "Anthropic")
        XCTAssertEqual(AgentVoiceHostBrand.brand(forHostName: "Claude Code").host, .claudeCode)

        let muse = AgentVoiceHostBrand.brand(forHostName: "muse")
        XCTAssertEqual(muse.displayName, "Muse Code")
        XCTAssertEqual(muse.vendorName, "Meta")

        let openCode = AgentVoiceHostBrand.brand(forHostName: "opencode")
        XCTAssertEqual(openCode.displayName, "OpenCode")
        XCTAssertEqual(openCode.systemImage, "terminal")

        let pi = AgentVoiceHostBrand.brand(forHostName: "pi")
        XCTAssertEqual(pi.displayName, "Pi")
        XCTAssertEqual(pi.systemImage, "terminal")

        let unknown = AgentVoiceHostBrand.brand(forHostName: "mystery-host")
        XCTAssertEqual(unknown.displayName, "mystery-host")
        XCTAssertEqual(unknown.systemImage, "app.dashed")

        XCTAssertEqual(AgentVoiceHostBrand.brand(forHostName: "").displayName, "Unknown host")
    }

    func testSessionsGroupByHostAndSession() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let sessionA = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-a")
        let sessionB = VoiceSession(installationID: UUID(), host: "claude", sessionID: "sess-b")
        let attachmentA = try await attach(store, session: sessionA, connection: connection)
        _ = try await prompt(store, session: sessionA, attachment: attachmentA, turn: "turn-1", text: "first prompt", connection: connection)
        _ = try await prompt(store, session: sessionA, attachment: attachmentA, turn: "turn-2", text: "second prompt", connection: connection)
        let attachmentB = try await attach(store, session: sessionB, connection: connection)
        _ = try await prompt(store, session: sessionB, attachment: attachmentB, turn: nil, text: "other host prompt", connection: connection)

        let sessions = AgentVoiceSessionGrouping.sessions(from: try await store.store.historyRecords(limit: 100))
        XCTAssertEqual(sessions.count, 2)

        let codex = try XCTUnwrap(sessions.first { $0.sessionID == "sess-a" })
        XCTAssertEqual(codex.brand.displayName, "Codex")
        XCTAssertEqual(codex.brand.vendorName, "OpenAI")
        XCTAssertEqual(codex.threads.count, 2)
        XCTAssertEqual(codex.interactionCount, 2)
        XCTAssertEqual(codex.shortID, "sess-a")

        let claude = try XCTUnwrap(sessions.first { $0.sessionID == "sess-b" })
        XCTAssertEqual(claude.brand.displayName, "Claude Code")
        XCTAssertEqual(claude.threads.count, 1)
    }

    func testThreadsGroupByNativeTurn() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-dup")
        let attachment = try await attach(store, session: session, connection: connection)
        _ = try await prompt(store, session: session, attachment: attachment, turn: "same-turn", text: "one", connection: connection)
        _ = try await prompt(store, session: session, attachment: attachment, turn: "same-turn", text: "two", connection: connection)

        let sessions = AgentVoiceSessionGrouping.sessions(from: try await store.store.historyRecords(limit: 100))
        let grouped = try XCTUnwrap(sessions.first)
        XCTAssertEqual(grouped.threads.count, 1)
        XCTAssertEqual(grouped.threads.first?.records.count, 2)
        XCTAssertEqual(grouped.threads.first?.nativeTurnID, "same-turn")
        XCTAssertEqual(grouped.threads.first?.promptSnippet, "one")
    }

    func testSessionStartAndLiveState() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "muse", sessionID: "sess-live")
        let attachment = try await attach(store, session: session, connection: connection)
        _ = try await prompt(store, session: session, attachment: attachment, turn: "t1", text: "hello", connection: connection)

        let records = try await store.store.historyRecords(limit: 100)
        var sessions = AgentVoiceSessionGrouping.sessions(from: records)
        let live = try XCTUnwrap(sessions.first)
        XCTAssertEqual(live.startDate, records.map(\.interaction.createdAt).min())
        XCTAssertTrue(live.lastActiveDate >= live.startDate)
        XCTAssertTrue(live.isLive)

        try await store.store.disconnect(connectionID: connection)
        sessions = AgentVoiceSessionGrouping.sessions(from: try await store.store.historyRecords(limit: 100))
        XCTAssertEqual(sessions.first?.isLive, false)
    }

    func testMatchesFiltersAcrossFields() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-filter")
        let attachment = try await attach(store, session: session, connection: connection)
        let input = try await prompt(store, session: session, attachment: attachment, turn: "t1", text: "filter me", connection: connection)
        _ = try await store.store.handle(
            .init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "spoken rendition words"),
            connectionID: connection
        )

        let history = try await store.store.historyRecords(limit: 100)
        let record = try XCTUnwrap(history.first)
        XCTAssertTrue(AgentVoiceSessionGrouping.matches(record, query: ""))
        XCTAssertTrue(AgentVoiceSessionGrouping.matches(record, query: "codex"))
        XCTAssertTrue(AgentVoiceSessionGrouping.matches(record, query: "sess-filter"))
        XCTAssertTrue(AgentVoiceSessionGrouping.matches(record, query: "filter me"))
        XCTAssertTrue(AgentVoiceSessionGrouping.matches(record, query: "rendition words"))
        XCTAssertFalse(AgentVoiceSessionGrouping.matches(record, query: "no such text"))
    }

    func testHistoryRecordSeparatesContentFromEvents() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-counts")
        let attachment = try await attach(store, session: session, connection: connection)
        let input = try await prompt(store, session: session, attachment: attachment, turn: "t1", text: "count me", connection: connection)
        _ = try await store.store.handle(
            .init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "spoken words"),
            connectionID: connection
        )
        let rends = try await store.store.renditions(inputID: input)
        let rendition = try XCTUnwrap(rends.first)
        _ = try await store.store.requestManualPlayback(renditionID: rendition.id)

        let history = try await store.store.historyRecords(limit: 100)
        let record = try XCTUnwrap(history.first)
        let thread = try XCTUnwrap(AgentVoiceSessionGrouping.sessions(from: history).first?.threads.first)
        XCTAssertEqual(record.renditions.count, 1)
        XCTAssertEqual(record.attempts.count, 1)
        XCTAssertEqual(thread.records.count, 1)
        XCTAssertFalse(record.events.isEmpty)
        XCTAssertGreaterThan(record.events.count, record.attempts.count)
    }

    func testSpeechHeadlineLifecycle() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-headline")
        let attachment = try await attach(store, session: session, connection: connection)
        let input = try await prompt(store, session: session, attachment: attachment, turn: "t1", text: "headline me", connection: connection)

        var historyRecs = try await store.store.historyRecords(limit: 100)
        var record = try XCTUnwrap(historyRecs.first)
        XCTAssertEqual(AgentVoiceSpeechStatus.headline(for: record), "No spoken response")

        _ = try await store.store.handle(
            .init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "ready words"),
            connectionID: connection
        )
        historyRecs = try await store.store.historyRecords(limit: 100)
        record = try XCTUnwrap(historyRecs.first)
        XCTAssertEqual(AgentVoiceSpeechStatus.headline(for: record), "Ready to play")

        let rends = try await store.store.renditions(inputID: input)
        let rendition = try XCTUnwrap(rends.first)
        _ = try await store.store.requestManualPlayback(renditionID: rendition.id)
        historyRecs = try await store.store.historyRecords(limit: 100)
        record = try XCTUnwrap(historyRecs.first)
        XCTAssertEqual(AgentVoiceSpeechStatus.headline(for: record), "Generating speech")

        _ = try await store.store.suppressInteraction(inputID: input)
        historyRecs = try await store.store.historyRecords(limit: 100)
        record = try XCTUnwrap(historyRecs.first)
        XCTAssertEqual(AgentVoiceSpeechStatus.headline(for: record), "Suppressed")
    }

    func testThreadHeadlineFallsBackToOlderRecord() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-fallback")
        let attachment = try await attach(store, session: session, connection: connection)
        let first = try await prompt(store, session: session, attachment: attachment, turn: "same-turn", text: "older prompt", connection: connection)
        _ = try await store.store.handle(
            .init(session: session, operation: .prepare, attachment: attachment, inputID: first, text: "older words"),
            connectionID: connection
        )
        _ = try await prompt(store, session: session, attachment: attachment, turn: "same-turn", text: "newer prompt", connection: connection)

        let history = try await store.store.historyRecords(limit: 100)
        let thread = try XCTUnwrap(AgentVoiceSessionGrouping.sessions(from: history).first?.threads.first)
        XCTAssertEqual(thread.records.count, 2)
        XCTAssertEqual(thread.records.flatMap(\.renditions).count, 1)
        XCTAssertEqual(thread.speechStatusHeadline, "Ready to play")
    }

    func testVoiceRetentionDefaultsToThirtyDays() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let interval = try await store.store.historyRetentionInterval()
        XCTAssertEqual(interval ?? 0, 30 * 24 * 60 * 60, accuracy: 0.001)
    }

    func testVoiceHistoryRetentionSettingDefaultsAndRoundTrips() {
        let suiteName = "test.voice.retention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.voiceHistoryRetention, .thirtyDays)
        settings.saveVoiceHistoryRetention(.sevenDays)
        XCTAssertEqual(settings.voiceHistoryRetention, .sevenDays)
        XCTAssertEqual(VoiceHistoryRetention.load(from: defaults), .sevenDays)
    }

    func testPruneCutoffHonorsSetting() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let now = Date()
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-retention")
        let oldAttachment = try await attach(store, session: session, connection: connection, now: old)
        let oldInput = try await prompt(store, session: session, attachment: oldAttachment, turn: "old-turn",
                                        text: "old prompt", connection: connection, now: old)
        let freshAttachment = try await attach(store, session: session, connection: connection, now: now)
        _ = try await prompt(store, session: session, attachment: freshAttachment, turn: "new-turn",
                             text: "new prompt", connection: connection, now: now)

        try await store.store.setHistoryRetentionInterval(7 * 24 * 60 * 60)
        let interval = try await store.store.historyRetentionInterval()
        XCTAssertEqual(interval ?? 0, 7 * 24 * 60 * 60, accuracy: 0.001)
        let expiring = try await store.store.countInteractionsExpiring(retention: 7 * 24 * 60 * 60, now: now)
        XCTAssertEqual(expiring, 1)
        _ = try await store.store.pruneHistory(now: now)
        let pruned = try await store.store.interaction(inputID: oldInput)
        XCTAssertNil(pruned)
        let remaining = try await store.store.historyRecords(limit: 100)
        XCTAssertEqual(remaining.count, 1)
    }

    func testOffStopsRetainingNewHistoryButKeepsExisting() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let now = Date()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-off")
        let firstAttachment = try await attach(store, session: session, connection: connection, now: now)
        let first = try await prompt(store, session: session, attachment: firstAttachment, turn: "kept-turn",
                                     text: "kept prompt", connection: connection, now: now)

        // Off stops new history from being retained, but the live pipeline
        // still accepts turns: speech must keep working while history is off.
        try await store.store.setHistoryRetentionInterval(nil)
        let interval = try await store.store.historyRetentionInterval()
        XCTAssertNil(interval)
        let expiring = try await store.store.countInteractionsExpiring(retention: nil, now: now)
        XCTAssertEqual(expiring, 0)
        let offAttachment = try await attach(store, session: session, connection: connection, now: now)
        let offInput = try await prompt(store, session: session, attachment: offAttachment, turn: "off-turn",
                                        text: "off prompt", connection: connection, now: now)

        try await store.store.disconnect(connectionID: connection)
        _ = try await store.store.pruneHistory(now: now)
        let kept = try await store.store.interaction(inputID: first)
        XCTAssertNotNil(kept)
        let dropped = try await store.store.interaction(inputID: offInput)
        XCTAssertNil(dropped)
    }

    func testTurningRetentionBackOnRestampsLiveRows() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let now = Date()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "sess-reon")
        try await store.store.setHistoryRetentionInterval(nil)
        let attachment = try await attach(store, session: session, connection: connection, now: now)
        let input = try await prompt(store, session: session, attachment: attachment, turn: "live-turn",
                                     text: "live prompt", connection: connection, now: now)

        try await store.store.setHistoryRetentionInterval(7 * 24 * 60 * 60)
        try await store.store.disconnect(connectionID: connection)
        _ = try await store.store.pruneHistory(now: now)
        let retained = try await store.store.interaction(inputID: input)
        XCTAssertNotNil(retained)
        _ = try await store.store.pruneHistory(now: now.addingTimeInterval(8 * 24 * 60 * 60))
        let expired = try await store.store.interaction(inputID: input)
        XCTAssertNil(expired)
    }

    func testConversationOrdersInputsAcrossTurnsAndUsesReadablePreviews() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "conversation-order")
        let now = Date()
        let attachment = try await attach(store, session: session, connection: connection, now: now)
        let first = try await prompt(store, session: session, attachment: attachment, turn: "first-turn",
                                     text: "  Plan\n the next step  ", connection: connection, now: now)
        let second = try await prompt(store, session: session, attachment: attachment, turn: "second-turn",
                                      text: "A separate turn", connection: connection, now: now.addingTimeInterval(1))
        let corrected = try await prompt(store, session: session, attachment: attachment, turn: "first-turn",
                                         text: "A corrected input", connection: connection, now: now.addingTimeInterval(2))
        var request = VoiceRequest(session: session, operation: .prepare, attachment: attachment,
                                   inputID: corrected, text: "The latest\n spoken reply")
        request.issuedAt = now.addingTimeInterval(3)
        _ = try await store.store.handle(request, connectionID: connection, now: request.issuedAt)

        let records = try await store.store.historyRecords(limit: 100)
        let conversation = try XCTUnwrap(AgentVoiceSessionGrouping.sessions(from: records).first)
        XCTAssertEqual(conversation.threads.count, 2)
        XCTAssertEqual(conversation.records.map(\.id), [first, second, corrected],
                       "Corrected inputs must follow time across native turn groups")
        XCTAssertEqual(conversation.title, "Plan the next step")
        XCTAssertEqual(conversation.preview, "The latest spoken reply")
    }

    func testSearchPreservesCompleteSessionAndDeletionScope() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "shared-session")
        let now = Date()
        let attachment = try await attach(store, session: session, connection: connection, now: now)
        let first = try await prompt(store, session: session, attachment: attachment, turn: "t1",
                                     text: "Earlier context", connection: connection, now: now)
        let match = try await prompt(store, session: session, attachment: attachment, turn: "t2",
                                     text: "Choose the needle", connection: connection, now: now.addingTimeInterval(1))
        let last = try await prompt(store, session: session, attachment: attachment, turn: "t3",
                                    text: "Later context", connection: connection, now: now.addingTimeInterval(2))
        // Host is part of session identity, even when native IDs coincide.
        let other = VoiceSession(installationID: UUID(), host: "claude", sessionID: session.sessionID)
        let otherAttachment = try await attach(store, session: other, connection: connection, now: now)
        let otherInput = try await prompt(store, session: other, attachment: otherAttachment, turn: "t1",
                                          text: "Unrelated conversation", connection: connection, now: now)
        let history = try await store.store.historyRecords(limit: 100)
        let all = AgentVoiceSessionGrouping.sessions(from: history)
        let matches = AgentVoiceSessionGrouping.sessions(from: history, matching: "  NEEDLE  ")
        let found = try XCTUnwrap(matches.first)
        let original = try XCTUnwrap(all.first { $0.host == "codex" })
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(found.records.map(\.id), [first, match, last])
        XCTAssertEqual(found.interactionCount, 3)
        XCTAssertEqual(found.startDate, original.startDate)
        XCTAssertEqual(found.lastActiveDate, original.lastActiveDate)
        XCTAssertEqual(found.title, original.title)
        XCTAssertEqual(found.preview, original.preview)
        XCTAssertTrue(AgentVoiceSessionGrouping.sessions(from: history, matching: "not present").isEmpty)
        XCTAssertEqual(AgentVoiceSessionGrouping.sessions(from: history, matching: "  ").count, 2)

        for id in found.records.map(\.id) { _ = try await store.store.deleteInteraction(inputID: id) }
        let remaining = try await store.store.historyRecords(limit: 100)
        XCTAssertEqual(remaining.map(\.id), [otherInput],
                       "Deleting a search result must remove the full session and preserve other hosts")
    }

    func testSearchFindsSpokenTextWithoutDroppingOtherExchanges() async throws {
        let store = try makeStore()
        defer { cleanup(store) }
        let connection = UUID()
        let session = VoiceSession(installationID: UUID(), host: "codex", sessionID: "spoken-search")
        let attachment = try await attach(store, session: session, connection: connection)
        let input = try await prompt(store, session: session, attachment: attachment, turn: "t1",
                                     text: "Explain the result", connection: connection)
        _ = try await store.store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                              inputID: input, text: "Silver compass"), connectionID: connection)
        let next = try await prompt(store, session: session, attachment: attachment, turn: "t2",
                                    text: "Continue", connection: connection)
        let history = try await store.store.historyRecords(limit: 100)
        let matches = AgentVoiceSessionGrouping.sessions(from: history, matching: "compass")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.records.map(\.id), [input, next])
    }

    // MARK: - Fixtures

    private final class StoreFixture {
        let root: URL
        let store: VoiceStore
        init(root: URL, store: VoiceStore) { self.root = root; self.store = store }
    }

    private func makeStore() throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try VoiceStore(url: root.appendingPathComponent("AgentVoice/voice.sqlite"))
        return StoreFixture(root: root, store: store)
    }

    private func cleanup(_ fixture: StoreFixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @discardableResult
    private func attach(_ fixture: StoreFixture, session: VoiceSession, connection: UUID, now: Date = Date()) async throws -> VoiceAttachment {
        var request = VoiceRequest(session: session, operation: .attach)
        request.issuedAt = now
        let reply = try await fixture.store.handle(request, connectionID: connection, now: now)
        return try XCTUnwrap(reply.attachment)
    }

    @discardableResult
    private func prompt(_ fixture: StoreFixture, session: VoiceSession, attachment: VoiceAttachment, turn: String?, text: String, connection: UUID, now: Date = Date()) async throws -> UUID {
        var request = VoiceRequest(session: session, operation: .prompt, attachment: attachment, nativeTurnID: turn, promptText: text)
        request.issuedAt = now
        let reply = try await fixture.store.handle(request, connectionID: connection, now: now)
        return try XCTUnwrap(reply.inputID)
    }
}

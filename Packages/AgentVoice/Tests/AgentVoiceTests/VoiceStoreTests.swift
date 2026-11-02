import AgentVoice
import Foundation
import Testing

struct VoiceStoreTests {
    func fixture(limits: VoiceLimits = .init()) throws -> (VoiceStore, URL, VoiceSession, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try VoiceStore(url: root.appendingPathComponent("voice.sqlite"), limits: limits), root,
                VoiceSession(installationID: UUID(), host: "fixture", sessionID: UUID().uuidString), UUID())
    }

    @Test func modelStopCannotAuthorizePlayback() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attached = try await store.handle(.init(session: session, operation: .attach), connectionID: connection)
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attached.attachment), connectionID: connection)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attached.attachment,
                                                    inputID: input.inputID, text: "The fix is ready. One test is still failing."), connectionID: connection)
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attached.attachment, inputID: input.inputID), connectionID: connection)
        #expect(stop.state == .awaitingCompletion)
        #expect(try await store.nextJob() == nil)
        let authorized = try await store.authorizeByUser(draftID: prepared.draftID!)
        #expect(authorized.state == .queued)
        #expect(try await store.nextJob()?.id == authorized.id)
    }

    @Test func stopBeforeDraftAndLateRetriesNeverReopenInput() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection).inputID
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(stop.state == .skippedMissingDraft)
        let late = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Late answer"), connectionID: connection)
        #expect(late.code == "input_closed")
        let unknown = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: UUID(), text: "Unknown"), connectionID: connection)
        #expect(unknown.code == "unknown_input")
    }

    @Test func replacementRequiresCurrentRevisionAndCannotChangeQueuedWork() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection).inputID
        let first = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "First"), connectionID: connection)
        let conflict = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Second"), connectionID: connection)
        #expect(conflict.code == "replacement_conflict")
        let second = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Second",
                                                  replacesDraftID: first.draftID, expectedRevision: 1), connectionID: connection)
        #expect(second.revision == 2)
        _ = try await store.authorizeByUser(draftID: second.draftID!)
        let frozen = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Third",
                                                  replacesDraftID: second.draftID, expectedRevision: 2), connectionID: connection)
        #expect(!frozen.accepted)
    }

    @Test func reconnectFencesWritersButIdenticalRetryCanReadReceipt() async throws {
        var limits = VoiceLimits(); limits.attachmentLease = 1
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection, now: now).attachment
        let request = VoiceRequest(session: session, operation: .prompt, attachment: attachment)
        let original = try await store.handle(request, connectionID: connection, now: now)
        let otherConnection = UUID()
        let reattached = try await store.handle(.init(session: session, operation: .attach), connectionID: otherConnection, now: now.addingTimeInterval(2))
        #expect(reattached.attachment?.epoch == 2)
        let receipt = try await store.handle(request, connectionID: otherConnection, now: now.addingTimeInterval(2))
        #expect(receipt == original)
        let stale = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: original.inputID, text: "Old writer"), connectionID: connection, now: now.addingTimeInterval(2))
        #expect(stale.code == "stale_attachment")
        var changed = request; changed.text = "Changed"
        #expect(try await store.handle(changed, connectionID: connection).code == "request_conflict")
    }

    @Test func newPromptInvalidatesOldSpeechAndRecoveryNeverAutoReplays() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection).inputID
        let draft = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Answer"), connectionID: connection)
        let job = try await store.authorizeByUser(draftID: draft.draftID!)
        _ = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection)
        #expect(try await store.transition(job.id, from: .queued, to: .synthesizing) == false)
        let recovered = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"))
        #expect(try await recovered.nextJob() == nil)
    }

    @Test func queueExpiryStartsAtAdmissionAndIsCheckedBeforePlayback() async throws {
        var limits = VoiceLimits(); limits.queueLifetime = 2
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection, now: now).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection, now: now).inputID
        let draft = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Answer"), connectionID: connection, now: now)
        let job = try await store.authorizeByUser(draftID: draft.draftID!, now: now)
        #expect(try await store.nextJob(now: now)?.id == job.id)
        #expect(try await store.transition(job.id, from: .synthesizing, to: .playing, now: now.addingTimeInterval(3)) == false)
        #expect(try await store.drafts(now: now.addingTimeInterval(3)).first?.state == .expired)
    }

    @Test func retryAfterRetentionCannotRecreateInputAndUserRetryKeepsHostClosed() async throws {
        var limits = VoiceLimits(); limits.retryRetention = 10; limits.attachmentLease = 30
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection, now: now).attachment
        let prompt = VoiceRequest(session: session, operation: .prompt, attachment: attachment)
        let input = try await store.handle(prompt, connectionID: connection, now: now).inputID
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Answer"), connectionID: connection, now: now)
        let job = try await store.authorizeByUser(draftID: prepared.draftID!, now: now)
        #expect(try await store.transition(job.id, from: .queued, to: .failed))
        let retry = try await store.authorizeByUser(draftID: job.id, now: now)
        #expect(retry.id != job.id)
        let late = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Late correction"), connectionID: connection, now: now)
        #expect(late.code == "input_closed")
        #expect(try await store.handle(prompt, connectionID: connection, now: now.addingTimeInterval(11)).code == "request_expired")
        var unknown = VoiceRequest(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Old input")
        unknown.issuedAt = now.addingTimeInterval(11)
        #expect(try await store.handle(unknown, connectionID: connection, now: now.addingTimeInterval(11)).code == "unknown_input")
    }

    @Test func longAgentTurnDoesNotConsumePreparedRenditionLifetime() async throws {
        var limits = VoiceLimits(); limits.attachmentLease = 3600
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection, now: now).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection, now: now).inputID
        let preparation = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "The ten-minute task is complete."), connectionID: connection, now: now.addingTimeInterval(600))
        #expect(preparation.accepted)
        let attempt = try await store.authorizeByUser(draftID: preparation.draftID!, now: now.addingTimeInterval(601))
        #expect(attempt.state == .queued)
    }
}

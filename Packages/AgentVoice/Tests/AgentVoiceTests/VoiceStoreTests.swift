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

    @Test func userRetryAfterDisconnectKeepsHostClosedAndOldAttemptInert() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection).inputID
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Answer kept across disconnect."), connectionID: connection)
        let attempt = try await store.authorizeByUser(draftID: prepared.draftID!)
        // Claiming the queued job starts synthesis; disconnect then silences it.
        #expect(try await store.nextJob()?.id == attempt.id)
        try await store.disconnect(connectionID: connection)
        // Disconnect silences active work instead of leaving it playable in place.
        #expect(try await store.nextJob() == nil)
        let retry = try await store.authorizeByUser(draftID: attempt.id)
        #expect(retry.state == .queued)
        #expect(retry.id != attempt.id)
        #expect(retry.text == "Answer kept across disconnect.")
        #expect(try await store.nextJob()?.id == retry.id)
        // The host input stays closed: the old attachment cannot mutate it after an app retry.
        let late = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                inputID: input, text: "Late correction"), connectionID: connection)
        #expect(late.code == "input_closed" || late.code == "stale_attachment")
        // The superseded attempt identity can never affect the new one.
        #expect(try await store.transition(attempt.id, from: .queued, to: .synthesizing) == false)
        #expect(try await store.transition(attempt.id, from: .synthesizing, to: .playing) == false)
    }

    @Test func userRetryAfterSupersessionKeepsHostClosedAndOldAttemptInert() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection).inputID
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "First answer."), connectionID: connection)
        let attempt = try await store.authorizeByUser(draftID: prepared.draftID!)
        _ = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection)
        // A new prompt cancels the queued attempt; it never replays on its own.
        #expect(try await store.nextJob() == nil)
        #expect(try await store.transition(attempt.id, from: .queued, to: .synthesizing) == false)
        let retry = try await store.authorizeByUser(draftID: attempt.id)
        #expect(retry.state == .queued)
        #expect(retry.id != attempt.id)
        #expect(retry.text == "First answer.")
        #expect(try await store.nextJob()?.id == retry.id)
        let late = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                inputID: input, text: "Late correction"), connectionID: connection)
        #expect(late.code == "input_closed")
        #expect(try await store.transition(attempt.id, from: .queued, to: .synthesizing) == false)
    }

    @Test func expiredAndUnknownResponsesStayUnplayable() async throws {
        var limits = VoiceLimits(); limits.preparedLifetime = 2
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection, now: now).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection, now: now).inputID
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Short-lived answer."), connectionID: connection, now: now)
        do {
            _ = try await store.authorizeByUser(draftID: prepared.draftID!, now: now.addingTimeInterval(5))
            Issue.record("Expired text must not be playable.")
        } catch { #expect((error as? VoiceError)?.errorDescription == "This response is no longer available.") }
        do {
            _ = try await store.authorizeByUser(draftID: UUID(), now: now)
            Issue.record("Unknown rows must not be recreated.")
        } catch { #expect((error as? VoiceError)?.errorDescription == "This response is no longer available.") }
        #expect(try await store.nextJob(now: now.addingTimeInterval(5)) == nil)
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

    @Test func retainedTerminalReplayRespectsQueueCap() async throws {
        for terminal in [VoiceState.completed, .cancelled, .interrupted] {
            var limits = VoiceLimits(); limits.maxPending = 1; limits.maxPendingPerSession = 10
            let (store, root, _, connection) = try fixture(limits: limits)
            defer { try? FileManager.default.removeItem(at: root) }
            let base = VoiceSession(installationID: UUID(), host: "fixture", sessionID: UUID().uuidString)
            let terminalSession = VoiceSession(installationID: base.installationID, host: base.host, sessionID: base.sessionID + "-terminal")
            let fillerSession = VoiceSession(installationID: base.installationID, host: base.host, sessionID: base.sessionID + "-filler")
            let terminalAttachment = try await store.handle(.init(session: terminalSession, operation: .attach), connectionID: connection).attachment
            let terminalInput = try await store.handle(.init(session: terminalSession, operation: .prompt, attachment: terminalAttachment), connectionID: connection).inputID
            let prepared = try await store.handle(.init(session: terminalSession, operation: .prepare, attachment: terminalAttachment,
                                                        inputID: terminalInput, text: "Retained \(terminal.rawValue) response."), connectionID: connection)
            let attempt = try await store.authorizeByUser(draftID: prepared.draftID!)
            #expect(try await store.transition(attempt.id, from: .queued, to: terminal))
            let fillerAttachment = try await store.handle(.init(session: fillerSession, operation: .attach), connectionID: connection).attachment
            let fillerInput = try await store.handle(.init(session: fillerSession, operation: .prompt, attachment: fillerAttachment), connectionID: connection).inputID
            let fillerPrepared = try await store.handle(.init(session: fillerSession, operation: .prepare, attachment: fillerAttachment,
                                                              inputID: fillerInput, text: "Filler response."), connectionID: connection)
            let filler = try await store.authorizeByUser(draftID: fillerPrepared.draftID!)
            #expect(filler.state == .queued)
            do {
                _ = try await store.authorizeByUser(draftID: attempt.id)
                Issue.record("Retained \(terminal.rawValue) replay must respect the queue cap.")
            } catch {
                #expect((error as? VoiceError)?.errorDescription == "The speech queue is full.")
            }
            let drafts = try await store.drafts()
            #expect(drafts.count == 2)
            #expect(drafts.first(where: { $0.id == attempt.id })?.text == "Retained \(terminal.rawValue) response.")
            #expect(drafts.first(where: { $0.id == attempt.id })?.state == terminal)
            #expect(drafts.first(where: { $0.id == filler.id })?.state == .queued)
            #expect(try await store.nextJob()?.id == filler.id)
        }
    }
}

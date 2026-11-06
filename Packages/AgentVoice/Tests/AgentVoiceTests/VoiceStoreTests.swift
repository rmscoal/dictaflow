import AgentVoice
import Foundation
import Testing

struct VoiceStoreTests {
    func fixture(limits: VoiceLimits = .init()) throws -> (VoiceStore, URL, VoiceSession, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try VoiceStore(url: root.appendingPathComponent("voice.sqlite"), limits: limits), root,
                VoiceSession(installationID: UUID(), host: "fixture", sessionID: UUID().uuidString), UUID())
    }

    private func attach(_ store: VoiceStore, _ session: VoiceSession, _ connection: UUID, now: Date = Date()) async throws -> VoiceAttachment {
        try await store.handle(.init(session: session, operation: .attach), connectionID: connection, now: now).attachment!
    }

    private func prompt(_ store: VoiceStore, _ session: VoiceSession, _ attachment: VoiceAttachment?,
                        _ connection: UUID, nativeTurn: String? = nil, now: Date = Date()) async throws -> UUID {
        try await store.handle(.init(session: session, operation: .prompt, attachment: attachment,
                                     nativeTurnID: nativeTurn), connectionID: connection, now: now).inputID!
    }

    @Test func automaticStopAdmitsCurrentRevisionExactlyOnce() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "The fix is ready."), connectionID: connection)
        #expect(prepared.code == "prepared")
        #expect(try await store.nextJob() == nil, "Prepare alone must never admit playback.")
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(stop.code == "auto_admitted")
        #expect(stop.state == .queued)
        #expect(stop.draftID == prepared.draftID, "Rendition identity stays stable.")
        #expect(stop.renditionID == prepared.draftID)
        #expect(stop.attemptID != nil && stop.attemptID != stop.draftID, "Attempt identity is separate.")
        let duplicate = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(duplicate.code == "stop_duplicate")
        #expect(duplicate.attemptID == stop.attemptID)
        #expect(try await store.attempts(inputID: input).filter { $0.kind == .automatic }.count == 1)
        let job = try await store.nextJob()
        #expect(job?.id == stop.attemptID, "nextJob is keyed by attempt identity.")
        #expect(job?.renditionID == prepared.draftID)
        #expect(try await store.nextJob() == nil)
        let drafts = try await store.drafts()
        #expect(drafts.first?.id == prepared.draftID, "History rows stay keyed by rendition after admission.")
        #expect(drafts.first?.attemptID == stop.attemptID)
    }

    @Test func manualOnlyPolicyRecordsStopWithoutAdmission() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.setAdmissionPolicy(.manualOnly)
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Quiet answer."), connectionID: connection)
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(stop.code == "stop_observed_manual_only")
        #expect(stop.state == .awaitingCompletion)
        #expect(try await store.nextJob() == nil)
        // Switching back does not retroactively admit; a fresh Stop does.
        try await store.setAdmissionPolicy(.automatic)
        #expect(try await store.nextJob() == nil)
        let fresh = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(fresh.code == "auto_admitted")
        // Switching to manual-only cancels queued automatic work.
        try await store.setAdmissionPolicy(.manualOnly)
        #expect(try await store.nextJob() == nil)
        #expect(try await store.attempts(inputID: input).last?.state == .cancelled)
        _ = prepared
    }

    @Test func stopBeforePrepareDoesNotAdmitLaterPrepare() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(stop.code == "stop_observed_no_rendition")
        #expect(stop.state == .awaitingCompletion)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Late rendition."), connectionID: connection)
        #expect(prepared.code == "prepared_awaiting_stop")
        #expect(try await store.nextJob() == nil, "An old Stop must not admit a later revision.")
        let fresh = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(fresh.code == "auto_admitted")
        #expect(try await store.nextJob()?.renditionID == prepared.draftID)
    }

    @Test func correctionSupersedesPlayingAttemptAndWaitsForFreshStop() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let first = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                 inputID: input, text: "First version."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        let job = try await store.nextJob()
        #expect(try await store.transition(job!.id, from: .synthesizing, to: .playing))
        let corrected = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input,
                                                     text: "Corrected version.", replacesDraftID: first.draftID,
                                                     expectedRevision: 1), connectionID: connection)
        #expect(corrected.revision == 2)
        #expect(corrected.draftID != first.draftID)
        #expect(try await store.transition(job!.id, from: .playing, to: .completed) == false,
                "A superseded attempt can never complete late.")
        #expect(try await store.nextJob() == nil, "The correction waits for a fresh Stop.")
        #expect(try await store.renditions(inputID: input).map(\.text) == ["First version.", "Corrected version."],
                "Earlier revisions stay immutable in history.")
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(stop.code == "auto_admitted")
        #expect(stop.revision == 2)
        #expect(try await store.nextJob()?.text == "Corrected version.")
    }

    @Test func suppressionCancelsActiveBlocksLateAutoButAllowsManualReplay() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let first = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                 inputID: input, text: "Speak this."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        let suppressed = try await store.suppressInteraction(inputID: input)
        #expect(suppressed.isSuppressed)
        #expect(try await store.attempts(inputID: input).last?.state == .cancelled)
        #expect(try await store.nextJob() == nil)
        // A late correction is retained but never auto-admitted while suppressed.
        let corrected = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input,
                                                     text: "Corrected but muted.", replacesDraftID: first.draftID,
                                                     expectedRevision: 1), connectionID: connection)
        #expect(corrected.accepted)
        let lateStop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        #expect(lateStop.code == "stop_suppressed")
        #expect(try await store.nextJob() == nil)
        // A suppressed Stop must not leave eligibility behind for a future consumer.
        #expect(try await store.interaction(inputID: input)?.stopEligibleRevision == nil)
        // Explicit manual replay remains available and does not clear suppression.
        let manual = try await store.requestManualPlayback(renditionID: corrected.draftID!)
        #expect(manual.kind == .manual)
        #expect(manual.interactionSuppressed)
        #expect(try await store.interaction(inputID: input)?.isSuppressed == true)
        #expect(try await store.nextJob()?.id == manual.id)
        // Suppression also cancels a manual attempt already in flight.
        _ = try await store.suppressInteraction(inputID: input)
        #expect(try await store.transition(manual.id, from: .synthesizing, to: .playing) == false)
    }

    @Test func suppressActiveSpeechCoversLateAttemptsButLeavesPreparedAlone() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        // Session A: prepared, stopped, and therefore holding a queued automatic attempt.
        let inputA = try await prompt(store, session, attachment, connection)
        _ = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                         inputID: inputA, text: "Speak this."), connectionID: connection)
        let stopA = try await store.handle(.init(session: session, operation: .stop, attachment: attachment,
                                                inputID: inputA), connectionID: connection)
        #expect(stopA.code == "auto_admitted")
        // Session B: prepared but never stopped, so no attempt exists yet.
        let sessionB = VoiceSession(installationID: session.installationID, host: session.host,
                                    sessionID: UUID().uuidString)
        let attachmentB = try await attach(store, sessionB, connection)
        let inputB = try await prompt(store, sessionB, attachmentB, connection)
        _ = try await store.handle(.init(session: sessionB, operation: .prepare, attachment: attachmentB,
                                         inputID: inputB, text: "Other turn."), connectionID: connection)
        // A user Stop names only A's interaction, without any UI refresh in between.
        let suppressed = try await store.suppressActiveSpeech(for: inputA)
        #expect(suppressed.map(\.id).contains(inputA))
        #expect(try await store.attempts(inputID: inputA).last?.state == .cancelled)
        #expect(try await store.interaction(inputID: inputA)?.stopEligibleRevision == nil)
        // B was never speaking, so it stays eligible: its Stop still admits.
        #expect(try await store.interaction(inputID: inputB)?.isSuppressed == false)
        let stopB = try await store.handle(.init(session: sessionB, operation: .stop, attachment: attachmentB,
                                                inputID: inputB), connectionID: connection)
        #expect(stopB.code == "auto_admitted")
        // An unknown named input is skipped, not an error; active attempts still resolve.
        let none = try await store.suppressActiveSpeech(for: UUID())
        #expect(none.map(\.id).contains(inputB))
    }

    @Test func completedTurnCannotBeCorrectedAfterNewPromptOrReconnect() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let oldInput = try await prompt(store, session, attachment, connection)
        let oldPrepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                       inputID: oldInput, text: "Finished answer."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: oldInput), connectionID: connection)
        let job = try await store.nextJob()
        #expect(try await store.transition(job!.id, from: .synthesizing, to: .playing))
        #expect(try await store.transition(job!.id, from: .playing, to: .completed))
        // A new prompt closes the finished turn for host mutation while
        // keeping its completed history intact.
        _ = try await prompt(store, session, attachment, connection)
        let correction = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: oldInput,
                                                      text: "Late correction.", replacesDraftID: oldPrepared.draftID,
                                                      expectedRevision: 1), connectionID: connection)
        #expect(correction.code == "input_closed")
        #expect(try await store.interaction(inputID: oldInput)?.state == .completed)
        #expect(try await store.renditions(inputID: oldInput).count == 1, "No new revision may be created for the closed turn.")
        // The same closure holds across disconnect and reattach.
        let other = UUID()
        try await store.disconnect(connectionID: connection)
        let reattached = try await attach(store, session, other)
        let afterReconnect = try await store.handle(.init(session: session, operation: .prepare, attachment: reattached, inputID: oldInput,
                                                          text: "Post-reconnect correction.", replacesDraftID: oldPrepared.draftID,
                                                          expectedRevision: 1), connectionID: other)
        #expect(afterReconnect.code == "input_closed")
        #expect(try await store.nextJob()?.inputID != oldInput)
    }

    @Test func staleStopForSupersededInputNeverAppliesToNewerInput() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let oldInput = try await prompt(store, session, attachment, connection)
        _ = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                         inputID: oldInput, text: "Old answer."), connectionID: connection)
        let newInput = try await prompt(store, session, attachment, connection)
        let stale = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: oldInput), connectionID: connection)
        #expect(stale.code == "input_closed")
        #expect(try await store.attempts(inputID: newInput).isEmpty)
        #expect(try await store.nextJob() == nil)
    }

    @Test func restartNeverAutoReplaysButManualReplaySurvives() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("voice.sqlite")
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Retained answer."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        let recovered = try VoiceStore(url: url)
        #expect(try await recovered.nextJob() == nil)
        #expect(try await recovered.attempts(inputID: input).last?.state == .interrupted)
        let manual = try await recovered.requestManualPlayback(renditionID: prepared.draftID!)
        #expect(try await recovered.nextJob()?.id == manual.id)
        #expect(try await recovered.admissionPolicy() == .automatic)
    }

    @Test func historyPreservesRevisionsAttemptsEventsAndDeleteRejectsLateCallbacks() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection, nativeTurn: "turn-9")
        let first = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                 inputID: input, text: "Version one."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input,
                                         text: "Version two.", replacesDraftID: first.draftID, expectedRevision: 1), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        let record = try await store.historyRecords().first
        #expect(record?.interaction.nativeTurnID == "turn-9")
        #expect(record?.renditions.map(\.revision) == [1, 2])
        #expect(record?.attempts.map(\.kind) == [.automatic])
        #expect(record?.attempts.first?.interactionSuppressed == false)
        let kinds = Set(record?.events.map(\.kind) ?? [])
        #expect(kinds.contains(.promptOpened) && kinds.contains(.renditionPrepared)
                && kinds.contains(.stopObserved) && kinds.contains(.autoAdmitted))
        #expect(try await store.interaction(forAttemptID: record!.attempts[0].id)?.id == input)
        // Deleting cancels the queued attempt; a late transition is rejected.
        let attemptID = record!.attempts[0].id
        #expect(try await store.deleteInteraction(inputID: input))
        #expect(try await store.transition(attemptID, from: .queued, to: .synthesizing) == false)
        #expect(try await store.historyRecords().isEmpty)
    }

    @Test func queueExpiryIsIndependentOfHistoryRetention() async throws {
        var limits = VoiceLimits(); limits.queueLifetime = 2
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await attach(store, session, connection, now: now)
        let input = try await prompt(store, session, attachment, connection, now: now)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Answer"), connectionID: connection, now: now)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection, now: now)
        let job = try await store.nextJob(now: now)
        #expect(try await store.transition(job!.id, from: .synthesizing, to: .playing, now: now.addingTimeInterval(3)) == false)
        #expect(try await store.drafts(now: now.addingTimeInterval(3)).first?.state == .expired)
        // The rendition remains in history and can still be replayed manually.
        let manual = try await store.requestManualPlayback(renditionID: prepared.draftID!, now: now.addingTimeInterval(3))
        #expect(manual.state == .queued)
    }

    @Test func manualReplayIsSeparateFromAutomaticAttempt() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Play me twice."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        let auto = try await store.nextJob()
        #expect(try await store.transition(auto!.id, from: .synthesizing, to: .playing))
        #expect(try await store.transition(auto!.id, from: .playing, to: .completed))
        let manual = try await store.requestManualPlayback(renditionID: prepared.draftID!)
        #expect(manual.id != auto!.id)
        #expect(manual.kind == .manual)
        #expect(try await store.drafts().first?.id == prepared.draftID, "Manual replay does not change history identity.")
    }

    @Test func sessionOnlyStopAddressesCurrentInteractionForHostsWithoutTurnID() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        _ = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                         inputID: input, text: "Session addressed answer."), connectionID: connection)
        // No input ID and no native turn: the current session interaction is
        // addressed, as a Claude Code Stop hook (session_id only) requires.
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment), connectionID: connection)
        #expect(stop.code == "auto_admitted")
        #expect(stop.inputID == input)
        // Preparation still demands exact identity; it never falls back.
        let vague = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, text: "Vague."), connectionID: connection)
        #expect(vague.code == "unknown_input")
    }

    @Test func unknownNativeTurnNeverFallsThroughToCurrentTurn() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let oldInput = try await prompt(store, session, attachment, connection, nativeTurn: "old-turn")
        let oldPrepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                       inputID: oldInput, text: "Old answer."), connectionID: connection)
        let currentInput = try await prompt(store, session, attachment, connection, nativeTurn: "current-turn")
        _ = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                         inputID: currentInput, text: "Current answer."), connectionID: connection)
        // An explicit but unknown native turn is stronger identity than no
        // identity: it must reject, never degrade to the current turn.
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment,
                                                nativeTurnID: "unknown-turn"), connectionID: connection)
        #expect(stop.code == "unknown_input")
        let interrupt = try await store.handle(.init(session: session, operation: .interrupt, attachment: attachment,
                                                     nativeTurnID: "unknown-turn"), connectionID: connection)
        #expect(interrupt.code == "unknown_input")
        #expect(try await store.attempts(inputID: currentInput).isEmpty)
        #expect(try await store.interaction(inputID: currentInput)?.state == .prepared)
        // A stale host interrupt for the known, closed old turn must not
        // cancel a manual replay the user started from retained history.
        let manual = try await store.requestManualPlayback(renditionID: oldPrepared.draftID!)
        let staleInterrupt = try await store.handle(.init(session: session, operation: .interrupt, attachment: attachment,
                                                          nativeTurnID: "old-turn"), connectionID: connection)
        #expect(staleInterrupt.code == "input_closed")
        #expect(try await store.nextJob()?.id == manual.id, "Manual replay survives the stale host interrupt.")
    }

    @Test func nativeTurnResolvesDurablyButClosureSurvivesReconnect() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection, nativeTurn: "native-1")
        // No explicit input ID: the persisted native turn resolves it.
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    text: "Resolved answer.", nativeTurnID: "native-1"), connectionID: connection)
        #expect(prepared.accepted)
        #expect(prepared.inputID == input)
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment,
                                                 nativeTurnID: "native-1"), connectionID: connection)
        #expect(stop.code == "auto_admitted")
        // Disconnect closes the turn. A reconnected writer cannot reopen it,
        // even by presenting the same durable native turn identity.
        try await store.disconnect(connectionID: connection)
        let other = UUID()
        let reattached = try await attach(store, session, other)
        let late = try await store.handle(.init(session: session, operation: .prepare, attachment: reattached,
                                                text: "Reopened.", nativeTurnID: "native-1"), connectionID: other)
        #expect(late.code == "input_closed")
        let status = try await store.handle(.init(session: session, operation: .status, attachment: reattached,
                                                  nativeTurnID: "native-1"), connectionID: other)
        #expect(status.accepted)
        #expect(status.state == .interrupted)
    }

    @Test func pendingCapacityExcludesRetainedTerminalHistory() async throws {
        var limits = VoiceLimits(); limits.maxPending = 1; limits.maxPendingPerSession = 10
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let firstInput = try await prompt(store, session, attachment, connection)
        let first = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                 inputID: firstInput, text: "Done answer."), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: firstInput), connectionID: connection)
        let job = try await store.nextJob()
        #expect(try await store.transition(job!.id, from: .synthesizing, to: .playing))
        #expect(try await store.transition(job!.id, from: .playing, to: .completed))
        // Retained completed history must not consume pending capacity.
        let secondSession = VoiceSession(installationID: session.installationID, host: session.host, sessionID: "second")
        let secondAttachment = try await attach(store, secondSession, connection)
        let secondInput = try await prompt(store, secondSession, secondAttachment, connection)
        let second = try await store.handle(.init(session: secondSession, operation: .prepare, attachment: secondAttachment,
                                                  inputID: secondInput, text: "Next answer."), connectionID: connection)
        #expect(second.accepted)
        _ = first
    }

    @Test func legacyMigrationRetainsPlayableTextWithoutEligibilityOrResurrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("voice.sqlite")
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "legacy")
        let keyEncoder = JSONEncoder(); keyEncoder.outputFormatting = [.sortedKeys]
        let key = String(decoding: try keyEncoder.encode(session), as: UTF8.self)
        func legacyDraft(text: String, state: VoiceState) throws -> String {
            let draft = VoiceDraft(id: UUID(), inputID: UUID(), session: session, revision: 1, text: text,
                                   state: state, createdAt: Date())
            // The input ID inside the blob is replaced below by the row ID.
            return String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        }
        // Build a v2-shaped database with the system sqlite3, including
        // GRDB's migration registry so only v3 runs on open.
        let retainedID = UUID(); let expiredID = UUID()
        var retained = try legacyDraft(text: "Legacy retained answer.", state: .prepared)
        var expired = try legacyDraft(text: "Legacy expired answer.", state: .expired)
        // Rewrite blob input IDs to match their rows.
        for (blob, id) in [(retained, retainedID), (expired, expiredID)] {
            _ = blob; _ = id
        }
        func blobHex(_ json: String, id: UUID, input: UUID) -> String {
            var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            object["id"] = id.uuidString; object["inputID"] = input.uuidString
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.map { String(format: "%02x", $0) }.joined()
        }
        retained = blobHex(retained, id: UUID(), input: retainedID)
        expired = blobHex(expired, id: UUID(), input: expiredID)
        let escapedKey = key.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations VALUES ('agentVoice-v1'), ('agentVoice-v2-closed-inputs');
        CREATE TABLE sessions (key TEXT PRIMARY KEY, epoch INTEGER NOT NULL, attachment TEXT, connection TEXT, lease REAL NOT NULL DEFAULT 0);
        CREATE TABLE inputs (id TEXT PRIMARY KEY, session TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL, draft BLOB, host_closed INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX inputs_session ON inputs(session);
        CREATE TABLE receipts (session TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, reply BLOB NOT NULL, created REAL NOT NULL, PRIMARY KEY(session, id));
        INSERT INTO inputs VALUES ('\(retainedID.uuidString)', '\(escapedKey)', 'prepared', \(Date().timeIntervalSince1970), X'\(retained)', 0);
        INSERT INTO inputs VALUES ('\(expiredID.uuidString)', '\(escapedKey)', 'expired', \(Date().timeIntervalSince1970), X'\(expired)', 1);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path]
        let pipe = Pipe(); process.standardInput = pipe
        try process.run()
        try pipe.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let store = try VoiceStore(url: url)
        let drafts = try await store.drafts()
        #expect(drafts.map(\.text) == ["Legacy retained answer."], "Expired legacy text must not be resurrected.")
        #expect(try await store.nextJob() == nil, "Legacy rows never auto-admit.")
        let manual = try await store.requestManualPlayback(renditionID: drafts[0].id)
        #expect(manual.kind == .manual)
        let legacyEvents = try await store.events(inputID: retainedID).map(\.kind)
        #expect(legacyEvents.first == .migrated && legacyEvents.count == 2,
                "Migration records only its own note; the manual admission is a new, real event.")
    }

    @Test func replacementRequiresCurrentRevision() async throws {
        let (store, root, session, connection) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let first = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "First"), connectionID: connection)
        let conflict = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Second"), connectionID: connection)
        #expect(conflict.code == "replacement_conflict")
        let second = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Second",
                                                  replacesDraftID: first.draftID, expectedRevision: 1), connectionID: connection)
        #expect(second.revision == 2)
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
        let attachment = try await attach(store, session, connection)
        let input = try await prompt(store, session, attachment, connection)
        let draft = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Answer"), connectionID: connection)
        _ = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection)
        let job = try await store.nextJob()
        _ = try await prompt(store, session, attachment, connection)
        #expect(try await store.transition(job!.id, from: .synthesizing, to: .playing) == false)
        let recovered = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"))
        #expect(try await recovered.nextJob() == nil)
        _ = draft
    }

    @Test func hostMutationWindowClosesButHistoryStaysReplayable() async throws {
        var limits = VoiceLimits(); limits.retryRetention = 10; limits.attachmentLease = 30
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await attach(store, session, connection, now: now)
        let input = try await prompt(store, session, attachment, connection, now: now)
        let prepared = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Answer"), connectionID: connection, now: now)
        // After the retry window the host can no longer mutate the turn, and
        // an unknown input stays unknown; retained history remains playable.
        var late = VoiceRequest(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Late")
        late.issuedAt = now.addingTimeInterval(11)
        #expect(try await store.handle(late, connectionID: connection, now: now.addingTimeInterval(11)).code == "input_closed")
        var unknown = VoiceRequest(session: session, operation: .prepare, attachment: attachment, inputID: UUID(), text: "Old input")
        unknown.issuedAt = now.addingTimeInterval(11)
        #expect(try await store.handle(unknown, connectionID: connection, now: now.addingTimeInterval(11)).code == "unknown_input")
        let manual = try await store.requestManualPlayback(renditionID: prepared.draftID!, now: now.addingTimeInterval(11))
        #expect(manual.state == .queued)
    }

    @Test func pruneHistoryBoundsInteractionsWithoutTouchingActiveWork() async throws {
        var limits = VoiceLimits(); limits.maxHistoryInteractions = 2
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        var firstInput: UUID?
        var last: (VoiceSession, VoiceAttachment?, UUID)?
        for index in 0..<3 {
            let each = VoiceSession(installationID: session.installationID, host: session.host, sessionID: "s-\(index)")
            let attachment = try await attach(store, each, connection)
            let input = try await prompt(store, each, attachment, connection)
            if index == 0 { firstInput = input }
            _ = try await store.handle(.init(session: each, operation: .prepare, attachment: attachment,
                                             inputID: input, text: "Answer \(index)."), connectionID: connection)
            last = (each, attachment, input)
        }
        // The newest interaction is made active so pruning must spare it.
        _ = try await store.handle(.init(session: last!.0, operation: .stop, attachment: last!.1, inputID: last!.2), connectionID: connection)
        #expect(try await store.nextJob() != nil)
        _ = try await store.pruneHistory()
        #expect(try await store.interactions(limit: 10).count <= 2)
        #expect(try await store.interaction(inputID: firstInput!) == nil)
    }

    @Test func unknownManualPlaybackThrowsInsteadOfRecreating() async throws {
        let (store, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await store.requestManualPlayback(renditionID: UUID())
            Issue.record("Unknown rows must not be recreated.")
        } catch { #expect((error as? VoiceError)?.errorDescription == "This response is no longer available.") }
        #expect(try await store.nextJob() == nil)
    }

    @Test func longAgentTurnDoesNotConsumeRenditionAutoWindow() async throws {
        var limits = VoiceLimits(); limits.attachmentLease = 3600
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let attachment = try await attach(store, session, connection, now: now)
        let input = try await prompt(store, session, attachment, connection, now: now)
        let preparation = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "The ten-minute task is complete."), connectionID: connection, now: now.addingTimeInterval(600))
        #expect(preparation.accepted)
        let stop = try await store.handle(.init(session: session, operation: .stop, attachment: attachment, inputID: input), connectionID: connection, now: now.addingTimeInterval(601))
        #expect(stop.code == "auto_admitted")
    }

    @Test func retainedTerminalReplayRespectsQueueCap() async throws {
        var limits = VoiceLimits(); limits.maxPending = 1; limits.maxPendingPerSession = 10
        let (store, root, session, connection) = try fixture(limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminalSession = VoiceSession(installationID: session.installationID, host: session.host, sessionID: "terminal")
        let terminalAttachment = try await attach(store, terminalSession, connection)
        let terminalInput = try await prompt(store, terminalSession, terminalAttachment, connection)
        let prepared = try await store.handle(.init(session: terminalSession, operation: .prepare, attachment: terminalAttachment,
                                                    inputID: terminalInput, text: "Retained response."), connectionID: connection)
        _ = try await store.handle(.init(session: terminalSession, operation: .stop, attachment: terminalAttachment, inputID: terminalInput), connectionID: connection)
        let auto = try await store.nextJob()
        #expect(try await store.transition(auto!.id, from: .synthesizing, to: .playing))
        #expect(try await store.transition(auto!.id, from: .playing, to: .completed))
        let fillerSession = VoiceSession(installationID: session.installationID, host: session.host, sessionID: "filler")
        let fillerAttachment = try await attach(store, fillerSession, connection)
        let fillerInput = try await prompt(store, fillerSession, fillerAttachment, connection)
        let fillerPrepared = try await store.handle(.init(session: fillerSession, operation: .prepare, attachment: fillerAttachment,
                                                          inputID: fillerInput, text: "Filler response."), connectionID: connection)
        _ = try await store.requestManualPlayback(renditionID: fillerPrepared.draftID!)
        do {
            _ = try await store.requestManualPlayback(renditionID: prepared.draftID!)
            Issue.record("Retained replay must respect the queue cap.")
        } catch {
            #expect((error as? VoiceError)?.errorDescription == "The speech queue is full.")
        }
    }
}

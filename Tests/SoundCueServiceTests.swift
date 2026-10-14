import AVFoundation
import XCTest
@testable import DictaFlow_Dev

/// Players load bundled WAV metadata but never play audio or access hardware.
@MainActor
final class SoundCueServiceTests: XCTestCase {
    func testInterruptedCallbacksCannotFinishReplacementCue() async throws {
        let fixture = CuePlaybackFixture()
        let interruptedStarted = expectation(description: "Interrupted cue starts")
        fixture.onStart = { interruptedStarted.fulfill() }
        let interrupted = Task { try await fixture.service.play(.startRecording, style: .softDigital) }
        await fulfillment(of: [interruptedStarted], timeout: 2)
        let oldPlayer = try XCTUnwrap(fixture.players.first)
        fixture.service.stop()
        try await interrupted.value

        let replacementStarted = expectation(description: "Replacement cue starts")
        fixture.onStart = { replacementStarted.fulfill() }
        let replacement = Task { try await fixture.service.play(.startRecording, style: .softDigital) }
        defer { fixture.service.stop() }
        await fulfillment(of: [replacementStarted], timeout: 2)
        let newPlayer = try XCTUnwrap(fixture.players.last)
        XCTAssertFalse(oldPlayer === newPlayer)

        oldPlayer.finish()
        oldPlayer.reportDecodeError()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(newPlayer.stops, 0, "Interrupted callbacks stopped the replacement cue")

        newPlayer.finish()
        try await replacement.value
        XCTAssertEqual(newPlayer.stops, 1)
    }

    func testTimedOutCallbackCannotFinishReplacementCue() async throws {
        let fixture = CuePlaybackFixture()
        do {
            try await fixture.service.play(.error, style: .softDigital)
            XCTFail("A player without a completion callback should time out")
        } catch SoundCueServiceError.playbackFailed {}
        let oldPlayer = try XCTUnwrap(fixture.players.first)

        let replacementStarted = expectation(description: "Replacement after timeout starts")
        fixture.onStart = { replacementStarted.fulfill() }
        let replacement = Task { try await fixture.service.play(.error, style: .softDigital) }
        defer { fixture.service.stop() }
        await fulfillment(of: [replacementStarted], timeout: 2)
        let newPlayer = try XCTUnwrap(fixture.players.last)
        XCTAssertFalse(oldPlayer === newPlayer)

        oldPlayer.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(newPlayer.stops, 0, "A timed-out callback stopped the replacement cue")

        newPlayer.finish()
        try await replacement.value
    }

    func testQueuedRequestsForSameCueHaveSeparatePlayers() async throws {
        let fixture = CuePlaybackFixture()
        let firstStarted = expectation(description: "First cue starts")
        fixture.onStart = { firstStarted.fulfill() }
        let first = Task { try await fixture.service.play(.startRecording, style: .softDigital) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let firstPlayer = try XCTUnwrap(fixture.players.first)

        let secondCreated = expectation(description: "Second player is reserved")
        let secondStarted = expectation(description: "Second cue starts")
        fixture.onCreate = { secondCreated.fulfill() }
        fixture.onStart = { secondStarted.fulfill() }
        let second = Task { try await fixture.service.play(.startRecording, style: .softDigital) }
        defer { fixture.service.stop() }
        await fulfillment(of: [secondCreated], timeout: 2)
        let secondPlayer = try XCTUnwrap(fixture.players.last)
        XCTAssertFalse(firstPlayer === secondPlayer)
        XCTAssertEqual(secondPlayer.starts, 0, "Queued playback must wait for the first cue")

        firstPlayer.finish()
        try await first.value
        await fulfillment(of: [secondStarted], timeout: 2)
        firstPlayer.reportDecodeError()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(secondPlayer.stops, 0, "A completed cue's callback stopped the next cue")

        secondPlayer.finish()
        try await second.value
    }
}

@MainActor
private final class CuePlaybackFixture {
    var players: [SilentCuePlayer] = []
    var onCreate: (() -> Void)?
    var onStart: (() -> Void)?
    lazy var service = SoundCueService { [unowned self] url in
        let player = try SilentCuePlayer(contentsOf: url)
        player.onStart = { [weak self] in self?.onStart?() }
        players.append(player)
        onCreate?()
        return player
    }
}

@MainActor
private final class SilentCuePlayer: AVAudioPlayer {
    var starts = 0
    var stops = 0
    var onStart: (() -> Void)?
    override var duration: TimeInterval { 0.01 }
    override func prepareToPlay() -> Bool { true }
    override func play() -> Bool { starts += 1; onStart?(); return true }
    override func stop() { stops += 1 }

    func finish() { delegate?.audioPlayerDidFinishPlaying?(self, successfully: true) }
    func reportDecodeError() { delegate?.audioPlayerDecodeErrorDidOccur?(self, error: nil) }
}

import XCTest
@testable import DictaFlow_Dev

final class RecordingAudioStatusTests: XCTestCase {
    func testLateCallbacksFromCancelledCaptureDoNotAffectRetry() {
        let status = RecordingAudioStatus()
        let cancelled = UUID()
        status.prepare(session: cancelled)
        status.beginCapture()
        status.clear()
        let retry = UUID()
        status.prepare(session: retry)
        status.beginCapture()

        status.fail(with: AudioRecorderServiceError.failedToWrite, session: cancelled)
        status.reportUnexpectedStop(session: cancelled)
        status.updatePower(1, session: cancelled)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.powerLevel, 0)

        status.updatePower(0.5, session: retry)
        status.reportUnexpectedStop(session: retry)
        XCTAssertEqual(status.powerLevel, 0.5)
        XCTAssertEqual(status.error as? AudioRecorderServiceError, .audioDeviceChanged)
    }

    func testNormalStopIgnoresCompletionButPreservesFinalizationFailure() {
        let status = RecordingAudioStatus()
        let session = UUID()
        status.prepare(session: session)
        status.beginCapture()
        status.endCapture()

        status.reportUnexpectedStop(session: session)
        XCTAssertNil(status.error)
        status.fail(with: AudioRecorderServiceError.failedToWrite, session: session)
        status.fail(with: AudioRecorderServiceError.audioDeviceChanged, session: session)
        XCTAssertEqual(status.error as? AudioRecorderServiceError, .failedToWrite)

        status.clear()
        status.fail(with: AudioRecorderServiceError.failedToWrite, session: session)
        XCTAssertNil(status.error)
    }
}

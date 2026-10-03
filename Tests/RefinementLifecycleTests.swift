import Darwin
import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class RefinementLifecycleTests: XCTestCase {
    func testLegacyPreferencesMigrateWithoutDisablingRefinement() throws {
        for model in ["qwen25HalfB", "qwen25OneAndHalfB", "qwen25ThreeB", "smolLM2OnePointSevenB", "qwen3SmallMLX"] {
            let data = Data("{\"isEnabled\":true,\"model\":\"\(model)\",\"mode\":\"smartCleanup\"}".utf8)
            let configuration = try JSONDecoder().decode(RefinementConfiguration.self, from: data)
            XCTAssertEqual(configuration.model, .qwen3Small)
            XCTAssertTrue(configuration.isEnabled)
            XCTAssertEqual(configuration.mode, .smartCleanup)
        }

    }

    func testUnsuccessfulHealthResponsesWaitAndConcurrentPreparationSharesServer() async throws {
        let fixture = try makeRuntime(exitImmediately: false)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        RefinementHTTPFixture.reset(loadingResponses: 2)
        let service = LlamaCLITranscriptRefinementService(executableURL: fixture, urlSession: fixtureSession())
        let started = ContinuousClock.now
        let model = fixture.deletingLastPathComponent().appendingPathComponent("model.gguf")
        async let first: Void = service.prepare(modelURL: model)
        async let second: Void = service.prepare(modelURL: model)
        do {
            _ = try await (first, second)
            XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(450))
            XCTAssertEqual(RefinementHTTPFixture.healthRequests, 3)
        } catch {
            await service.stop()
            throw error
        }
        await service.stop()
        let launches = try String(contentsOf: fixture.deletingLastPathComponent().appendingPathComponent("launches"), encoding: .utf8)
        XCTAssertEqual(launches.split(separator: "\n").count, 1)
    }

    func testExitedRuntimeFailsQuicklyAndCanBeRetried() async throws {
        let fixture = try makeRuntime(exitImmediately: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        RefinementHTTPFixture.reset(loadingResponses: 100)
        let service = LlamaCLITranscriptRefinementService(executableURL: fixture, urlSession: fixtureSession())
        for _ in 0..<2 {
            let started = ContinuousClock.now
            do {
                try await service.prepare(modelURL: fixture.appendingPathExtension("gguf"))
                XCTFail("An exited process must not be treated as ready")
            } catch {
                XCTAssertLessThan(started.duration(to: .now), .seconds(3))
            }
        }
        await service.stop()
    }

    func testStoppingDuringStartupAllowsFreshPreparation() async throws {
        let fixture = try makeRuntime(exitImmediately: false)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        RefinementHTTPFixture.reset(loadingResponses: 100)
        let service = LlamaCLITranscriptRefinementService(executableURL: fixture, urlSession: fixtureSession())
        let model = fixture.appendingPathExtension("gguf")
        let preparation = Task { try await service.prepare(modelURL: model) }
        try await Task.sleep(for: .milliseconds(100))
        await service.stop()
        do {
            try await preparation.value
            XCTFail("Interrupted startup must be cancelled")
        } catch is CancellationError {}
        RefinementHTTPFixture.reset()
        do { try await service.prepare(modelURL: model) }
        catch { await service.stop(); throw error }
        await service.stop()
    }

    func testForcedShutdownIsBoundedAndConcurrentStopsAllowRestart() async throws {
        let fixture = try makeRuntime(exitImmediately: false, ignoresTermination: true)
        let directory = fixture.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        RefinementHTTPFixture.reset()
        let service = LlamaCLITranscriptRefinementService(executableURL: fixture, urlSession: fixtureSession())
        try await service.prepare(modelURL: fixture.appendingPathExtension("gguf"))
        // The fixture writes its PID after installing the SIGTERM handler.
        let pidURL = directory.appendingPathComponent("pid")
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: pidURL.path), ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        let started = ContinuousClock.now
        async let first: Void = service.stop()
        async let second: Void = service.stop()
        _ = await (first, second)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(3))
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "The owned runtime must actually exit")
        XCTAssertEqual(errno, ESRCH)

        // Relaunch the same executable with normal termination behavior.
        let script = try String(contentsOf: fixture, encoding: .utf8)
        try script.replacingOccurrences(of: "signal.signal(signal.SIGTERM, signal.SIG_IGN)", with: "")
            .write(to: fixture, atomically: false, encoding: .utf8)
        try await service.prepare(modelURL: fixture.appendingPathExtension("gguf"))
        let restartDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (try? String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8)
            .split(separator: "\n").count) != 2, ContinuousClock.now < restartDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let stopStarted = ContinuousClock.now
        await service.stop()
        XCTAssertLessThan(stopStarted.duration(to: .now), .seconds(2))
        let launches = try String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8)
        XCTAssertEqual(launches.split(separator: "\n").count, 2)
    }

    func testSleepingServerIsWokenWithoutGeneratingOutput() async throws {
        let fixture = try makeRuntime(exitImmediately: false)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        RefinementHTTPFixture.reset(sleeping: true)
        let service = LlamaCLITranscriptRefinementService(executableURL: fixture, urlSession: fixtureSession())
        do { try await service.prepare(modelURL: fixture.appendingPathExtension("gguf")) }
        catch { await service.stop(); throw error }
        await service.stop()
        XCTAssertEqual(RefinementHTTPFixture.wakeTokenLimit, 0)
    }

    func testTruncatedOrReasoningOutputIsRejected() async throws {
        let fixture = try makeRuntime(exitImmediately: false)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        RefinementHTTPFixture.reset(finishReason: "length")
        let service = LlamaCLITranscriptRefinementService(executableURL: fixture, urlSession: fixtureSession())
        do {
            _ = try await service.refine(transcript: "Please send the report tomorrow.", whisperTaskMode: .transcribe,
                modelURL: fixture.appendingPathExtension("gguf"), configuration: .default, promptTemplate: "")
            XCTFail("A token-limited response must fall back to the original transcript")
        } catch TranscriptRefinementServiceError.incompleteOutput {} catch {
            await service.stop()
            throw error
        }
        await service.stop()
        for output in ["", "<think>reasoning</think>Answer", "<|im_start|>assistant"] {
            XCTAssertThrowsError(try RefinementInference.result(output, original: "Original", configuration: .default))
        }
        XCTAssertEqual(try RefinementInference.result("  Correct text.\n", original: "Original", configuration: .default).refinedText, "Correct text.")
    }

    func testOutputBudgetCoversDenseScripts() {
        XCTAssertEqual(RefinementInference.maximumOutputTokens(for: ""), 128)
        XCTAssertEqual(RefinementInference.maximumOutputTokens(for: String(repeating: "a", count: 300)), 364)
        // CJK scripts use about one token per character, so the budget must not
        // assume Latin token density.
        XCTAssertEqual(RefinementInference.maximumOutputTokens(for: String(repeating: "中", count: 600)), 664)
        XCTAssertEqual(RefinementInference.maximumOutputTokens(for: String(repeating: "中", count: 5000)), 1024)
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefinementHTTPFixture.self]
        return URLSession(configuration: configuration)
    }

    private func makeRuntime(exitImmediately: Bool, ignoresTermination: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("runtime.py")
        let script = """
        #!/usr/bin/python3
        import os, pathlib, signal, time
        \(ignoresTermination ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "")
        pathlib.Path(__file__).with_name('pid').write_text(str(os.getpid()))
        with pathlib.Path(__file__).with_name('launches').open('a') as file:
            file.write('launch\\n')
        \(exitImmediately ? "raise SystemExit(1)" : "time.sleep(30)")
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private final class RefinementHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var remainingLoadingResponses = 0
    private static var sleeping = false
    private static var finishReason = "stop"
    private static var requestCount = 0
    private static var tokenLimit: Int?

    static var healthRequests: Int { lock.withLock { requestCount } }
    static var wakeTokenLimit: Int? { lock.withLock { tokenLimit } }

    static func reset(loadingResponses: Int = 0, sleeping: Bool = false, finishReason: String = "stop") {
        lock.withLock {
            remainingLoadingResponses = loadingResponses
            self.sleeping = sleeping
            self.finishReason = finishReason
            requestCount = 0
            tokenLimit = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func requestBody() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    override func startLoading() {
        let response: (Int, [String: Any]) = Self.lock.withLock {
            switch request.url!.path {
            case "/health":
                Self.requestCount += 1
                if Self.remainingLoadingResponses > 0 {
                    Self.remainingLoadingResponses -= 1
                    return (503, [:])
                }
                return (200, [:])
            case "/props": return (200, ["is_sleeping": Self.sleeping])
            case "/completion":
                let payload = try? JSONSerialization.jsonObject(with: requestBody()) as? [String: Any]
                Self.tokenLimit = payload?["n_predict"] as? Int
                return (200, [:])
            default:
                return (200, ["choices": [["finish_reason": Self.finishReason, "message": ["content": "Correct text."]]]])
            }
        }
        let httpResponse = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response.1))
        client?.urlProtocolDidFinishLoading(self)
    }
}

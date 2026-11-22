import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@Suite("ConnectionTester")
struct ConnectionTesterTests {
    @Test("a base URL that is not http or https is refused before any request")
    func invalidURL() async {
        #expect(await ConnectionTester.run(baseURLString: "ftp://hermes.example.test", apiKey: "key").hermes == .invalidURL)
        #expect(await ConnectionTester.run(baseURLString: "hermes.example.test", apiKey: "key").hermes == .invalidURL)
        #expect(await ConnectionTester.run(baseURLString: "", apiKey: "key") == ConnectionTestReport(hermes: .invalidURL))
    }

    @Test("an empty or blank API key is refused before any request, sidecar included")
    func missingKey() async {
        let report = await ConnectionTester.run(
            baseURLString: "https://hermes.example.test", apiKey: "   ", sidecarURLString: "/sidecar")
        #expect(report == ConnectionTestReport(hermes: .missingKey))
    }

    @Test("a blank sidecar is not checked; one that does not resolve is reported without a request")
    func sidecarNotChecked() async {
        let none = await ConnectionTester.run(baseURLString: "nope", apiKey: "key", sidecarURLString: "  ")
        #expect(none.sidecar == nil)
        #expect(none.sidecarMessage == nil)

        let invalid = await ConnectionTester.run(baseURLString: "nope", apiKey: "key", sidecarURLString: "/sidecar")
        #expect(invalid == ConnectionTestReport(hermes: .invalidURL, sidecar: .invalidURL))
        #expect(invalid.sidecarMessage?.hasPrefix("Sidecar:") == true)
    }

    @Test("each service gets its own line, green on success, and a cancelled check shows nothing")
    func reportMessages() {
        let ok = ConnectionTestReport(hermes: .succeeded, sidecar: .succeeded(detail: "v0.1.0"))
        #expect(ok.hermesMessage == "Hermes: OK")
        #expect(ok.sidecarMessage == "Sidecar: OK (v0.1.0)")
        #expect(ok.hermes.isSuccess && ok.sidecar?.isSuccess == true)

        let down = ConnectionTestReport(hermes: .succeeded, sidecar: .failed(.http(status: 502)))
        #expect(down.sidecarMessage?.contains("cannot reach Hermes") == true)
        #expect(down.sidecar?.isSuccess == false)

        #expect(ConnectionTestReport(hermes: .succeeded, sidecar: .cancelled).isCancelled)
        #expect(!ok.isCancelled)
    }

    @Test("typed API errors are kept as failures with their message")
    func typedErrors() {
        let cases: [HermesAPIError] = [.unauthorized, .notFound, .timeout, .network, .invalidResponse, .http(status: 500)]
        for error in cases {
            let outcome = ConnectionTester.outcome(for: error)
            #expect(outcome == .failed(error))
            #expect(outcome.message == error.errorDescription)
        }
    }

    @Test("URLError values map to typed errors, and cancellation is not a failure")
    func urlErrors() {
        #expect(ConnectionTester.outcome(for: URLError(.timedOut)) == .failed(.timeout))
        #expect(ConnectionTester.outcome(for: URLError(.notConnectedToInternet)) == .failed(.network))
        #expect(ConnectionTester.outcome(for: URLError(.cancelled)) == .cancelled)
        #expect(ConnectionTester.outcome(for: CancellationError()) == .cancelled)
        #expect(ConnectionTestOutcome.cancelled.message == nil)
    }

    @Test("success and failure messages are non-empty and do not contain the key")
    func messages() {
        let key = "secret-key-value"
        #expect(ConnectionTestOutcome.succeeded.message?.isEmpty == false)
        #expect(ConnectionTestOutcome.invalidURL.message?.isEmpty == false)
        #expect(ConnectionTestOutcome.missingKey.message?.isEmpty == false)
        for outcome in [ConnectionTestOutcome.succeeded, .invalidURL, .missingKey, .failed(.unauthorized)] {
            #expect(outcome.message?.contains(key) != true)
        }
    }
}

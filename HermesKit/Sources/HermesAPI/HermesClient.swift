import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Explicit client configuration: base URL and API key, provided by the caller.
/// No default value and no singleton. The key never appears in descriptions.
public struct HermesClientConfiguration: Sendable {
    public let baseURL: URL
    public let apiKey: String
    /// Request timeout. Large, because an agent request can run for ~30 minutes.
    public let timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, timeout: TimeInterval = 30 * 60) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

extension HermesClientConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "HermesClientConfiguration(baseURL: \(baseURL.absoluteString), apiKey: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Client for a Hermes instance. Conversations are sessions stored on the instance (`/api/sessions`).
///
/// POST requests are never retried automatically.
public struct HermesClient: Sendable {
    public let configuration: HermesClientConfiguration
    private let session: URLSession

    public init(configuration: HermesClientConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// The URL session, for `SidecarClient`, which reuses this client's request building.
    var sessionForSidecar: URLSession { session }

    /// Sends one message to a session stored on the instance and streams the reply events, in order.
    /// `images` go with the text as `image_url` parts (see `MessageContent`).
    ///
    /// `POST {baseURL}/api/sessions/{id}/chat/stream`. The stream finishes on `done` or at the end of the
    /// response. Cancelling the consuming task, or leaving the loop, cancels the request. The request is
    /// never retried automatically.
    public func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment] = []
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        streamEvents {
            // The id goes into the path as is: it must be a single segment.
            try Self.checkPathSegment(sessionID)
            var request = makeRequest(
                method: "POST",
                path: HermesAPIPaths.sessionChatStream(sessionID),
                accept: "text/event-stream"
            )
            request.httpBody = try JSONEncoder().encode(
                SessionChatRequest(message: MessageContent(text: message, images: images))
            )
            return request
        }
    }

    /// Sends the request `build` returns and streams the session chat events of its SSE response, in order,
    /// until `done` or the end of the response. Shared with `SidecarClient`, whose streams carry the same
    /// events. Cancelling the consuming task, or leaving the loop, cancels the request and finishes the
    /// stream without an error; other failures finish it with a `HermesAPIError`. Never retried.
    func streamEvents(
        _ build: @escaping @Sendable () throws -> URLRequest
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try build()
                    #if canImport(Darwin)
                        let (bytes, response) = try await session.bytes(for: request)
                        try Self.validate(response, requestURL: request.url)
                        try await Self.forEachSessionEvent(in: bytes) { continuation.yield($0) }
                    #else
                        // Linux (tests only): URLSession.bytes is unavailable, so the body is buffered.
                        let (data, response) = try await session.data(for: request)
                        try Self.validate(response, requestURL: request.url)
                        let bytes = AsyncThrowingStream<UInt8, any Error> { source in
                            for byte in data {
                                source.yield(byte)
                            }
                            source.finish()
                        }
                        try await Self.forEachSessionEvent(in: bytes) { continuation.yield($0) }
                    #endif
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HermesAPIError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses the named events of a session chat stream and emits each one that a transcript shows,
    /// until `done`.
    private static func forEachSessionEvent<Bytes: AsyncSequence>(
        in bytes: Bytes,
        _ emit: (SessionChatEvent) -> Void
    ) async throws where Bytes.Element == UInt8 {
        var parser = SessionEventParser()
        for try await byte in bytes {
            for frame in parser.feed(CollectionOfOne(byte)) {
                if emitSessionEvent(frame, emit) { return }
            }
        }
        for frame in parser.finish() {
            if emitSessionEvent(frame, emit) { return }
        }
    }

    /// Returns `true` once the stream is complete (`done`).
    private static func emitSessionEvent(_ frame: SessionEventFrame, _ emit: (SessionChatEvent) -> Void) -> Bool {
        guard let event = SessionChatEvent(frame) else { return false }
        if event == .finished {
            return true
        }
        emit(event)
        return false
    }

    /// Checks the URL and the key with the lightest authenticated request: one session from
    /// `GET {baseURL}/api/sessions?limit=1`. Unlike `healthCheck()`, a wrong key fails (`unauthorized`), and
    /// it proves the endpoint the app relies on answers. Throws `HermesAPIError`; cancellation throws
    /// `CancellationError`.
    public func checkConnection() async throws {
        _ = try await listSessions(limit: 1)
    }

    /// Checks that the instance answers at `HermesAPIPaths.health`. Hermes answers it without checking the key:
    /// use `checkConnection()` to check the key too.
    ///
    /// Succeeds only for a 2xx response that was not redirected and has a JSON object body. A redirect
    /// (for example an access gate sending the request to `/login`) and a non-JSON body are errors.
    /// Throws `HermesAPIError`; cancellation throws `CancellationError`.
    public func healthCheck() async throws {
        do {
            let request = makeRequest(method: "GET", path: HermesAPIPaths.health, accept: "application/json")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw HermesAPIError.invalidResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// Lists the model IDs from `GET {baseURL}/v1/models`.
    ///
    /// A failed listing is not an error: any HTTP, network, timeout or contract failure returns
    /// `.fallback` with the reason, so that the user can type a model name by hand.
    /// Only cancellation throws (`CancellationError`).
    public func listModels() async throws -> ModelListResult {
        do {
            let request = makeRequest(method: "GET", path: HermesAPIPaths.models, accept: "application/json")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            let ids = list.data.map(\.id)
            guard !ids.isEmpty else {
                return .fallback(.invalidResponse)
            }
            return .models(ids)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .fallback(HermesAPIError.from(error))
        }
    }

    /// Fetches one page of sessions from `GET {baseURL}/api/sessions`, most recently active first.
    ///
    /// `limit` is clamped to the 1...200 range the instance accepts. Unlike `listModels()`, a failure
    /// is thrown: the conversation list has no fallback. Cancellation throws `CancellationError`.
    public func listSessions(limit: Int = 50, offset: Int = 0) async throws -> SessionPage {
        do {
            let query = [
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
                URLQueryItem(name: "offset", value: String(max(offset, 0))),
            ]
            let request = makeRequest(
                method: "GET", path: HermesAPIPaths.sessions, accept: "application/json", query: query
            )
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            let body = try JSONDecoder().decode(SessionListBody.self, from: data)
            return SessionPage(sessions: body.data, hasMore: body.hasMore)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// Fetches one page of a session's messages, from `GET {baseURL}/api/sessions/{id}/messages`.
    ///
    /// Paging starts from the newest message: `offset` 0 is the last message, and each larger offset goes back
    /// in time. The page itself is in chronological order, oldest first. `limit` is clamped to 1...500, the
    /// maximum the instance accepts; `offset` to 0 or more. `hasMore` is true when the page was full. Failures are thrown, as for `listSessions(limit:offset:)`.
    public func listSessionMessages(sessionID: String, limit: Int = 200, offset: Int = 0) async throws -> SessionMessagesPage {
        do {
            // The id goes into the path as is: it must be a single segment.
            guard !sessionID.isEmpty, !sessionID.contains("/") else {
                throw HermesAPIError.invalidResponse
            }
            let pageLimit = min(max(limit, 1), 500)
            let query = [
                URLQueryItem(name: "limit", value: String(pageLimit)),
                URLQueryItem(name: "offset", value: String(max(offset, 0))),
                URLQueryItem(name: "order", value: "latest"),
            ]
            let request = makeRequest(
                method: "GET",
                path: HermesAPIPaths.sessionMessages(sessionID),
                accept: "application/json",
                query: query
            )
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            let body = try JSONDecoder().decode(SessionMessagesBody.self, from: data)
            return SessionMessagesPage(
                sessionID: sessionID,
                messages: body.data,
                hasMore: body.returned == pageLimit
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// Copies a session into a new session owned by the API, from `POST {baseURL}/api/sessions/{id}/fork`,
    /// and returns the new session.
    ///
    /// The instance copies every message, gives the copy a title derived from the original, and ends
    /// the original as `branched`. Use it to continue a session the API may not write to (see
    /// `RemoteSession.acceptsAPIMessages`). The request is never retried automatically.
    public func forkSession(sessionID: String) async throws -> RemoteSession {
        do {
            // The id goes into the path as is: it must be a single segment.
            guard !sessionID.isEmpty, !sessionID.contains("/") else {
                throw HermesAPIError.invalidResponse
            }
            var request = makeRequest(
                method: "POST", path: HermesAPIPaths.sessionFork(sessionID), accept: "application/json"
            )
            request.httpBody = Data("{}".utf8)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            return try JSONDecoder().decode(SessionBody.self, from: data).session
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// Creates an empty session owned by the API, from `POST {baseURL}/api/sessions`, and returns it.
    ///
    /// With a `model`, the session is locked on it (and on `provider` when given): every turn runs on that
    /// model. Without one, the instance picks its default model. The request is never retried automatically.
    public func createSession(model: String? = nil, provider: String? = nil) async throws -> RemoteSession {
        try await sessionRequest(
            method: "POST",
            path: HermesAPIPaths.sessions,
            body: JSONEncoder().encode(SessionCreateRequest(model: model, provider: provider))
        )
    }

    /// Fetches one session, from `GET {baseURL}/api/sessions/{id}`. Used for a session a project names that
    /// the loaded pages do not hold. A session that is gone throws `HermesAPIError.notFound`.
    ///
    /// needs-verification: the body is read as `{"session": {...}}`, as `PATCH` answers, or as the bare session.
    public func getSession(sessionID: String) async throws -> RemoteSession {
        do {
            try Self.checkPathSegment(sessionID)
            let request = makeRequest(method: "GET", path: HermesAPIPaths.session(sessionID), accept: "application/json")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            if let body = try? JSONDecoder().decode(SessionBody.self, from: data) {
                return body.session
            }
            return try JSONDecoder().decode(RemoteSession.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// Renames a session, from `PATCH {baseURL}/api/sessions/{id}`, and returns the updated session.
    public func renameSession(sessionID: String, title: String) async throws -> RemoteSession {
        try Self.checkPathSegment(sessionID)
        return try await sessionRequest(
            method: "PATCH",
            path: HermesAPIPaths.session(sessionID),
            body: JSONEncoder().encode(SessionRenameRequest(title: title))
        )
    }

    /// Deletes a session and its messages, from `DELETE {baseURL}/api/sessions/{id}`.
    ///
    /// The instance refuses to delete a session while one of its turns runs (`409`).
    public func deleteSession(sessionID: String) async throws {
        do {
            try Self.checkPathSegment(sessionID)
            let request = makeRequest(
                method: "DELETE", path: HermesAPIPaths.session(sessionID), accept: "application/json"
            )
            let (_, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// Sends `body` as JSON and decodes the session the instance returns (`{"session": {...}}`).
    private func sessionRequest(method: String, path: String, body: Data) async throws -> RemoteSession {
        do {
            var request = makeRequest(method: method, path: path, accept: "application/json")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            return try JSONDecoder().decode(SessionBody.self, from: data).session
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// A session id goes into the path as is: it must be a single, non-empty segment.
    static func checkPathSegment(_ sessionID: String) throws {
        guard !sessionID.isEmpty, !sessionID.contains("/") else {
            throw HermesAPIError.invalidResponse
        }
    }

    /// Lists the provider catalog from `GET {baseURL}/api/model/options?include_unconfigured=false`:
    /// the models grouped by provider, as the dashboard's model picker shows them.
    ///
    /// Like `listModels()`, a failed listing is not an error: any HTTP, network, timeout or contract failure,
    /// or a catalog with no usable provider, returns `.fallback` with the reason. Only cancellation throws.
    public func listModelOptions() async throws -> ModelOptionsResult {
        do {
            let request = makeRequest(
                method: "GET",
                path: HermesAPIPaths.modelOptions,
                accept: "application/json",
                query: [URLQueryItem(name: "include_unconfigured", value: "false")]
            )
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, requestURL: request.url)
            let options = try JSONDecoder().decode(ModelOptionsPayload.self, from: data).options
            guard !options.providers.isEmpty else {
                return .fallback(.invalidResponse)
            }
            return .options(options)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .fallback(HermesAPIError.from(error))
        }
    }

    /// Builds an authenticated request to `{baseURL}{path}`, with the Bearer header and the client timeout.
    func makeRequest(
        method: String, path: String, accept: String, query: [URLQueryItem] = []
    ) -> URLRequest {
        let relativePath = String(path.drop(while: { $0 == "/" }))
        var url = configuration.baseURL.appending(path: relativePath)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        if method == "POST" || method == "PATCH" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Rejects non-2xx statuses, and any response whose final URL differs from the request URL
    /// (a redirect, for example to an access gate's `/login` page), so that it never counts as a success.
    static func validate(_ response: URLResponse, requestURL: URL?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HermesAPIError.invalidResponse
        }
        if let error = HermesAPIError.from(status: http.statusCode) {
            throw error
        }
        guard http.url == requestURL else {
            throw HermesAPIError.invalidResponse
        }
    }
}

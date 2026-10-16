import Foundation

/// JSON value used at the Dashboard boundary. The typed representation keeps
/// untrusted JSON from leaking as Foundation Any values across actor boundaries.
public enum DashboardJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DashboardJSONValue])
    case object([String: DashboardJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DashboardJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DashboardJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public init(_ value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Int64:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(DashboardJSONValue.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(DashboardJSONValue.init))
        default:
            self = .null
        }
    }

    public var objectValue: [String: DashboardJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [DashboardJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    public subscript(_ key: String) -> DashboardJSONValue? {
        objectValue?[key]
    }

    public var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        }
    }
}

public struct DashboardConnectionConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var username: String?
    public var password: String?
    public var profile: String?

    public init(baseURL: String, username: String? = nil, password: String? = nil, profile: String? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.profile = profile
    }
}

public struct DashboardRPCError: Error, LocalizedError, Sendable, Equatable {
    public let code: Int?
    public let message: String

    public init(code: Int?, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum DashboardGatewayEvent: Sendable {
    case event(DashboardJSONValue)
    case serverRequest(id: String, method: String, params: DashboardJSONValue)
    case disconnected(String)
}

/// The session identity fields are intentionally separate. Runtime IDs route
/// live Gateway calls; stored IDs are the durable keys used for history and
/// opening the same conversation after a Gateway restart.
public struct DashboardSessionIdentity: Sendable, Equatable {
    public let runtimeSessionID: String
    public let storedSessionID: String?
    public let profile: String?

    public init(runtimeSessionID: String, storedSessionID: String?, profile: String?) {
        self.runtimeSessionID = runtimeSessionID
        self.storedSessionID = storedSessionID
        self.profile = profile
    }
}

public struct DashboardSessionResume: Sendable {
    public let identity: DashboardSessionIdentity
    public let isRunning: Bool?
    public let messages: [DashboardJSONValue]
    public let rawResponse: DashboardJSONValue
}

public struct DashboardTranscriptPage: Sendable {
    public let sessionID: String
    public let messages: [DashboardJSONValue]
    public let limit: Int
    public let offset: Int
    public let order: String?
    public let hasMoreOlderMessages: Bool
}

/// Native Hermes Dashboard transport. It owns an isolated cookie jar, obtains
/// a fresh single-use WebSocket ticket, correlates JSON-RPC requests and reads
/// persisted transcripts through the Dashboard REST API instead of SSH/SQLite.
public actor DashboardGatewayClient {
    private struct PendingRPC {
        let continuation: CheckedContinuation<DashboardJSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let configuration: DashboardConnectionConfiguration
    private let cookieStorage: HTTPCookieStorage
    private let urlSession: URLSession
    private let eventStream: AsyncStream<DashboardGatewayEvent>
    private let eventContinuation: AsyncStream<DashboardGatewayEvent>.Continuation

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [Int: PendingRPC] = [:]
    private var nextRequestID = 1
    private var closing = false

    public init(configuration: DashboardConnectionConfiguration) {
        self.configuration = configuration
        let storage = HTTPCookieStorage()
        self.cookieStorage = storage

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = storage
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: sessionConfiguration)

        let pair = AsyncStream<DashboardGatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        eventContinuation.finish()
    }

    public var events: AsyncStream<DashboardGatewayEvent> { eventStream }
    public var isConnected: Bool { socket != nil && !closing }

    /// Login is optional for intentionally anonymous dashboards. On a protected
    /// dashboard, ticket issuance fails with the original HTTP status and a
    /// useful error instead of failing later as an opaque WebSocket handshake.
    public func connect() async throws {
        if socket != nil { return }
        closing = false
        try validateBaseURL()

        if let username = configuration.username, !username.isEmpty,
           let password = configuration.password, !password.isEmpty {
            try await passwordLogin(username: username, password: password)
        }

        let ticketURL = try endpointURL(path: "/api/auth/ws-ticket")
        var ticketRequest = URLRequest(url: ticketURL)
        ticketRequest.httpMethod = "POST"
        ticketRequest.timeoutInterval = 20
        if let cookies = cookieStorage.cookies(for: ticketURL), !cookies.isEmpty {
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                ticketRequest.setValue(value, forHTTPHeaderField: field)
            }
        }

        let (ticketData, ticketResponse) = try await urlSession.data(for: ticketRequest)
        guard let ticketHTTP = ticketResponse as? HTTPURLResponse else {
            throw DashboardRPCError(code: nil, message: "Dashboard ticket endpoint returned no HTTP response.")
        }
        guard (200..<300).contains(ticketHTTP.statusCode) else {
            let detail = Self.responseDetail(ticketData)
            let message = ticketHTTP.statusCode == 401 || ticketHTTP.statusCode == 403
                ? "Dashboard authentication required. Enter the Dashboard username and password."
                : "Dashboard ticket request failed (HTTP \(ticketHTTP.statusCode))\(detail.map { ": \($0)" } ?? "")."
            throw DashboardRPCError(code: ticketHTTP.statusCode, message: message)
        }
        let ticketObject = (try? JSONSerialization.jsonObject(with: ticketData)) as? [String: Any]
        guard let ticket = ticketObject?["ticket"] as? String, !ticket.isEmpty else {
            throw DashboardRPCError(code: nil, message: "Dashboard ticket response did not contain a ticket.")
        }

        let webSocketURL = try endpointURL(
            path: "/api/ws",
            webSocket: true,
            queryItems: [URLQueryItem(name: "ticket", value: ticket)]
        )
        var request = URLRequest(url: webSocketURL)
        request.setValue("scarf", forHTTPHeaderField: "X-Hermes-Client")
        let webSocket = urlSession.webSocketTask(with: request)
        socket = webSocket
        webSocket.resume()
        receiveTask = Task { [weak self, weak webSocket] in
            guard let self, let webSocket else { return }
            await self.receiveLoop(webSocket)
        }

        do {
            _ = try await rpc("ping", params: [:], timeout: 8, sendEmptyParams: false)
        } catch let error as DashboardRPCError where error.code == -32601 {
            // Older Gateway without ping: its valid JSON-RPC error proves the
            // socket is alive and answering requests.
            return
        } catch {
            await disconnect(reason: "Dashboard handshake failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func disconnect(reason: String? = nil) async {
        closing = true
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAllPending(with: DashboardRPCError(code: nil, message: reason ?? "Dashboard connection closed."))
        if let reason { eventContinuation.yield(.disconnected(reason)) }
    }

    public func rpc(
        _ method: String,
        params: [String: DashboardJSONValue] = [:],
        timeout: TimeInterval = 30,
        sendEmptyParams: Bool = true
    ) async throws -> DashboardJSONValue {
        guard let socket, !closing else {
            throw DashboardRPCError(code: nil, message: "Dashboard WebSocket is not connected.")
        }
        let requestID = nextRequestID
        nextRequestID += 1

        var request: [String: DashboardJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(requestID)),
            "method": .string(method)
        ]
        if !params.isEmpty || sendEmptyParams {
            request["params"] = .object(params)
        }
        let data = try JSONEncoder().encode(DashboardJSONValue.object(request))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DashboardRPCError(code: nil, message: "Could not encode Dashboard RPC request.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            var call = PendingRPC(continuation: continuation, timeoutTask: nil)
            call.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, timeout)))
                guard !Task.isCancelled else { return }
                await self?.expirePending(id: requestID, method: method)
            }
            pending[requestID] = call
            Task { [weak self, weak socket] in
                guard let self, let socket else { return }
                do {
                    try await socket.send(.string(text))
                } catch {
                    await self.failPending(id: requestID, error: error)
                }
            }
        }
    }

    public func notify(_ method: String, params: [String: DashboardJSONValue] = [:]) async throws {
        guard let socket, !closing else {
            throw DashboardRPCError(code: nil, message: "Dashboard WebSocket is not connected.")
        }
        var frame: [String: DashboardJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]
        if !params.isEmpty { frame["params"] = .object(params) }
        let data = try JSONEncoder().encode(DashboardJSONValue.object(frame))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DashboardRPCError(code: nil, message: "Could not encode Dashboard notification.")
        }
        try await socket.send(.string(text))
    }

    /// Answer a Gateway-initiated request using its string ID. Sending a new
    /// client request here is not equivalent and would leave the agent waiting.
    public func answerServerRequest(
        id: String,
        result: DashboardJSONValue? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil
    ) async throws {
        guard let socket, !closing else {
            throw DashboardRPCError(code: nil, message: "Dashboard WebSocket is not connected.")
        }
        var frame: [String: DashboardJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string(id)
        ]
        if let result {
            frame["result"] = result
        } else if let errorCode, let errorMessage {
            frame["error"] = .object([
                "code": .number(Double(errorCode)),
                "message": .string(errorMessage)
            ])
        } else {
            frame["result"] = .object([:])
        }
        let data = try JSONEncoder().encode(DashboardJSONValue.object(frame))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DashboardRPCError(code: nil, message: "Could not encode Dashboard server response.")
        }
        try await socket.send(.string(text))
    }

    public func createSession(
        cwd: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        profile: String? = nil
    ) async throws -> DashboardSessionIdentity {
        var params: [String: DashboardJSONValue] = [
            "cols": .number(96),
            "source": .string("desktop")
        ]
        let selectedProfile = normalizedProfile(profile)
        if let selectedProfile { params["profile"] = .string(selectedProfile) }
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["cwd"] = .string(cwd)
        }
        if let model, !model.isEmpty {
            params["model"] = .string(model)
            if let provider, !provider.isEmpty { params["provider"] = .string(provider) }
        }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        guard let runtimeID = object["session_id"]?.stringValue, !runtimeID.isEmpty else {
            throw DashboardRPCError(code: nil, message: "session.create did not return a runtime session_id.")
        }
        return DashboardSessionIdentity(
            runtimeSessionID: runtimeID,
            storedSessionID: Self.firstNonEmptyString(object, keys: ["stored_session_id", "storedSessionId", "session_key"]),
            profile: Self.firstNonEmptyString(object, keys: ["profile", "profile_id"]) ?? selectedProfile
        )
    }

    public func resumeSession(
        storedSessionID: String,
        includeMessages: Bool = false,
        profile: String? = nil
    ) async throws -> DashboardSessionResume {
        guard !storedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DashboardRPCError(code: nil, message: "A stored session ID is required to resume a conversation.")
        }
        var params: [String: DashboardJSONValue] = [
            "session_id": .string(storedSessionID),
            "cols": .number(96),
            "source": .string("desktop")
        ]
        if !includeMessages { params["omit_messages"] = .bool(true) }
        if let selectedProfile = normalizedProfile(profile) {
            params["profile"] = .string(selectedProfile)
        }
        let result = try await rpc("session.resume", params: params, timeout: includeMessages ? 90 : 30)
        let object = result.objectValue ?? [:]
        let runtimeID = Self.firstNonEmptyString(object, keys: ["session_id"]) ?? storedSessionID
        let returnedStoredID = Self.firstNonEmptyString(object, keys: ["stored_session_id", "storedSessionId", "session_key"])
        if let returnedStoredID, returnedStoredID != storedSessionID {
            throw DashboardRPCError(
                code: 4001,
                message: "Dashboard resolved a different stored session (\(returnedStoredID)) than requested (\(storedSessionID))."
            )
        }
        let info = object["info"]?.objectValue ?? [:]
        let running = object["running"]?.boolValue ?? info["running"]?.boolValue
        return DashboardSessionResume(
            identity: DashboardSessionIdentity(
                runtimeSessionID: runtimeID,
                storedSessionID: returnedStoredID ?? storedSessionID,
                profile: Self.firstNonEmptyString(object, keys: ["profile", "profile_id"]) ?? normalizedProfile(profile)
            ),
            isRunning: running,
            messages: object["messages"]?.arrayValue ?? [],
            rawResponse: result
        )
    }

    public func submitPrompt(runtimeSessionID: String, text: String, surface: String? = nil) async throws -> String? {
        var params: [String: DashboardJSONValue] = [
            "session_id": .string(runtimeSessionID),
            "text": .string(text)
        ]
        if let surface, !surface.isEmpty { params["surface"] = .string(surface) }
        let result = try await rpc("prompt.submit", params: params, timeout: 45)
        return result.objectValue?["status"]?.stringValue
    }

    public func fetchSidebarSessions(profile: String? = nil, recentsLimit: Int = 50) async throws -> [DashboardJSONValue] {
        let selectedProfile = normalizedProfile(profile) ?? "default"
        let result = try await requestJSON(
            path: "/api/profiles/sessions/sidebar",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "recents_profile", value: selectedProfile),
                URLQueryItem(name: "recents_limit", value: String(max(1, recentsLimit))),
                URLQueryItem(name: "cron_limit", value: "1"),
                URLQueryItem(name: "messaging_limit", value: "1")
            ],
            timeout: 45
        )
        guard let object = result.objectValue,
              let recents = object["recents"]?.objectValue,
              let sessions = recents["sessions"]?.arrayValue else {
            throw DashboardRPCError(code: nil, message: "Dashboard sidebar response did not contain recents.sessions.")
        }
        return sessions
    }

    public func fetchTranscriptPage(
        storedSessionID: String,
        limit: Int = 120,
        offset: Int = 0,
        includeCompacted: Bool = true,
        profile: String? = nil
    ) async throws -> DashboardTranscriptPage {
        guard !storedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DashboardRPCError(code: nil, message: "A stored session ID is required for transcript history.")
        }
        var queryItems = [
            URLQueryItem(name: "limit", value: String(max(1, limit))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "include_compacted", value: includeCompacted ? "true" : "false")
        ]
        if let selectedProfile = normalizedProfile(profile) {
            queryItems.append(URLQueryItem(name: "profile", value: selectedProfile))
        }
        let encodedID = storedSessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? storedSessionID
        let response = try await requestJSON(
            path: "/api/sessions/\(encodedID)/messages",
            method: "GET",
            queryItems: queryItems,
            timeout: 60
        )
        let object = response.objectValue ?? [:]
        let messages = object["messages"]?.arrayValue ?? response.arrayValue ?? []
        let pagination = object["pagination"]?.objectValue
        let order = pagination?["order"]?.stringValue
        let pageLimit = pagination?["limit"]?.intValue ?? max(1, limit)
        let resolvedID = Self.firstNonEmptyString(object, keys: ["session_id"]) ?? storedSessionID
        guard resolvedID == storedSessionID else {
            throw DashboardRPCError(
                code: 4001,
                message: "Dashboard returned history for a different stored session (\(resolvedID))."
            )
        }
        return DashboardTranscriptPage(
            sessionID: resolvedID,
            messages: messages,
            limit: pageLimit,
            offset: max(0, offset),
            order: order,
            hasMoreOlderMessages: order == "latest" && messages.count >= pageLimit
        )
    }

    public func requestJSON(path: String, method: String = "GET", queryItems: [URLQueryItem] = [], timeout: TimeInterval = 30) async throws -> DashboardJSONValue {
        var url = try endpointURL(path: path)
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw DashboardRPCError(code: nil, message: "Invalid Dashboard API URL.")
            }
            components.queryItems = queryItems
            guard let builtURL = components.url else {
                throw DashboardRPCError(code: nil, message: "Invalid Dashboard API URL.")
            }
            url = builtURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardRPCError(code: nil, message: "Dashboard API returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DashboardRPCError(
                code: http.statusCode,
                message: "Dashboard API \(path) failed (HTTP \(http.statusCode))\(Self.responseDetail(data).map { ": \($0)" } ?? "")."
            )
        }
        do {
            return try JSONDecoder().decode(DashboardJSONValue.self, from: data)
        } catch {
            throw DashboardRPCError(code: nil, message: "Dashboard API \(path) returned invalid JSON.")
        }
    }

    private func receiveLoop(_ receivingSocket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await receivingSocket.receive()
                guard socket === receivingSocket, !closing else { break }
                let data: Data
                switch message {
                case .data(let incoming):
                    data = incoming
                case .string(let incoming):
                    data = Data(incoming.utf8)
                @unknown default:
                    continue
                }
                handleFrame(data)
            }
        } catch {
            guard socket === receivingSocket, !closing else { return }
            socket = nil
            failAllPending(with: DashboardRPCError(code: nil, message: "Dashboard WebSocket disconnected: \(error.localizedDescription)"))
            eventContinuation.yield(.disconnected(error.localizedDescription))
        }
    }

    private func handleFrame(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(DashboardJSONValue.self, from: data),
              let object = frame.objectValue else {
            return
        }
        if object["method"]?.stringValue == "event", let params = object["params"] {
            eventContinuation.yield(.event(params))
            return
        }
        if let method = object["method"]?.stringValue, let idValue = object["id"] {
            if let requestID = idValue.stringValue {
                eventContinuation.yield(.serverRequest(
                    id: requestID,
                    method: method,
                    params: object["params"] ?? .object([:])
                ))
            }
            return
        }
        guard let requestID = object["id"]?.intValue,
              let call = pending.removeValue(forKey: requestID) else { return }
        call.timeoutTask?.cancel()
        if let errorObject = object["error"]?.objectValue {
            call.continuation.resume(throwing: DashboardRPCError(
                code: errorObject["code"]?.intValue,
                message: errorObject["message"]?.stringValue ?? "Dashboard RPC failed."
            ))
        } else {
            call.continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func expirePending(id: Int, method: String) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.continuation.resume(throwing: DashboardRPCError(code: nil, message: "Dashboard RPC timed out: \(method)"))
    }

    private func failPending(id: Int, error: Error) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeoutTask?.cancel()
        call.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let calls = Array(pending.values)
        pending.removeAll()
        for call in calls {
            call.timeoutTask?.cancel()
            call.continuation.resume(throwing: error)
        }
    }

    private func passwordLogin(username: String, password: String) async throws {
        let url = try endpointURL(path: "/auth/password-login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "basic",
            "username": username,
            "password": password
        ])
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardRPCError(code: nil, message: "Dashboard login returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DashboardRPCError(
                code: http.statusCode,
                message: "Dashboard password login failed (HTTP \(http.statusCode))\(Self.responseDetail(data).map { ": \($0)" } ?? "")."
            )
        }
    }

    private func endpointURL(
        path: String,
        webSocket: Bool = false,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw DashboardRPCError(code: nil, message: "Dashboard URL must be an HTTP(S) base URL without embedded credentials or query parameters.")
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        if webSocket {
            components.scheme = scheme == "https" ? "wss" : "ws"
        }
        guard let url = components.url else {
            throw DashboardRPCError(code: nil, message: "Could not construct Dashboard endpoint URL.")
        }
        return url
    }

    private func validateBaseURL() throws {
        _ = try endpointURL(path: "/")
    }

    private func normalizedProfile(_ candidate: String?) -> String? {
        let value = candidate ?? configuration.profile ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmptyString(_ object: [String: DashboardJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key]?.stringValue else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func responseDetail(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["detail"] as? String) ?? (object["message"] as? String) ?? (object["error"] as? String)
    }
}

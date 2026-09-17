import Foundation
import CryptoKit
import Domain

public struct RelayHTTPError: LocalizedError {
    public let status: Int
    public var errorDescription: String? { "中继请求失败（HTTP \(status)）" }
}

public struct RelayEpochChanged: LocalizedError {
    public var errorDescription: String? { "配对身份已失效，请检查连接状态。" }
}

private final class NoRelayRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One device's authenticated HTTP connection. Private authentication keys never leave the device.
public actor HTTPRelay: RelayTransport {
    public let baseURL: URL
    private let deviceID: UUID
    private let epoch: UInt64
    private let key: P256.Signing.PrivateKey
    private let session: URLSession
    public init(baseURL: URL, deviceID: UUID, epoch: UInt64 = 1, authKey: Data) throws {
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(baseURL.host ?? "")),
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else { throw SpaceError.invalidInput }
        self.baseURL = baseURL; self.deviceID = deviceID; self.epoch = epoch
        self.key = try P256.Signing.PrivateKey(rawRepresentation: authKey)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config, delegate: NoRelayRedirects(), delegateQueue: nil)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public func request(_ path: String, method: String = "POST", body: Data = Data(), authenticated: Bool = true, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if authenticated {
            struct Challenge: Decodable { let nonce: String; let epoch: UInt64 }
            let bytes = try await self.request("/v1/auth/challenges", body: Self.encode(["deviceID": deviceID.uuidString]), authenticated: false)
            let challenge = try JSONDecoder().decode(Challenge.self, from: bytes)
            guard challenge.epoch == epoch else { throw RelayEpochChanged() }
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let canonical: [Any] = ["couple-api-v1", challenge.nonce, method, path, hash, epoch, deviceID.uuidString]
            let signed = try JSONSerialization.data(withJSONObject: canonical, options: [.withoutEscapingSlashes])
            request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Device-ID")
            request.setValue(challenge.nonce, forHTTPHeaderField: "X-Challenge")
            request.setValue(try key.signature(for: signed).rawRepresentation.base64EncodedString(), forHTTPHeaderField: "X-Signature")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpaceError.invalidEnvelope }
        guard (200..<300).contains(response.statusCode) else { throw RelayHTTPError(status: response.statusCode) }
        guard data.count <= 600_000 else { throw SpaceError.capacity }
        return data
    }
    /// The media socket uses the same one-use signed challenge as ordinary relay requests.
    public func openMediaSocket() async throws -> URLSessionWebSocketTask {
        struct Challenge: Decodable { let nonce: String; let epoch: UInt64 }
        let bytes = try await request("/v1/auth/challenges",
                                      body: Self.encode(["deviceID": deviceID.uuidString]), authenticated: false)
        let challenge = try JSONDecoder().decode(Challenge.self, from: bytes)
        guard challenge.epoch == epoch else { throw RelayEpochChanged() }
        let path = "/v1/media/socket"
        let hash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let signed = try JSONSerialization.data(withJSONObject:
            ["couple-api-v1", challenge.nonce, "GET", path, hash, epoch, deviceID.uuidString] as [Any],
            options: [.withoutEscapingSlashes])
        var components = URLComponents(url: URL(string: path, relativeTo: baseURL)!.absoluteURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw SpaceError.invalidInput }
        var socketRequest = URLRequest(url: url)
        socketRequest.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Device-ID")
        socketRequest.setValue(challenge.nonce, forHTTPHeaderField: "X-Challenge")
        socketRequest.setValue(try key.signature(for: signed).rawRepresentation.base64EncodedString(),
                               forHTTPHeaderField: "X-Signature")
        let task = session.webSocketTask(with: socketRequest)
        task.maximumMessageSize = 2_001_000
        task.resume()
        return task
    }
    public func put(_ envelope: Envelope, now: Date) async throws {
        try envelope.validate()
        guard envelope.sender == deviceID else { throw SpaceError.unauthorized }
        _ = try await request("/v1/mailbox/" + envelope.id.uuidString, method: "PUT", body: Self.encode(envelope))
    }
    public func fetch(recipient: UUID, now: Date) async throws -> [Envelope] {
        guard recipient == deviceID else { throw SpaceError.unauthorized }
        struct Page: Decodable { let envelopes: [Envelope] }
        return try JSONDecoder().decode(Page.self, from: await request("/v1/mailbox?limit=50", method: "GET")).envelopes
    }
    public func acknowledge(recipient: UUID, ids: [UUID]) async throws {
        guard recipient == deviceID else { throw SpaceError.unauthorized }
        _ = try await request("/v1/mailbox/ack", body: Self.encode(["ids": ids.map(\.uuidString)]))
    }
}

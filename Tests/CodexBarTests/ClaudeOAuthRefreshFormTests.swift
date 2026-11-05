import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthRefreshFormTests {
    @Test(arguments: ["", "+&=%2B /東京"])
    func refreshPreservesOpaqueToken(suffix: String) async throws {
        let refreshToken = "refresh-before-rotation\(suffix)"
        let registered = URLProtocol.registerClass(ClaudeRefreshFormURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(ClaudeRefreshFormURLProtocol.self) }
            ClaudeRefreshFormURLProtocol.handler = nil
        }
        ClaudeRefreshFormURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let body: Data
            if let data = request.httpBody {
                body = data
            } else {
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            let fields = try FormBodyTestSupport.decode(body)
            #expect(Set(fields.keys) == ["grant_type", "refresh_token", "client_id"])
            #expect(fields["grant_type"] == "refresh_token")
            #expect(fields["refresh_token"] == refreshToken)
            #expect(fields["client_id"]?.isEmpty == false)
            let url = try #require(request.url)
            return try #require(HTTPURLResponse(
                url: url, statusCode: 599, httpVersion: nil, headerFields: nil))
        }
        // Reject after inspecting the request so this check cannot write refreshed credentials.
        await ClaudeOAuthRefreshFailureGate.$shouldAttemptOverride.withValue(true) {
            do {
                _ = try await ClaudeOAuthCredentialsStore.refreshAccessToken(
                    refreshToken: refreshToken, existingScopes: ["user:profile"], existingRateLimitTier: nil)
                Issue.record("Expected the stub refresh rejection")
            } catch let ClaudeOAuthCredentialsError.refreshFailed(message) {
                #expect(message == "HTTP 599")
            } catch {
                Issue.record("Unexpected refresh error: \(error)")
            }
        }
    }
}

private final class ClaudeRefreshFormURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> HTTPURLResponse)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.claude.com" && request.url?.path == "/v1/oauth/token"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            self.client?.urlProtocol(self, didReceive: try handler(self.request), cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data())
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

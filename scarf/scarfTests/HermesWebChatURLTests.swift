import Foundation
import Testing
@testable import scarf

@Suite("Hermes direct Web Chat URL")
struct HermesWebChatURLTests {
    @Test("appends the chat route to a host root")
    func appendsChatAtRoot() {
        #expect(
            HermesWebChatURL.chatURL(from: "https://hermes.example.com")?.absoluteString
                == "https://hermes.example.com/chat"
        )
    }

    @Test("preserves a reverse proxy path prefix")
    func preservesReverseProxyPrefix() {
        #expect(
            HermesWebChatURL.chatURL(from: "https://example.net/hermes/")?.absoluteString
                == "https://example.net/hermes/chat"
        )
    }

    @Test("does not duplicate an existing chat route")
    func existingChatRoute() {
        #expect(
            HermesWebChatURL.chatURL(from: "https://hermes.example.com/chat")?.absoluteString
                == "https://hermes.example.com/chat"
        )
    }

    @Test("rejects query tokens, embedded credentials, and non-web schemes")
    func rejectsCredentialsAndNonWebSchemes() {
        #expect(HermesWebChatURL.chatURL(from: "https://hermes.example.com/?token=secret") == nil)
        #expect(HermesWebChatURL.chatURL(from: "https://alice:secret@hermes.example.com") == nil)
        #expect(HermesWebChatURL.chatURL(from: "http://127.0.0.1:53141") == nil)
        #expect(HermesWebChatURL.chatURL(from: "http://localhost:9119") == nil)
        #expect(HermesWebChatURL.chatURL(from: "ssh://hermes.example.com") == nil)
        #expect(HermesWebChatURL.chatURL(from: "https://") == nil)
    }
}

import AppKit
import SwiftUI
import WebKit

/// Turns a directly reachable Hermes Dashboard base URL into its `/chat`
/// route. A base path is preserved for reverse proxies such as
/// `https://example.net/hermes`; the caller must not include query strings
/// or credentials because authentication belongs to Hermes's own login UI.
enum HermesWebChatURL {
    static func chatURL(from rawValue: String) -> URL? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              !Self.isLoopbackHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/chat"
        } else if path == "chat" || path.hasSuffix("/chat") {
            components.path = "/" + path
        } else {
            components.path = "/" + path + "/chat"
        }
        return components.url
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host.hasPrefix("127.")
            || host == "0.0.0.0"
    }
}

/// Displays Hermes's own chat web client in Scarf. That client authenticates
/// through the configured Dashboard login flow and speaks the Dashboard's
/// WebSocket protocol directly; Scarf does not spawn `hermes acp`, start a
/// Dashboard process, or create a loopback/SSH port-forward.
struct RemoteHermesChatView: View {
    let configuredBaseURL: String
    @State private var reloadToken = 0

    private var endpoint: URL? {
        HermesWebChatURL.chatURL(from: configuredBaseURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Hermes Web Chat", systemImage: "network")
                    .font(.headline)
                Spacer()
                if let endpoint {
                    Text(endpoint.host ?? endpoint.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Open in Browser") {
                        NSWorkspace.shared.open(endpoint)
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    reloadToken &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload Hermes Web Chat")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let endpoint {
                HermesDashboardWebView(url: endpoint, reloadToken: reloadToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("chat.hermesWeb")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "link.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Invalid Hermes Web URL")
                        .font(.headline)
                    Text("Set a base URL such as https://hermes.example.com in Manage Servers. Do not include /login, a query string, or a token.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Text(configuredBaseURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HermesDashboardWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Default store keeps Hermes's login cookies across section changes
        // and app launches, like its normal browser UI.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.loadedURL = url
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
        } else if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var lastReloadToken = 0

        // Hermes can open login or consent links with target=_blank. Keep the
        // navigation in this authenticated WebKit view so cookies remain
        // available to the Dashboard's WebSocket handshake.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            webView.load(navigationAction.request)
            return nil
        }
    }
}

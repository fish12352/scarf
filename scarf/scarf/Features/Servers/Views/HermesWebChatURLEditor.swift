import SwiftUI
import ScarfCore
import ScarfDesign

/// Edits only the direct Dashboard URL. SSH host/key settings remain untouched.
struct HermesWebChatURLEditor: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    let context: ServerContext
    @State private var webURL: String

    init(context: ServerContext) {
        self.context = context
        let initial = context.hermesWebURL ?? ""
        _webURL = State(initialValue: initial)
    }

    private var trimmedURL: String {
        webURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        trimmedURL.isEmpty || HermesWebChatURL.chatURL(from: trimmedURL) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes Web Chat")
                        .font(.headline)
                    Text(context.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Enter a Dashboard address this Mac can reach directly. Scarf opens its /chat page, which uses Hermes's WebSocket session protocol and login flow. This is independent of the SSH connection used by the rest of Scarf.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://hermes.example.com", text: $webURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            Text("Use HTTPS where possible. The Dashboard must already be running and reachable through LAN, Tailscale, or a configured reverse proxy. Scarf does not create an SSH tunnel or expose a new listener.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Disable Web Chat") { save(nil) }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(trimmedURL.isEmpty ? nil : trimmedURL) }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520, height: 300)
    }

    private func save(_ value: String?) {
        guard case .ssh(var config) = context.kind else { return }
        config.hermesWebURL = value
        registry.updateServer(context.id, displayName: nil, config: config)
        dismiss()
    }
}

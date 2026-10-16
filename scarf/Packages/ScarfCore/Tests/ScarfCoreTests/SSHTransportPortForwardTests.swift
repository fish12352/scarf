import Foundation
import Testing
@testable import ScarfCore

#if !os(iOS)
@Suite struct SSHTransportPortForwardTests {
    @Test func buildsManagedLoopbackForwardWithSavedSSHConfig() throws {
        let transport = SSHTransport(
            contextID: ServerID(),
            config: SSHConfig(
                host: "example.test",
                user: "alice",
                port: 2222,
                identityFile: "/tmp/scarf-test-ed25519"
            ),
            displayName: "Forward test"
        )
        let process = try transport.makeLoopbackPortForwardProcess(localPort: 19119, remotePort: 9119)
        let args = process.arguments ?? []

        #expect(process.executableURL?.path == "/usr/bin/ssh")
        #expect(args.last == "alice@example.test")
        #expect(args.contains("-p"))
        #expect(args.contains("2222"))
        #expect(args.contains("-i"))
        #expect(args.contains("/tmp/scarf-test-ed25519"))
        #expect(args.contains("-N"))
        #expect(args.contains("-T"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("ControlMaster=no"))
        #expect(args.contains("ControlPath=none"))
        #expect(args.contains("ControlPersist=no"))
        #expect(!args.contains(where: { $0.hasPrefix("ControlPath=/tmp/scarf-ssh-") }))
        #expect(args.contains("-L"))
        #expect(args.contains("127.0.0.1:19119:127.0.0.1:9119"))
        #expect(!args.contains("0.0.0.0"))
        #expect(!args.contains("-g"))
        #expect(!args.contains("-f"))
    }

    @Test func rejectsInvalidLocalPort() {
        let transport = SSHTransport(contextID: ServerID(), config: SSHConfig(host: "example.test"), displayName: "Forward test")
        do {
            _ = try transport.makeLoopbackPortForwardProcess(localPort: 0, remotePort: 9119)
            Issue.record("Expected local port 0 to be rejected")
        } catch let error as SSHTransport.PortForwardError {
            #expect(error == .invalidLocalPort(0))
        } catch {
            Issue.record("Unexpected error")
        }
    }

    @Test func rejectsInvalidRemotePort() {
        let transport = SSHTransport(contextID: ServerID(), config: SSHConfig(host: "example.test"), displayName: "Forward test")
        do {
            _ = try transport.makeLoopbackPortForwardProcess(localPort: 19119, remotePort: 65536)
            Issue.record("Expected remote port 65536 to be rejected")
        } catch let error as SSHTransport.PortForwardError {
            #expect(error == .invalidRemotePort(65536))
        } catch {
            Issue.record("Unexpected error")
        }
    }
}
#endif

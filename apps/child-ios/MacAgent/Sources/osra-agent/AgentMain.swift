import Foundation
import OSRAMacAgentCore

/// The `osra-agent` binary: the launch daemon (`run`) and the root-only setup commands (`pair`, `status`,
/// `unpair`). One binary on purpose: the System keychain trusts the program that stored a secret, so the
/// command that pairs and the daemon that reads must be the same program.
@main
enum AgentMain {
    static func main() async {
        exit(await AgentCLI.main(Array(CommandLine.arguments.dropFirst())))
    }
}

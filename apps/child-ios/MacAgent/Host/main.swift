import Foundation
import SystemExtensions

/// The out-of-tree host for the Mac content filter (roadmap 5.9, step (iii), #988).
///
/// A system extension cannot be activated by itself. The system accepts an activation request only from an app
/// bundle that carries the extension in `Contents/Library/SystemExtensions/`, which is why this target exists:
/// it has no window and no menu, it submits the request and reports what the system said on stdout.
///
/// Run once as the Mac's administrator, after the bundle is signed with a Developer ID identity carrying
/// `com.apple.developer.networking.networkextension` = `content-filter-provider-systemextension`:
///
///     /Applications/OSRA.app/Contents/MacOS/OSRAMacHost activate
///
/// The system may then require the parent's approval in System Settings → Privacy & Security. Approval is a
/// person's action; nothing here can do it.
///
/// **Least-verified file in this PR.** It is compiled by the same Xcode build as the extension, which runs only
/// on a Mac with the identity, so no CI job has compiled it and I have not run it. Its API is
/// `SystemExtensions`' documented surface, and the device row is where it gets proven.
final class Activator: NSObject, OSSystemExtensionRequestDelegate {
    private let identifier = "com.osratech.agent.filter"

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionRequest.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForExtension identifier: String) -> OSSystemExtensionRequest.ReplacementAction {
        // The daemon writes the policy, the extension only reads it, so replacing a running extension loses
        // nothing: replace it rather than asking the parent to stop it first.
        print("replace: \(identifier)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("needs_approval: approve \(identifier) in System Settings → Privacy & Security")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("result: \(result == .completed ? "completed" : "will_complete_after_reboot")")
        exit(result == .completed ? 0 : 3)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        // The daemon's log is the place a parent's Mac records failures; this host only reports its own run.
        print("failed: \(error.localizedDescription)")
        exit(1)
    }
}

let activator = Activator()
activator.activate()
RunLoop.main.run()

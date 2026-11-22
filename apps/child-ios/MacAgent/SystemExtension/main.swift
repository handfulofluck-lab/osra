import Foundation
import NetworkExtension

/// The system extension's entry point (roadmap 5.9, step (iii), #988).
///
/// A Network Extension system extension is not an ordinary program: the system starts it as a provider, and the
/// process must hand control to NetworkExtension before it does anything else. `NEProvider.startSystemExtensionMode()`
/// installs the run loop the system talks to, which is why it is the whole of this file: every decision lives in
/// `OSRAMacAgentFilterProvider.FilterDataProvider`, and nothing here can be unit-tested because it only exists
/// inside a signed bundle the system loads.
///
/// `dispatchMain()` keeps the process parked if the system returns control instead of taking the run loop
/// itself — the failure it prevents is the extension exiting immediately and being restarted in a loop.
///
/// Built by `MacAgent/project.yml` (the `OSRAFilter` target), not by SwiftPM: a system extension has to be a
/// bundle with this entry point, which a Swift package cannot produce. The package target
/// `OSRAMacAgentFilterProvider` is the library this links against, and it is what the existing macOS job
/// compiles and tests.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()

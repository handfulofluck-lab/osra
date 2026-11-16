import Darwin
import Foundation
import FamilyShieldAgent

/// What this Mac says it is when it pairs. The parent reads the model and the name on the Allow / Deny screen.
public enum MacDevice {
    /// `hw.model`, for example "Mac14,2"; nil when the system does not say.
    public static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let model = String(cString: buffer)
        return model.isEmpty ? nil : model
    }

    /// "Mac (Mac14,2)", or "Mac" when the hardware model is unknown.
    public static func model(hardware: String? = hardwareModel()) -> String {
        guard let hardware, !hardware.isEmpty else { return "Mac" }
        return "Mac (\(hardware))"
    }

    public static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The computer's name as System Settings shows it; the parent can rename the device in the parent app.
    public static func computerName() -> String? {
        Host.current().localizedName
    }

    public static func claimDevice(report: MacCapabilityReport = MacCapabilityReport()) -> PairingClient.ClaimDevice {
        PairingClient.ClaimDevice(platform: "macos", model: model(), osVersion: osVersion(),
                                  capabilities: report.json, clientHeader: report.clientHeader)
    }
}

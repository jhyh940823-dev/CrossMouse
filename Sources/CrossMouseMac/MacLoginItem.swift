import AppKit
import ServiceManagement

/// Uses the system login-item API; never writes credentials, launches a
/// privileged daemon, or changes the user's login/security settings.
@MainActor
enum MacLoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Respect a disabled/pending item instead of unregister/register
            // loops that would repeatedly request consent at every launch.
            if status == .notRegistered || status == .notFound {
                try SMAppService.mainApp.register()
            }
            if status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    static func isBackgroundLaunch(
        arguments: [String], event: NSAppleEventDescriptor?
    ) -> Bool {
        if arguments.contains("--background") { return true }
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
    }

    /// Tests startup classification without registering a login item or
    /// reading the user's pairing key. Runs in CI as well as a local build.
    static func selfTest() -> Bool {
        let normal = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        guard !isBackgroundLaunch(arguments: [], event: nil),
              !isBackgroundLaunch(arguments: [], event: normal),
              isBackgroundLaunch(arguments: ["--background"], event: nil) else { return false }
        normal.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
                        forKeyword: keyAEPropData)
        guard isBackgroundLaunch(arguments: [], event: normal) else { return false }
        normal.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem),
                        forKeyword: keyAEPropData)
        return !isBackgroundLaunch(arguments: [], event: normal)
    }
}

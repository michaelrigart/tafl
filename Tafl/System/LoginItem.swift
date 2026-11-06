import ServiceManagement

enum LoginItem {
    static func apply(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .notRegistered): try service.register()
            case (false, .enabled), (false, .requiresApproval): try service.unregister()
            default: break
            }
        } catch {
            Log.app.notice("Launch at login not changed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

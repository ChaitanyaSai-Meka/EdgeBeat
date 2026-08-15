import Foundation

final class DisplaySleepController {
    private var activity: NSObjectProtocol?

    func setPrevented(_ prevented: Bool) {
        if prevented {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled],
                reason: "EdgeBeat is showing a playing track on the lock screen"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit {
        setPrevented(false)
    }
}

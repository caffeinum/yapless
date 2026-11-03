import Foundation

/// When the user's keypress became a process: the launcher's exec of yapless.
/// A detached child inherits its parent's time through the environment, so the
/// detach hop is counted too. Without this, a slow start can't be told apart
/// from a slow launcher.
let launchTime: Date = {
    if let raw = ProcessInfo.processInfo.environment["YAPLESS_LAUNCH_TIME"], let seconds = Double(raw) {
        return Date(timeIntervalSince1970: seconds)
    }
    return processStartTime()
}()

/// A hotkey launcher is a background app, and what it spawns can inherit
/// background scheduling: measured under load, a throttled start took ~3s to
/// the first audio buffer instead of ~1s. Someone is waiting to talk, so claim
/// foreground priority before doing anything else.
func raiseLaunchPriority() {
    let inherited = ProcessInfo.processInfo.environment["YAPLESS_LAUNCHED_BACKGROUND"] != nil
    if getpriority(PRIO_DARWIN_PROCESS, 0) != 0 {
        // Not fatal: a slow start still records, a crash records nothing.
        guard setpriority(PRIO_DARWIN_PROCESS, 0, 0) == 0 else {
            print("WARNING: launched with background priority and could not clear it (errno \(errno)) — start will be slow")
            return
        }
        setenv("YAPLESS_LAUNCHED_BACKGROUND", "1", 1)
        print("Launched with background priority — cleared")
    } else if inherited {
        print("Launcher started us with background priority — cleared before detaching")
    }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
}

private func processStartTime() -> Date {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
        fatalError("sysctl KERN_PROC_PID failed: errno \(errno)")
    }
    let start = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
}

/// strftime, not DateFormatter: the first DateFormatter loads ICU, 5-38ms
/// paid on the very first log line — i.e. on the way to opening the mic.
private func logClock(_ date: Date) -> String {
    var seconds = time_t(date.timeIntervalSince1970)
    var parts = tm()
    localtime_r(&seconds, &parts)
    var text = [CChar](repeating: 0, count: 16)
    strftime(&text, text.count, "%H:%M:%S", &parts)
    let millis = Int(date.timeIntervalSince1970 * 1000) % 1000
    return String(cString: text) + String(format: ".%03d", millis)
}

/// Every log line carries wall time and ms since launch, so a slow start can be
/// located in detached.log after the fact instead of reproduced.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let now = Date()
    let elapsed = Int(now.timeIntervalSince(launchTime) * 1000)
    let message = items.map { "\($0)" }.joined(separator: separator)
    Swift.print("\(logClock(now)) +\(elapsed)ms \(message)", terminator: terminator)
}

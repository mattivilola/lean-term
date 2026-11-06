// External launch observer; never instruments or rebuilds the installed app.
// Leaves the task-owned app running. Close it normally before the next trial.
import AppKit
import Quartz
import Foundation
let args = CommandLine.arguments
let split = args.firstIndex(of: "--") ?? args.count
let positional = Array(args[1..<split])
guard (2...3).contains(positional.count) else {
    fputs("Usage: window-launch OUTPUT_JSON WORKING_DIRECTORY [APP_PATH] [-- extra app args...]\n", stderr)
    exit(2)
}
let extraArguments = Array(args.dropFirst(split + 1))
let output = URL(fileURLWithPath: positional[0])
let appURL = URL(fileURLWithPath: positional.count == 3 ? positional[2] : "/Applications/Lean Term.app")
let config = NSWorkspace.OpenConfiguration()
config.createsNewApplicationInstance = true
let frame = try PropertyListSerialization.data(fromPropertyList: [200.0,100.0,988.0,726.0], format: .xml, options: 0)
config.arguments = ["--working-directory", positional[1], "-fontSize", "13", "-windowFrame", String(data:frame,encoding:.utf8)!] + extraArguments
let start = ProcessInfo.processInfo.systemUptime
var target: NSRunningApplication?
var failed: Error?
NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
    target = app; failed = error
}
while ProcessInfo.processInfo.systemUptime - start < 15 {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    if let failed { fputs("Launch failed: \(failed)\n", stderr); exit(1) }
    guard let target else { continue }
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String:Any]] ?? []
    if let window = windows.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int32) == target.processIdentifier &&
        ($0[kCGWindowLayer as String] as? Int) == 0 &&
        (($0[kCGWindowBounds as String] as? [String:Double])?["Width"] ?? 0) > 400
    }) {
        let result: [String:Any] = ["pid":Int(target.processIdentifier),"seconds":ProcessInfo.processInfo.systemUptime - start,
            "endpoint":"launch request to first on-screen main window; not first paint or shell-ready",
            "bounds":window[kCGWindowBounds as String] ?? [:],"poll_interval_ms":5]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.withoutOverwriting)
        print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
        exit(0)
    }
}
fputs("No matching on-screen window within 15 seconds\n", stderr); exit(1)

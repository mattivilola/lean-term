import Foundation
import Darwin

public struct ShellLaunch: Sendable {
    public let executable: String
    public let execName: String
    public let directory: String
    public let environment: [String]
    public let usedFallback: Bool

    public struct Account: Sendable {
        public let name: String
        public let home: String
        public let shell: String

        public init(name: String, home: String, shell: String) {
            self.name = name; self.home = home; self.shell = shell
        }

        public static func current() -> Account {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX))))
            let account = buffer.withUnsafeMutableBufferPointer { bytes -> Account? in
                guard getpwuid_r(getuid(), &entry, bytes.baseAddress!, bytes.count, &result) == 0,
                      result != nil else { return nil }
                return Account(name: String(cString: entry.pw_name),
                               home: String(cString: entry.pw_dir), shell: String(cString: entry.pw_shell))
            }
            return account ?? Account(name: NSUserName(), home: NSHomeDirectory(), shell: "/bin/zsh")
        }
    }

    public init(account: Account = .current(), inherited: [String: String] = ProcessInfo.processInfo.environment,
                directory: String? = nil, isExecutable: (String) -> Bool = { path in
                    var directory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                        && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
                }) {
        let validShell = account.shell.hasPrefix("/") && isExecutable(account.shell)
        executable = validShell ? account.shell : "/bin/zsh"
        execName = "-" + URL(fileURLWithPath: executable).lastPathComponent
        usedFallback = !validShell
        var env = inherited
        env["HOME"] = account.home
        env["USER"] = account.name
        env["LOGNAME"] = account.name
        env["SHELL"] = executable
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "LeanTerm"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        if env["PATH"]?.isEmpty != false { env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        if env["LANG"]?.isEmpty != false && env["LC_ALL"]?.isEmpty != false { env["LANG"] = "en_US.UTF-8" }
        environment = env.keys.sorted().map { "\($0)=\(env[$0]!)" }
        self.directory = directory ?? account.home
    }

    /// Accept local OSC 7 file URLs only; never treat remote host paths as local directories.
    public static func localDirectory(from value: String?, localHost: String = ProcessInfo.processInfo.hostName) -> String? {
        guard let value, let url = URL(string: value), url.isFileURL,
              isLocalHost(url.host, localHost: localHost),
              url.path.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.path
    }

    /// The host and absolute path of an OSC 7 file URL that names another machine. No filesystem check.
    public static func remoteDirectory(from value: String?, localHost: String = ProcessInfo.processInfo.hostName) -> (host: String, path: String)? {
        guard let value, let url = URL(string: value), url.isFileURL,
              let host = url.host, !isLocalHost(host, localHost: localHost),
              url.path.hasPrefix("/") else { return nil }
        return (host, url.path)
    }

    private static func isLocalHost(_ host: String?, localHost: String) -> Bool {
        host == nil || host == "" || host == "localhost" || host == localHost
    }
}

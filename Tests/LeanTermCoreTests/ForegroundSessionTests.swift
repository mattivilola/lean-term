import Foundation
import Testing
@testable import LeanTermCore

@Test func sessionClassificationPrioritisesRemoteOverRoot() {
    func process(_ name: String, _ arguments: [String] = [], uid: uid_t = 501) -> ForegroundProcess {
        ForegroundProcess(name: name, arguments: arguments, effectiveUserID: uid)
    }
    #expect(ForegroundSession(nil) == .local)
    #expect(ForegroundSession(process("make")) == .local)
    #expect(ForegroundSession(process("make", uid: 0)) == .root)
    #expect(ForegroundSession(process("ssh", ["ssh", "user@build-01"], uid: 0)) == .remote(tool: "ssh", host: "build-01"))
}

@Test func sshDestinationSkipsOptions() {
    #expect(ForegroundSession.sshDestination(arguments: ["ssh", "user@host"]) == "host")
    #expect(ForegroundSession.sshDestination(arguments: ["ssh", "-p", "2222", "host"]) == "host")
    #expect(ForegroundSession.sshDestination(arguments: ["ssh", "-vp22", "host"]) == "host")
    #expect(ForegroundSession.sshDestination(arguments: ["ssh", "ssh://user@host:2200"]) == "host")
    #expect(ForegroundSession.sshDestination(arguments: ["ssh", "-v"]) == nil)
}

@Test func remoteDirectoryNamesOnlyOtherMachines() {
    let remote = ShellLaunch.remoteDirectory(from: "file://build-01/var/log", localHost: "mac.local")
    #expect(remote?.host == "build-01")
    #expect(remote?.path == "/var/log")
    #expect(ShellLaunch.remoteDirectory(from: "file://mac.local/tmp", localHost: "mac.local") == nil)
}

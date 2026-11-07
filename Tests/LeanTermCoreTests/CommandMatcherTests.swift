import Testing
@testable import LeanTermCore

@Test func commandMatcherRanksWordStartsAndConsecutiveCharactersFirst() {
    #expect(CommandMatcher.score(query: "", candidate: "Anything") == 0)
    #expect(CommandMatcher.score(query: "xyz", candidate: "New Tab") == nil)
    #expect(CommandMatcher.score(query: "tn", candidate: "New Tab") == nil)
    #expect(CommandMatcher.score(query: "NEW", candidate: "New Tab") == CommandMatcher.score(query: "new", candidate: "New Tab"))
    let prefix = CommandMatcher.score(query: "ne", candidate: "New Tab")!
    let scattered = CommandMatcher.score(query: "ne", candidate: "Rename Tab")!
    #expect(prefix > scattered)
    let initials = CommandMatcher.score(query: "sr", candidate: "Split Right")!
    let midWord = CommandMatcher.score(query: "sr", candidate: "Clear Scrollback")!
    #expect(initials > midWord)
}

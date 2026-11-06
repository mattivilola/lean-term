import Foundation
import Testing
@testable import LeanTermCore

@Test func redactorReplacesEveryKindAndKeepsLabels() {
    let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEabc\ndef123\n-----END RSA PRIVATE KEY-----"
    let input = """
    \(pem)
    git clone https://alice:s3cretpw@example.com/repo.git
    curl -H 'Authorization: Bearer abc.def-123' https://api.example.com
    aws AKIAIOSFODNN7EXAMPLE
    gh ghp_0123456789abcdefghijklmnopqrstuvwxyz
    slack xoxb-1234567890-abcdefghij
    openai sk-abcdefghijklmnopqrstuvwx
    google AIzaSyA1234567890abcdefghijklmnopqrstuv
    stripe sk_live_abcdefghijklmnop1234
    gitlab glpat-abcdefghijklmnopqrstu
    npm npm_0123456789abcdefghijklmnopqrstuvwxyz
    jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2Q
    DB_PASSWORD=hunter2
    client-secret: "top secret"
    {"api_key": "k-123456", "token": "t-456789"}
    card 4111 1111 1111 1111
    iban FI21 1234 5600 0007 85
    ssn 123-45-6789
    hetu 131052-308T
    mail bob@example.com
    """
    let result = SensitiveDataRedactor.redact(input)
    let expected = """
    [REMOVED:private-key]
    git clone https://alice:[REMOVED:url-credentials]@example.com/repo.git
    curl -H 'Authorization: Bearer [REMOVED:bearer-token]' https://api.example.com
    aws [REMOVED:aws-key]
    gh [REMOVED:github-token]
    slack [REMOVED:slack-token]
    openai [REMOVED:api-key]
    google [REMOVED:api-key]
    stripe [REMOVED:api-key]
    gitlab [REMOVED:api-key]
    npm [REMOVED:api-key]
    jwt [REMOVED:jwt]
    DB_PASSWORD=[REMOVED:password]
    client-secret: "[REMOVED:secret]"
    {"api_key": "[REMOVED:api-key]", "token": "[REMOVED:token]"}
    card [REMOVED:card-number]
    iban [REMOVED:iban]
    ssn [REMOVED:ssn]
    hetu [REMOVED:finnish-ssn]
    mail [REMOVED:email]
    """
    #expect(result.text == expected)
    #expect(result.removed == 21)
}

@Test func redactorLeavesOrdinaryOutputUntouched() {
    let input = """
    commit 5b5135b3c1d2e4f60718293a4b5c6d7e8f901234 (HEAD -> main)
    Author: Matti Vilola
    Date:   Fri Nov 6 12:34:56 2026 +0200
    id 123e4567-e89b-12d3-a456-426614174000 at 2026-11-06T12:34:56Z
    ping 192.168.1.10 via ::1 and 2001:db8::ff00:42:8329
    cd /Users/matti/Development/ILOapps/leanterm-macosx && PWD=/Users/matti
    -rw-r--r--  1 matti  staff  1234567 Nov  6 12:34 Package.swift
    swift 6.2.1 build 4.0.0-beta.2
    number 4111111111111112 and 1700000000123
    tokenizer=fast secretary: Jane
    Password:
    git remote: git@github.com:org/repo.git and deploy@10.0.0.5:/srv
    token_count=123456789 token_url=https://example.com password_file=/etc/pw api_key_name=production-key
    token=12345678 password=false secret: none token: abc password=foo(bar) secret=short
    """
    let result = SensitiveDataRedactor.redact(input)
    #expect(result.text == input)
    #expect(result.removed == 0)
}

@Test func redactorHandlesLargeScrollbackQuickly() {
    let line = "2026-11-06 12:34:56 INFO user=bob@example.com password=hunter2 sha 5b5135b card 4111 1111 1111 1111 /usr/local/bin ok\n"
    let input = String(repeating: line, count: 1_500_000 / line.utf8.count)
    let start = ContinuousClock.now
    let result = SensitiveDataRedactor.redact(input)
    let elapsed = ContinuousClock.now - start
    #expect(result.removed > 0)
    #expect(elapsed < .milliseconds(500))
}

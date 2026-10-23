import Testing
@testable import SSHConfigKit

@Suite struct SSHConfigDocumentTests {
    let sample = """
    # Global defaults
    Include config.d/*

    Host jump
        HostName jump.example.com
        User admin

    # Production web server
    Host web web-alias
        HostName 10.0.0.5
        User deploy
        ProxyJump jump
        IdentityFile ~/.ssh/id_ed25519
        IdentityFile "~/.ssh/my key"

    Host *
        ServerAliveInterval 30
    """

    @Test func roundTripPreservesText() {
        let doc = SSHConfigDocument(text: sample)
        #expect(doc.text == sample + "\n")
    }

    @Test func parsesHosts() {
        let doc = SSHConfigDocument(text: sample)
        let hosts = doc.hosts
        #expect(hosts.count == 3)
        #expect(hosts[0].alias == "jump")
        #expect(hosts[1].patterns == ["web", "web-alias"])
        #expect(hosts[1].proxyJump == "jump")
        #expect(hosts[1].identityFiles == ["~/.ssh/id_ed25519", "~/.ssh/my key"])
        #expect(hosts[2].isWildcardOnly)
    }

    @Test func parsesEqualsSyntax() {
        let doc = SSHConfigDocument(text: "Host a\n  Port=2222\n  User = bob\n")
        #expect(doc.hosts[0].port == 2222)
        #expect(doc.hosts[0].user == "bob")
    }

    @Test func setOptionReplacesAndKeepsComments() throws {
        var doc = SSHConfigDocument(text: sample)
        try doc.setOption("User", value: "root", forHost: "web")
        try doc.setOption("Port", value: "2200", forHost: "web")
        try doc.setOption("ProxyJump", value: nil, forHost: "web")
        let web = try #require(doc.host(named: "web"))
        #expect(web.user == "root")
        #expect(web.port == 2200)
        #expect(web.proxyJump == nil)
        #expect(doc.text.contains("# Production web server"))
        #expect(doc.text.contains("    User root"))
    }

    @Test func addAndRemoveHost() throws {
        var doc = SSHConfigDocument(text: sample)
        try doc.addHost("db", options: [("HostName", "db.example.com"), ("User", ""), ("Port", "5022")])
        let db = try #require(doc.host(named: "db"))
        #expect(db.hostName == "db.example.com")
        #expect(db.user == nil)
        #expect(throws: SSHConfigDocument.EditError.self) { try doc.addHost("db", options: []) }
        try doc.removeHost("db")
        #expect(doc.host(named: "db") == nil)
        #expect(doc.text == sample + "\n")
    }

    @Test func removeMiddleHostKeepsNeighbours() throws {
        var doc = SSHConfigDocument(text: sample)
        try doc.removeHost("web")
        #expect(doc.host(named: "web") == nil)
        #expect(doc.host(named: "jump")?.hostName == "jump.example.com")
        #expect(doc.hosts.count == 2)
    }

    @Test func renameKeepsOtherPatterns() throws {
        var doc = SSHConfigDocument(text: sample)
        try doc.renameHost("web", to: "www")
        #expect(doc.host(named: "www")?.patterns == ["www", "web-alias"])
    }

    @Test func tokenizeHonoursQuotes() {
        #expect(SSHConfigDocument.tokenize(#"a "b c" d"#) == ["a", "b c", "d"])
    }
}

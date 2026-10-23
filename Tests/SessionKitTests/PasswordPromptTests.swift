import Foundation
import Testing
@testable import SessionKit

@Suite struct PasswordPromptTests {
    @Test func recognizesCommonPrompts() {
        #expect(PasswordPrompt.recognize("[sudo] password for alice: ") == PasswordPrompt(kind: .sudo, user: "alice", text: "[sudo] password for alice:"))
        #expect(PasswordPrompt.recognize("[sudo: authenticate] Password:")?.kind == .sudo)
        #expect(PasswordPrompt.recognize("Password: ")?.kind == .generic)
        #expect(PasswordPrompt.recognize("Enter password:")?.kind == .generic)
        let login = PasswordPrompt.recognize("bob@db.example.com's password: ")
        #expect(login?.kind == .login && login?.user == "bob" && login?.host == "db.example.com")
        #expect(PasswordPrompt.recognize("Enter passphrase for key '/home/user/.ssh/id_ed25519': ")?.kind == .passphrase)
        #expect(PasswordPrompt.recognize("Password for 'https://user@example.com':")?.kind == .generic)
    }

    @Test func ignoresOrdinaryOutputAndNewPasswords() {
        #expect(PasswordPrompt.recognize("alice@web:~$ ") == nil)
        #expect(PasswordPrompt.recognize("Changing password for alice.") == nil)
        #expect(PasswordPrompt.recognize("New password:") == nil)
        #expect(PasswordPrompt.recognize("Retype new password:") == nil)
        #expect(PasswordPrompt.recognize("Current password:")?.kind == .generic)
    }

    @Test func detectorFollowsTheLastLineAcrossChunksAndColors() {
        var d = PasswordPromptDetector()
        #expect(d.feed(Array("alice@web:~$ sudo ls\r\n".utf8)) == nil)
        #expect(d.feed(Array("\u{1b}[1m[sudo] pass".utf8)) == nil)
        let p = d.feed(Array("word for alice:\u{1b}[0m ".utf8))
        #expect(p?.kind == .sudo && p?.user == "alice")
        // Once the line moves on, the prompt is gone.
        #expect(d.feed(Array("\r\nfile1  file2\r\nalice@web:~$ ".utf8)) == nil)
    }
}

@Suite struct ForegroundProcessTests {
    @Test func findsTheProgramAskingAndItsUser() {
        // macOS `ps -t ttys003 -o stat=,ruser=,args=`
        let mac = """
        Ss   alice  -zsh
        S+   alice  sudo -u bob ls
        """
        let p = ForegroundProcess.parse(ps: mac, command: "sudo")
        #expect(p?.command == "sudo" && p?.user == "alice")
        let linux = """
        Ss   carol    -bash
        S+   carol    su - dbadmin
        """
        let su = ForegroundProcess.parse(ps: linux, command: "su")
        #expect(su?.user == "carol" && su?.suTarget == "dbadmin")
        #expect(ForegroundProcess.parse(ps: "S+ carol su\n", command: "su")?.suTarget == "root")
        #expect(ForegroundProcess.parse(ps: "S+ carol su -c 'id' bob\n", command: "su")?.suTarget == "bob")
        #expect(ForegroundProcess.parse(ps: "S+ carol /usr/bin/su -l eve\n", command: "su")?.suTarget == "eve")
        // Nothing in the foreground: nothing known.
        #expect(ForegroundProcess.parse(ps: "Ss alice -zsh\n", command: "sudo") == nil)
    }
}

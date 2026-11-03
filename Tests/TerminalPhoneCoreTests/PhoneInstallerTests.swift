import XCTest
import Foundation
@testable import TerminalPhoneCore

final class PhoneInstallerTests: XCTestCase {
    private func fixture(_ root: URL) throws -> URL {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("resources"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf 'fixture phone\\n'\n".utf8).write(to: source.appendingPathComponent("terminal-phone"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("terminal-phone").path)
        for name in ["phone-agent-worker.py", "phone-viewer-worker.py", "phone-idb-requirements.txt"] {
            try Data(name.utf8).write(to: source.appendingPathComponent("resources/\(name)"))
        }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("dependencies/private-signing"), withIntermediateDirectories: true)
        return source
    }
    func testInstallHandlesSpacesQuotesAndDoesNotCopySigningData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone install '\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), prefix = root.appendingPathComponent("installed cli")
        let result = try PhoneInstaller.install(source: source, prefix: prefix)
        let output = try await CommandRunner.checked(result.launcher, ["version"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "fixture phone\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.runtime + "/dependencies"))
        let repeated = try PhoneInstaller.install(source: source, prefix: prefix)
        XCTAssertEqual(result.runtime, repeated.runtime)
        try Data("updated worker".utf8).write(to: source.appendingPathComponent("resources/phone-agent-worker.py"))
        let upgraded = try PhoneInstaller.install(source: source, prefix: prefix)
        XCTAssertNotEqual(result.runtime, upgraded.runtime)
    }
    func testProfileConfigurationIsBackedUpAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), prefix = root.appendingPathComponent("prefix"), profile = root.appendingPathComponent(".zshrc")
        try Data("# existing user configuration\n".utf8).write(to: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
        let first = try PhoneInstaller.install(source: source, prefix: prefix, profile: profile)
        let second = try PhoneInstaller.install(source: source, prefix: prefix, profile: profile)
        XCTAssertTrue(first.profileUpdated); XCTAssertFalse(second.profileUpdated)
        let text = try String(contentsOf: profile)
        XCTAssertTrue(text.hasPrefix("# existing user configuration\n"))
        XCTAssertEqual(text.components(separatedBy: "# terminal-phone command path").count, 2)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("terminal-phone-backup") }
        XCTAssertEqual(backups.count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testSymlinkedProfileStaysALink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), prefix = root.appendingPathComponent("prefix")
        let dotfiles = root.appendingPathComponent("dotfiles"), target = dotfiles.appendingPathComponent("zshrc"), profile = root.appendingPathComponent(".zshrc")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try Data("# managed by a dotfiles repo\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)
        XCTAssertTrue(try PhoneInstaller.install(source: source, prefix: prefix, profile: profile).profileUpdated)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile.path), target.path)
        XCTAssertTrue(try String(contentsOf: target).contains("# terminal-phone command path"))
    }
    func testUnrelatedCommandIsPreservedAndIncompletePackageRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let command = prefix.appendingPathComponent("bin/terminal-phone")
        try Data("unrelated command".utf8).write(to: command)
        XCTAssertThrowsError(try PhoneInstaller.install(source: source, prefix: prefix))
        XCTAssertEqual(try String(contentsOf: command), "unrelated command")
        try FileManager.default.removeItem(at: source.appendingPathComponent("resources/phone-agent-worker.py"))
        XCTAssertThrowsError(try PhoneInstaller.install(source: source, prefix: root.appendingPathComponent("other")))
    }
    func testConfigurationRoundTripAndInvalidPhoneName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneStore(root: root)
        let value = PhoneConfiguration(preferredPhone: "work", developerDirectory: "/Applications/Xcode.app/Contents/Developer", signingTeam: "TESTTEAM01")
        try value.save(store: store)
        XCTAssertEqual(try PhoneConfiguration.load(store: store), value)
        XCTAssertThrowsError(try PhoneConfiguration(preferredPhone: "../other").save(store: store))
    }
}

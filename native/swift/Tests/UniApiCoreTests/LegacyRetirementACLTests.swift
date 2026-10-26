import Foundation
import XCTest
import Darwin
import CNativeSystem
@testable import UniApiCore

final class LegacyRetirementACLTests: XCTestCase {
    // macOS's well-known everyone group; no user account or real home is used.
    private static let everyone = "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::"
    private static let denyDelete = "!#acl 1\n" + everyone + "deny:delete\n"

    func testStandardDenyDeleteLibraryAncestorAdmitsDefinitionWithoutChangingACLOrIdentity() throws {
        let root = try fixture(), library = root.appendingPathComponent("Library"), definition = root.appendingPathComponent("Library/LaunchAgents/fixture.plist")
        try setACL(Self.denyDelete, at: library)
        let acl = try aclBytes(library), before = try info(library), bytes = try Data(contentsOf: definition)
        let fd = try NativeLegacyProtected.directory(anchor: root, relative: "Library/LaunchAgents", owner: getuid(), privateLast: true); close(fd)
        XCTAssertEqual(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024, privateFile: true), bytes)
        XCTAssertFalse(acl.isEmpty); XCTAssertEqual(try aclBytes(library), acl)
        XCTAssertTrue(NativeLegacyProtected.stable(before, try info(library)))
        XCTAssertEqual(try Data(contentsOf: definition), bytes)
        try setACL(Self.denyDelete + Self.everyone + "deny:write\n", at: library)
        let multiple = try aclBytes(library)
        XCTAssertEqual(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024, privateFile: true), bytes)
        XCTAssertEqual(try aclBytes(library), multiple)
    }

    func testGrantingDirectoryACLRefusesEvenBehindOrBeforeProtectiveDeny() throws {
        let root = try fixture(), library = root.appendingPathComponent("Library")
        let deny = Self.everyone + "deny:delete\n", allowWrite = Self.everyone + "allow:write\n", allowRead = Self.everyone + "allow:read\n"
        for entries in [allowWrite, deny + allowWrite, allowWrite + deny, deny + allowRead] {
            try setACL("!#acl 1\n" + entries, at: library)
            let before = try aclBytes(library)
            XCTAssertThrowsError(try NativeLegacyProtected.directory(anchor: root, relative: "Library/LaunchAgents", owner: getuid()))
            XCTAssertEqual(try aclBytes(library), before)
        }
    }

    func testProtectiveDirectoryACLDoesNotRelaxMetadataFileOrRecoveryPolicy() throws {
        let root = try fixture(), library = root.appendingPathComponent("Library"), definition = root.appendingPathComponent("Library/LaunchAgents/fixture.plist")
        try setACL(Self.denyDelete, at: library); try setACL(Self.denyDelete, at: definition)
        let before = try aclBytes(definition)
        XCTAssertThrowsError(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024, privateFile: true))
        XCTAssertEqual(try aclBytes(definition), before)
        let fd = open(definition.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); XCTAssertGreaterThanOrEqual(fd, 0); defer { if fd >= 0 { close(fd) } }
        XCTAssertThrowsError(try NativeLegacyProtected.validateFile(fd, owner: getuid(), maximum: 1024, privateFile: true))
        XCTAssertThrowsError(try NativeLegacyProtected.directoryACL(fd))
        try clearACL(at: definition)
        XCTAssertEqual(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024, privateFile: true), Data("fixture definition".utf8))
    }

    func testDenyOnlyAncestorKeepsOwnerModeLinkAndSingleInodeGuards() throws {
        let root = try fixture(), library = root.appendingPathComponent("Library"), agents = library.appendingPathComponent("LaunchAgents"), definition = agents.appendingPathComponent("fixture.plist")
        try setACL(Self.denyDelete, at: library)
        XCTAssertThrowsError(try NativeLegacyProtected.directory(anchor: root, relative: "Library/LaunchAgents", owner: getuid() &+ 1))
        XCTAssertEqual(chmod(agents.path, 0o777), 0)
        XCTAssertThrowsError(try NativeLegacyProtected.directory(anchor: root, relative: "Library/LaunchAgents", owner: getuid()))
        XCTAssertEqual(chmod(agents.path, 0o700), 0)
        XCTAssertEqual(chmod(definition.path, 0o666), 0)
        XCTAssertThrowsError(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024))
        XCTAssertEqual(chmod(definition.path, 0o600), 0)
        let alias = agents.appendingPathComponent("linked.plist")
        XCTAssertEqual(link(definition.path, alias.path), 0)
        XCTAssertThrowsError(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024))
        XCTAssertEqual(unlink(alias.path), 0)
        try FileManager.default.createSymbolicLink(at: agents.appendingPathComponent("directory-link"), withDestinationURL: agents)
        XCTAssertThrowsError(try NativeLegacyProtected.directory(anchor: root, relative: "Library/LaunchAgents/directory-link", owner: getuid()))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: definition)
        XCTAssertThrowsError(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/linked.plist", owner: getuid(), maximum: 1024))
    }

    func testUnknownACLTagsEmptyObjectsAndDescriptorReadFailuresRefuse() throws {
        var working = acl_init(1)
        guard working != nil else { throw NativeFailure("Fixture ACL allocation failed") }
        defer { if let working { acl_free(UnsafeMutableRawPointer(working)) } }
        var entry: acl_entry_t?
        guard acl_create_entry(&working, &entry) == 0, let value = working else { throw NativeFailure("Fixture ACL entry allocation failed") }
        // A new native ACL entry has an undefined tag. This malformed policy
        // cannot be treated as a successful end of the entry iterator.
        XCTAssertThrowsError(try NativeLegacyProtected.denyOnlyACL(value))
        guard let empty = acl_init(0) else { throw NativeFailure("Fixture ACL allocation failed") }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        XCTAssertThrowsError(try NativeLegacyProtected.denyOnlyACL(empty))
        XCTAssertThrowsError(try NativeLegacyProtected.directoryACL(-1))
        XCTAssertThrowsError(try NativeLegacyProtected.noACL(-1))
    }

    func testUnmodifiedNoACLDirectoryAndFileRemainAdmitted() throws {
        let root = try fixture()
        let fd = try NativeLegacyProtected.directory(anchor: root, relative: "Library/LaunchAgents", owner: getuid(), privateLast: true); close(fd)
        XCTAssertEqual(try NativeLegacyProtected.read(anchor: root, relative: "Library/LaunchAgents/fixture.plist", owner: getuid(), maximum: 1024, privateFile: true), Data("fixture definition".utf8))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-retirement-acl-" + UUID().uuidString)
        let agents = root.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let definition = agents.appendingPathComponent("fixture.plist")
        try Data("fixture definition".utf8).write(to: definition); XCTAssertEqual(chmod(definition.path, 0o600), 0)
        addTeardownBlock {
            // Only ACLs installed by this fixture are cleared, to remove its
            // disposable deny-delete directories. Never touch an OS home ACL.
            for path in [definition, agents, root.appendingPathComponent("Library")] { try? self.clearACL(at: path) }
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
    private func setACL(_ text: String, at path: URL) throws {
        guard let value = text.withCString({ acl_from_text($0) }) else { throw NativeFailure("Fixture ACL text was rejected") }
        defer { acl_free(UnsafeMutableRawPointer(value)) }
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Fixture ACL target unavailable") }; defer { close(fd) }
        guard acl_set_fd(fd, value) == 0 else { throw NativeFailure("Fixture ACL installation failed: \(errno)") }
    }
    private func clearACL(at path: URL) throws {
        guard let value = acl_init(0) else { throw NativeFailure("Fixture ACL allocation failed") }
        defer { acl_free(UnsafeMutableRawPointer(value)) }
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Fixture ACL target unavailable") }; defer { close(fd) }
        guard acl_set_fd(fd, value) == 0 else { throw NativeFailure("Fixture ACL cleanup failed") }
    }
    private func aclBytes(_ path: URL) throws -> Data {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Fixture ACL target unavailable") }; defer { close(fd) }
        guard let value = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { throw NativeFailure("Expected fixture ACL") }
        defer { acl_free(UnsafeMutableRawPointer(value)) }
        let size = acl_size(value); guard size > 0 else { throw NativeFailure("Fixture ACL size unavailable") }
        var bytes = Data(count: size)
        let count = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, value, size) }
        guard count == size else { throw NativeFailure("Fixture ACL serialization failed") }; return bytes
    }
    private func info(_ path: URL) throws -> stat {
        var value = stat(); guard lstat(path.path, &value) == 0 else { throw NativeFailure("Fixture identity unavailable") }; return value
    }
}

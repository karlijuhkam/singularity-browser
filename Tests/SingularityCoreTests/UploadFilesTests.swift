import Foundation
import Testing
@testable import SingularityCore

@Suite struct UploadFilesTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sg-up-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func checksPaths() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.pdf")
        try Data("x".utf8).write(to: file)
        let link = dir.appending(path: "link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(try UploadFiles.check([], multiple: false) == [])
        #expect(try UploadFiles.check([file.path], multiple: false).map(\.path) == [file.resolvingSymlinksInPath().path])
        #expect(try UploadFiles.check([link.path], multiple: false).map(\.path) == [file.resolvingSymlinksInPath().path])
        #expect(throws: UploadFiles.Refusal.self) { try UploadFiles.check(["a.pdf"], multiple: false) }
        #expect(throws: UploadFiles.Refusal.self) { try UploadFiles.check([dir.path], multiple: false) }
        #expect(throws: UploadFiles.Refusal.self) { try UploadFiles.check([dir.appending(path: "missing").path], multiple: false) }
        #expect(throws: UploadFiles.Refusal.self) { try UploadFiles.check([file.path, file.path], multiple: false) }
        #expect(try UploadFiles.check([file.path, link.path], multiple: true).count == 2)
        #expect(throws: UploadFiles.Refusal.self) {
            try UploadFiles.check(Array(repeating: file.path, count: 21), multiple: true)
        }
    }
}

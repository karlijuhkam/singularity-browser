import Foundation
import Testing
@testable import SingularityCore

@Suite struct ArcImportTests {
    /// A small sidebar in Arc's shape: one Space with pinned tabs, nested folders, a split view,
    /// a note and a non-web address; and one empty Space without a title.
    private func sidebar() -> Data {
        func item(_ id: String, parent: String?, children: [String] = [], title: String? = nil, data: [String: Any]) -> [Any] {
            [id, ["id": id, "parentID": parent as Any, "childrenIds": children, "title": title as Any, "data": data,
                  "isUnread": false, "createdAt": 1.0] as [String: Any]]
        }
        func tab(_ url: String?, _ savedTitle: String) -> [String: Any] {
            var tab: [String: Any] = ["savedTitle": savedTitle, "timeLastActiveAt": 1.0]
            if let url { tab["savedURL"] = url }
            return ["tab": tab]
        }
        var items: [Any] = []
        items += item("P", parent: nil, children: ["t1", "f1", "sv", "doc", "t5"], data: ["itemContainer": ["containerType": ["spaceItems": ["_0": "S1"]]]])
        items += item("t1", parent: "P", title: "My mail", data: tab("https://mail.example.com/inbox", "Inbox (3)"))
        items += item("f1", parent: "P", children: ["t2", "f2", "t3"], title: "Docs", data: ["list": [String: Any]()])
        items += item("t2", parent: "f1", data: tab("https://docs.example.com/a", "Doc A"))
        items += item("f2", parent: "f1", children: ["t4"], title: "Deep", data: ["list": [String: Any]()])
        items += item("t4", parent: "f2", data: tab("https://docs.example.com/deep", "Deep doc"))
        items += item("t3", parent: "f1", data: tab("http://localhost:3000/", "Local"))
        items += item("sv", parent: "P", children: ["t6", "t7"], data: ["splitView": ["layoutOrientation": "horizontal"]])
        items += item("t6", parent: "sv", data: tab("https://left.example.com/", "Left"))
        items += item("t7", parent: "sv", data: tab("https://right.example.com/", "Right"))
        items += item("doc", parent: "P", data: ["arcDocument": ["arcDocumentID": "x"]])
        items += item("t5", parent: "P", data: tab("arc://settings", "Settings"))
        items += item("U", parent: nil, children: ["g", "t9", "t10"], data: ["itemContainer": ["containerType": ["spaceItems": ["_0": "S1"]]]])
        items += item("g", parent: "U", children: ["t8"], data: ["tabGroup": ["title": "Group"]])
        items += item("t8", parent: "g", data: tab("https://grouped.example.com/", "Grouped"))
        items += item("t9", parent: "U", data: tab("https://today.example.com/", "Today"))
        items += item("t10", parent: "U", data: tab(nil, "No address"))
        items += item("P2", parent: nil, data: ["itemContainer": [String: Any]()])
        items += item("U2", parent: nil, data: ["itemContainer": [String: Any]()])

        let theme: [String: Any] = ["windowTheme": ["primaryColorPalette": ["midTone": ["red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1]]]]
        let spaces: [Any] = [
            "S1", ["id": "S1", "title": "Work", "containerIDs": ["unpinned", "U", "pinned", "P"], "customInfo": theme,
                   "profile": ["custom": ["_0": ["directoryBasename": "Profile 2", "machineID": "m"]]]] as [String: Any],
            "S2", ["id": "S2", "containerIDs": ["pinned", "P2", "unpinned", "U2"], "profile": ["default": true]] as [String: Any],
        ]
        let root: [String: Any] = ["version": 1, "sidebar": ["containers": [["global": [String: Any]()], ["spaces": spaces, "items": items]]]]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test func readsSpacesFoldersAndTabsInOrder() throws {
        let spaces = try ArcImport.parse(sidebar()).get()
        #expect(spaces.map(\.name) == ["Work", "Arc"])
        let work = spaces[0]
        #expect(work.colorHex == "#FF8000")
        #expect(work.profile == "Profile 2")
        #expect(spaces[1].profile == "Default" && spaces[1].colorHex == nil)
        #expect(work.pinnedTabCount == 6 && work.unpinnedTabCount == 2)
        #expect(work.skipped == 3) // the note, arc://settings, the tab without an address
        // A custom title wins over the page's saved title.
        #expect(work.pinned.first == .tab(title: "My mail", url: URL(string: "https://mail.example.com/inbox")!))
        guard case .folder(let name, let children) = work.pinned[1] else {
            Issue.record("expected a folder")
            return
        }
        #expect(name == "Docs" && children.count == 3)
        #expect(spaces[1].pinned.isEmpty && spaces[1].unpinned.isEmpty)
    }

    @Test func makesASpaceWithPinnedFoldersAndOpenTabs() throws {
        let work = try ArcImport.parse(sidebar()).get()[0]
        let space = ArcImport.makeSpace(from: work, slug: "work", fallbackColorHex: "#000000")
        #expect(space.name == "Work" && space.slug == "work" && space.colorHex == "#FF8000")
        // Pinned: the tab directly under "pinned", and the split view's two tabs in place.
        #expect(space.tabs(in: .pinned).map(\.title) == ["My mail", "Left", "Right"])
        // A folder in a folder stays inside it.
        #expect(space.folders.map(\.name) == ["Docs", "Deep"])
        #expect(space.folders[0].parentID == nil && space.folders[1].parentID == space.folders[0].id)
        #expect(space.childFolders(of: nil).map(\.name) == ["Docs"])
        #expect(space.folderPath(space.folders[1].id) == "Docs / Deep")
        #expect(space.tabs(in: .folder(space.folders[0].id)).map(\.title) == ["Doc A", "Local"])
        #expect(space.tabs(in: .folder(space.folders[1].id)).map(\.title) == ["Deep doc"])
        #expect(space.tabs(in: .open).map(\.title) == ["Grouped", "Today"])
        #expect(space.selectedTabID == nil && !space.agentsEnabled)
        // Without Arc's unpinned tabs.
        let pinnedOnly = ArcImport.makeSpace(from: work, slug: "work", fallbackColorHex: "#000000", options: .init(includeUnpinned: false))
        #expect(pinnedOnly.tabs(in: .open).isEmpty && pinnedOnly.tabs.count == 6)
        // A Space without a theme gets the fallback colour.
        let plain = ArcImport.makeSpace(from: try ArcImport.parse(sidebar()).get()[1], slug: "arc", fallbackColorHex: "#123456")
        #expect(plain.colorHex == "#123456" && plain.tabs.isEmpty)
    }

    @Test func refusesOtherFilesAndSurvivesLoops() throws {
        #expect(ArcImport.parse(Data("nope".utf8)) == .failure(.unreadable))
        #expect(ArcImport.parse(Data(#"{"sidebar":{"containers":[{"global":{}}]}}"#.utf8)) == .failure(.unrecognised))
        #expect(ArcImport.parse(Data(#"{"version":1}"#.utf8)) == .failure(.unrecognised))
        // Items that contain each other must not hang the import.
        let loop = #"{"sidebar":{"containers":[{"spaces":["S",{"id":"S","title":"L","containerIDs":["pinned","a"]}],"items":["a",{"id":"a","childrenIds":["b"],"data":{"itemContainer":{}}},"b",{"id":"b","childrenIds":["a","b"],"data":{"list":{}},"title":"F"}]}]}}"#
        let spaces = try ArcImport.parse(Data(loop.utf8)).get()
        #expect(spaces.count == 1 && spaces[0].pinnedTabCount == 0)
    }
}

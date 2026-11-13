import Testing
@testable import SingularityCore

@Suite struct UpdateTests {
    let ok: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "abc="]
    let installed = "/Applications/Singularity.app"
    var config: UpdateAvailability {
        .available(UpdateConfig(feedURL: "https://example.com/appcast.xml", publicKey: "abc="))
    }

    @Test func releaseBuildMayUpdate() {
        #expect(UpdatePolicy.availability(infoPlist: ok, environment: [:], bundlePath: installed) == config)
    }

    @Test func emptyInfoPlistIsNotAReleaseBuild() {
        #expect(UpdatePolicy.availability(infoPlist: [:], environment: [:], bundlePath: installed) == .unavailable(.notAReleaseBuild))
    }

    @Test func missingKeyIsNotAReleaseBuild() {
        let onlyFeed: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml"]
        #expect(UpdatePolicy.availability(infoPlist: onlyFeed, environment: [:], bundlePath: installed) == .unavailable(.notAReleaseBuild))
    }

    @Test func emptyKeyIsNotAReleaseBuild() {
        var plist = ok
        plist["SUPublicEDKey"] = ""
        #expect(UpdatePolicy.availability(infoPlist: plist, environment: [:], bundlePath: installed) == .unavailable(.notAReleaseBuild))
    }

    @Test func wrongTypeIsNotAReleaseBuild() {
        var plist = ok
        plist["SUFeedURL"] = 42
        #expect(UpdatePolicy.availability(infoPlist: plist, environment: [:], bundlePath: installed) == .unavailable(.notAReleaseBuild))
    }

    @Test func ownDataFolderDoesNotUpdate() {
        #expect(UpdatePolicy.availability(infoPlist: ok, environment: ["SINGULARITY_HOME": "/private/tmp/x"], bundlePath: installed)
                == .unavailable(.separateDataFolder))
    }

    @Test func emptyDataFolderVariableIsIgnored() {
        #expect(UpdatePolicy.availability(infoPlist: ok, environment: ["SINGULARITY_HOME": ""], bundlePath: installed) == config)
    }

    @Test func testBundleMayUpdateWithOwnDataFolder() {
        var plist = ok
        plist["SGUpdateTestBundle"] = true
        #expect(UpdatePolicy.availability(infoPlist: plist, environment: ["SINGULARITY_HOME": "/private/tmp/x"],
                                          bundlePath: "/private/tmp/sg-upd/Singularity.app") == config)
    }

    @Test func translocatedCopyDoesNotUpdate() {
        #expect(UpdatePolicy.availability(infoPlist: ok, environment: [:],
                                          bundlePath: "/private/var/folders/x/AppTranslocation/y/d/Singularity.app")
                == .unavailable(.translocated))
    }

    @Test func translocatedWinsOverDataFolder() {
        #expect(UpdatePolicy.availability(infoPlist: ok, environment: ["SINGULARITY_HOME": "/private/tmp/x"],
                                          bundlePath: "/private/var/folders/x/AppTranslocation/y/d/Singularity.app")
                == .unavailable(.translocated))
    }

    @Test func textsAreFixed() {
        #expect(UpdateUnavailable.notAReleaseBuild.text == "This is a development build. It doesn't update itself.")
        #expect(UpdateUnavailable.separateDataFolder.text == "This copy uses its own data folder, so it doesn't update itself.")
        #expect(UpdateUnavailable.translocated.text == "Move Singularity to the Applications folder to get updates.")
    }
}

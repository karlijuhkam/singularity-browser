import Foundation
import Testing
@testable import SingularityCore

@Suite struct PrivateWindowRulesTests {
    private let template = "https://duckduckgo.com/?q=%s"

    @Test func typedTextIsAnAddressOrASearch() {
        #expect(PrivateWindowRules.destination(typed: "example.com", searchTemplate: template)?.absoluteString == "https://example.com")
        #expect(PrivateWindowRules.destination(typed: "  http://localhost:3000/a ", searchTemplate: template)?.absoluteString == "http://localhost:3000/a")
        #expect(PrivateWindowRules.destination(typed: "swift actors", searchTemplate: template)?.absoluteString == "https://duckduckgo.com/?q=swift%20actors")
        #expect(PrivateWindowRules.destination(typed: "   ", searchTemplate: template) == nil)
        #expect(PrivateWindowRules.destination(typed: "", searchTemplate: template) == nil)
    }

    @Test func theFieldShowsTheWholeAddress() {
        #expect(PrivateWindowRules.fieldText(URL(string: "https://www.example.com/a?b=c#d")) == "https://www.example.com/a?b=c#d")
        #expect(PrivateWindowRules.fieldText(nil) == "")
        #expect(PrivateWindowRules.fieldText(URL(string: "about:blank")) == "")
    }

    @Test func popUpsOpenForWebAddressesOrEmptyOnes() {
        #expect(PrivateWindowRules.opensPopup(URL(string: "https://accounts.example.com/login")))
        #expect(PrivateWindowRules.opensPopup(nil))
        #expect(PrivateWindowRules.opensPopup(URL(string: "about:blank")))
        #expect(!PrivateWindowRules.opensPopup(URL(string: "file:///etc/passwd")))
        #expect(!PrivateWindowRules.opensPopup(URL(string: "javascript:alert(1)")))
    }
}

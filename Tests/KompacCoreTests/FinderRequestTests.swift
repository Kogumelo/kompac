import Foundation
import Testing
@testable import KompacCore

@Test func finderRequestRoundTrip() throws {
    // characters that break a query string or a URL: & = + # % ? space, accents, emoji
    let items = ["/Users/a/Relatórios & Notas", "/tmp/a+b=c#d%e?f.txt", "/Volumes/Disco Externo/foto 🍄.jpg"]
        .map { URL(fileURLWithPath: $0) }
    for action in [FinderRequest.Action.zip, .window] {
        let request = FinderRequest(action: action, items: items)
        #expect(request.url.scheme == "kompac")
        let back = try #require(FinderRequest(url: URL(string: request.url.absoluteString)!))
        #expect(back == request)
    }
}

@Test func finderRequestRejectsMalformed() {
    let bad = [
        "kompac://compress?action=zip",                          // no items
        "kompac://compress?path=/tmp/x",                         // no action
        "kompac://compress?action=delete&path=/tmp/x",           // unknown action
        "kompac://compress?action=zip&path=tmp/x",               // relative path
        "kompac://extract?action=zip&path=/tmp/x",               // another host
        "kompac://compress?action=zip&path=/tmp/x&password=1",   // unknown key
        "http://compress?action=zip&path=/tmp/x",                // another scheme
    ]
    for text in bad {
        #expect(FinderRequest(url: URL(string: text)!) == nil, "\(text)")
    }
}

@Test func finderRequestStandardizesPaths() throws {
    let r = try #require(FinderRequest(url: URL(string: "kompac://compress?action=window&path=/tmp/a/../b")!))
    #expect(r.items.map(\.path) == ["/tmp/b"])
}

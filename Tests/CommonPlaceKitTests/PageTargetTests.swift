import CoreGraphics
import XCTest
@testable import CommonPlaceKit

/// The chains are the ones Comet reported on the test Mac (2026-10-14,
/// Wikipedia's Espresso page), innermost first.
final class PageTargetTests: XCTestCase {
    private let window = PointerNode(role: "AXWindow", title: "Espresso - Wikipedia - Comet", frame: CGRect(x: 596, y: 41, width: 805, height: 949))
    private let page = PointerNode(role: "AXGroup", roleDescription: "group", title: "Espresso - Wikipedia - Comet",
                                   url: "https://en.wikipedia.org/wiki/Espresso", frame: CGRect(x: 596, y: 41, width: 805, height: 949))

    func testThePhotoUnderThePointer() {
        let photo = PointerNode(role: "AXImage", roleDescription: "Unlabeled image",
                                url: "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a5/Tazzina.jpg/330px-Tazzina.jpg",
                                frame: CGRect(x: 1066, y: 452, width: 302, height: 251))
        let link = PointerNode(role: "AXLink", url: "https://en.wikipedia.org/wiki/File:Tazzina.jpg",
                               frame: CGRect(x: 1063, y: 449, width: 308, height: 257))
        let figure = PointerNode(role: "AXGroup", roleDescription: "figure", frame: CGRect(x: 1062, y: 448, width: 310, height: 304))
        XCTAssertEqual(PageTarget.decide([photo, link, figure, page, window]),
                       .image(source: URL(string: "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a5/Tazzina.jpg/330px-Tazzina.jpg"),
                              frame: CGRect(x: 1066, y: 452, width: 302, height: 251)))
    }

    func testAPausedVideosPlayButtonIsTheVideo() {
        let play = PointerNode(role: "AXButton", roleDescription: "button", title: "Play video", description: "Play video",
                               frame: CGRect(x: 1115, y: 781, width: 256, height: 148))
        let figure = PointerNode(role: "AXGroup", roleDescription: "figure", frame: CGRect(x: 1114, y: 780, width: 258, height: 205))
        XCTAssertEqual(PageTarget.decide([play, figure, page, window]), .video(frame: CGRect(x: 1115, y: 781, width: 256, height: 148)))
    }

    func testAPlayingVideosPlayerRegion() {
        let group = PointerNode(role: "AXGroup", roleDescription: "group", frame: CGRect(x: 601, y: 167, width: 795, height: 818))
        let player = PointerNode(role: "AXGroup", roleDescription: "region", title: "Video Player", description: "Video Player",
                                 frame: CGRect(x: 601, y: 167, width: 795, height: 818))
        XCTAssertEqual(PageTarget.decide([group, player, group, group, page, window]), .video(frame: player.frame))
    }

    /// Comet showing a video file (the test Mac): the <video> is only a
    /// "group"; the page's address is the .mp4.
    func testAVideoFileOpenedInTheBrowser() {
        let video = PointerNode(role: "AXGroup", roleDescription: "group", frame: CGRect(x: 601, y: 352, width: 795, height: 448))
        let content = PointerNode(role: "AXGroup", roleDescription: "HTML content", url: "file:///Users/me/Movies/kyoto-walk.mp4",
                                  frame: CGRect(x: 601, y: 167, width: 795, height: 818))
        XCTAssertEqual(PageTarget.decide([video, video, video, content, window]), .video(frame: video.frame))
    }

    /// A site's player is known by its class names (YouTube: "html5-main-video").
    func testAPlayerByItsClassNames() {
        let video = PointerNode(role: "AXGroup", roleDescription: "group", frame: CGRect(x: 0, y: 100, width: 854, height: 480),
                                domClasses: ["video-stream", "html5-main-video"])
        XCTAssertEqual(PageTarget.decide([video, page, window]), .video(frame: video.frame))
        let plain = PointerNode(role: "AXGroup", frame: CGRect(x: 0, y: 100, width: 854, height: 480), domClasses: ["article-body"])
        XCTAssertEqual(PageTarget.decide([plain, page, window]), .window)
    }

    func testTextIconsAndUnreadPagesKeepTheWindow() {
        let text = PointerNode(role: "AXStaticText", roleDescription: "text", title: "Espresso is a coffee", frame: CGRect(x: 600, y: 400, width: 300, height: 20))
        XCTAssertEqual(PageTarget.decide([text, page, window]), .window)
        let icon = PointerNode(role: "AXImage", url: "https://x.org/icon.png", frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertEqual(PageTarget.decide([icon, page, window]), .window)
        // Before the browser built its tree: only the scroll area (Comet's first answer).
        let scroll = PointerNode(role: "AXScrollArea", roleDescription: "scroll area", frame: CGRect(x: 601, y: 167, width: 795, height: 818))
        XCTAssertEqual(PageTarget.decide([scroll, page, window]), .window)
        // "Play" on a tiny control is not a video.
        let tinyPlayer = PointerNode(role: "AXButton", title: "Video player settings", frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        XCTAssertEqual(PageTarget.decide([tinyPlayer, window]), .window)
        // An image with an inline (data:) source is still kept, from the screen.
        let inline = PointerNode(role: "AXImage", url: "data:image/png;base64,AAAA", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(PageTarget.decide([inline, window]), .image(source: nil, frame: inline.frame))
    }

    func testWikimediaThumbnailsLeadToTheOriginal() {
        let thumb = URL(string: "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a5/Tazzina_di_caff%C3%A8_a_Ventimiglia.jpg/330px-Tazzina_di_caff%C3%A8_a_Ventimiglia.jpg")!
        XCTAssertEqual(ImageSources.candidates(for: thumb).map(\.absoluteString), [
            "https://upload.wikimedia.org/wikipedia/commons/a/a5/Tazzina_di_caff%C3%A8_a_Ventimiglia.jpg",
            thumb.absoluteString,
        ])
        let other = URL(string: "https://images.example.com/photo.jpg")!
        XCTAssertEqual(ImageSources.candidates(for: other), [other])
        let original = URL(string: "https://upload.wikimedia.org/wikipedia/commons/a/a5/Name.jpg")!
        XCTAssertEqual(ImageSources.candidates(for: original), [original], "already the original")
    }
}

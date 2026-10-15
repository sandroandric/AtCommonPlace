import CoreGraphics
import Foundation

/// One element under the pointer, as Accessibility describes it.
public struct PointerNode: Equatable, Sendable {
    public var role: String
    public var roleDescription: String
    public var title: String
    public var description: String
    public var url: String?
    /// Screen points, top-left origin.
    public var frame: CGRect
    /// The element's HTML class names and id (Chromium: `AXDOMClassList`, `AXDOMIdentifier`).
    public var domClasses: [String]
    public var domIdentifier: String

    public init(role: String, roleDescription: String = "", title: String = "", description: String = "",
                url: String? = nil, frame: CGRect, domClasses: [String] = [], domIdentifier: String = "") {
        self.role = role
        self.roleDescription = roleDescription
        self.title = title
        self.description = description
        self.url = url
        self.frame = frame
        self.domClasses = domClasses
        self.domIdentifier = domIdentifier
    }
}

/// What the capture keys keep when the pointer is on something inside a
/// page: the image under it, the video under it, or (anything else) the
/// window.
public enum PageTarget: Equatable, Sendable {
    /// `source`: the image's own address when it has one (http/https).
    case image(source: URL?, frame: CGRect)
    case video(frame: CGRect)
    case window

    /// Smaller than this (points) either way, an image is an icon or a button.
    public static let minimumImageSide: CGFloat = 120
    /// A video area smaller than this is a control, not the picture.
    public static let minimumVideoSize = CGSize(width: 160, height: 90)
    /// How far up from the element under the pointer a video player is looked for.
    public static let videoSearchDepth = 7

    /// `chain`: the element under the pointer first, then its ancestors.
    ///
    /// Measured in Comet (Wikipedia's Espresso page): the photo is an
    /// `AXImage` with its address (`AXURL`) and frame; a paused video is a
    /// "Play video" button in a figure; a playing one sits in a region
    /// titled "Video Player".
    public static func decide(_ chain: [PointerNode]) -> PageTarget {
        for node in chain.prefix(videoSearchDepth) where isVideo(node) {
            if node.frame.width >= minimumVideoSize.width, node.frame.height >= minimumVideoSize.height {
                return .video(frame: node.frame)
            }
        }
        // A video file opened in the browser: its page's address is the
        // file; the video is the element under the pointer (Chromium names a
        // bare <video> only "group").
        if let page = chain.firstIndex(where: { isVideoFile($0.url) }),
           let video = chain[..<page].first(where: {
               $0.frame.width >= minimumVideoSize.width && $0.frame.height >= minimumVideoSize.height
           }) {
            return .video(frame: video.frame)
        }
        for node in chain.prefix(3) where node.role == "AXImage" {
            guard node.frame.width >= minimumImageSide, node.frame.height >= minimumImageSide else { break }
            let source = node.url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            return .image(source: source, frame: node.frame)
        }
        return .window
    }

    static func isVideo(_ node: PointerNode) -> Bool {
        if node.role == "AXVideo" { return true }
        let words = [node.roleDescription, node.title, node.description].joined(separator: " ").lowercased()
        if words.range(of: #"\b(video|player)\b"#, options: .regularExpression) != nil { return true }
        // Class names and ids are written for developers: "html5-main-video", "videoPlayer".
        let names = (node.domClasses + [node.domIdentifier]).joined(separator: " ").lowercased()
        return names.range(of: #"video|player"#, options: .regularExpression) != nil
    }

    static func isVideoFile(_ url: String?) -> Bool {
        guard let url, let parsed = URL(string: url) else { return false }
        return ["mp4", "webm", "mov", "m4v"].contains(parsed.pathExtension.lowercased())
    }
}

/// Browsers built on Chromium build their page's Accessibility tree only
/// when asked (`AXEnhancedUserInterface`); Safari always has it.
public enum ChromiumBrowsers {
    public static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "ai.perplexity.comet",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]
}

/// Where a larger version of a page's image is, for hosts whose addresses
/// say so.  Wikipedia shows a thumbnail (`…/thumb/a/a5/Name.jpg/330px-Name.jpg`)
/// of an original at a predictable address (`…/a/a5/Name.jpg`).
public enum ImageSources {
    /// Addresses to try, largest first; `url` itself last.
    public static func candidates(for url: URL) -> [URL] {
        guard let host = url.host()?.lowercased(),
              host == "upload.wikimedia.org" || host == "thumb.wikimedia.org" else { return [url] }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let thumb = parts.firstIndex(of: "thumb"), parts.count > thumb + 2 else { return [url] }
        parts.remove(at: thumb)
        parts.removeLast()
        var original = URLComponents()
        original.scheme = "https"
        original.host = "upload.wikimedia.org"
        original.path = "/" + parts.joined(separator: "/")
        return [original.url, url].compactMap { $0 }
    }
}

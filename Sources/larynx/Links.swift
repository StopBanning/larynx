import AppKit

/// Where Larynx lives on the web, in one place (PLAN-launch LQ2 may move the repository).
enum Links {
    static let repo = "https://github.com/StopBanning/larynx"
    static var releases: URL { URL(string: repo + "/releases")! }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// A new issue with what a bug report needs and nothing else: the version, macOS and the speech model.
    static func feedback(engine: String) -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = """
            **What happened**


            **What you expected**


            ---
            Larynx \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · speech model: \(engine)
            Nothing you dictated is attached. Add only what you are comfortable sharing in public.
            """
        var parts = URLComponents(string: repo + "/issues/new")!
        parts.queryItems = [URLQueryItem(name: "title", value: "Feedback: "), URLQueryItem(name: "body", value: body)]
        return parts.url!
    }

    /// The About panel's small print: what Larynx is built on.
    static var credits: NSAttributedString {
        let text = """
            Free and open source (MIT). Everything runs on this Mac.

            Speech: Parakeet Ultra by moondream and Parakeet by NVIDIA (CC BY 4.0), Parakeet Unified (NVIDIA Open
            Model License), Bark by Conway Research (CC BY-NC 4.0, non-commercial), run with FluidAudio (Apache 2.0).
            Word list: SCOWL. Licence texts are inside the app, in Contents/Resources/Licenses.

            \(repo)
            """
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let out = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                                                        .paragraphStyle: style])
        out.addAttribute(.link, value: repo, range: (text as NSString).range(of: repo))
        return out
    }
}

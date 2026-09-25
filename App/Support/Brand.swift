import Foundation

/// The product's own name, read from the bundle rather than written into the
/// source. A build of your own (see `project.local.yml` in docs/development.md)
/// differs from MacBench by a name, an icon and a bundle identifier, and none of
/// those belongs in a sentence.
///
/// The one thing that is deliberately *not* branded is the `.macbench` folder in
/// a project: it is the data format, and every build has to read the others'.
enum Brand {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MacBench"
    }

    static let repository = URL(string: "https://github.com/chprinz/macbench")!

    /// "0.1 (18)" — the marketing version, and the build number, which build.sh
    /// sets to the number of commits. Two builds of 0.1 are otherwise
    /// indistinguishable, which is exactly the situation where you need to know
    /// which one somebody is running.
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

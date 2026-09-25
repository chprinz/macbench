import AppKit
import QuickLookThumbnailing
import MacBenchCore

/// Previews for the file list.
///
/// Two rules, both about not being rude to the user's machine or connection:
/// nothing is generated for a row that is not on screen, and nothing is ever
/// requested for a file iCloud has not downloaded — asking for a preview would
/// pull the whole file down.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    private let inspector = ICloudInspector()
    private let diskDirectory: URL

    init() {
        memory.countLimit = 400
        diskDirectory = URL.applicationSupportDirectory
            .appending(path: "MacBench/thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    func cached(for url: URL) -> NSImage? {
        let version = versionKey(for: url)
        if let image = memory.object(forKey: version as NSString) { return image }
        guard let image = NSImage(contentsOf: diskKey(for: version)) else { return nil }
        memory.setObject(image, forKey: version as NSString)
        return image
    }

    /// The file as it is now: its path and when it last changed. Keyed on the
    /// path alone, the first preview a file ever had was the one it kept — a
    /// layout reworked all week still showed Monday's version.
    private func versionKey(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return url.path + "@" + String(modified)
    }

    /// `nil` means: show an icon, and do not try again for this file right now.
    func thumbnail(for url: URL, size: CGSize = CGSize(width: 96, height: 96)) async -> NSImage? {
        if let image = cached(for: url) { return image }
        guard inspector.isMaterialised(url) else { return nil }
        let path = url.path
        guard !inFlight.contains(path) else { return nil }
        inFlight.insert(path)
        defer { inFlight.remove(path) }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }

        let image = representation.nsImage
        let version = versionKey(for: url)
        memory.setObject(image, forKey: version as NSString)
        if let data = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            try? png.write(to: diskKey(for: version))
        }
        return image
    }

    /// A plain icon costs nothing and works for a file that is not downloaded.
    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    func isMaterialised(_ url: URL) -> Bool { inspector.isMaterialised(url) }

    private func diskKey(for version: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in version.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return diskDirectory.appending(path: String(hash, radix: 16) + ".png")
    }
}

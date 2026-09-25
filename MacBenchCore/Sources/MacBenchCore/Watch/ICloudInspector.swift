import Foundation

/// What the filesystem can tell us about where a change came from.
public struct FileOriginSignals: Sendable, Hashable {
    /// The file is still arriving, or arrived moments ago.
    public var isDownloading: Bool = false
    public var isNotDownloaded: Bool = false
    /// A `.name.icloud` placeholder for this exact file disappeared just before the
    /// file itself showed up. That is sync materialising a file, nothing else.
    public var wasJustMaterialised: Bool = false
    /// The file is on its way up to the cloud, which only happens for a local edit.
    public var isUploading: Bool = false
    /// How far the file's own modification date is behind the moment we noticed.
    public var contentAge: TimeInterval = 0

    public init() {}
}

/// Who iCloud says last edited a file in a shared folder.
///
/// iCloud keeps this whether or not anybody's app was running — which is the one
/// thing the rest of the attribution cannot do without, because it depends on the
/// app watching on the Mac where the change was made.
public enum SharedEditor: Sendable, Hashable {
    /// Not in a folder shared through iCloud, or iCloud did not say.
    case notShared
    /// The person at this Mac. iCloud leaves the name out for them.
    case currentUser
    /// Somebody else, by the name on their iCloud account.
    case named(PersonNameComponents)
}

/// Reads iCloud's own bookkeeping about a file.
public struct ICloudInspector: Sendable {
    public init() {}

    /// For a document package, ask about the package: the files inside it carry
    /// none of this.
    ///
    /// No name only means the person here once the file has finished moving.
    /// While a new version is still arriving iCloud can leave the name out — it
    /// did, on a Pages document the other person was saving every few minutes,
    /// and the change went down under the wrong name.
    public func sharedEditor(of url: URL) -> SharedEditor {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsSharedKey,
                                         .ubiquitousSharedItemMostRecentEditorNameComponentsKey,
                                         .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.ubiquitousItemIsShared == true else { return .notShared }
        if let name = values.ubiquitousSharedItemMostRecentEditorNameComponents {
            return .named(name)
        }
        let isSettled = values.ubiquitousItemDownloadingStatus == .current
            && values.ubiquitousItemIsDownloading != true
            && values.ubiquitousItemIsUploading != true
        return isSettled ? .currentUser : .notShared
    }

    public func signals(for url: URL, observedAt: Date, recentlyMaterialised: Bool) -> FileOriginSignals {
        var signals = FileOriginSignals()
        signals.wasJustMaterialised = recentlyMaterialised

        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey,
            .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return signals }

        if let modified = values.contentModificationDate {
            signals.contentAge = observedAt.timeIntervalSince(modified)
        }
        guard values.isUbiquitousItem == true else { return signals }
        signals.isDownloading = values.ubiquitousItemIsDownloading ?? false
        signals.isUploading = values.ubiquitousItemIsUploading ?? false
        if let status = values.ubiquitousItemDownloadingStatus {
            signals.isNotDownloaded = status != .current
        }
        return signals
    }

    /// True when the file has an unresolved conflict copy. iCloud creates these
    /// silently when both people save at once, and they are typically found weeks
    /// later — which is why this is the one thing allowed to raise a notification.
    public func hasUnresolvedConflict(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?
            .ubiquitousItemHasUnresolvedConflicts ?? false
    }

    /// Whether the bytes are present. Never call this on a file just to show a
    /// thumbnail: it would pull gigabytes of video down over someone's tethered
    /// connection.
    public func isMaterialised(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return true }
        guard values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    /// Matches the hidden placeholder iCloud leaves for an evicted file
    /// (`.report.pdf.icloud`) back to the file it stands for (`report.pdf`).
    public static func placeholderTarget(ofFileName name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }
}

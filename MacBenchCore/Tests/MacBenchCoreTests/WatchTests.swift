import Foundation
import Testing
@testable import MacBenchCore

@Suite("Exclusions")
struct ExclusionTests {
    let rules = ExclusionRules()

    @Test("Real work is never excluded", arguments: [
        "Kunde A/Layout/plakat.afdesign",
        "Kunde A/Video/schnitt.drp",
        "Kunde B/Text/Angebot final.docx",
        "Kunde B/Bilder/DSC_0042.jpg",
        "Ordner mit Leerzeichen/Datei mit Ümlaut.pdf",
    ])
    func keepsDocuments(path: String) {
        #expect(rules.exclusion(forRelativePath: path, isDirectory: false) == nil)
    }

    @Test("Noise from the usual suspects is excluded", arguments: [
        "Kunde A/.DS_Store",
        "Kunde A/.localized",
        "Kunde A/Layout/.plakat.afdesign.icloud",
        "Kunde A/Layout/~doc.idlk",
        "Kunde A/Text/~$Angebot.docx",
        "Kunde A/Video/CacheClip/clip_0001.dat",
        "Kunde A/Video/ProxyMedia/proxy.mov",
        "Kunde A/Adobe Premiere Pro Auto-Save/schnitt.prproj",
        "Kunde A/Layout/Autosave/plakat.afdesign",
        "Kunde A/Web/node_modules/left-pad/index.js",
        "Kunde A/Web/.git/HEAD",
        "Kunde A/Export/render.mov.tmp",
    ])
    func dropsNoise(path: String) {
        #expect(rules.exclusion(forRelativePath: path, isDirectory: false) != nil,
                "\(path) should not reach the change stream")
    }

    @Test("The app never watches its own log")
    func ignoresOwnLog() {
        #expect(rules.exclusion(forRelativePath: ".macbench/devices/x/000001.jsonl",
                                isDirectory: false) == .ownLog)
    }

    @Test("A folder the user excluded takes its contents with it")
    func userExclusion() {
        let rules = ExclusionRules(userExcludedPaths: ["Kunde A/Rohmaterial"])
        #expect(rules.exclusion(forRelativePath: "Kunde A/Rohmaterial/clip.mov", isDirectory: false)
                == .userExcluded("Kunde A/Rohmaterial"))
        #expect(rules.exclusion(forRelativePath: "Kunde A/Rohmaterial", isDirectory: true)
                == .userExcluded("Kunde A/Rohmaterial"))
        // A sibling whose name merely starts with the same letters stays visible.
        #expect(rules.exclusion(forRelativePath: "Kunde A/Rohmaterial Auswahl/clip.mov",
                                isDirectory: false) == nil)
    }
}

@Suite("Coalescing")
struct CoalescerTests {
    let node = UUID()
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ type: FileEventType, offset: TimeInterval, node: UUID? = nil) -> RawFileEvent {
        RawFileEvent(nodeID: node ?? self.node, relativePath: "Kunde A/plakat.afdesign",
                     isDirectory: false, type: type,
                     contentDate: start.addingTimeInterval(offset),
                     observedAt: start.addingTimeInterval(offset))
    }

    @Test("Seven saves in a row become one line that says seven")
    func foldsRepeatedSaves() {
        var c = Coalescer()
        for i in 0..<7 { c.ingest(event(.modified, offset: Double(i) * 60)) }
        #expect(c.drain(now: start.addingTimeInterval(60)).isEmpty, "the window is still open")
        let out = c.drain(now: start.addingTimeInterval(20 * 60 + 1))
        #expect(out.count == 1)
        #expect(out.first?.event.type == .modified)
        #expect(out.first?.event.count == 7)
    }

    @Test("Two writes a second apart are one save, not two")
    func collapsesBurstWrites() {
        var c = Coalescer()
        c.ingest(event(.modified, offset: 0))
        c.ingest(event(.modified, offset: 1))
        c.ingest(event(.modified, offset: 2))
        let out = c.drainAll()
        #expect(out.first?.event.count == 1)
    }

    @Test("A new file shows up quickly, a quiet change waits")
    func loudEventsSettleFast() {
        var c = Coalescer()
        c.ingest(event(.created, offset: 0))
        #expect(c.drain(now: start.addingTimeInterval(10)).isEmpty)
        #expect(c.drain(now: start.addingTimeInterval(31)).count == 1)
    }

    @Test("A file created and deleted again inside the window never happened")
    func suppressesScratchFiles() {
        var c = Coalescer()
        c.ingest(event(.created, offset: 0))
        c.ingest(event(.removed, offset: 6))
        #expect(c.drainAll().isEmpty)
    }

    @Test("Creating then saving reads as created, not modified")
    func creationWins() {
        var c = Coalescer()
        c.ingest(event(.created, offset: 0))
        c.ingest(event(.modified, offset: 6))
        c.ingest(event(.modified, offset: 12))
        let out = c.drainAll()
        #expect(out.count == 1)
        #expect(out.first?.event.type == .created)
        #expect(out.first?.event.count == 3)
    }

    @Test("The timestamp shown is the file's, never the moment we noticed")
    func usesContentDate() {
        var c = Coalescer()
        let yesterday = start.addingTimeInterval(-86_400)
        c.ingest(RawFileEvent(nodeID: node, relativePath: "a.psd", isDirectory: false,
                              type: .modified, contentDate: yesterday, observedAt: start))
        let out = c.drainAll()
        #expect(out.first?.contentDate == yesterday)
        #expect(out.first?.observedAt == start)
    }

    @Test("Different files keep their own windows")
    func separatesNodes() {
        var c = Coalescer()
        let other = UUID()
        c.ingest(event(.modified, offset: 0))
        c.ingest(event(.created, offset: 0, node: other))
        let out = c.drain(now: start.addingTimeInterval(31))
        #expect(out.count == 1)
        #expect(out.first?.nodeID == other)
        #expect(c.pendingCount == 1)
    }

    @Test("Both machines derive the same dedup key for one change")
    func dedupKeyMatchesAcrossMachines() {
        var here = Coalescer()
        var there = Coalescer()
        here.ingest(event(.modified, offset: 0))
        // The other Mac sees the same file later, but the file's date is the same.
        there.ingest(RawFileEvent(nodeID: node, relativePath: "Kunde A/plakat.afdesign",
                                  isDirectory: false, type: .modified,
                                  contentDate: start, observedAt: start.addingTimeInterval(9_000)))
        #expect(here.drainAll().first?.dedupKey == there.drainAll().first?.dedupKey)
    }

    @Test("The next deadline lets the timer sleep instead of poll")
    func reportsDeadline() {
        var c = Coalescer()
        c.ingest(event(.modified, offset: 0))
        #expect(c.nextDeadline() == start.addingTimeInterval(20 * 60))
        c.ingest(event(.created, offset: 0, node: UUID()))
        #expect(c.nextDeadline() == start.addingTimeInterval(30))
    }
}

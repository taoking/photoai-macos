import Foundation
import Testing
@testable import PhotoAIMac

struct KeyboardShortcutReferenceTests {
    @Test
    func listsEveryCullingEssentialKey() {
        let keys = Set(KeyboardShortcutReference.cullingEssentials.map(\.keys))

        #expect(keys == ["← →", "1–5", "0", "P", "X", "U", "Esc"])
    }

    @Test
    func keepsKeyEntriesUniqueSoTheCheatSheetHasNoDuplicates() {
        let all = KeyboardShortcutReference.all

        #expect(Set(all.map(\.keys)).count == all.count)
        #expect(all.allSatisfy { !$0.keys.isEmpty && !$0.action.isEmpty })
    }

    @Test
    func cullingAnnouncementDescribesTheEssentialKeys() {
        let announcement = KeyboardShortcutReference.cullingAnnouncement

        #expect(announcement.hasPrefix("快速筛选模式："))
        for shortcut in KeyboardShortcutReference.cullingEssentials {
            #expect(announcement.contains(shortcut.keys))
        }
    }

    @Test
    func documentsTheGlobalShortcutsUsersAreMostLikelyToLookUp() {
        let keys = Set(KeyboardShortcutReference.all.map(\.keys))

        #expect(keys.isSuperset(of: ["空格", "F", "E", "⌘Z", "⌘⇧K", "⌘A", "⌘⌥I"]))
    }
}

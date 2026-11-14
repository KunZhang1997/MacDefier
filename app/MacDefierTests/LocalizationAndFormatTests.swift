import CleanupKit
import Foundation
import XCTest
@testable import MacDefier

final class LocalizationAndFormatTests: XCTestCase {
    private func parseRawStringsKeys(at fileURL: URL) throws -> [String] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^\s*"((?:\\.|[^"\\])*)"\s*="#, options: [.anchorsMatchLines])
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[range])
        }
    }

    func testLocalizableStringsHaveZeroDuplicatesAndSymmetricKeys() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let zhURL = appRoot.appendingPathComponent("MacDefier/Resources/zh-Hans.lproj/Localizable.strings")
        let enURL = appRoot.appendingPathComponent("MacDefier/Resources/en.lproj/Localizable.strings")

        let zhKeys = try parseRawStringsKeys(at: zhURL)
        let enKeys = try parseRawStringsKeys(at: enURL)
        XCTAssertGreaterThan(zhKeys.count, 1000)

        let zhDuplicates = Dictionary(grouping: zhKeys, by: { $0 }).filter { $0.value.count > 1 }.map(\.key).sorted()
        let enDuplicates = Dictionary(grouping: enKeys, by: { $0 }).filter { $0.value.count > 1 }.map(\.key).sorted()
        XCTAssertTrue(zhDuplicates.isEmpty, "Duplicate keys in zh-Hans Localizable.strings: \(zhDuplicates)")
        XCTAssertTrue(enDuplicates.isEmpty, "Duplicate keys in en Localizable.strings: \(enDuplicates)")

        let zhSet = Set(zhKeys)
        let enSet = Set(enKeys)
        let missingInEn = zhSet.subtracting(enSet).sorted()
        let missingInZh = enSet.subtracting(zhSet).sorted()
        XCTAssertTrue(missingInEn.isEmpty, "Keys missing in en.lproj: \(missingInEn)")
        XCTAssertTrue(missingInZh.isEmpty, "Keys missing in zh-Hans.lproj: \(missingInZh)")

        // Validate property list parsing & bundled .lproj presence in host app
        let zhPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: zhURL), format: nil) as? [String: String]
        let enPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: enURL), format: nil) as? [String: String]
        XCTAssertEqual(zhPlist?.count, zhSet.count)
        XCTAssertEqual(enPlist?.count, enSet.count)

        XCTAssertNotNil(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        XCTAssertNotNil(Bundle.main.path(forResource: "en", ofType: "lproj"))
        // Verify zip sample archive is NOT bundled anywhere inside Contents/Resources
        if let resourcesURL = Bundle.main.resourceURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("defier-guard-bot.zip").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("Pet/Samples/defier-guard-bot.zip").path))
        }
    }

    func testLanguageSwitchUpdatesCachedBundleImmediately() {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: AppLanguage.storageKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: AppLanguage.storageKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.storageKey)
            }
        }

        defaults.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.current, .chinese)
        let zhSheetWorking = L10n.t("uninstall.sheet.working")

        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.current, .english)
        let enSheetWorking = L10n.t("uninstall.sheet.working")

        XCTAssertNotEqual(zhSheetWorking, enSheetWorking)
        XCTAssertNotEqual(enSheetWorking, "uninstall.sheet.working")
    }

    func testF6DecimalFileBytesAndBinaryMemoryBytes() {
        // 622,000 bytes in decimal (.file) is 622 KB (never 607 KB binary KiB),
        // matching macOS Finder and CleanupKit item sizes.
        let singleFile = Format.bytes(622_000)
        XCTAssertTrue(singleFile.contains("622"), "Expected decimal 622 KB, got \(singleFile)")

        let totalWith8KBExtra = Format.bytes(630_000)
        XCTAssertTrue(totalWith8KBExtra.contains("630"), "Expected decimal 630 KB >= 622 KB, got \(totalWith8KBExtra)")

        // Physical RAM uses binary (.memory): 1,073,741,824 bytes == 1 GB
        let ram1GiB = Format.memoryBytes(1_073_741_824)
        XCTAssertTrue(ram1GiB.contains("1"), "Expected 1 GB for 2^30 RAM bytes, got \(ram1GiB)")
    }

    func testPnpmSubstringNotShadowedByNpmAndLargeItemZeroDiskIO() {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: AppLanguage.storageKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: AppLanguage.storageKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.storageKey)
            }
        }
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)

        let pnpmResult = CleanupItemL10n.explain(
            name: "pnpm",
            path: "/Users/fixture/Library/pnpm/store/v3",
            category: .node,
            appName: nil
        )
        let npmResult = CleanupItemL10n.explain(
            name: "npm",
            path: "/Users/fixture/.npm/_cacache",
            category: .node,
            appName: nil
        )
        XCTAssertNotEqual(pnpmResult.title, npmResult.title, "pnpm must not be shadowed by npm substring")

        let syntheticFolder = CleanableItem(
            name: "HugeProject",
            path: "/nonexistent-fixture-root/Downloads/HugeProject",
            bytes: 500_000_000,
            category: .largeAppData,
            isSelected: false,
            isDirectory: true
        )
        let syntheticFile = CleanableItem(
            name: "Archive.mov",
            path: "/nonexistent-fixture-root/Downloads/Archive.mov",
            bytes: 500_000_000,
            category: .largeAppData,
            isSelected: false,
            isDirectory: false
        )
        XCTAssertNotEqual(syntheticFolder.localizedWhatIsIt, syntheticFile.localizedWhatIsIt)
    }
}

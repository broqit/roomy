import XCTest
@testable import CleanMac

final class PathGuardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRejectsAnotherUsersHome() throws {
        let mine = try makeDir("mine")
        let theirs = try makeDir("theirs/Library/Caches/npm")
        let verdict = PathGuard(home: mine).vetDirectory(theirs)
        guard case .rejected(.outsideHome) = verdict else {
            return XCTFail("expected outsideHome, got \(verdict)")
        }
    }

    func testSkipsSymlinkThatLeavesHome() throws {
        let home = try makeDir("home")
        let outside = try makeDir("outside/secret")
        let cache = try makeDir(home.appendingPathComponent("cache"))
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("escape"), withDestinationURL: outside)
        try Data("ok".utf8).write(to: cache.appendingPathComponent("keep.txt"))

        let listing = PathGuard(home: home).listChildren(of: cache)
        XCTAssertEqual(listing.children.map(\.lastPathComponent), ["keep.txt"])
        XCTAssertGreaterThanOrEqual(listing.skippedSymlinks, 1)
    }

    func testRejectsSymlinkRootEvenIfItStaysInsideHome() throws {
        let home = try makeDir("home")
        let real = try makeDir(home.appendingPathComponent("real"))
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let verdict = PathGuard(home: home).vetDirectory(link)
        guard case .rejected(.symlink) = verdict else {
            return XCTFail("expected symlink, got \(verdict)")
        }
    }

    func testCrashDumpFileMustBeADirectHomeChild() throws {
        let home = try makeDir("home")
        let dump = home.appendingPathComponent("java_error_in_phpstorm_1.log")
        try Data("crash".utf8).write(to: dump)
        let nestedDir = try makeDir(home.appendingPathComponent("project"))
        let nested = nestedDir.appendingPathComponent("java_error_in_phpstorm_1.log")
        try Data("nope".utf8).write(to: nested)
        let folder = try makeDir(home.appendingPathComponent("hs_err_pid1.log"))

        let guarder = PathGuard(home: home)
        guard case .allowed = guarder.vetHomeFile(dump, nameAllowed: CategoryRules.isIDECrashDump) else {
            return XCTFail("direct crash log should be allowed")
        }
        guard case .rejected = guarder.vetHomeFile(nested, nameAllowed: CategoryRules.isIDECrashDump) else {
            return XCTFail("nested crash log must be rejected")
        }
        guard case .rejected = guarder.vetHomeFile(folder, nameAllowed: CategoryRules.isIDECrashDump) else {
            return XCTFail("a directory with a crash name must be rejected")
        }
    }

    func testRevalidateFailsWhenChildBecomesSymlink() throws {
        let home = try makeDir("home")
        let cache = try makeDir(home.appendingPathComponent("cache"))
        let outside = try makeDir("outside")
        let child = cache.appendingPathComponent("item")
        try Data("x".utf8).write(to: child)
        let guarder = PathGuard(home: home)
        let listing = guarder.listChildren(of: cache)
        let expected = try XCTUnwrap(listing.children.first)
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        let again = guarder.revalidate(child, asChildOf: cache, expected: expected)
        guard case .rejected = again else {
            return XCTFail("changed path must be refused, got \(again)")
        }
    }

    private func makeDir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class DiskPressureTests: XCTestCase {
    private let thresholds = PressureThresholds.default

    func testEntersLowImmediatelyBelow20GB() {
        let low = thresholds.pressure(freeBytes: 19_000_000_000, previous: .normal)
        XCTAssertEqual(low, .low)
        XCTAssertEqual(thresholds.pressure(freeBytes: 9_000_000_000, previous: .normal), .critical)
        XCTAssertEqual(thresholds.pressure(freeBytes: 4_000_000_000, previous: .normal), .urgent)
    }

    func testHysteresisHoldsNearTheBoundary() {
        let stillLow = thresholds.pressure(freeBytes: 20_500_000_000, previous: .low)
        XCTAssertEqual(stillLow, .low)
        let recovered = thresholds.pressure(freeBytes: 21_000_000_000, previous: .low)
        XCTAssertEqual(recovered, .normal)
    }

    func testRecoveryFromUrgentStepsThroughHigherStates() {
        let atSeven = thresholds.pressure(freeBytes: 7_000_000_000, previous: .urgent)
        XCTAssertEqual(atSeven, .critical)
        let heldUrgent = thresholds.pressure(freeBytes: 5_500_000_000, previous: .urgent)
        XCTAssertEqual(heldUrgent, .urgent)
    }
}

final class PolicyTests: XCTestCase {
    func testTelegramNamesAreExact() {
        XCTAssertTrue(CategoryRules.isTelegramUserDataDirectory("user_data"))
        XCTAssertTrue(CategoryRules.isTelegramUserDataDirectory("user_data#2"))
        XCTAssertFalse(CategoryRules.isTelegramUserDataDirectory("user_data#2/../../tdata"))
        XCTAssertFalse(CategoryRules.isTelegramUserDataDirectory("user_data.bak"))
        XCTAssertFalse(CategoryRules.isTelegramUserDataDirectory("userdata"))
        XCTAssertTrue(CategoryRules.isTelegramMacMediaCache(relative: "stable/account-1/postbox/media"))
        XCTAssertFalse(CategoryRules.isTelegramMacMediaCache(relative: "stable/account-1/postbox/db"))
        XCTAssertFalse(CategoryRules.isTelegramMacMediaCache(relative: "stable/account-x/postbox/media"))
    }

    func testUnclaimedCachesDoNotDoubleCount() {
        let paths = CategoryRules.unclaimedCachePaths(
            topLevel: ["Google", "Homebrew", "com.apple.Safari", "TemporaryItems", "Firefox"],
            nested: ["Google": ["Chrome", "AndroidStudio"]],
            claimed: ["Google/Chrome", "Homebrew"],
            excludedNames: ["TemporaryItems"],
            excludedPrefixes: ["com.apple."]
        )
        XCTAssertEqual(paths, ["Firefox", "Google/AndroidStudio"])
    }

    func testRecommendationAndBulkSelection() {
        XCTAssertFalse(CategoryRules.recommends(included: false, cleanable: true, appRunning: false, excepted: false))
        XCTAssertTrue(CategoryRules.recommends(included: true, cleanable: true, appRunning: false, excepted: false))
        XCTAssertFalse(CategoryRules.recommends(included: true, cleanable: false, appRunning: false, excepted: false))
        XCTAssertFalse(CategoryRules.recommends(included: true, cleanable: true, appRunning: false, excepted: true))
        XCTAssertFalse(CategoryRules.recommends(included: true, cleanable: true, appRunning: true, excepted: false))
        XCTAssertFalse(CategoryRules.allowsBulkClean(id: "trash", cleanable: true))
        XCTAssertTrue(CategoryRules.allowsBulkClean(id: "npm", cleanable: true))
    }

    func testLanguagesShareKeysAndDetectTheSystem() {
        let ukrainian = L10nTable.keys("uk")
        for code in ["en", "es", "de", "kk"] {
            XCTAssertEqual(L10nTable.keys(code), ukrainian, code)
        }
        XCTAssertEqual(AppLanguage.resolve(preference: "system", preferredLanguages: ["kk-KZ"]), "kk")
        XCTAssertEqual(AppLanguage.resolve(preference: "system", preferredLanguages: ["kz"]), "kk")
        XCTAssertEqual(AppLanguage.resolve(preference: "system", preferredLanguages: ["fr-FR", "es-ES"]), "es")
        XCTAssertEqual(AppLanguage.resolve(preference: "de", preferredLanguages: ["uk"]), "de")
        XCTAssertEqual(AppLanguage.resolve(preference: "system", preferredLanguages: ["fr"]), "en")
        XCTAssertEqual(L10n.t("hero.settings", language: "es"), "Ajustes")
        XCTAssertEqual(L10n.t("cat.android-images", language: "de"), "Android-Geräteimages")
    }

    func testDeviceImageIdentifiersStayNarrow() {
        let json = """
        {"9DFA9201-3E3A-4465-ACCA-758A0F4BE99A":{"identifier":"9DFA9201-3E3A-4465-ACCA-758A0F4BE99A","version":"18.6","build":"22G86","platformIdentifier":"com.apple.platform.iphonesimulator","sizeBytes":1000,"deletable":true},"../etc":{"identifier":"../etc","version":"1","deletable":true}}
        """.data(using: .utf8)!
        let images = DeviceImages.parseRuntimes(json)
        XCTAssertEqual(images.map(\.token), ["9DFA9201-3E3A-4465-ACCA-758A0F4BE99A"])
        XCTAssertEqual(images.first?.name, "iOS 18.6 (22G86)")
        XCTAssertFalse(DeviceImages.isRuntimeIdentifier("all"))
        XCTAssertFalse(DeviceImages.isRuntimeIdentifier("/Library/Developer"))
        XCTAssertFalse(DeviceImages.isAndroidRelativePath("../system-images"))
        XCTAssertFalse(DeviceImages.isAndroidRelativePath("android-33/../../etc"))
        XCTAssertTrue(DeviceImages.isAndroidRelativePath("android-33/google_apis/arm64-v8a"))
    }

    func testRunningAppBytesStayCleanable() {
        let children = [
            MeasuredChild(name: "Chrome", bytes: 10, modified: nil, disposition: .blocked("Google Chrome")),
            MeasuredChild(name: "notes", bytes: 5, modified: nil, disposition: .viewOnly("лише перегляд")),
        ]
        XCTAssertEqual(
            CacheScanner.cleanableByteCount(methodIsCommand: false, revealOnly: false, unrecognized: false, total: 15, children: children),
            10
        )
        XCTAssertEqual(
            CacheScanner.cleanableByteCount(methodIsCommand: false, revealOnly: true, unrecognized: false, total: 15, children: children),
            0
        )
        XCTAssertEqual(
            CacheScanner.cleanableByteCount(methodIsCommand: false, revealOnly: false, unrecognized: true, total: 15, children: children),
            0
        )
    }

    func testDockerSystemDFParsesDecimalSizes() {
        let output = """
        TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
        Images          96        15        35.21GB   7.551GB (21%)
        Containers      17        0         81.01MB   81.01MB (100%)
        Local Volumes   16        9         13.6GB    212.5MB (1%)
        Build Cache     44        0         23.9GB    8.415GB
        """
        let rows = DockerUsage.parse(output)
        XCTAssertEqual(rows.map(\.name), ["Образи", "Контейнери", "Томи", "Кеш збірки"])
        XCTAssertEqual(rows[0].bytes, Int64((35.21 * 1_000_000_000).rounded()))
        XCTAssertEqual(rows[2].reclaimable, Int64((212.5 * 1_000_000).rounded()))
        XCTAssertNil(DockerUsage.parseSize("96"))
        XCTAssertEqual(DockerUsage.buildCacheReclaimable(in: rows), Int64((8.415 * 1_000_000_000).rounded()))
    }

    func testIDECrashDumpNamesStayNarrow() {
        XCTAssertTrue(CategoryRules.isIDECrashDump("java_error_in_phpstorm_1842.log"))
        XCTAssertTrue(CategoryRules.isIDECrashDump("java_error_in_idea.hprof"))
        XCTAssertTrue(CategoryRules.isIDECrashDump("hs_err_pid4242.log"))
        XCTAssertTrue(CategoryRules.isIDECrashDump("replay_pid9.log"))
        XCTAssertFalse(CategoryRules.isIDECrashDump("java_error_in_phpstorm.txt"))
        XCTAssertFalse(CategoryRules.isIDECrashDump("notes.log"))
        XCTAssertFalse(CategoryRules.isIDECrashDump("java_error_in_phpstorm.log/secret"))
        XCTAssertFalse(CategoryRules.isIDECrashDump("../java_error_in_phpstorm.log"))
    }

    func testHomebrewOutsideHomeIsNotACommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let prefix = URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        let plan = CategoryRules.homebrewPlan(
            cache: cache, prefix: prefix, home: home, ownerUID: getuid(), currentUID: getuid(), cacheIsDirectory: true
        )
        guard case let .trashCache(_, note) = plan else {
            return XCTFail("expected trash of the user cache, got \(plan)")
        }
        XCTAssertTrue(note.contains("brew cleanup"))
        try? FileManager.default.removeItem(at: root)
    }

    func testPnpmSkipsBrokenCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let store = home.appendingPathComponent("Library/pnpm/store/v11", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let broken = URL(fileURLWithPath: "/tmp/broken-pnpm")
        let good = URL(fileURLWithPath: "/opt/homebrew/bin/pnpm")
        let choice = CategoryRules.choosePnpm(
            home: home,
            probes: [
                (broken, ToolProbe(exitCode: 1, output: "Cannot find module")),
                (good, ToolProbe(exitCode: 0, output: store.path)),
            ],
            directoryExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        XCTAssertEqual(choice.tool, good)
        XCTAssertEqual(choice.store?.resolvingSymlinksInPath().standardizedFileURL.path, store.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertTrue(choice.ignoredBrokenCandidate)
        XCTAssertNil(choice.problem)
        try? FileManager.default.removeItem(at: root)
    }

    func testNpmCacheOutsideHomeIsRejected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let accepted = CategoryRules.acceptCacheDirectory(
            output: "npm warn something\n\(outside.path)\n",
            home: home,
            directoryExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        XCTAssertNil(accepted)
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: outside)
    }
}

final class CopyAndSuggestionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.testingLanguage = "uk"
    }

    override func tearDown() {
        L10n.testingLanguage = nil
        super.tearDown()
    }

    func testTrashIsNotCalledFreed() {
        let report = CleanReport(
            trashedBytes: 2_300_000_000, cacheReductionBytes: 2_300_000_000, irreversible: false,
            freeBefore: 10_000_000_000, freeAfter: 10_100_000_000, failures: [], skipped: [], categoryNames: ["Bun cache"]
        )
        let toast = ResultCopy.toast(report)
        XCTAssertTrue(toast.contains("Переміщено в Кошик"))
        XCTAssertFalse(toast.contains("Звільнено"))
        XCTAssertTrue(ResultCopy.details(report).contains("інші програми"))
    }

    func testIrreversibleCommandCopy() {
        let report = CleanReport(
            trashedBytes: 0, cacheReductionBytes: 500_000_000, irreversible: true,
            freeBefore: 1, freeAfter: 1, failures: [], skipped: [], categoryNames: ["npm cache"]
        )
        XCTAssertTrue(ResultCopy.toast(report).contains("Кеш зменшився"))
        XCTAssertFalse(ResultCopy.toast(report).contains("Звільнено"))
    }

    func testLowSpaceWithSmallCachesPointsAtSystemStorage() {
        let suggestions = SuggestionEngine.make(SuggestionInput(
            pressure: .low,
            freeBytes: 16_000_000_000,
            items: [SuggestionItem(id: "npm", name: "npm cache", bytes: 20_000_000, accessDenied: false, partial: false, blockedApp: nil, toolProblem: nil, recommend: true, viewOnly: false)],
            scanDate: Date(),
            now: Date(),
            lastReport: nil
        ))
        XCTAssertTrue(suggestions.contains { $0.action == .openStorageSettings })
        XCTAssertFalse(suggestions.contains { if case .reviewCategory = $0.action { return false }; return false })
    }

    func testTelegramBlockSuggestsClosingTheApp() {
        let suggestions = SuggestionEngine.make(SuggestionInput(
            pressure: .normal,
            freeBytes: 40_000_000_000,
            items: [SuggestionItem(id: "telegram-desktop", name: "Telegram Desktop", bytes: 2_000_000_000, accessDenied: false, partial: false, blockedApp: "Telegram", toolProblem: nil, recommend: false, viewOnly: false)],
            scanDate: Date(),
            now: Date(),
            lastReport: nil
        ))
        XCTAssertEqual(suggestions.first?.action, .reviewCategory("telegram-desktop"))
        XCTAssertTrue(suggestions.first?.detail.contains("примусово") == true)
    }

    func testBrokenToolSuggestsRecheckNotDeletion() {
        let suggestions = SuggestionEngine.make(SuggestionInput(
            pressure: .normal,
            freeBytes: 40_000_000_000,
            items: [SuggestionItem(id: "pnpm", name: "pnpm store", bytes: nil, accessDenied: false, partial: false, blockedApp: nil, toolProblem: "Команда pnpm не працює", recommend: false, viewOnly: true)],
            scanDate: Date(),
            now: Date(),
            lastReport: nil
        ))
        XCTAssertEqual(suggestions.first?.action, .refresh)
    }
}

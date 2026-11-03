import Foundation

/// Builds the categories that exist for the current user. Paths come from that user's home
/// and from tool output checked against it — never from another account or a guessed store version.
enum CategoryCatalog {
    static func detect(environment: UserEnvironment = .current()) async -> [CacheCategory] {
        let home = environment.home
        let uid = environment.uid
        var categories: [CacheCategory] = []

        if let pnpm = await pnpmCategory(home: home) { categories.append(pnpm.grouped(.development)) }
        if let npm = await npmCategory(home: home) { categories.append(npm.grouped(.development)) }
        if let yarn = await yarnCategory(home: home) { categories.append(yarn.grouped(.development)) }
        if let bun = bunCategory(home: home, uid: uid) { categories.append(bun.grouped(.development)) }
        if let nodeGyp = nodeGypCategory(home: home) { categories.append(nodeGyp.grouped(.development)) }
        if let homebrew = homebrewCategory(home: home, uid: uid) { categories.append(homebrew.grouped(.development)) }
        if let xcode = xcodeCategory(home: home) { categories.append(xcode.grouped(.development)) }
        if let pods = cocoapodsCategory(home: home) { categories.append(pods.grouped(.development)) }
        if let pip = await pipCategory(home: home) { categories.append(pip.grouped(.development)) }

        let telegramDesktop = telegramDesktopCategory(home: home)
        if let telegramDesktop { categories.append(telegramDesktop.grouped(.messengers)) }
        if let telegramMac = telegramMacCategory(home: home) { categories.append(telegramMac.grouped(.messengers)) }

        categories.append(contentsOf: browserCategories(home: home).map { $0.grouped(.browsers) })
        categories.append(contentsOf: footprintCategories(home: home))
        categories.append(contentsOf: editorCacheCategories(home: home))

        let claimed = Set(categories.compactMap { relativeLibraryCachePath($0, home: home) }.flatMap { $0 })
        categories.append(contentsOf: await libraryCacheCategories(home: home, claimed: claimed))

        let hasRuntimes = await Task.detached { !DeviceImages.xcodeImages(home: home).isEmpty }.value
        if hasRuntimes {
            categories.append(xcodeRuntimesCategory().grouped(.development))
        }
        if let android = androidImagesCategory(home: home) { categories.append(android.grouped(.development)) }
        if let dumps = crashDumpCategory(home: home) { categories.append(dumps.grouped(.development)) }
        if let trash = trashCategory(home: home) { categories.append(trash) }
        return categories
    }

    // MARK: - Tools

    private static func pnpmCategory(home: URL) async -> CacheCategory? {
        var probes: [(tool: URL, probe: ToolProbe)] = []
        let shim = ToolLocator.pnpmShim(home: home)
        if let shim, let probe = await run(shim, ["store", "path"], home: home) {
            probes.append((shim, probe))
        }
        for tool in ToolLocator.findAll("pnpm", home: home) {
            let key = tool.resolvingSymlinksInPath().path
            if let shim, shim.resolvingSymlinksInPath().path == key { continue }
            if probes.contains(where: { $0.tool.resolvingSymlinksInPath().path == key }) { continue }
            if let probe = await run(tool, ["store", "path"], home: home) {
                probes.append((tool, probe))
            }
        }
        guard !probes.isEmpty else { return nil }
        let choice = CategoryRules.choosePnpm(home: home, probes: probes, directoryExists: isDirectory)
        if let store = choice.store, let tool = choice.tool {
            let displayStore = tilde(store, home: home)
            var note = "Видаляє лише пакети, які не використовує жоден проєкт. Поточний розмір store більший за те, що зникне."
            if choice.ignoredBrokenCandidate {
                note = "Файл ~/Library/pnpm/pnpm не запускається, використано інший pnpm. " + note
            }
            return CacheCategory(
                id: "pnpm",
                name: "pnpm store",
                symbol: "shippingbox",
                roots: [store],
                method: .command(
                    executable: tool,
                    arguments: ["store", "prune", "--yes", "--store-dir", store.path, "--dir", home.path],
                    display: "pnpm store prune --yes --store-dir \(displayStore)",
                    scope: store
                ),
                note: note,
                consequences: "Невикористані пакети доведеться завантажити знову. Команда безповоротна.",
                includeInRecommendations: true,
                toolProblem: nil
            )
        }
        return CacheCategory(
            id: "pnpm",
            name: "pnpm store",
            symbol: "shippingbox",
            roots: [],
            method: .revealOnly,
            note: choice.problem,
            consequences: "Store не змінюється, доки команда pnpm не запрацює.",
            includeInRecommendations: false,
            toolProblem: choice.problem
        )
    }

    private static func npmCategory(home: URL) async -> CacheCategory? {
        guard let npm = ToolLocator.find("npm", home: home),
              let probe = await run(npm, ["config", "get", "cache"], home: home) else { return nil }
        guard let cache = CategoryRules.acceptCacheDirectory(output: probe.output, home: home, directoryExists: isDirectory) else {
            let problem = "npm cache не вдалося обмежити домашньою текою (\(npm.lastPathComponent)). Кеш не змінювався."
            return CacheCategory(
                id: "npm", name: "npm cache", symbol: "cube.box", roots: [], method: .revealOnly,
                note: problem, consequences: "Без підтвердженого каталогу кешу команда не запускається.",
                includeInRecommendations: false, toolProblem: problem
            )
        }
        let display = tilde(cache, home: home)
        return CacheCategory(
            id: "npm",
            name: "npm cache",
            symbol: "cube.box",
            roots: [cache],
            method: .command(
                executable: npm,
                arguments: ["cache", "clean", "--force", "--cache", cache.path],
                display: "npm cache clean --force --cache \(display)",
                scope: cache
            ),
            note: "Команда очищає весь цей каталог кешу, не окремий вкладений файл.",
            consequences: "Пакети завантажаться знову. Видалення безповоротне й не йде через Кошик.",
            includeInRecommendations: true
        )
    }

    private static func yarnCategory(home: URL) async -> CacheCategory? {
        let fallback = home.appendingPathComponent("Library/Caches/Yarn", isDirectory: true)
        guard let yarn = ToolLocator.find("yarn", home: home) else {
            return trashCategory(
                id: "yarn", name: "Yarn cache", symbol: "cube", roots: existingDirectories([fallback], home: home),
                note: "Команду yarn не знайдено, тому файли підуть у Кошик.",
                consequences: "Пакети Yarn завантажаться знову."
            )
        }
        guard let probe = await run(yarn, ["cache", "dir"], home: home),
              let cache = CategoryRules.acceptCacheDirectory(output: probe.output, home: home, directoryExists: isDirectory) else {
            return trashCategory(
                id: "yarn", name: "Yarn cache", symbol: "cube", roots: existingDirectories([fallback], home: home),
                note: "yarn cache dir не підтвердив каталог у домашній теці. Якщо тека є, файли підуть у Кошик.",
                consequences: "Пакети Yarn завантажаться знову."
            )
        }
        let display = tilde(cache, home: home)
        return CacheCategory(
            id: "yarn", name: "Yarn cache", symbol: "cube", roots: [cache],
            method: .command(
                executable: yarn,
                arguments: ["cache", "clean", "--cache-folder", cache.path],
                display: "yarn cache clean --cache-folder \(display)",
                scope: cache
            ),
            consequences: "Пакети Yarn завантажаться знову. Команда безповоротна.",
            includeInRecommendations: true
        )
    }

    private static func bunCategory(home: URL, uid: uid_t) -> CacheCategory? {
        let cache = home.appendingPathComponent(".bun/install/cache", isDirectory: true)
        guard isDirectory(cache), case .allowed = PathGuard(home: home).vetDirectory(cache) else { return nil }
        guard PathGuard(home: home).ownerUID(cache) == uid else {
            return CacheCategory(
                id: "bun", name: "Bun cache", symbol: "hare", roots: [cache], method: .revealOnly,
                note: "Власник кешу Bun не збігається з поточним користувачем.",
                consequences: "Каталог не змінюється.", includeInRecommendations: false,
                toolProblem: "Кеш Bun належить іншому власнику. Лише перегляд."
            )
        }
        return CacheCategory(
            id: "bun", name: "Bun cache", symbol: "hare", roots: [cache], method: .trashContents,
            note: "У цій версії Bun немає перевіреної команди очищення кешу. Файли буде переміщено в Кошик.",
            consequences: "Пакети Bun завантажаться знову.",
            includeInRecommendations: true
        )
    }

    private static func nodeGypCategory(home: URL) -> CacheCategory? {
        let roots = existingDirectories([
            home.appendingPathComponent("Library/Caches/node-gyp", isDirectory: true),
            home.appendingPathComponent(".node-gyp", isDirectory: true),
            home.appendingPathComponent(".cache/node-gyp", isDirectory: true),
        ], home: home)
        return trashCategory(
            id: "node-gyp", name: "node-gyp", symbol: "hammer", roots: roots,
            note: "Заголовки Node, завантажуються знову за потреби.",
            consequences: "Наступне збирання нативних модулів завантажить заголовки ще раз."
        )
    }

    private static func homebrewCategory(home: URL, uid: uid_t) -> CacheCategory? {
        let cache = home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        let prefix = ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0, isDirectory: true) }.first(where: isDirectory)
        let owner = isDirectory(cache) ? PathGuard(home: home).ownerUID(cache) : nil
        switch CategoryRules.homebrewPlan(cache: isDirectory(cache) ? cache : nil, prefix: prefix, home: home, ownerUID: owner, currentUID: uid, cacheIsDirectory: isDirectory(cache)) {
        case .hidden:
            return nil
        case let .viewOnly(reason):
            return CacheCategory(
                id: "homebrew", name: "Homebrew cache", symbol: "mug", roots: isDirectory(cache) ? [cache] : [],
                method: .revealOnly, note: reason, consequences: "Спільний Homebrew не змінюється.",
                includeInRecommendations: false, toolProblem: reason
            )
        case let .trashCache(resolved, note):
            return CacheCategory(
                id: "homebrew", name: "Homebrew cache", symbol: "mug", roots: [resolved],
                method: .trashContents, note: note,
                consequences: "Завантаження формул повторяться. Старі версії у Cellar ця дія не чіпає.",
                includeInRecommendations: true
            )
        }
    }

    private static func xcodeCategory(home: URL) -> CacheCategory? {
        let root = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        guard isDirectory(root), case .allowed = PathGuard(home: home).vetDirectory(root) else { return nil }
        return CacheCategory(
            id: "xcode", name: "Xcode DerivedData", symbol: "hammer.circle", roots: [root],
            method: .trashContents,
            blockingApps: [BlockingApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")],
            consequences: "Наступна збірка проєктів Xcode триватиме довше.",
            includeInRecommendations: true
        )
    }

    private static func cocoapodsCategory(home: URL) -> CacheCategory? {
        let root = home.appendingPathComponent("Library/Caches/CocoaPods", isDirectory: true)
        return trashCategory(
            id: "cocoapods", name: "CocoaPods cache", symbol: "leaf", roots: existingDirectories([root], home: home),
            note: "pod cache clean не запускається: його обсяг не обмежено окремим прапорцем. Файли підуть у Кошик.",
            consequences: "Поди завантажаться знову."
        )
    }

    private static func pipCategory(home: URL) async -> CacheCategory? {
        guard let pip = ToolLocator.find("pip3", home: home) ?? ToolLocator.find("pip", home: home),
              let probe = await run(pip, ["cache", "dir"], home: home),
              let cache = CategoryRules.acceptCacheDirectory(output: probe.output, home: home, directoryExists: isDirectory) else { return nil }
        let display = tilde(cache, home: home)
        return CacheCategory(
            id: "pip", name: "pip cache", symbol: "chevron.left.forwardslash.chevron.right", roots: [cache],
            method: .command(
                executable: pip,
                arguments: ["--cache-dir", cache.path, "cache", "purge"],
                display: "\(pip.lastPathComponent) --cache-dir \(display) cache purge",
                scope: cache
            ),
            consequences: "Колеса Python завантажаться знову. Команда безповоротна.",
            includeInRecommendations: true
        )
    }

    // MARK: - Apps

    private static func telegramDesktopCategory(home: URL) -> CacheCategory? {
        let tdata = home.appendingPathComponent("Library/Application Support/Telegram Desktop/tdata", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tdata.path)) ?? []
        var roots: [URL] = []
        for name in names where CategoryRules.isTelegramUserDataDirectory(name) {
            for cacheName in CategoryRules.telegramCacheNames {
                roots.append(tdata.appendingPathComponent(name).appendingPathComponent(cacheName, isDirectory: true))
            }
        }
        roots.append(home.appendingPathComponent("Library/Caches/com.tdesktop.Telegram", isDirectory: true))
        let existing = existingDirectories(roots, home: home)
        guard !existing.isEmpty else { return nil }
        return CacheCategory(
            id: "telegram-desktop",
            name: "Telegram Desktop",
            symbol: "paperplane",
            roots: existing,
            method: .trashContents,
            blockingApps: [BlockingApp(bundleID: "com.tdesktop.Telegram", name: "Telegram")],
            note: "Лише cache, media_cache і кеш у Library/Caches. База, ключі, сесії й увесь tdata не входять.",
            consequences: "Медіа й файли кешу завантажаться знову. Дані акаунта не чіпаються.",
            includeInRecommendations: false
        )
    }

    private static func telegramMacCategory(home: URL) -> CacheCategory? {
        let group = home.appendingPathComponent("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", isDirectory: true)
        var roots: [URL] = []
        for channel in CategoryRules.telegramMacChannels {
            let channelURL = group.appendingPathComponent(channel, isDirectory: true)
            let accounts = (try? FileManager.default.contentsOfDirectory(atPath: channelURL.path)) ?? []
            for account in accounts {
                let relative = "\(channel)/\(account)/postbox/media"
                guard CategoryRules.isTelegramMacMediaCache(relative: relative) else { continue }
                roots.append(group.appendingPathComponent(relative, isDirectory: true))
            }
        }
        let existing = existingDirectories(roots, home: home)
        guard !existing.isEmpty else { return nil }
        return CacheCategory(
            id: "telegram-macos",
            name: "Telegram (macOS)",
            symbol: "paperplane.fill",
            roots: existing,
            method: .trashContents,
            blockingApps: [BlockingApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram")],
            note: "Лише postbox/media. База postbox/db не входить.",
            consequences: "Медіа завантажаться знову. Повідомлення й акаунт не чіпаються.",
            includeInRecommendations: false
        )
    }

    private static func browserCategories(home: URL) -> [CacheCategory] {
        let browsers: [(id: String, name: String, symbol: String, path: String, bundle: String, app: String)] = [
            ("chrome", "Chrome cache", "globe", "Library/Caches/Google/Chrome", "com.google.Chrome", "Google Chrome"),
            ("safari", "Safari cache", "safari", "Library/Caches/com.apple.Safari", "com.apple.Safari", "Safari"),
            ("arc", "Arc cache", "circle.hexagongrid", "Library/Caches/company.thebrowser.Browser", "company.thebrowser.Browser", "Arc"),
        ]
        return browsers.compactMap { browser in
            let root = home.appendingPathComponent(browser.path, isDirectory: true)
            guard isDirectory(root), case .allowed = PathGuard(home: home).vetDirectory(root) else { return nil }
            return CacheCategory(
                id: browser.id, name: browser.name, symbol: browser.symbol, roots: [root],
                method: .trashContents,
                blockingApps: [BlockingApp(bundleID: browser.bundle, name: browser.app)],
                note: "Лише кеш у ~/Library/Caches, не профіль і не закладки.",
                consequences: "Сторінки можуть відкриватися повільніше, офлайн-копії зникнуть.",
                includeInRecommendations: false
            )
        }
    }

    private static func libraryCacheCategories(home: URL, claimed: Set<String>) async -> [CacheCategory] {
        let library = home.appendingPathComponent("Library/Caches", isDirectory: true)
        guard isDirectory(library) else { return [] }
        let excludedNames: Set<String> = ["TemporaryItems", Bundle.main.bundleIdentifier ?? "com.mortimer.CleanMac"]
        let top = directoryNames(library)
        var nested: [String: [String]] = [:]
        for name in top where claimed.contains(where: { $0.hasPrefix(name + "/") }) {
            nested[name] = directoryNames(library.appendingPathComponent(name, isDirectory: true))
        }
        let relative = CategoryRules.unclaimedCachePaths(
            topLevel: top, nested: nested, claimed: claimed,
            excludedNames: excludedNames, excludedPrefixes: ["com.apple."]
        )
        var identified: [URL] = []
        var unrecognized: [URL] = []
        let installed = await MainActor.run {
            Set(relative.filter { InstalledApps.isInstalled(bundleID: URL(fileURLWithPath: $0).lastPathComponent) })
        }
        for path in relative {
            let url = library.appendingPathComponent(path, isDirectory: true)
            guard case .allowed = PathGuard(home: home).vetDirectory(url) else { continue }
            if installed.contains(path) {
                identified.append(url)
            } else {
                unrecognized.append(url)
            }
        }
        var results: [CacheCategory] = []
        if !identified.isEmpty {
            results.append(CacheCategory(
                id: "library-caches",
                name: "Інші кеші програм",
                symbol: "folder",
                roots: identified,
                method: .trashContents,
                childFilter: .identifiedApplications,
                blocksMatchingBundleChildren: true,
                note: "Лише теки, чий власник — встановлена програма. Якщо програма запущена, підтвердження її закриє.",
                consequences: "Програма створить кеш знову. Дані, які не вдалося пов’язати з програмою, сюди не входять.",
                includeInRecommendations: false
            ))
        }
        if !unrecognized.isEmpty {
            results.append(CacheCategory(
                id: "unrecognized-caches",
                name: "Нерозпізнані кеші",
                symbol: "questionmark.folder",
                roots: unrecognized,
                method: .revealOnly,
                childFilter: .unrecognized,
                note: "Власника надійно не визначено, тому лише перегляд і показ у Finder.",
                consequences: "Roomy ці теки не змінює.",
                includeInRecommendations: false
            ))
        }
        return results
    }

    // MARK: - App footprints

    /// Caches that can be removed without chat history, plus view-only rows for the data that must stay.
    private static func footprintCategories(home: URL) -> [CacheCategory] {
        var categories: [CacheCategory] = []
        if let docker = dockerCategory(home: home) { categories.append(docker.grouped(.development)) }
        if let cursor = cursorCacheCategory(home: home) { categories.append(cursor.grouped(.ai)) }
        if let kept = cursorKeptCategory(home: home) { categories.append(kept.grouped(.ai)) }
        if let claude = claudeCacheCategory(home: home) { categories.append(claude.grouped(.ai)) }
        if let codex = codexCacheCategory(home: home) { categories.append(codex.grouped(.ai)) }
        if let sessions = codexSessionsCategory(home: home) { categories.append(sessions.grouped(.ai)) }
        if let chats = chatGPTHistoryCategory(home: home) { categories.append(chats.grouped(.ai)) }
        if let viber = viberCacheCategory(home: home) { categories.append(viber.grouped(.messengers)) }
        if let viberData = viberDataCategory(home: home) { categories.append(viberData.grouped(.messengers)) }
        return categories
    }

    private static func dockerCategory(home: URL) -> CacheCategory? {
        let config = home.appendingPathComponent(".docker", isDirectory: true)
        let roots = isDirectory(config) ? [config] : []
        let installed = FileManager.default.fileExists(atPath: "/Applications/OrbStack.app")
            || FileManager.default.fileExists(atPath: "/Applications/Docker.app")
        guard installed || ToolLocator.find("docker", home: home) != nil || !roots.isEmpty else { return nil }
        let method: CleanMethod
        if let docker = ToolLocator.find("docker", home: home) {
            method = .command(
                executable: docker,
                arguments: ["builder", "prune", "-f"],
                display: "docker builder prune -f",
                scope: home
            )
        } else {
            method = .revealOnly
        }
        return CacheCategory(
            id: "docker-orbstack",
            name: "Docker і OrbStack",
            symbol: "shippingbox",
            roots: roots,
            method: method,
            usageProbe: .dockerSystemDF,
            note: "Розмір із docker system df. Очищення забирає лише зайвий кеш збірки.",
            consequences: "Кеш збірки доведеться зібрати знову. Образи, томи, контейнери й файл диска OrbStack не чіпаються.",
            includeInRecommendations: false
        )
    }

    private static func cursorCacheCategory(home: URL) -> CacheCategory? {
        let support = home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        let folders = ["Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "CachedData", "logs", "Service Worker", "CachedProfilesData"]
        var urls = folders.map { support.appendingPathComponent($0, isDirectory: true) }
        urls.append(home.appendingPathComponent("Library/Caches/cursor-compile-cache", isDirectory: true))
        return cleanableCaches(
            id: "cursor-caches",
            name: "Кеш Cursor",
            symbol: "sparkles",
            roots: existingDirectories(urls, home: home),
            blocking: [BlockingApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor")],
            note: "Кеш, логи й тимчасові дані. Чати, state.vscdb і локальна історія файлів сюди не входять.",
            consequences: "Cursor створить кеш знову. Історія розмов і налаштування залишаються."
        )
    }

    private static func cursorKeptCategory(home: URL) -> CacheCategory? {
        let user = home.appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
        var urls = existingDirectories([
            user.appendingPathComponent("History", isDirectory: true),
            user.appendingPathComponent("workspaceStorage", isDirectory: true),
            user.appendingPathComponent("globalStorage/anysphere.cursor-agent-worker/agent-cli", isDirectory: true),
        ], home: home)
        let state = user.appendingPathComponent("globalStorage/state.vscdb")
        if FileManager.default.fileExists(atPath: state.path), !isDirectory(state) {
            urls.append(state)
        }
        guard !urls.isEmpty else { return nil }
        return CacheCategory(
            id: "cursor-kept",
            name: "Cursor — історія й агент",
            symbol: "bubble.left.and.bubble.right",
            roots: urls,
            method: .revealOnly,
            note: "state.vscdb і History — історія. agent-cli — завантажені версії агента, не чати, але Roomy їх не видаляє, бо ними може користуватися поточний Cursor.",
            consequences: "Roomy ці дані не змінює.",
            includeInRecommendations: false
        )
    }

    private static func claudeCacheCategory(home: URL) -> CacheCategory? {
        let support = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let folders = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache"]
        var urls = folders.map { support.appendingPathComponent($0, isDirectory: true) }
        urls.append(home.appendingPathComponent(".claude/cache", isDirectory: true))
        urls.append(home.appendingPathComponent(".claude/debug", isDirectory: true))
        return cleanableCaches(
            id: "claude-caches",
            name: "Кеш Claude",
            symbol: "text.bubble",
            roots: existingDirectories(urls, home: home),
            blocking: [BlockingApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude")],
            note: "Кеш застосунку й журнали налагодження. ~/.claude/projects і history.jsonl не входять.",
            consequences: "Claude створить кеш знову. Історія розмов залишається."
        )
    }

    private static func codexCacheCategory(home: URL) -> CacheCategory? {
        let urls = [
            home.appendingPathComponent("Library/Caches/com.openai.codex", isDirectory: true),
            home.appendingPathComponent("Library/Caches/Codex", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Codex/component_crx_cache", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Codex/GraphiteDawnCache", isDirectory: true),
            home.appendingPathComponent(".codex/cache", isDirectory: true),
        ]
        return cleanableCaches(
            id: "codex-caches",
            name: "Кеш Codex і ChatGPT",
            symbol: "sparkle",
            roots: existingDirectories(urls, home: home),
            blocking: [
                BlockingApp(bundleID: "com.openai.codex", name: "ChatGPT"),
                BlockingApp(bundleID: "com.openai.chat", name: "ChatGPT"),
            ],
            note: "Кеш оновлень Sparkle і дрібний кеш браузера. Сесії Codex і розмови ChatGPT сюди не входять.",
            consequences: "Оновлення й кеш завантажаться знову. Історія чатів залишається."
        )
    }

    private static func codexSessionsCategory(home: URL) -> CacheCategory? {
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let roots = existingDirectories([sessions], home: home)
        guard !roots.isEmpty else { return nil }
        return CacheCategory(
            id: "codex-sessions",
            name: "Сесії Codex",
            symbol: "text.bubble",
            roots: roots,
            method: .revealOnly,
            note: "Історія сесій Codex.",
            consequences: "Roomy сесії не видаляє.",
            includeInRecommendations: false
        )
    }

    private static func chatGPTHistoryCategory(home: URL) -> CacheCategory? {
        let root = home.appendingPathComponent("Library/Application Support/com.openai.chat", isDirectory: true)
        guard isDirectory(root), case .allowed = PathGuard(home: home).vetDirectory(root) else { return nil }
        return CacheCategory(
            id: "chatgpt-history",
            name: "Історія ChatGPT",
            symbol: "text.bubble",
            roots: [root],
            method: .revealOnly,
            note: "Локальні розмови ChatGPT.",
            consequences: "Roomy історію не видаляє.",
            includeInRecommendations: false
        )
    }

    private static func viberCacheCategory(home: URL) -> CacheCategory? {
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        var urls = [
            caches.appendingPathComponent("com.viber.osx", isDirectory: true),
            caches.appendingPathComponent("SentryCrash/Viber", isDirectory: true),
        ]
        let media = directoryNames(caches).filter { $0.hasPrefix("Viber Media") }
        urls += media.map { caches.appendingPathComponent($0, isDirectory: true) }
        return cleanableCaches(
            id: "viber-caches",
            name: "Кеш Viber",
            symbol: "phone",
            roots: existingDirectories(urls, home: home),
            blocking: [BlockingApp(bundleID: "com.viber.osx", name: "Viber")],
            note: "Лише кеш і звіти про падіння. База ViberPC і листування не входять.",
            consequences: "Viber створить кеш знову. Листування залишається."
        )
    }

    private static func viberDataCategory(home: URL) -> CacheCategory? {
        let root = home.appendingPathComponent("Library/Application Support/ViberPC", isDirectory: true)
        guard isDirectory(root), case .allowed = PathGuard(home: home).vetDirectory(root) else { return nil }
        return CacheCategory(
            id: "viber-data",
            name: "Дані Viber",
            symbol: "phone",
            roots: [root],
            method: .revealOnly,
            note: "Обліковий запис і локальна база. Це не кеш.",
            consequences: "Roomy дані Viber не змінює.",
            includeInRecommendations: false
        )
    }

    private static func cleanableCaches(
        id: String,
        name: String,
        symbol: String,
        roots: [URL],
        blocking: [BlockingApp],
        note: String,
        consequences: String
    ) -> CacheCategory? {
        guard !roots.isEmpty else { return nil }
        return CacheCategory(
            id: id,
            name: name,
            symbol: symbol,
            roots: roots,
            method: .trashContents,
            blockingApps: blocking,
            note: note,
            consequences: consequences,
            includeInRecommendations: true
        )
    }

    /// PhpStorm and other JetBrains IDEs leave `java_error_in_*.log` / `.hprof` and `hs_err_pid*.log` in the home folder after a crash.
    /// Only those file names, only as direct children of this user's home. The home folder itself is never a root.
    private static func crashDumpCategory(home: URL) -> CacheCategory? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let guarder = PathGuard(home: home)
        let files = names.compactMap { name -> URL? in
            guard CategoryRules.isIDECrashDump(name) else { return nil }
            let url = home.appendingPathComponent(name)
            guard case .allowed = guarder.vetHomeFile(url, nameAllowed: CategoryRules.isIDECrashDump) else { return nil }
            return url
        }
        guard !files.isEmpty else { return nil }
        return CacheCategory(
            id: "ide-crash-dumps",
            name: "Аварійні файли IDE",
            symbol: "exclamationmark.triangle",
            roots: files,
            method: .trashContents,
            childFilter: .namedFiles,
            note: "Журнали та дампи пам’яті, які PhpStorm, IDEA, WebStorm та інші IDE залишають у домашній теці після падіння.",
            consequences: "Проєкти й налаштування IDE не чіпаються. Дамп може знадобитися, лише якщо ви самі розбираєте падіння.",
            includeInRecommendations: false
        )
    }

    private static func xcodeRuntimesCategory() -> CacheCategory {
        CacheCategory(
            id: "xcode-runtimes",
            name: "Образи пристроїв Xcode",
            symbol: "iphone",
            roots: [],
            method: .revealOnly,
            usageProbe: .deviceImages,
            consequences: "Кожен образ видаляється окремо й безповоротно. Проєкти Xcode не чіпаються.",
            includeInRecommendations: false
        )
    }

    private static func androidImagesCategory(home: URL) -> CacheCategory? {
        let root = home.appendingPathComponent("Library/Android/sdk/system-images", isDirectory: true)
        guard isDirectory(root), case .allowed = PathGuard(home: home).vetDirectory(root) else { return nil }
        guard !PathGuard(home: home).listChildren(of: root).children.isEmpty else { return nil }
        return CacheCategory(
            id: "android-images",
            name: "Образи пристроїв Android",
            symbol: "square.stack.3d.up",
            roots: [root],
            method: .revealOnly,
            usageProbe: .deviceImages,
            consequences: "Кожен образ іде в Кошик окремо. SDK і проєкти лишаються.",
            includeInRecommendations: false
        )
    }

    private static func trashCategory(home: URL) -> CacheCategory? {
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        guard isDirectory(trash), case .allowed = PathGuard(home: home).vetDirectory(trash) else { return nil }
        return CacheCategory(
            id: "trash", name: "Кошик", symbol: "trash", roots: [trash], method: .revealOnly,
            note: "Спорожнення лишається у Finder. Кошик не входить у «Очистити вибране».",
            consequences: "Roomy не видаляє вміст Кошика.",
            includeInRecommendations: false
        )
    }

    /// Regenerable editor and browser caches that would otherwise land in the unrecognized bucket.
    private static func editorCacheCategories(home: URL) -> [CacheCategory] {
        var categories: [CacheCategory] = []
        if let firefox = cleanableCaches(
            id: "firefox",
            name: "Кеш Firefox",
            symbol: "flame",
            roots: existingDirectories([
                home.appendingPathComponent("Library/Caches/Firefox", isDirectory: true),
                home.appendingPathComponent("Library/Caches/org.mozilla.firefox", isDirectory: true),
            ], home: home),
            blocking: [BlockingApp(bundleID: "org.mozilla.firefox", name: "Firefox")],
            note: "Лише кеш у ~/Library/Caches. Профіль, закладки й паролі не входять.",
            consequences: "Сторінки можуть відкриватися повільніше. Профіль Firefox не змінюється."
        ) {
            categories.append(firefox.grouped(.browsers))
        }
        if let jetbrains = cleanableCaches(
            id: "jetbrains-caches",
            name: "Кеш JetBrains",
            symbol: "chevron.left.forwardslash.chevron.right",
            roots: existingDirectories([
                home.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true),
            ], home: home),
            blocking: jetBrainsApps,
            note: "Лише ~/Library/Caches/JetBrains. Проєкти, налаштування й плагіни не входять.",
            consequences: "IDE збудує індекси знову. Проєкти й налаштування залишаються."
        ) {
            categories.append(jetbrains.grouped(.development))
        }
        if let studio = cleanableCaches(
            id: "android-studio-caches",
            name: "Кеш Android Studio",
            symbol: "square.dashed",
            roots: androidStudioCacheRoots(home: home),
            blocking: [BlockingApp(bundleID: "com.google.android.studio", name: "Android Studio")],
            note: "Лише теки AndroidStudio у ~/Library/Caches. Gradle, SDK і проєкти не входять.",
            consequences: "Студія створить кеш знову. SDK і проєкти не змінюються."
        ) {
            categories.append(studio.grouped(.development))
        }
        return categories
    }

    private static let jetBrainsApps = [
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.CLion",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.datagrip",
        "com.jetbrains.rubymine",
        "com.jetbrains.AppCode",
        "com.jetbrains.rustrover",
    ].map { BlockingApp(bundleID: $0, name: "JetBrains") }

    private static func androidStudioCacheRoots(home: URL) -> [URL] {
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let google = caches.appendingPathComponent("Google", isDirectory: true)
        let top = directoryNames(caches).filter { $0.hasPrefix("AndroidStudio") }
        let nested = directoryNames(google).filter { $0.hasPrefix("AndroidStudio") }
        let urls = top.map { caches.appendingPathComponent($0, isDirectory: true) }
            + nested.map { google.appendingPathComponent($0, isDirectory: true) }
        return existingDirectories(urls, home: home)
    }

    // MARK: - Helpers

    private static func trashCategory(id: String, name: String, symbol: String, roots: [URL], note: String, consequences: String) -> CacheCategory? {
        guard !roots.isEmpty else { return nil }
        return CacheCategory(
            id: id, name: name, symbol: symbol, roots: roots, method: .trashContents,
            note: note, consequences: consequences, includeInRecommendations: true
        )
    }

    private static func existingDirectories(_ urls: [URL], home: URL) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard isDirectory(url), case let .allowed(resolved) = PathGuard(home: home).vetDirectory(url) else { return nil }
            guard seen.insert(resolved.path).inserted else { return nil }
            return resolved
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func directoryNames(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { name in
            var isDirectory: ObjCBool = false
            let child = url.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func relativeLibraryCachePath(_ category: CacheCategory, home: URL) -> [String]? {
        let root = home.appendingPathComponent("Library/Caches").resolvingSymlinksInPath().standardizedFileURL.path
        let paths = category.roots.compactMap { url -> String? in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { return nil }
            return String(path.dropFirst(root.count + 1))
        }
        return paths.isEmpty ? nil : paths
    }

    private static func tilde(_ url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    private static func run(_ tool: URL, _ arguments: [String], home: URL) async -> ToolProbe? {
        await Task.detached(priority: .utility) {
            let result = ToolRunner.run(tool, arguments, home: home, timeout: 8)
            return ToolProbe(exitCode: result.exitCode, output: result.output, timedOut: result.timedOut)
        }.value
    }
}

import AppKit
import SwiftUI

struct CacheListView: View {
    @ObservedObject var store: CacheStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var disk: DiskMonitor
    @ObservedObject var history: HistoryStore
    var hasNotch: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false
    @State private var expandedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSettings {
                settingsHeader
                settingsView
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                hero
                if MeterRow.isVisible(settings) {
                    MeterRow(settings: settings, disk: disk)
                        .transition(.opacity)
                }
                if let banner = store.banner {
                    bannerView(banner)
                } else {
                    suggestion
                }
                ZStack {
                    VStack(spacing: 12) {
                        list.frame(maxHeight: .infinity)
                        footer
                    }
                    if let pending = store.pendingClean {
                        confirmationOverlay(pending)
                            .transition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: motion), value: showsSettings)
        .animation(.easeInOut(duration: motion), value: store.pendingClean != nil)
        .animation(.easeInOut(duration: motion), value: expandedID)
        .animation(.easeInOut(duration: motion), value: MeterRow.isVisible(settings))
        .animation(.easeInOut(duration: motion), value: store.isScanning)
    }

    private var motion: Double { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.18 }

    // MARK: Hero

    private var settingsHeader: some View {
        HStack {
            Text(L10n.t("hero.settings"))
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button { showsSettings = false } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconCircleStyle())
            .help(L10n.t("hero.settings.close"))
            .accessibilityLabel(L10n.t("hero.settings.close"))
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(cacheAmount)
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.primary)
                        .contentTransition(.numericText())
                    Text(cacheCaption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(secondaryLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(cacheCaption) \(cacheAmount). \(secondaryLine)")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if store.isScanning {
                    ScanSeeker(reduceMotion: motion < 0.05)
                    Button(L10n.t("hero.stop")) { store.cancelScan() }
                        .buttonStyle(QuietPillStyle())
                        .accessibilityLabel(L10n.t("hero.stop"))
                } else {
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconCircleStyle())
                        .help(L10n.t("hero.refresh"))
                        .accessibilityLabel(L10n.t("hero.refresh"))
                        .disabled(store.isCleaning)
                }
                Button { showsSettings.toggle() } label: {
                    Image(systemName: showsSettings ? "xmark" : "gearshape")
                }
                .buttonStyle(IconCircleStyle())
                .help(showsSettings ? L10n.t("hero.settings.close") : L10n.t("hero.settings"))
                .accessibilityLabel(showsSettings ? L10n.t("hero.settings.close") : L10n.t("hero.settings"))
            }
        }
    }

    private var cacheAmount: String {
        if store.isScanning, !store.hasScannedAnything { return "…" }
        return ByteFormat.string(store.totalKnownBytes)
    }

    private var cacheCaption: String {
        store.totalsComplete ? L10n.t("hero.cache") : L10n.t("hero.cache.atLeast")
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if store.isScanning {
            parts.append(store.plannedCount > 0 ? L10n.f("hero.progress", store.scannedCount, store.plannedCount) : L10n.t("hero.counting"))
        } else if let last = store.lastScanDate {
            parts.append(L10n.f("hero.checked", last.formatted(date: .omitted, time: .shortened)))
        }
        if disk.pressure != .normal {
            parts.append(disk.pressure.title)
        }
        return parts.isEmpty ? L10n.t("hero.notChecked") : parts.joined(separator: " · ")
    }

    private var pressureColor: Color {
        switch disk.pressure {
        case .normal: return .primary
        case .low: return .yellow
        case .critical: return .orange
        case .urgent: return .red
        }
    }

    // MARK: Suggestion

    /// Problems already show on their own rows, so a space suggestion wins the single slot when there is one.
    private var primarySuggestion: Suggestion? {
        let items = SuggestionEngine.make(store.suggestionInput())
        let rowProblems: (Suggestion) -> Bool = { $0.id == "tool" || $0.id == "access" || $0.id.hasPrefix("blocked-") }
        return items.first { !rowProblems($0) } ?? items.first
    }

    @ViewBuilder
    private var suggestion: some View {
        if let suggestion = primarySuggestion {
            Button { perform(suggestion.action) } label: {
                HStack(spacing: 10) {
                    Image(systemName: suggestionSymbol(suggestion))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(disk.pressure == .normal ? Color.primary.opacity(0.8) : pressureColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(Self.shortDetail(suggestion.detail))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(suggestion.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(suggestion.title). \(suggestion.detail)")
            .accessibilityHint(L10n.t("suggestion.hint"))
            .accessibilityAddTraits(.isButton)
        }
    }

    /// The hero already shows free space, so the card drops a leading free-space sentence.
    private static func shortDetail(_ detail: String) -> String {
        guard let end = detail.range(of: ". ") else { return detail }
        let head = detail[..<end.lowerBound]
        let prefixes = ["Вільно ", "Free ", "Libre ", "Frei ", "Бос "]
        guard prefixes.contains(where: { head.hasPrefix($0) }) else { return detail }
        return String(detail[end.upperBound...])
    }

    private func suggestionSymbol(_ suggestion: Suggestion) -> String {
        switch suggestion.action {
        case .reviewLargest, .reviewCategory: return "arrow.down.right"
        case .refresh: return "arrow.clockwise"
        case .openStorageSettings: return "internaldrive"
        case .explainPermission: return "lock"
        case .explainCloseApp: return "app.badge"
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let sections = groupedItems
                LazyVStack(spacing: 10) {
                    if sections.isEmpty, !store.isScanning {
                        Text(L10n.t("hero.noCaches"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(sections) { section in
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(sectionSize(section))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .accessibilityElement(children: .combine)
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                CacheRow(item: item, store: store, settings: settings, isExpanded: expandedID == item.id) {
                                    expandedID = expandedID == item.id ? nil : item.id
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(rowFill(item))
                                )
                                .overlay(alignment: .bottom) {
                                    if index < section.items.count - 1, expandedID != item.id, expandedID != section.items[index + 1].id {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(height: 1)
                                            .padding(.leading, 40)
                                            .padding(.trailing, 10)
                                    }
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.bottom, 4)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: store.highlightedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: motion)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private struct CategorySection: Identifiable {
        var id: String
        var title: String
        var items: [CacheItem]
    }

    /// Order and titles come from the category. A new category picks its own group.
    private var groupedItems: [CategorySection] {
        let items = store.sortedItems
        return CategoryGroup.allCases.compactMap { group in
            let rows = items.filter { $0.category.group == group }
            guard !rows.isEmpty else { return nil }
            return CategorySection(id: group.rawValue, title: group.title, items: rows)
        }
    }

    private func sectionSize(_ section: CategorySection) -> String {
        let known = section.items.compactMap(\.result.bytes)
        guard !known.isEmpty else { return "—" }
        let sum = known.reduce(0, +)
        let incomplete = known.count < section.items.count || section.items.contains { $0.result.access != .full }
        return (incomplete ? "≥ " : "") + ByteFormat.string(sum)
    }

    private func rowFill(_ item: CacheItem) -> Color {
        if store.highlightedID == item.id { return Color.accentColor.opacity(0.16) }
        if expandedID == item.id { return Color.primary.opacity(0.06) }
        return .clear
    }

    // MARK: Footer

    private var footer: some View {
        let ids = store.selectedCleanableIDs
        let bytes = ids.compactMap(store.item).reduce(Int64(0)) { $0 + $1.result.cleanableBytes }
        return HStack(spacing: 8) {
            Button(L10n.t("footer.recommended")) { store.selectRecommended() }
                .buttonStyle(QuietPillStyle())
                .disabled(store.isScanning || store.isCleaning)
                .help(L10n.t("footer.recommended.help"))
            Spacer()
            Button(ids.isEmpty ? L10n.t("footer.clean") : L10n.f("footer.clean.named", ByteFormat.string(bytes))) {
                store.requestClean(ids: ids)
            }
            .buttonStyle(PrimaryPillStyle())
            .disabled(ids.isEmpty || store.isCleaning || store.pendingClean != nil)
            .accessibilityLabel(ids.isEmpty ? L10n.t("footer.clean") : L10n.f("footer.clean.named", ByteFormat.string(bytes)))
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.orange : Color.green)
            Text(banner.message)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(banner.message)
    }

    // MARK: Confirmation

    private func confirmationOverlay(_ pending: PendingClean) -> some View {
        let rows = pending.ids.compactMap(store.item)
        let irreversible = rows.contains { $0.category.method.isCommand }
        let total = rows.reduce(Int64(0)) { $0 + $1.result.cleanableBytes }
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.55 : 0.22))
                .contentShape(Rectangle())
                .onTapGesture { store.cancelPendingClean() }
                .accessibilityLabel("Закрити підтвердження")
                .accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pending.childToken == nil ? L10n.t("confirm.title") : L10n.t("confirm.delete"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(ByteFormat.string(imageBytes(pending, fallback: total)))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                if let title = pending.childTitle {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows.prefix(4)) { item in
                            HStack {
                                Text(L10n.categoryName(item.category)).lineLimit(1)
                                Spacer()
                                Text(ByteFormat.string(item.result.cleanableBytes)).monospacedDigit()
                            }
                        }
                        if rows.count > 4 {
                            Text(L10n.f("confirm.more", rows.count - 4))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Text(confirmBody(pending, irreversible: irreversible))
                    .font(.system(size: 11))
                    .foregroundStyle((irreversible || pending.childToken != nil) ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !pending.appsToQuit.isEmpty {
                    Text(quitWarning(pending.appsToQuit))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(L10n.t("confirm.cancel")) { store.cancelPendingClean() }
                        .buttonStyle(QuietPillStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(confirmButton(pending)) { store.confirmPendingClean() }
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.thickMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    private func imageBytes(_ pending: PendingClean, fallback: Int64) -> Int64 {
        guard let token = pending.childToken else { return fallback }
        return rowsMatch(pending, token: token) ?? fallback
    }

    private func rowsMatch(_ pending: PendingClean, token: String) -> Int64? {
        pending.ids.compactMap(store.item).lazy.compactMap { item in
            item.result.children.first { $0.actionToken?.caseInsensitiveCompare(token) == .orderedSame }?.bytes
        }.first
    }

    private func confirmBody(_ pending: PendingClean, irreversible: Bool) -> String {
        if pending.ids.first == "xcode-runtimes" { return L10n.t("images.xcode.confirm") }
        if pending.ids.first == "android-images", pending.childToken != nil { return L10n.t("images.android.confirm") }
        return irreversible ? L10n.t("confirm.command") : L10n.t("confirm.trash")
    }

    private func confirmButton(_ pending: PendingClean) -> String {
        if pending.childToken != nil { return L10n.t("list.delete") }
        return pending.appsToQuit.isEmpty ? L10n.t("confirm.clean") : L10n.t("confirm.quitAndClean")
    }

    private func quitWarning(_ names: [String]) -> String {
        let shown = names.prefix(4).joined(separator: ", ")
        let extra = names.count > 4 ? " " + L10n.f("confirm.more", names.count - 4) : ""
        return L10n.f("confirm.quit", shown + extra)
    }

    private func perform(_ action: SuggestionAction) {
        switch action {
        case .reviewLargest:
            store.highlightedID = store.sortedItems.first?.id
            expandedID = store.highlightedID
        case let .reviewCategory(id):
            store.highlightedID = id
            expandedID = id
            showsSettings = false
        case .refresh:
            store.refresh()
        case .openStorageSettings:
            settings.openStorageSettings()
        case .explainPermission:
            settings.openFullDiskAccessSettings()
        case .explainCloseApp:
            store.refresh()
        }
    }

    // MARK: Settings

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection(L10n.t("settings.language")) {
                    HStack {
                        Picker(L10n.t("settings.language"), selection: Binding(
                            get: { settings.language },
                            set: { settings.language = $0 }
                        )) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer()
                    }
                    Text(L10n.f("lang.detected", settings.detectedLanguageName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection(L10n.t("settings.appearance")) {
                    Picker(L10n.t("settings.theme"), selection: Binding(
                        get: { settings.appearance },
                        set: { settings.appearance = $0 }
                    )) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        meterChip("CPU", \.showCPUMeter)
                        meterChip("RAM", \.showMemoryMeter)
                        meterChip("GPU", \.showGPUMeter)
                        meterChip(L10n.t("meter.disk"), \.showDiskMeter)
                    }
                    Text(L10n.t("settings.meters"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsSection(L10n.t("settings.open")) {
                    Toggle(isOn: binding(\.notchPanelEnabled)) {
                        Label(hasNotch ? L10n.t("settings.notch") : L10n.t("settings.top"), systemImage: "macwindow")
                    }
                    .disabled(settings.notchPanelEnabled && !settings.showMenuBarIcon)
                    Toggle(isOn: binding(\.showMenuBarIcon)) {
                        Label(L10n.t("settings.menuIcon"), systemImage: "menubar.rectangle")
                    }
                    .disabled(settings.showMenuBarIcon && !settings.notchPanelEnabled)
                    Text(L10n.t("settings.open.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection(L10n.t("settings.system")) {
                    Toggle(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })) {
                        Label(L10n.t("settings.launch"), systemImage: "power")
                    }
                    if settings.launchAtLoginStatus == .requiresApproval {
                        Button(L10n.t("settings.login.approve")) { settings.openLoginItemsSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if let error = settings.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if showsLoginCaption {
                        Text(loginStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { settings.setNotificationsEnabled($0) }
                    )) {
                        Label(L10n.t("settings.notify"), systemImage: "bell")
                    }
                    if let error = settings.notificationError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if settings.notificationsEnabled {
                        Button(L10n.t("settings.snooze")) { settings.snoozeNotifications() }
                            .buttonStyle(QuietPillStyle())
                    }
                }

                settingsSection(L10n.t("settings.thresholds")) {
                    thresholdField(L10n.t("settings.low"), bytes: intBinding(\.pressureLowBytes))
                    thresholdField(L10n.t("settings.critical"), bytes: intBinding(\.pressureCriticalBytes))
                    thresholdField(L10n.t("settings.urgent"), bytes: intBinding(\.pressureUrgentBytes))
                    Text(L10n.t("settings.threshold.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !suggestionSections.isEmpty {
                    settingsSection(L10n.t("settings.suggestions")) {
                        Text(L10n.t("settings.suggestions.note"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(suggestionSections) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                            ForEach(section.items) { item in
                                Toggle(isOn: Binding(
                                    get: { !settings.excludedSuggestions.contains(item.id) },
                                    set: { settings.setExcluded(item.id, excluded: !$0) }
                                )) {
                                    Text(L10n.categoryName(item.category))
                                }
                            }
                        }
                    }
                }

                settingsSection(L10n.t("settings.history")) {
                    if history.entries.isEmpty {
                        Label(L10n.t("settings.history.empty"), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history.entries.prefix(6)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(entry.categoryNames.joined(separator: ", "))
                                    .lineLimit(1)
                                Text(historyLine(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(L10n.t("settings.fda")) { settings.openFullDiskAccessSettings() }
                        .buttonStyle(.link)
                    Button(L10n.t("settings.storage")) { settings.openStorageSettings() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 4)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Roomy \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        Text(L10n.t("settings.author"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("settings.quit")) { NSApp.terminate(nil) }
                        .buttonStyle(QuietPillStyle())
                }
                .padding(.horizontal, 4)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }

    private var suggestionSections: [CategorySection] {
        let items = store.items.filter(\.category.includeInRecommendations)
        return CategoryGroup.allCases.compactMap { group in
            let rows = items.filter { $0.category.group == group }
            guard !rows.isEmpty else { return nil }
            return CategorySection(id: "suggest-\(group.rawValue)", title: group.title, items: rows)
        }
    }

    private var showsLoginCaption: Bool {
        switch settings.launchAtLoginStatus {
        case .enabled, .notRegistered: return false
        default: return true
        }
    }

    private func meterChip(_ title: String, _ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> some View {
        let on = settings[keyPath: keyPath]
        return Button {
            settings[keyPath: keyPath] = !on
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(on ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private var loginStatus: String {
        switch settings.launchAtLoginStatus {
        case .enabled: return L10n.t("settings.login.enabled")
        case .requiresApproval: return L10n.t("settings.login.waiting")
        case .notRegistered: return L10n.t("settings.login.off")
        case .notFound: return L10n.t("settings.login.missing")
        @unknown default: return L10n.t("settings.login.unknown")
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func intBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func thresholdField(_ title: String, bytes: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            TextField(title, value: Binding(
                get: { bytes.wrappedValue / 1_000_000_000 },
                set: { bytes.wrappedValue = max(1, $0) * 1_000_000_000 }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            Text(L10n.t("settings.gb"))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }

    private func historyLine(_ entry: HistoryEntry) -> String {
        var parts = [
            L10n.f("settings.history.cache", ByteFormat.string(entry.cacheReductionBytes)),
            L10n.f("settings.history.trash", ByteFormat.string(entry.trashedBytes)),
            L10n.f("settings.history.free", ByteFormat.string(entry.freeBefore), ByteFormat.string(entry.freeAfter)),
        ]
        if entry.irreversible { parts.append(L10n.t("settings.history.irreversible")) }
        if !entry.failures.isEmpty { parts.append(L10n.t("settings.history.errors")) }
        return parts.joined(separator: " · ")
    }
}

private struct CacheRow: View {
    let item: CacheItem
    @ObservedObject var store: CacheStore
    @ObservedObject var settings: AppSettings
    var isExpanded: Bool
    var toggle: () -> Void

    private var isCleaning: Bool { store.cleaningIDs.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle(L10n.f("list.select", L10n.categoryName(item.category)), isOn: Binding(
                    get: { store.selection.contains(item.id) },
                    set: { isOn in
                        if isOn { store.selection.insert(item.id) } else { store.selection.remove(item.id) }
                    }
                ))
                .toggleStyle(RoundCheckStyle(accessibilityName: L10n.f("list.select", L10n.categoryName(item.category))))
                .disabled(!item.isCleanable)

                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: item.category.symbol)
                            .font(.system(size: 13))
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.categoryName(item.category))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if let warning {
                                Text(warning)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .help(warning)
                            }
                        }
                        Spacer(minLength: 8)
                        if isCleaning {
                            ProgressView().controlSize(.mini)
                        }
                        Text(sizeText)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(item.result.bytes == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(isExpanded ? "Сховати подробиці" : "Показати подробиці")
                .accessibilityAddTraits(.isButton)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, warning == nil ? 9 : 6)
            if isExpanded {
                detail
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var sizeText: String {
        switch item.result.access {
        case .denied where item.result.bytes == nil:
            return "—"
        case .unknown where item.result.bytes == nil:
            return store.isScanning ? "…" : "—"
        case .partial:
            guard let bytes = item.result.bytes, bytes > 0 else { return L10n.t("list.notAll") }
            return "≥ \(ByteFormat.string(bytes))"
        default:
            return ByteFormat.string(item.result.bytes ?? 0)
        }
    }

    private var accessibilityText: String {
        var parts = [L10n.categoryName(item.category)]
        switch item.result.access {
        case .denied where item.result.bytes == nil: break
        case .unknown where item.result.bytes == nil: parts.append(store.isScanning ? "рахується" : "не скановано")
        case .partial:
            if let bytes = item.result.bytes, bytes > 0 {
                parts.append("щонайменше \(ByteFormat.string(bytes))")
            } else {
                parts.append("прочитано не все")
            }
        default: parts.append(ByteFormat.string(item.result.bytes ?? 0))
        }
        if let warning { parts.append(warning) }
        return parts.joined(separator: ", ")
    }

    /// Shown only when something is actually wrong with this category.
    private var warning: String? {
        if item.result.bytes == nil, let note = item.result.note { return note }
        if let app = item.runningApp {
            return item.appsToQuit.count > 1
                ? L10n.f("list.running.many", item.appsToQuit.count)
                : L10n.f("list.running.one", app)
        }
        if let problem = item.category.toolProblem { return problem }
        if item.result.access == .denied { return L10n.t("list.noAccess") }
        if item.result.access == .partial { return L10n.t("list.partial") }
        return nil
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = item.result.note ?? L10n.categoryNote(item.category) {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.categoryWhy(item.category))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.category.method.userDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(item.category.roots, id: \.path) { root in
                Text(root.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if item.category.usageProbe == .deviceImages {
                imageList
            } else if !item.result.children.isEmpty {
                let label = item.category.usageProbe == nil ? L10n.t("list.largest") : L10n.t("list.composition")
                Text(label + ": " + item.result.children.prefix(4).map { "\($0.name) \(ByteFormat.string($0.bytes))" }.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let age = AgeHint.text(oldest: item.result.oldest) {
                Text(age).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button(L10n.t("list.reveal")) { reveal() }
                    .buttonStyle(QuietPillStyle())
                Button(settings.excludedSuggestions.contains(item.id) ? L10n.t("list.suggestAgain") : L10n.t("list.dontSuggest")) {
                    settings.setExcluded(item.id, excluded: !settings.excludedSuggestions.contains(item.id))
                }
                .buttonStyle(QuietPillStyle())
                Spacer()
                if item.isCleanable, item.category.id != "trash" {
                    Button(L10n.t("list.clean")) { store.requestClean(ids: [item.id]) }
                        .buttonStyle(PrimaryPillStyle())
                        .disabled(store.pendingClean != nil || isCleaning)
                        .accessibilityLabel(L10n.f("list.clean", L10n.categoryName(item.category)))
                }
            }
            .padding(.top, 4)
        }
        .padding(.leading, 40)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
    }

    private var imageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.result.children) { child in
                HStack(spacing: 8) {
                    Text(child.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(child.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let token = child.actionToken, case .cleanable = child.disposition {
                        Button(L10n.t("list.delete")) {
                            store.requestDeleteImage(categoryID: item.id, token: token, title: child.name)
                        }
                        .buttonStyle(QuietPillStyle())
                        .disabled(store.pendingClean != nil || isCleaning)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private func reveal() {
        let urls = item.category.roots.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser]
            : item.category.roots
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

// MARK: - Island controls

/// A round checkbox that keeps VoiceOver's toggle semantics.
private struct RoundCheckStyle: ToggleStyle {
    var accessibilityName: String

    func makeBody(configuration: Configuration) -> some View {
        RoundCheck(configuration: configuration, accessibilityName: accessibilityName)
    }

    private struct RoundCheck: View {
        let configuration: ToggleStyleConfiguration
        let accessibilityName: String
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(isEnabled ? 0.32 : 0.14), lineWidth: 1.5)
                        .opacity(configuration.isOn ? 0 : 1)
                    if configuration.isOn {
                        Circle().fill(Color.primary)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(InkOnPrimary.color(colorScheme))
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(configuration.isOn ? "вибрано" : "не вибрано")
        }
    }
}

private struct QuietPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: false)
    }
}

private struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: true)
    }
}

private struct Pill: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? InkOnPrimary.color(colorScheme) : Color.primary.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent
                    ? Color.primary.opacity(configuration.isPressed ? 0.75 : 0.92)
                    : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09))
            )
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(Capsule())
    }
}

/// A drawn searching eye. The pupil looks around and a slit crosses the iris while nodes blink along the links.
private struct ScanSeeker: View {
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                drawSeeker(canvas, size: size, time: time, still: reduceMotion)
            }
        }
        .frame(width: 104, height: 52)
        .accessibilityHidden(true)
    }
}

private func drawSeeker(_ canvas: GraphicsContext, size: CGSize, time: Double, still: Bool) {
    let eye = CGPoint(x: size.width * 0.52, y: size.height * 0.5)
    let nodes = [
        CGPoint(x: 7, y: 11),
        CGPoint(x: 18, y: 40),
        CGPoint(x: 32, y: 8),
        CGPoint(x: 78, y: 9),
        CGPoint(x: 96, y: 38),
    ]
    for (index, node) in nodes.enumerated() {
        var link = Path()
        link.move(to: node)
        link.addLine(to: eye)
        let pulse = still ? 0.4 : (sin(time * 3.1 - Double(index) * 0.85) + 1) / 2
        canvas.stroke(link, with: .color(Color.accentColor.opacity(0.12 + pulse * 0.5)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        let dot = Path(ellipseIn: CGRect(x: node.x - 2.3, y: node.y - 2.3, width: 4.6, height: 4.6))
        canvas.fill(dot, with: .color(Color.accentColor.opacity(0.3 + pulse * 0.7)))
    }

    let frame = CGRect(x: eye.x - 17, y: eye.y - 17, width: 34, height: 34)
    canvas.stroke(viewfinder(frame), with: .color(Color.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))

    let irisRect = CGRect(x: eye.x - 11, y: eye.y - 11, width: 22, height: 22)
    let iris = Path(ellipseIn: irisRect)
    canvas.fill(iris, with: .color(Color.accentColor.opacity(0.16)))
    canvas.stroke(iris, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 1.3))

    let lookX = still ? 0.0 : sin(time * 2.3) * 4.4
    let lookY = still ? 0.0 : sin(time * 1.6 + 0.7) * 2.5
    let pupil = Path(ellipseIn: CGRect(x: eye.x + lookX - 3.3, y: eye.y + lookY - 3.3, width: 6.6, height: 6.6))
    canvas.fill(pupil, with: .color(Color.primary.opacity(0.92)))

    guard !still else { return }
    let travel = (sin(time * 2.6) + 1) / 2
    let slitY = irisRect.minY + travel * irisRect.height
    var slit = Path()
    slit.addRect(CGRect(x: irisRect.minX, y: slitY - 0.7, width: irisRect.width, height: 1.4))
    var clipped = canvas
    clipped.clip(to: iris)
    clipped.fill(slit, with: .color(Color.accentColor.opacity(0.95)))
}

private func viewfinder(_ rect: CGRect) -> Path {
    let arm: CGFloat = 6
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
    path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
    path.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
    return path
}

private struct IconCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconCircle(configuration: configuration)
    }

    private struct IconCircle: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
                .opacity(isEnabled ? 1 : 0.38)
                .contentShape(Circle())
        }
    }
}

/// Text and glyphs drawn on a `Color.primary` fill.
private enum InkOnPrimary {
    static func color(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }
}

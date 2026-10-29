import CleanoriCore
import SwiftUI

/// The fixed-column results table (spec §6.1, ruling R22): checkbox 18 · chevron 12 · Item · Method 140 · Size 62,
/// group rows 30 pt and child rows 26 pt, as in the approved mockup.
///
/// Each rule's help text (spec §9, `CleanupRule.regenerateHint`) is the tooltip of its group and item rows, and an
/// open group starts with it in grey, one 26 pt line per distinct hint (`Catalog.hintLines`).
struct JunkTableView: View {
    let model: DeveloperJunkModel

    private enum Layout {
        static let checkbox: CGFloat = 18
        static let chevron: CGFloat = 12
        static let method: CGFloat = 140
        static let size: CGFloat = 62
        static let gap: CGFloat = 8
        static let inset: CGFloat = 12
        static let groupRow: CGFloat = 30
        static let childRow: CGFloat = 26
        static let header: CGFloat = 24
    }

    // MARK: - Rows

    private enum Row: Identifiable {
        case group(ScanGroup)
        /// `showsLock` is false when the group's own row already carries the lock reason.
        case item(ScanItem, showsLock: Bool)
        /// A line of the open group's help text: how its items come back, or what is lost for good.
        case hint(String, group: RuleGroup, index: Int)
        /// "+ N more folders": the items of `node_modules` beyond the largest few.
        case more(hidden: [ScanItem])
        case fewer

        var id: String {
            switch self {
            case .group(let group): "group|\(group.id.rawValue)"
            case .item(let item, _): "item|\(item.id)"
            case .hint(_, let group, let index): "hint|\(group.rawValue)|\(index)"
            case .more: "more"
            case .fewer: "fewer"
            }
        }
    }

    private var rows: [Row] {
        guard let result = model.result else { return [] }
        var rows: [Row] = []
        for group in result.groups {
            rows.append(.group(group))
            guard model.expanded.contains(group.id) else { continue }
            rows += Self.hintLines(of: group).enumerated().map { .hint($1, group: group.id, index: $0) }
            let showsLock = GroupTag(of: group).lock == nil
            var items = group.items
            var hidden: [ScanItem] = []
            if group.id == .nodeModules, !model.showsAllNodeModules, items.count > DeveloperJunkModel.collapsedNodeModulesCount {
                hidden = Array(items.dropFirst(DeveloperJunkModel.collapsedNodeModulesCount))
                items = Array(items.prefix(DeveloperJunkModel.collapsedNodeModulesCount))
            }
            rows += items.map { .item($0, showsLock: showsLock) }
            if !hidden.isEmpty {
                rows.append(.more(hidden: hidden))
            } else if group.id == .nodeModules, model.showsAllNodeModules,
                      group.items.count > DeveloperJunkModel.collapsedNodeModulesCount {
                rows.append(.fewer)
            }
        }
        return rows
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ScrollView {
                let rows = rows
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                            .overlay(alignment: .top) {
                                if row.id != rows.first?.id { Rectangle().fill(Self.rule).frame(height: 1) }
                            }
                    }
                    if model.result?.groups.isEmpty ?? true {
                        emptyState
                    }
                    if let reason = model.simulatorsSkippedReason {
                        infoRow(reason, detail: "iOS Simulators skipped")
                            .overlay(alignment: .top) { Rectangle().fill(Self.rule).frame(height: 1) }
                    }
                }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder))
        .allowsHitTesting(!model.isCleaning)
        .opacity(model.isCleaning ? 0.6 : 1)
    }

    private static let rule = Color(light: Color(hex: 0x000000, opacity: 0.07), dark: Color(hex: 0xFFFFFF, opacity: 0.06))

    private var headerRow: some View {
        cells(height: Layout.header) {
            EmptyView()
        } chevron: {
            EmptyView()
        } name: {
            Text("Item")
        } method: {
            Text("Method")
        } size: {
            Text("Size")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .background(Color(light: Color(hex: 0x000000, opacity: 0.03), dark: Color(hex: 0xFFFFFF, opacity: 0.03)))
        .overlay(alignment: .bottom) { Rectangle().fill(Self.rule).frame(height: 1) }
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Nothing to clean")
                .font(.system(size: 13, weight: .semibold))
            Text("No caches or builds were found.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - One row

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .group(let group): groupRow(group)
        case .item(let item, let showsLock): itemRow(item, showsLock: showsLock)
        case .hint(let line, _, _): hintRow(line)
        case .more(let hidden): moreRow(hidden)
        case .fewer: fewerRow
        }
    }

    private func groupRow(_ group: ScanGroup) -> some View {
        let isExpanded = model.expanded.contains(group.id)
        let tag = GroupTag(of: group)
        let title = group.id.title
        // A group that is only partly locked is ticked like any other, so its row has to say that some of what it
        // adds up is held back and will not be cleaned. A fully locked group says so with its red tag.
        let locked = ItemTotal(group.items.filter { $0.lock != nil })
        let partlyLocked = locked.count > 0 && !tag.isFullyLocked
        return cells(height: Layout.groupRow) {
            TriStateCheckbox(state: model.selection?.state(of: group.id) ?? .off, label: title) {
                model.toggle(group: group.id)
            }
            .disabled(tag.isFullyLocked)
        } chevron: {
            Button {
                toggleExpanded(group.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Layout.chevron, height: Layout.groupRow)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        } name: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                detail(summary: Self.summary(of: group), locked: partlyLocked ? locked : nil)
            }
            .opacity(tag.isFullyLocked ? 0.45 : 1)
        } method: {
            tagView(tag)
        } size: {
            sizeText(group.totalBytes, approximate: group.items.contains { $0.size.isApproximate })
                .opacity(tag.isFullyLocked ? 0.45 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded(group.id) }
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { toggleExpanded(group.id) }
        .help(Self.hintLines(of: group).joined(separator: "\n"))
    }

    private func itemRow(_ item: ScanItem, showsLock: Bool) -> some View {
        let isLocked = item.lock != nil
        return cells(height: Layout.childRow) {
            TriStateCheckbox(state: model.selection?.isSelected(item.id) == true ? .on : .off, label: item.displayName) {
                model.toggle(itemID: item.id)
            }
            .disabled(isLocked)
        } chevron: {
            EmptyView()
        } name: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                ForEach(Array(item.badges.enumerated()), id: \.offset) { _, badge in
                    BadgePill(badge: badge)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 14)
            .opacity(isLocked ? 0.45 : 1)
        } method: {
            if showsLock, let lock = item.lock {
                MethodTag(lock: lock)
            }
        } size: {
            sizeText(item.size.bytes, approximate: item.size.isApproximate, font: .system(size: 12, weight: .semibold))
                .opacity(isLocked ? 0.45 : 1)
        }
        .background(Self.childBackground)
        // Only the checkbox ticks an item: a stray click on the row must never mark a project for deletion.
        .help(Self.help(for: item))
    }

    /// One line of an open group's help text, in grey under the group row. Too long a line is cut short; the
    /// tooltip has all of it.
    private func hintRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(line)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        // Lined up with the names of the items below it.
        .padding(.leading, Layout.inset + Layout.checkbox + Layout.chevron + 2 * Layout.gap + 14)
        .padding(.trailing, Layout.inset)
        .frame(height: Layout.childRow)
        .background(Self.childBackground)
        .help(line)
        .accessibilityElement(children: .combine)
    }

    private func moreRow(_ hidden: [ScanItem]) -> some View {
        let label = hidden.count == 1 ? "+ 1 more folder" : "+ \(hidden.count) more folders"
        let locked = ItemTotal(hidden.filter { $0.lock != nil })
        return cells(height: Layout.childRow) {
            TriStateCheckbox(state: model.state(of: hidden), label: label) {
                model.toggle(items: hidden)
            }
            // Nothing in the row can be ticked when every folder it stands for is locked.
            .disabled(locked.count == hidden.count)
        } chevron: {
            EmptyView()
        } name: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if locked.count > 0 {
                    Text(lockedText(locked))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.lockText)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 14)
        } method: {
            EmptyView()
        } size: {
            sizeText(
                hidden.reduce(0) { $0 + $1.size.bytes },
                approximate: hidden.contains { $0.size.isApproximate },
                font: .system(size: 12, weight: .medium),
                style: .secondary
            )
        }
        .background(Self.childBackground)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { model.showsAllNodeModules = true } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows every folder")
        .accessibilityAction(named: "Show every folder") { model.showsAllNodeModules = true }
    }

    private var fewerRow: some View {
        cells(height: Layout.childRow) {
            EmptyView()
        } chevron: {
            EmptyView()
        } name: {
            Text("Show fewer")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
        } method: {
            EmptyView()
        } size: {
            EmptyView()
        }
        .background(Self.childBackground)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { model.showsAllNodeModules = false } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show fewer folders") { model.showsAllNodeModules = false }
    }

    /// A line of plain information below the groups (spec §7).
    private func infoRow(_ text: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, Layout.inset)
        .frame(height: Layout.groupRow)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    /// "1 locked (7.3 MB)": what a lock holds back in a group or in "+ N more folders".
    private func lockedText(_ locked: ItemTotal) -> String {
        "\(locked.count) locked (\(locked.sizeText))"
    }

    /// The small line after a name: what the row holds, then, in the lock colour, what part of it is locked.
    @ViewBuilder private func detail(summary: String?, locked: ItemTotal?) -> some View {
        switch (summary, locked) {
        case (let summary?, let locked?):
            Text("\(Text(verbatim: summary)) · \(Text(verbatim: lockedText(locked)).foregroundStyle(Theme.lockText))")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case (nil, let locked?):
            Text(lockedText(locked)).font(.system(size: 11)).foregroundStyle(Theme.lockText).lineLimit(1)
        case (let summary?, nil):
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case (nil, nil):
            EmptyView()
        }
    }

    private static let childBackground = Color(light: Color(hex: 0x000000, opacity: 0.025), dark: Color(hex: 0x000000, opacity: 0.12))

    private func toggleExpanded(_ group: RuleGroup) {
        withAnimation(.easeOut(duration: 0.12)) { model.toggleExpanded(group) }
    }

    /// One row of the grid, so the header and every row share the same columns.
    private func cells<Check: View, Chevron: View, Name: View, Method: View, Size: View>(
        height: CGFloat,
        @ViewBuilder check: () -> Check,
        @ViewBuilder chevron: () -> Chevron,
        @ViewBuilder name: () -> Name,
        @ViewBuilder method: () -> Method,
        @ViewBuilder size: () -> Size
    ) -> some View {
        HStack(spacing: Layout.gap) {
            check().frame(width: Layout.checkbox, alignment: .leading)
            chevron().frame(width: Layout.chevron)
            name().frame(maxWidth: .infinity, alignment: .leading)
            method().frame(width: Layout.method, alignment: .leading)
            size().frame(width: Layout.size, alignment: .trailing)
        }
        .padding(.horizontal, Layout.inset)
        .frame(height: height)
    }

    /// A size, prefixed with `≈` when it may be off (ruling R11).
    private func sizeText(
        _ bytes: Int64,
        approximate: Bool,
        font: Font = .system(size: 12.5, weight: .semibold),
        style: HierarchicalShapeStyle = .primary
    ) -> some View {
        Text((approximate ? "≈" : "") + bytes.fileSizeText)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(style)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// The help text of the rules whose items are in `group`.
    private static func hintLines(of group: ScanGroup) -> [String] {
        Catalog.hintLines(forRules: group.items.map(\.ruleID))
    }

    /// An item's tooltip: where it is, then how it comes back (or that it does not).
    private static func help(for item: ScanItem) -> String {
        guard let hint = Catalog.rule(id: item.ruleID)?.regenerateHint else { return item.url.path }
        return "\(item.url.path)\n\(hint)"
    }

    /// The small line after a group's name: what it holds.
    private static func summary(of group: ScanGroup) -> String? {
        let count = group.items.count
        func counted(_ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }
        switch group.id {
        case .xcodeDerivedData: return counted("project")
        case .nodeModules, .projectBuilds, .toolCaches: return counted("folder")
        case .simulators: return counted("device")
        case .archives: return counted("archive")
        case .androidEmulators: return counted("emulator")
        case .packageCaches, .androidSDK:
            // The tools in the group, in catalog order: "npm · pnpm · Yarn · Bun".
            let ruleIDs = Set(group.items.map(\.ruleID))
            return Catalog.all().filter { ruleIDs.contains($0.id) }.map(\.title).joined(separator: " · ")
        case .gradle, .deviceSupport:
            return nil
        }
    }

    /// What a group row shows in its Method column.
    private struct GroupTag {
        let lock: LockReason?
        let method: CleanMethod?

        init(of group: ScanGroup) {
            if group.items.allSatisfy({ $0.lock != nil }), let first = group.items.first?.lock {
                lock = first
                method = nil
            } else {
                lock = nil
                let methods = Set(group.items.map(\.method))
                method = methods.count == 1 ? methods.first : nil
            }
        }

        /// Every item is locked, so the whole row is dimmed and cannot be ticked.
        var isFullyLocked: Bool { lock != nil }
    }

    @ViewBuilder private func tagView(_ tag: GroupTag) -> some View {
        if let lock = tag.lock {
            MethodTag(lock: lock)
        } else if let method = tag.method {
            MethodTag(method: method)
        }
    }
}

/// The small outlined `active` / `unused` / `no package.json` words after an item's name.
private struct BadgePill: View {
    let badge: Badge

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(badge == .active ? Self.activeColor : Color.secondary)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(badge == .active ? Self.activeColor.opacity(0.4) : Color.secondary.opacity(0.4))
            )
            .help(help)
    }

    private var text: String {
        switch badge {
        case .active: "active"
        case .unused: "unused"
        case .noPackageJSON: "no package.json"
        }
    }

    private var help: String {
        switch badge {
        case .active: "Worked on recently, so it is not ticked by default"
        case .unused: "Not used by any Android emulator"
        case .noPackageJSON: "Its folder has no package.json, so it may belong to a tool rather than a project. Not ticked by default"
        }
    }

    private static let activeColor = Color(light: Color(hex: 0x0B7F6C), dark: Color(hex: 0x4FE0C4))
}

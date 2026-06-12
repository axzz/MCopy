import SwiftUI
import SwiftData

struct ClipboardHistoryView: View {
    @Query(sort: \ClipboardItem.timestamp, order: .reverse) private var items: [ClipboardItem]
    @AppStorage(PanelPosition.defaultsKey) private var panelPositionRaw: String = PanelPosition.bottom.rawValue
    @ObservedObject var panelState: PanelState
    @State private var selectedID: UUID?
    @State private var searchQuery: String = ""
    @State private var scrollResetToken: UUID = UUID()
    @FocusState private var isSearchFocused: Bool

    var onPaste: (ClipboardItem) -> Void
    var onTogglePin: (ClipboardItem, Bool) -> Void
    var onTwoRowVisibilityChange: (Bool) -> Void
    var onDismiss: () -> Void

    private static let leadingAnchorID = "__leading_anchor__"
    private static let pinnedLeadingAnchorID = "__pinned_leading_anchor__"
    private static let layoutAnimation = Animation.easeInOut(duration: 0.22)

    private struct HistoryRow {
        let items: [ClipboardItem]
        let anchorID: String
    }

    private enum HistoryLayout {
        case one(HistoryRow)
        case two(HistoryRow, HistoryRow)

        var rows: [HistoryRow] {
            switch self {
            case .one(let row):
                return [row]
            case .two(let first, let second):
                return [first, second]
            }
        }

        var items: [ClipboardItem] {
            rows.flatMap(\.items)
        }

        var primaryAnchorID: String {
            rows.first?.anchorID ?? ClipboardHistoryView.leadingAnchorID
        }

        var isTwoRow: Bool {
            if case .two = self { return true }
            return false
        }

        var signature: String {
            rows
                .map { row in
                    "\(row.anchorID):\(row.items.map(\.id.uuidString).joined(separator: ","))"
                }
                .joined(separator: "|")
        }
    }

    private var panelPosition: PanelPosition {
        PanelPosition(rawValue: panelPositionRaw) ?? .bottom
    }

    private var displayItems: [ClipboardItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return unpinnedItems }
        return unpinnedItems.filter { ($0.textContent ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var pinnedItems: [ClipboardItem] {
        guard searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return items
            .filter(\.isPinned)
            .sorted { lhs, rhs in
                (lhs.pinnedAt ?? lhs.timestamp) > (rhs.pinnedAt ?? rhs.timestamp)
            }
    }

    private var unpinnedItems: [ClipboardItem] {
        items.filter { !$0.isPinned }
    }

    private var selectableItems: [ClipboardItem] {
        historyLayout.items
    }

    private var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var historyLayout: HistoryLayout {
        let normalRow = HistoryRow(items: displayItems, anchorID: Self.leadingAnchorID)
        let pinnedRow = HistoryRow(items: pinnedItems, anchorID: Self.pinnedLeadingAnchorID)

        if isSearchActive || pinnedItems.isEmpty {
            return .one(normalRow)
        }
        if displayItems.isEmpty {
            return .one(pinnedRow)
        }
        return .two(normalRow, pinnedRow)
    }

    private var hasTwoRows: Bool {
        historyLayout.isTwoRow
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            if selectableItems.isEmpty {
                emptyState
            } else if panelPosition.isVertical {
                verticalCardScroll
            } else {
                cardScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // NSVisualEffectView with corner radius on its own layer —
        // avoids SwiftUI Material's intrinsic 1px vibrancy edge highlight.
        .background(
            VisualEffectView(material: .menu, blendingMode: .behindWindow, cornerRadius: 16)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear {
            isSearchFocused = true
            selectedID = selectableItems.first?.id
            onTwoRowVisibilityChange(hasTwoRows)
            // Cold launch: the TextField isn't wired into the panel's
            // responder chain yet when onAppear fires, so re-assert next tick.
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: panelState.openToken) { _, _ in
            // The hosting view persists across panel opens, so onAppear only
            // fires once. Per-open behavior hangs off this token instead.
            isSearchFocused = true
            if panelState.resetOnNextOpen {
                panelState.resetOnNextOpen = false
                selectedID = selectableItems.first?.id
                scrollResetToken = UUID()
            }
        }
        .onChange(of: searchQuery) { _, _ in
            selectedID = selectableItems.first?.id
            onTwoRowVisibilityChange(hasTwoRows)
        }
        .onChange(of: selectableItems.map(\.id)) { _, _ in
            ensureValidSelection()
            onTwoRowVisibilityChange(hasTwoRows)
        }
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            TextField("Search clipboard", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($isSearchFocused)
                .onKeyPress(.escape) {
                    if !searchQuery.isEmpty { searchQuery = ""; return .handled }
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.return) { pasteSelected(); return .handled }
                .onKeyPress(.leftArrow) {
                    guard !panelPosition.isVertical else { return .ignored }
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard !panelPosition.isVertical else { return .ignored }
                    moveSelection(by: +1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard panelPosition.isVertical else { return .ignored }
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard panelPosition.isVertical else { return .ignored }
                    moveSelection(by: +1)
                    return .handled
                }
                .onKeyPress(keys: ["c"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    pasteSelected()
                    return .handled
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

            Text("⌘⇧V")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.2))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.06)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var cardScroll: some View {
        ScrollViewReader { proxy in
            horizontalLayoutRows
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(historyLayout.primaryAnchorID, anchor: .leading)
                }
            }
            .onChange(of: scrollResetToken) { _, _ in
                resetHorizontalScroll(proxy)
            }
            .onChange(of: selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var horizontalLayoutRows: some View {
        let rows = historyLayout.rows
        VStack(spacing: 12) {
            if let first = rows.first {
                horizontalRow(first)
                    .transaction { tx in
                        tx.animation = nil
                    }
            }
            if hasTwoRows, rows.count > 1 {
                rowDivider(horizontalInset: 16)
                    .transition(rowTransition)
                horizontalRow(rows[1])
                    .transition(rowTransition)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func horizontalRow(_ row: HistoryRow) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Sentinel sits outside the leading padding so scrolling to its
            // leading edge snaps content to offset 0 — preserving the
            // 16pt visual gutter that anchoring the first card would eat.
            HStack(spacing: 0) {
                Color.clear.frame(width: 0, height: 1).id(row.anchorID)
                HStack(spacing: 10) {
                    ForEach(row.items, id: \.id) { item in
                        CardView(
                            item: item,
                            isSelected: item.id == selectedID,
                            onTogglePin: { onTogglePin(item, !isSearchActive) }
                        )
                        .id(item.id)
                        .onTapGesture { onPaste(item) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var verticalCardScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                verticalLayoutRows
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(historyLayout.primaryAnchorID, anchor: .top)
                }
            }
            .onChange(of: scrollResetToken) { _, _ in
                resetVerticalScroll(proxy)
            }
            .onChange(of: selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var verticalLayoutRows: some View {
        let rows = historyLayout.rows
        VStack(spacing: 12) {
            if let first = rows.first {
                verticalRow(first)
                    .transaction { tx in
                        tx.animation = nil
                    }
            }
            if hasTwoRows, rows.count > 1 {
                rowDivider(horizontalInset: 2)
                    .transition(rowTransition)
                verticalRow(rows[1])
                    .transition(rowTransition)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func verticalRow(_ row: HistoryRow) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 1, height: 0).id(row.anchorID)
            VStack(spacing: 10) {
                ForEach(row.items, id: \.id) { item in
                    CardView(
                        item: item,
                        isSelected: item.id == selectedID,
                        onTogglePin: { onTogglePin(item, !isSearchActive) }
                    )
                    .id(item.id)
                    .onTapGesture { onPaste(item) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var rowTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 14).combined(with: .opacity),
            removal: .offset(y: 8).combined(with: .opacity)
        )
    }

    private func rowDivider(horizontalInset: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, horizontalInset)
    }

    private func resetHorizontalScroll(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(historyLayout.primaryAnchorID, anchor: .leading)
        if hasTwoRows {
            proxy.scrollTo(Self.pinnedLeadingAnchorID, anchor: .leading)
        }
    }

    private func resetVerticalScroll(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(historyLayout.primaryAnchorID, anchor: .top)
        if hasTwoRows {
            proxy.scrollTo(Self.pinnedLeadingAnchorID, anchor: .top)
        }
    }

    private var emptyState: some View {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 8) {
            Spacer()
            Image(systemName: isSearching ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.15))
            Text(isSearching ? "No matches" : "No clipboard history yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
    }

    // MARK: - Actions

    private func pasteSelected() {
        guard let id = selectedID,
              let item = selectableItems.first(where: { $0.id == id }) else { return }
        onPaste(item)
    }

    private func moveSelection(by delta: Int) {
        guard !selectableItems.isEmpty else { return }
        let currentIndex = selectableItems.firstIndex(where: { $0.id == selectedID }) ?? 0
        let newIndex = currentIndex + delta
        guard newIndex >= 0, newIndex < selectableItems.count else { return }
        selectedID = selectableItems[newIndex].id
    }

    /// Keep `selectedID` pointing at an item that still exists in `displayItems`.
    /// Falls back to the first item when the previously-selected one was removed
    /// or when nothing is selected yet.
    private func ensureValidSelection() {
        if let id = selectedID, selectableItems.contains(where: { $0.id == id }) { return }
        selectedID = selectableItems.first?.id
    }
}

// MARK: - NSVisualEffectView wrapper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        if cornerRadius > 0 {
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
        }
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

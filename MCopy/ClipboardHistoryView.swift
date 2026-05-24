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
    var onDismiss: () -> Void

    private static let leadingAnchorID = "__leading_anchor__"

    private var panelPosition: PanelPosition {
        PanelPosition(rawValue: panelPositionRaw) ?? .bottom
    }

    private var displayItems: [ClipboardItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { ($0.textContent ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            if displayItems.isEmpty {
                emptyState
            } else if panelPosition.isVertical {
                verticalCardScroll
            } else {
                cardScroll
            }
        }
        // NSVisualEffectView with corner radius on its own layer —
        // avoids SwiftUI Material's intrinsic 1px vibrancy edge highlight.
        .background(
            VisualEffectView(material: .menu, blendingMode: .behindWindow, cornerRadius: 16)
        )
        .preferredColorScheme(.dark)
        .onAppear {
            isSearchFocused = true
            selectedID = displayItems.first?.id
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
                selectedID = displayItems.first?.id
                scrollResetToken = UUID()
            }
        }
        .onChange(of: searchQuery) { _, _ in
            selectedID = displayItems.first?.id
        }
        .onChange(of: displayItems.map(\.id)) { _, _ in
            ensureValidSelection()
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
            ScrollView(.horizontal, showsIndicators: false) {
                // Sentinel sits outside the leading padding so scrolling to its
                // leading edge snaps content to offset 0 — preserving the
                // 16pt visual gutter that anchoring the first card would eat.
                HStack(spacing: 0) {
                    Color.clear.frame(width: 0, height: 1).id(Self.leadingAnchorID)
                    HStack(spacing: 10) {
                        ForEach(displayItems, id: \.id) { item in
                            CardView(item: item, isSelected: item.id == selectedID)
                                .id(item.id)
                                .onTapGesture { onPaste(item) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.leadingAnchorID, anchor: .leading)
                }
            }
            .onChange(of: scrollResetToken) { _, _ in
                proxy.scrollTo(Self.leadingAnchorID, anchor: .leading)
            }
            .onChange(of: selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var verticalCardScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(width: 1, height: 0).id(Self.leadingAnchorID)
                    VStack(spacing: 10) {
                        ForEach(displayItems, id: \.id) { item in
                            CardView(item: item, isSelected: item.id == selectedID)
                                .id(item.id)
                                .onTapGesture { onPaste(item) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 14)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.leadingAnchorID, anchor: .top)
                }
            }
            .onChange(of: scrollResetToken) { _, _ in
                proxy.scrollTo(Self.leadingAnchorID, anchor: .top)
            }
            .onChange(of: selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
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
              let item = displayItems.first(where: { $0.id == id }) else { return }
        onPaste(item)
    }

    private func moveSelection(by delta: Int) {
        guard !displayItems.isEmpty else { return }
        let currentIndex = displayItems.firstIndex(where: { $0.id == selectedID }) ?? 0
        let newIndex = currentIndex + delta
        guard newIndex >= 0, newIndex < displayItems.count else { return }
        selectedID = displayItems[newIndex].id
    }

    /// Keep `selectedID` pointing at an item that still exists in `displayItems`.
    /// Falls back to the first item when the previously-selected one was removed
    /// or when nothing is selected yet.
    private func ensureValidSelection() {
        if let id = selectedID, displayItems.contains(where: { $0.id == id }) { return }
        selectedID = displayItems.first?.id
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

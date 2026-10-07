import SwiftUI

/// The extra results the start menus show above the matching apps while
/// searching: a calculation's answer, matching files, and a web search for
/// the typed text. Shared by the Kickoff, Windows 7 and Windows 11 layouts.
struct SearchExtrasView: View {
    let query: String
    let tokens: ThemeTokens
    let onDone: () -> Void

    private let extras = SearchExtras.shared

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 1) {
            if let calculation = extras.calculation {
                row(symbol: "equal.circle.fill", title: "\(trimmed) = \(calculation)", subtitle: L("search.copy_result")) {
                    extras.copyCalculation()
                    onDone()
                }
            }
            ForEach(extras.files.results) { file in
                row(icon: NSWorkspace.shared.icon(forFile: file.url.path), title: file.url.lastPathComponent, subtitle: (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) {
                    NSWorkspace.shared.open(file.url)
                    onDone()
                }
                .contextMenu {
                    Button(L("menu.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                }
            }
            if !trimmed.isEmpty {
                row(symbol: "globe", title: L("search.web", ["query": trimmed]), subtitle: nil) {
                    SearchExtras.searchWeb(trimmed)
                    onDone()
                }
            }
        }
        .onAppear { extras.update(query: query) }
        .onChange(of: query) { _, newValue in extras.update(query: newValue) }
    }

    private func row(symbol: String? = nil, icon: NSImage? = nil, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(Color(hex: tokens.colors.accent))
                        .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: tokens.typography.fontSize))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: tokens.typography.fontSize - 2))
                            .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: tokens.colors.buttonBackgroundHover).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
    }
}

/// Windows 11's "Recommended" strip under the app grid: the files used most
/// recently, two per row. Hidden while searching or when there are none.
struct RecommendedFilesView: View {
    let tokens: ThemeTokens
    let onDone: () -> Void

    private let files = FileSearch.recents
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !files.results.isEmpty {
                Text(L("start.recommended"))
                    .font(.system(size: tokens.typography.fontSize, weight: .semibold))
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(files.results) { file in
                        Button {
                            NSWorkspace.shared.open(file.url)
                            onDone()
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(file.url.lastPathComponent)
                                        .font(.system(size: tokens.typography.fontSize - 1))
                                        .lineLimit(1)
                                    if let lastUsed = file.lastUsed {
                                        Text(lastUsed, format: .relative(presentation: .named))
                                            .font(.system(size: tokens.typography.fontSize - 3))
                                            .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("menu.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, files.results.isEmpty ? 0 : 10)
        .environment(\.locale, Localization.effectiveLocale)
        .onAppear { files.loadRecents() }
    }
}

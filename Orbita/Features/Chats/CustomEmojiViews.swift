import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Combine

// MARK: - Реакция: обычный эмодзи или своё («u:<id>»)

struct ReactionGlyph: View {
    let emoji: String
    var size: CGFloat = 24
    var animate = false

    var body: some View {
        if emoji.hasPrefix("u:") {
            CustomEmojiView(id: emoji, fallback: CustomEmojiStore.shared.info(emoji)?.emoji ?? "", size: size, animate: animate)
        } else {
            Text(emoji).font(.system(size: size * 0.82))
        }
    }
}

// MARK: - Нажали на чужое эмодзи — его набор: «Добавить N эмодзи»

@MainActor
final class EmojiPackPresenter: ObservableObject {
    static let shared = EmojiPackPresenter()
    struct Route: Identifiable, Equatable { let id: String }        // id набора "u:<id>"
    @Published var route: Route?

    /// Открыть набор, в котором лежит это эмодзи
    func open(emojiID: String) {
        Haptics.impact(.light)
        hideKeyboard()                       // клавиатура чата не должна выезжать поверх шторки набора
        if let pack = CustomEmojiStore.shared.info(emojiID)?.pack {
            route = Route(id: pack)
            return
        }
        CustomEmojiStore.shared.request([emojiID])                  // сведений ещё нет — подтянем и откроем
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let pack = CustomEmojiStore.shared.info(emojiID)?.pack { route = Route(id: pack); return }
            }
        }
    }
}

struct EmojiPackSheet: View {
    let packID: String
    var onChanged: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var pack: CustomStickerPack?
    @State private var failed = false
    @State private var busy = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pack?.pack.title ?? s.t("Набор эмодзи", "Emoji pack"))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(20)

            if let pack {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(pack.pack.stickers) { e in
                            CustomEmojiView(id: e.id, fallback: e.emoji, size: 46, animate: true)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                Button { toggle(pack) } label: {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else if pack.mine { Text(s.t("Это ваш набор", "This is your pack")) }
                        else if pack.installed { Text(s.t("Убрать набор", "Remove pack")) }
                        else { Text(lang == .ru ? "Добавить \(pack.pack.stickers.count) эмодзи" : "Add \(pack.pack.stickers.count) emoji") }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(pack.installed && !pack.mine ? theme.danger : .white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background {
                        if pack.installed && !pack.mine { Capsule().fill(theme.danger.opacity(0.14)) }
                        else { Capsule().fill(theme.accent) }
                    }
                }
                .buttonStyle(PressStyle())
                .disabled(busy || pack.mine)
                .padding(16)
            } else if failed {
                Spacer()
                Text(s.api(.offline)).foregroundStyle(theme.textSecondary)
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .task {
            do {
                let p = try await session.messengerRepo.stickerPack(id: packID)
                pack = p
                CustomEmojiStore.shared.register([p.pack])
            } catch { failed = true }
        }
    }

    private func toggle(_ p: CustomStickerPack) {
        busy = true
        Task {
            defer { busy = false }
            if let fresh = try? await session.messengerRepo.setStickerPack(id: p.id, installed: !p.installed) {
                Haptics.notify(.success)
                pack = fresh
                onChanged()
            }
        }
    }
}

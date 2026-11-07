import SwiftUI
import Combine

// MARK: - «Чем я занят»: живой статус на 15 минут – 24 часа
// Видно в профиле под именем, значком на аватарке в орбите у друзей и в шапке личного чата вместо «был(а) в сети».

/// Чип статуса: эмодзи покачивается, текст — рядом
struct ActivityChip: View {
    let activity: UserActivity
    var compact = false
    @Environment(\.theme) private var theme
    @State private var bob = false

    var body: some View {
        HStack(spacing: 6) {
            Text(activity.emoji).font(.system(size: compact ? 13 : 16))
                .rotationEffect(.degrees(bob ? 8 : -8))
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: bob)
            Text(activity.text).font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(theme.text).lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 12).frame(height: compact ? 24 : 32)
        .background(theme.accentColor.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(theme.accentColor.opacity(0.25), lineWidth: 1))
        .onAppear { bob = true }
    }
}

/// Значок статуса на аватарке (в орбите друзей): кружок с эмодзи, который мягко «дышит»
struct ActivityBadge: View {
    let emoji: String
    var size: CGFloat = 20
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        Text(emoji).font(.system(size: size * 0.62))
            .frame(width: size, height: size)
            .background(theme.sheet, in: Circle())
            .overlay(Circle().stroke(theme.accentColor.opacity(0.6), lineWidth: 1.5))
            .scaleEffect(pulse ? 1.08 : 0.94)
            .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

struct ActivityStatusSheet: View {
    let current: UserActivity?
    let onSave: ((emoji: String, text: String, hours: Double)?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var emoji = "✨"
    @State private var text = ""
    @State private var hours: Double = 4
    @State private var saving = false
    @State private var failed = false

    private var s: Strings { Strings(lang: lang) }

    private var presets: [(String, String)] {
        [("🎧", s.t("Слушаю музыку", "Listening to music")), ("🏋️", s.t("В зале", "At the gym")),
         ("✈️", s.t("В пути", "Travelling")), ("💼", s.t("Работаю", "Working")),
         ("📚", s.t("Учусь", "Studying")), ("🎮", s.t("Играю", "Gaming")),
         ("🍿", s.t("Смотрю кино", "Watching a movie")), ("☕️", s.t("Пью кофе", "Having coffee")),
         ("😴", s.t("Сплю", "Sleeping")), ("🚗", s.t("За рулём", "Driving")),
         ("🎉", s.t("На тусовке", "At a party")), ("🤒", s.t("Болею", "Feeling sick"))]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let current {
                        HStack {
                            ActivityChip(activity: current)
                            Spacer()
                            Text(s.t("до ", "until ") + FormatterCache.format(current.until, "HH:mm"))
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(presets, id: \.1) { e, t in
                            Button {
                                Haptics.select()
                                emoji = e; text = t
                            } label: {
                                HStack(spacing: 8) {
                                    Text(e).font(.system(size: 20))
                                    Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).frame(height: 46)
                                .background(theme.text.opacity(text == t ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(text == t ? theme.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.t("СВОЙ СТАТУС", "CUSTOM")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                        HStack(spacing: 10) {
                            TextField("✨", text: $emoji)
                                .font(.system(size: 22)).multilineTextAlignment(.center)
                                .frame(width: 52, height: 48)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onChange(of: emoji) { _, v in if v.count > 1 { emoji = String(v.suffix(1)) } }
                            TextField(s.t("Чем вы заняты?", "What are you up to?"), text: $text)
                                .font(.system(size: 16))
                                .padding(.horizontal, 14).frame(height: 48)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onChange(of: text) { _, v in if v.count > 60 { text = String(v.prefix(60)) } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.t("СКОЛЬКО ПОКАЗЫВАТЬ", "SHOW FOR")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                        Picker("", selection: $hours) {
                            Text(s.t("1 час", "1 hour")).tag(1.0)
                            Text(s.t("4 часа", "4 hours")).tag(4.0)
                            Text(s.t("8 часов", "8 hours")).tag(8.0)
                            Text(s.t("Сутки", "24 hours")).tag(24.0)
                        }
                        .pickerStyle(.segmented)
                    }
                    Button { save() } label: {
                        HStack {
                            if saving { ProgressView().tint(.white) }
                            Text(s.t("Поставить статус", "Set status")).font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52)
                        .background(text.trimmingCharacters(in: .whitespaces).isEmpty ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(theme.accent),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if current != nil {
                        Button {
                            Task {
                                saving = true
                                if await onSave(nil) { dismiss() } else { failed = true }
                                saving = false
                            }
                        } label: {
                            Text(s.t("Убрать статус", "Clear status")).font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.danger).frame(maxWidth: .infinity).frame(height: 44)
                        }
                    }
                    if failed {
                        Text(s.api(.offline)).font(.system(size: 13)).foregroundStyle(theme.danger)
                    }
                    Text(s.t("Статус видят в вашем профиле, в шапке личного чата и на вашей аватарке в орбите друзей. Пропадёт сам.",
                             "Shown on your profile, in chat headers and on your avatar in friends' orbits. Disappears by itself."))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                .padding(20)
            }
            .navigationTitle(s.t("Чем я занят", "What I'm up to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } } }
        }
        .onAppear {
            if let current { emoji = current.emoji; text = current.text }
        }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        saving = true
        failed = false
        Task {
            if await onSave((emoji.isEmpty ? "✨" : emoji, t, hours)) {
                Haptics.notify(.success)
                dismiss()
            } else {
                failed = true
            }
            saving = false
        }
    }
}

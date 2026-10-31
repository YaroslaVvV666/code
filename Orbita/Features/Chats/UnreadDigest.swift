import SwiftUI

// MARK: - «Кратко»: пересказ пропущенных сообщений

/// Плашка под шапкой чата, когда непрочитанного много
struct UnreadDigestPill: View {
    let count: Int
    var onOpen: () -> Void
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .symbolEffect(.pulse, options: .repeat(2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Кратко", "Catch up")).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                        Text(s.t("Пока тебя не было: \(count > 99 ? "99+" : "\(count)") сообщ.",
                                 "While you were away: \(count > 99 ? "99+" : "\(count)") messages"))
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(height: 46)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        .padding(.horizontal, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Шторка с пересказом
struct UnreadDigestSheet: View {
    let peerID: String
    let fromID: String
    let repo: MessengerRepository
    var onJump: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var digest: UnreadDigest?
    @State private var failed = false
    @State private var attempt = 0

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let digest {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(points(digest.summary).enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(theme.accentColor).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                                    Text(line).font(.system(size: 16)).foregroundStyle(theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))

                        HStack(spacing: 6) {
                            Image(systemName: digest.ai ? "sparkles" : "text.alignleft")
                            Text(footer(digest))
                        }
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    } else if failed {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(theme.textTertiary)
                            Text(s.t("Не получилось пересказать. Попробуйте ещё раз.", "Couldn't summarise. Try again."))
                                .font(.system(size: 15)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                            Button(s.t("Повторить", "Retry")) { failed = false; attempt += 1 }
                                .foregroundStyle(theme.accentColor)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        loadingCard
                    }

                    Button {
                        dismiss()
                        onJump()
                    } label: {
                        Text(s.t("К первому непрочитанному", "Go to first unread"))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .animation(.easeOut(duration: 0.25), value: digest)
            }
            .background(theme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Пока тебя не было", "While you were away"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.t("Готово", "Done")) { dismiss() }.foregroundStyle(theme.accentColor)
                }
            }
        }
        .task(id: attempt) {
            do { digest = try await repo.unreadDigest(peerID: peerID, from: fromID) }
            catch { failed = true }
        }
    }

    /// Мерцающие строки, пока сервер (или ИИ) пишет пересказ
    private var loadingCard: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(theme.accentColor)
                    Text(s.t("Читаю пропущенное…", "Reading what you missed…"))
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                ForEach(0..<4, id: \.self) { i in
                    let phase = (sin(t * 2.4 - Double(i) * 0.6) + 1) / 2
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.textTertiary.opacity(0.18 + 0.18 * phase))
                        .frame(height: 14)
                        .frame(maxWidth: i == 3 ? 180 : .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func points(_ text: String) -> [String] {
        text.split(separator: "\n").map { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            for p in ["• ", "- ", "* ", "•"] where l.hasPrefix(p) { l.removeFirst(p.count); break }
            return l.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
    }

    private func footer(_ d: UnreadDigest) -> String {
        let more = d.truncated == true ? "+" : ""
        return d.ai
            ? s.t("Пересказ ИИ по \(d.count)\(more) сообщениям — может быть неточным", "AI summary of \(d.count)\(more) messages — may be inaccurate")
            : s.t("Краткая выжимка по \(d.count)\(more) сообщениям", "Quick digest of \(d.count)\(more) messages")
    }
}

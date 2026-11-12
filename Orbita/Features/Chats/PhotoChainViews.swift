import SwiftUI
import Combine
import PhotosUI

// MARK: - Фото-цепочка
// Тема дня («мой завтрак», «вид из окна») — все в чате по кругу добавляют фото. Владелец может включить проверку:
// новые фото видит только он, пока не одобрит; не по теме — убирает (человек больше не займёт это место).
// В конце — «Завершить» и «Выложить в шортсы» коллажем (листается, как в TikTok).

private struct ChainModelKey: EnvironmentKey { static let defaultValue: ChatModel? = nil }

extension EnvironmentValues {
    /// Модель переписки — для действий в фото-цепочке
    var chainModel: ChatModel? {
        get { self[ChainModelKey.self] }
        set { self[ChainModelKey.self] = newValue }
    }
}

extension ChatModel {
    func sendChain(theme: String, moderated: Bool) async -> Bool {
        do {
            var sent = try await repo.sendChain(peerID: peerID, theme: theme, moderated: moderated)
            sent.key = sent.id
            if !messages.contains(where: { $0.id == sent.id }) { messages.append(sent) }
            Haptics.notify(.success)
            return true
        } catch {
            self.error = (error as? APIError) ?? .offline
            return false
        }
    }

    /// Действие с цепочкой → свежая цепочка сразу в сообщении
    func updateChain(_ messageID: String, _ action: (MessengerRepository) async throws -> PhotoChain) async -> Bool {
        do {
            let chain = try await action(repo)
            if let i = messages.firstIndex(where: { $0.id == messageID }) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { messages[i].chain = chain }
            }
            return true
        } catch {
            self.error = (error as? APIError) ?? .offline
            return false
        }
    }

    func addToChain(_ messageID: String, photo: PreparedMedia) async -> Bool {
        do {
            let up = try await repo.upload(.prepared(photo))
            guard let media = up.mediaID else { return false }
            return await updateChain(messageID) { try await $0.chainAdd(messageID: messageID, mediaID: media) }
        } catch {
            self.error = (error as? APIError) ?? .offline
            return false
        }
    }
}

struct PhotoChainBlock: View {
    let message: ChatMessage
    let chain: PhotoChain
    let mine: Bool

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.chainModel) private var model
    @State private var pick: PhotosPickerItem?
    @State private var uploading = false
    @State private var showModeration = false
    @State private var note: String?
    @State private var posted = false

    private var s: Strings { Strings(lang: lang) }
    private var ink: Color { mine ? .white : theme.text }
    private var sub: Color { mine ? Color.white.opacity(0.75) : theme.textSecondary }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("📸").font(.system(size: 26))
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [Color.orange, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.t("Фото-цепочка", "Photo chain")).font(.system(size: 12, weight: .semibold)).foregroundStyle(sub)
                    Text(chain.theme).font(.system(size: 17, weight: .bold)).foregroundStyle(ink).lineLimit(2)
                }
                Spacer(minLength: 0)
                if chain.owner { ownerMenu }
            }
            Text(statusLine).font(.system(size: 12)).foregroundStyle(sub)

            if !chain.items.isEmpty {
                LazyVGrid(columns: cols, spacing: 3) {
                    ForEach(chain.items) { item in cell(item) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // свои фото на проверке (у владельца — все, кнопкой ниже)
            let myPending = chain.pending.filter(\.mine)
            if !chain.owner && !myPending.isEmpty {
                Label(s.t("Ваше фото на проверке: \(myPending.count)", "Your photo is under review: \(myPending.count)"), systemImage: "clock")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(sub)
            }
            if chain.owner && !chain.pending.isEmpty {
                Button { showModeration = true } label: {
                    Label(s.t("На проверке: \(chain.pending.count)", "To review: \(chain.pending.count)"), systemImage: "checkmark.shield")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Color.orange, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
            if !chain.closed {
                PhotosPicker(selection: $pick, matching: .images) {
                    HStack(spacing: 6) {
                        if uploading { ProgressView().tint(mine ? .white : theme.accentColor).scaleEffect(0.8) }
                        else { Image(systemName: "plus.circle.fill") }
                        Text(s.t("Добавить своё фото", "Add your photo"))
                    }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(mine ? theme.accentColor : .white)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(mine ? Color.white : theme.accentColor, in: Capsule())
                }
                .disabled(uploading)
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(sub) }
        }
        .padding(12)
        .frame(width: 270)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            upload(item)
        }
        .sheet(isPresented: $showModeration) {
            ChainModerationSheet(messageID: message.id, chain: chain)
                .environment(\.chainModel, model)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationDetents([.medium, .large])
                .sheetStyle(theme)
        }
    }

    private var statusLine: String {
        let n = chain.items.count
        var parts = [s.t("\(n) фото · \(chain.people) чел.", "\(n) photos · \(chain.people) people")]
        if chain.moderated { parts.append(s.t("с проверкой", "reviewed")) }
        if chain.closed { parts.append(s.t("завершена", "finished")) }
        return parts.joined(separator: " · ")
    }

    private func cell(_ item: PhotoChain.Item) -> some View {
        RemoteImage(id: item.mediaID)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                AvatarView(name: item.name, size: 20, avatarID: item.avatarID).clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5)).padding(4)
            }
            .contextMenu {
                if chain.owner || item.mine {
                    Button(role: .destructive) { remove(item) } label: {
                        Label(chain.owner && !item.mine ? s.t("Убрать — не по теме", "Remove — off-topic") : s.t("Удалить моё фото", "Delete my photo"),
                              systemImage: "trash")
                    }
                }
            }
    }

    private var ownerMenu: some View {
        Menu {
            Toggle(isOn: Binding(get: { chain.moderated }, set: { on in
                Task { _ = await model?.updateChain(message.id) { try await $0.chainSettings(messageID: message.id, moderated: on, closed: nil) } }
            })) { Label(s.t("Проверять фото", "Review photos"), systemImage: "checkmark.shield") }
            Button {
                Task { _ = await model?.updateChain(message.id) { try await $0.chainSettings(messageID: message.id, moderated: nil, closed: !chain.closed) } }
            } label: {
                Label(chain.closed ? s.t("Продолжить цепочку", "Reopen") : s.t("Завершить цепочку", "Finish chain"),
                      systemImage: chain.closed ? "play.circle" : "flag.checkered")
            }
            if !chain.items.isEmpty {
                Button { postReel() } label: {
                    Label(s.t("Выложить в шортсы коллажем", "Post to Shorts as a collage"), systemImage: "play.rectangle.on.rectangle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill").font(.system(size: 22)).foregroundStyle(sub)
        }
    }

    private func upload(_ item: PhotosPickerItem) {
        uploading = true
        note = nil
        Task { @MainActor in
            defer { uploading = false }
            guard let model, let photo = try? await MediaPreparer.prepare(item) else { note = s.mediaFailed; return }
            if await model.addToChain(message.id, photo: photo) {
                Haptics.notify(.success)
                if chain.moderated && !chain.owner { note = s.t("Отправлено на проверку", "Sent for review") }
            }
        }
    }

    private func remove(_ item: PhotoChain.Item) {
        Task { _ = await model?.updateChain(message.id) { try await $0.chainRemove(messageID: message.id, itemID: item.id) } }
    }

    private func postReel() {
        Task { @MainActor in
            do {
                try await model?.repo.chainReel(messageID: message.id)
                Haptics.notify(.success)
                note = s.t("Коллаж выложен в шортсы 🎉", "Posted to Shorts 🎉")
            } catch {
                note = s.api((error as? APIError) ?? .offline)
            }
        }
    }
}

/// Проверка фото владельцем: одобрить или убрать (не по теме)
struct ChainModerationSheet: View {
    let messageID: String
    let chain: PhotoChain
    @Environment(\.chainModel) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var left: [PhotoChain.Item] = []

    var body: some View {
        let s = Strings(lang: lang)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(s.t("Тема: «\(chain.theme)»", "Theme: “\(chain.theme)”")).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    if left.isEmpty {
                        Label(s.t("Всё проверено", "All reviewed"), systemImage: "checkmark.seal.fill")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.green).padding(.top, 30)
                    }
                    ForEach(left) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                AvatarView(name: item.name, size: 28, avatarID: item.avatarID).clipShape(Circle())
                                Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                            }
                            RemoteImage(id: item.mediaID)
                                .aspectRatio(1, contentMode: .fill).frame(maxWidth: .infinity).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            HStack(spacing: 10) {
                                Button { decide(item, approve: false) } label: {
                                    Label(s.t("Не по теме", "Off-topic"), systemImage: "xmark")
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.danger)
                                        .frame(maxWidth: .infinity).frame(height: 44)
                                        .background(theme.danger.opacity(0.12), in: Capsule())
                                }
                                Button { decide(item, approve: true) } label: {
                                    Label(s.t("Одобрить", "Approve"), systemImage: "checkmark")
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                        .frame(maxWidth: .infinity).frame(height: 44)
                                        .background(Color.green, in: Capsule())
                                }
                            }
                            .buttonStyle(PressStyle())
                        }
                        .padding(14)
                        .background(theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
                .padding(16)
            }
            .navigationTitle(s.t("Проверка фото", "Review photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(s.t("Готово", "Done")) { dismiss() } } }
        }
        .onAppear { left = chain.pending }
    }

    private func decide(_ item: PhotoChain.Item, approve: Bool) {
        Haptics.impact(approve ? .light : .medium)
        withAnimation(.spring(response: 0.35)) { left.removeAll { $0.id == item.id } }
        Task {
            _ = await model?.updateChain(messageID) { repo in
                approve ? try await repo.chainApprove(messageID: messageID, itemID: item.id)
                        : try await repo.chainRemove(messageID: messageID, itemID: item.id)
            }
        }
    }
}

/// Создание цепочки: тема и проверка фото
struct ChainCreateSheet: View {
    let onCreate: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var theme_ = ""
    @State private var moderated = false

    var body: some View {
        let s = Strings(lang: lang)
        let presets = [s.t("Мой завтрак", "My breakfast"), s.t("Вид из окна", "View from my window"),
                       s.t("Моё рабочее место", "My workspace"), s.t("Что я сейчас слушаю", "What I'm listening to"),
                       s.t("Закат сегодня", "Today's sunset"), s.t("Мой питомец", "My pet"),
                       s.t("Что на мне надето", "My outfit"), s.t("Кадр дня", "Shot of the day")]
        NavigationStack {
            Form {
                Section(s.t("Тема", "Theme")) {
                    TextField(s.t("Например: мой завтрак", "E.g. my breakfast"), text: $theme_)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presets, id: \.self) { p in
                                Button { theme_ = p; Haptics.select() } label: {
                                    Text(p).font(.system(size: 13, weight: .medium)).foregroundStyle(theme_ == p ? .white : theme.text)
                                        .padding(.horizontal, 12).frame(height: 32)
                                        .background(theme_ == p ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.text.opacity(0.08)), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    Toggle(s.t("Проверять фото перед публикацией", "Review photos before they appear"), isOn: $moderated)
                        .tint(theme.accentColor)
                } footer: {
                    Text(s.t("С проверкой новые фото видите только вы, пока не одобрите. Не по теме — убирайте одним нажатием.",
                             "With review on, new photos are visible only to you until approved. Remove off-topic ones in one tap."))
                }
            }
            .navigationTitle(s.t("Фото-цепочка", "Photo chain"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.t("Начать", "Start")) {
                        onCreate(theme_.trimmingCharacters(in: .whitespaces), moderated)
                        dismiss()
                    }
                    .disabled(theme_.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

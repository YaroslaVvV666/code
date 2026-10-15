import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Строка ввода как в Telegram:
/// [скрепка] [поле с форматированием и смайлом] [отправить | микрофон ↔ камера]
/// Нажатие на микрофон превращает его в камеру (и обратно); удержание — запись голосового / «кружка».
struct ChatInputBar: View {
    @ObservedObject var model: ChatModel
    var onSent: () -> Void
    var onPoll: () -> Void = {}

    @StateObject private var controller = RichComposerController()
    @StateObject private var voice = VoiceRecorder()
    @StateObject private var circle = CircleRecorder()

    @AppStorage("chat.micMode") private var micModeRaw = "voice"
    @State private var drafts: [DraftAttachment] = []
    @State private var preparing = 0
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var emojiOpen = false
    @State private var holding = false
    @State private var active: Active = .none
    @State private var slide: CGFloat = 0
    @State private var slideY: CGFloat = 0
    @State private var locked = false
    @State private var trashing = false
    @State private var notice: String?
    @State private var lastEditID: String?

    @EnvironmentObject private var session: AppSession
    @State private var showSchedule = false
    @State private var kbVisible = false
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private enum Active { case none, voice, circle }
    private var s: Strings { Strings(lang: lang) }
    private var cameraMode: Bool { micModeRaw == "camera" }
    private var willCancel: Bool { !locked && slide < -90 }
    private var recording: Bool { active != .none }

    private var canSend: Bool {
        if let target = model.editing {
            return controller.hasContent || !target.attachments.isEmpty
        }
        return controller.hasContent || !drafts.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            tray
            if model.isPreview {
                joinBar
            } else if model.canWrite {
                inputRow
            } else if model.peer.isChannel {
                Button {
                    Task { await model.setMuted(!(model.group?.muted ?? false)) }
                } label: {
                    Text((model.group?.muted ?? false) ? s.t("Включить звук", "Unmute") : s.t("Выключить звук", "Mute"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .buttonStyle(.plain)
            } else if model.peer.isGroup {
                Text(s.t("Писать могут только администраторы", "Only admins can write here"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                Text(s.chatWriteBlocked)
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
        .background(alignment: .bottom) {
            if active == .circle {
                // всё за кружком размыто и слегка затемнено
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.28)
                }
                .frame(width: 1400, height: 2600)
                .allowsHitTesting(locked)
                .transition(.opacity)
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) { circleOverlay }
        .overlay(alignment: .top) {
            if let notice {
                ToastView(text: notice).offset(y: -52).allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(5)
        .sheet(isPresented: $showSchedule) {
            ScheduleSheet { date in showSchedule = false; scheduleSend(at: date) }
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationBackground(theme.sheet)
                .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 10,
                      matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            addMedia(items)
        }
        .onChange(of: controller.length) { _, now in
            if now > 0 && model.editing == nil { model.ping() }
            if model.editing == nil {                       // черновик сохраняется по ходу набора
                let snap = controller.snapshot()
                ChatDraftStore.save(chat: model.peer.id, text: snap.text, entities: snap.entities)
            }
        }
        .onChange(of: model.editing?.id) { _, id in startEditing(id) }
        .onChange(of: model.replyTo?.id) { _, id in if id != nil { controller.focus() } }
        .onChange(of: model.packs) { _, _ in if emojiOpen { showPanel() } }
        .task(id: active) {
            // «записывает голосовое / видео…» у собеседника — раз в 3 секунды, пока идёт запись
            guard active != .none else { return }
            while !Task.isCancelled {
                model.ping(active == .voice ? "voice" : "video")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onAppear {
            controller.onFieldTap = {
                if emojiOpen { emojiOpen = false; controller.resetInputPanel() }
            }
            // возвращаем недописанное сообщение
            if let draft = ChatDraftStore.load(chat: model.peer.id), model.editing == nil {
                controller.load(text: draft.text, entities: draft.entities, color: UIColor(theme.text))
            }
        }
        .gesture(DragGesture(minimumDistance: 18).onEnded { if $0.translation.height > 30 { hideKeyboard() } })
        .task { await model.loadStickers() }
        .onDisappear {
            voice.cancel()
            circle.shutdown()
            locked = false
            // вышли из чата, не отправив: сохраняем набранное как черновик
            if model.editing == nil {
                let snap = controller.snapshot()
                if !snap.text.isEmpty { ChatDraftStore.save(chat: model.peer.id, text: snap.text, entities: snap.entities) }
            }
        }
    }

    // MARK: Просмотр без вступления

    private var joinBar: some View {
        let g = model.group
        let pending = g?.pending ?? false
        let title: String = pending ? s.t("Заявка отправлена", "Request sent")
            : (g?.approve ?? false) ? s.t("Подать заявку", "Request to join")
            : model.peer.isChannel ? s.t("Подписаться", "Subscribe") : s.t("Вступить", "Join")
        return Button {
            Task { await model.join() }
        } label: {
            HStack(spacing: 8) {
                if model.joining { ProgressView() }
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(pending ? theme.textSecondary : Color.white)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(pending ? AnyShapeStyle(theme.surface) : AnyShapeStyle(theme.accent), in: Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(pending || model.joining)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Ответ / правка

    @ViewBuilder
    private var banner: some View {
        if let target = model.editing ?? model.replyTo {
            HStack(spacing: 10) {
                Image(systemName: model.editing != nil ? "pencil" : "arrowshape.turn.up.left")
                    .font(.system(size: 17)).foregroundStyle(theme.accentColor)
                Capsule().fill(theme.accentColor).frame(width: 2, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.editing != nil ? s.editing : (target.mine ? s.youPrefix.trimmingCharacters(in: [":", " "]) : model.peer.name))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor)
                    Text(preview(of: target))
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Button {
                    if model.editing != nil { controller.clear() }
                    model.editing = nil
                    model.replyTo = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 14).padding(.top, 8)
        }
    }

    private func preview(of m: ChatMessage) -> String {
        if !m.text.isEmpty { return m.text }
        guard let a = m.attachments.first else { return "" }
        switch a.kind {
        case .photo: return s.photoLabel
        case .video: return s.videoLabel
        case .circle: return s.circleLabel
        case .voice: return s.voiceLabel
        case .sticker: return s.stickerLabel
        case .file: return a.name ?? s.fileLabel
        case .audio: return a.displayTitle
        }
    }

    // MARK: Вложения над полем

    @ViewBuilder
    private var tray: some View {
        if let query = controller.mention, let members = mentionCandidates(query), !members.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(members, id: \.id) { m in
                        Button { controller.completeMention(m.username ?? "") } label: {
                            HStack(spacing: 6) {
                                AvatarView(name: m.name, size: 26, avatarID: m.avatarID).clipShape(Circle())
                                Text(m.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                                Text("@" + (m.username ?? "")).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            .glassCapsule(interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)
            }
        } else if !drafts.isEmpty || preparing > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(drafts) { draft in
                        DraftThumb(draft: draft) { drafts.removeAll { $0.id == draft.id } }
                    }
                    if preparing > 0 {
                        ProgressView().frame(width: 64, height: 64).card(theme, radius: 12)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
            }
        }
    }

    /// Участники группы с юзернеймом, подходящие под набранное после «@»
    private func mentionCandidates(_ query: String) -> [GroupMember]? {
        guard let group = model.group, model.peer.isGroup, !model.peer.isChannel else { return nil }
        let q = query.lowercased()
        return Array(group.members.filter {
            guard let u = $0.username, !u.isEmpty, $0.id.lowercased() != session.serverID else { return false }
            return q.isEmpty || u.lowercased().hasPrefix(q) || $0.name.lowercased().hasPrefix(q)
        }.prefix(12))
    }

    // MARK: Основная строка

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !recording {
                attachButton.transition(.opacity)
            }

            ZStack(alignment: .bottomLeading) {
                field.opacity(recording ? 0 : 1).allowsHitTesting(!recording)       // под полосой записи ничего не просвечивает и не нажимается
                if active == .voice { voiceStrip.transition(.opacity) }
                if active == .circle { circleStrip.transition(.opacity) }
            }
            .frame(maxWidth: .infinity)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))      // отдельная стеклянная плашка ввода

            trailingButton
        }
        .overlay(alignment: .bottomLeading) {
            // отмена записи: микрофон падает в мусорку, крышка открывается и закрывается
            if trashing {
                TrashCancelAnimation(color: theme.danger)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, kbVisible ? 22 : 12)      // зазор от клавиатуры — поле не «налезает» на неё
        .animation(.easeOut(duration: 0.2), value: kbVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in kbVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in kbVisible = false }
        .animation(.easeOut(duration: 0.18), value: recording)
    }

    private var attachButton: some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label(s.attachPhotoVideo, systemImage: "photo.on.rectangle") }
            Button { showFileImporter = true } label: { Label(s.attachFile, systemImage: "doc") }
            if !model.peer.isChannel || model.group?.isAdmin == true {
                Button { onPoll() } label: { Label(s.t("Опрос", "Poll"), systemImage: "chart.bar.fill") }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(theme.text)
                .frame(width: 44, height: 44)
                .glassCircle()
        }
    }

    private var field: some View {
        HStack(alignment: .center, spacing: 0) {
            ZStack(alignment: .leading) {
                if controller.length == 0 {
                    Text(drafts.isEmpty ? s.messagePlaceholder : s.t("Добавить подпись…", "Add a caption…"))
                        .font(.system(size: 17)).foregroundStyle(theme.textTertiary)
                        .allowsHitTesting(false)
                }
                FormattingTextView(controller: controller, textColor: UIColor(theme.text),
                                   tint: UIColor(theme.accentColor), maxHeight: 130)
            }
            .padding(.leading, 14)

            Button(action: toggleEmoji) {
                Image(systemName: emojiOpen ? "keyboard" : "face.smiling")
                    .font(.system(size: 21))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 40, height: 38)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 44)
    }

    // MARK: Правая кнопка

    @ViewBuilder
    private var trailingButton: some View {
        // кнопка микрофона остаётся в иерархии, пока идёт запись: иначе вместе с ней пропадал бы замок и жест
        let micVisible = model.editing == nil && (recording || !(canSend && !recording))
        ZStack {
            if micVisible {
                micButton
                    .opacity(locked ? 0 : 1)
                    .allowsHitTesting(!locked)
            }
            if locked {
                Button { finishRecording(cancel: false) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(theme.accent, in: Circle())
                }
                .buttonStyle(PressStyle())
                .background {
                    // на замке запись не «замирает»: вокруг кнопки бегут круги, в такт голосу
                    RecordPulse(color: theme.accentColor,
                                level: { [voice, active] in active == .voice ? CGFloat(voice.level) : 0.35 })
                        .allowsHitTesting(false)
                }
                .transition(.scale.combined(with: .opacity))
            } else if canSend && !recording {
                Button { send() } label: {
                    Image(systemName: model.editing != nil ? "checkmark" : "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(theme.accent, in: Circle())
                        .shadow(color: theme.accentColor.opacity(0.45), radius: 7, y: 3)
                }
                .buttonStyle(PressStyle())
                .contextMenu {
                    if model.editing == nil && model.peer.id != session.serverID {
                        Button { send(silent: true) } label: {
                            Label(s.t("Отправить без звука", "Send silently"), systemImage: "bell.slash")
                        }
                    }
                    if model.editing == nil && !model.peer.isGroup && model.peer.id != session.serverID {
                        Button { showSchedule = true } label: {
                            Label(s.t("Отправить позже", "Send later"), systemImage: "clock")
                        }
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 44, height: 44)
        .background {
            // микрофон — отдельная стеклянная кнопка, как и скрепка
            if micVisible && !recording && !(canSend) { Color.clear.glassCircle() }
        }
        .animation(.easeOut(duration: 0.15), value: canSend)
        .overlay(alignment: .top) {
            // замок остаётся на экране всё время записи: закрыт — можно в любой момент остановить и отправить
            if recording {
                if locked {
                    lockedStop.offset(y: -92)
                } else {
                    lockHint.offset(y: -158).allowsHitTesting(false)
                }
            }
        }
    }

    private var micButton: some View {
        ZStack {
            Image(systemName: cameraMode ? "video" : "mic")
                .font(.system(size: 22))
                .foregroundStyle(recording ? Color.white : theme.textSecondary)
                .frame(width: 40, height: 40)
                .background {
                    if recording { Circle().fill(willCancel ? theme.danger : theme.accentColor) }
                }
                .scaleEffect(recording ? 1.35 : 1)
        }
        .overlay {
            if recording {
                RecordPulse(color: willCancel ? theme.danger : theme.accentColor,
                            level: { [voice, active] in active == .voice ? CGFloat(voice.level) : 0.35 })
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            HoldOverlay(onTap: toggleMicMode, onBegin: beginHold,
                        onMove: { move in
                            slide = move.width
                            slideY = move.height
                            if recording, !locked, !willCancel, move.height < -70 {
                                locked = true
                                Haptics.impact(.medium)
                            }
                        }, onEnd: endHold)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recording)
    }

    /// Замок над кнопкой: чем выше палец, тем плотнее он закрывается (как в Telegram)
    private var lockHint: some View {
        let p = max(0, min(1, -slideY / 70))
        return VStack(spacing: 5) {
            Image(systemName: p > 0.6 ? "lock" : "lock.open")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(theme.text)
            Image(systemName: "chevron.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text.opacity(0.85))
                .opacity(1 - p)
        }
        .frame(width: 48, height: 86 - 30 * p)
        .glassCapsule()
        .offset(y: -p * 22)
        .animation(.easeOut(duration: 0.12), value: p)
    }

    /// Закрытый замок: нажмите — запись останавливается и уходит
    private var lockedStop: some View {
        Button { finishRecording(cancel: false) } label: {
            VStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 22, weight: .regular)).foregroundStyle(theme.text)
                Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.danger)
            }
            .frame(width: 48, height: 70)
            .glassCapsule(interactive: true)
        }
        .buttonStyle(PressStyle())
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(s.t("Остановить запись", "Stop recording"))
    }

    private func toggleMicMode() {
        Haptics.impact(.light)
        withAnimation(.easeOut(duration: 0.15)) { micModeRaw = cameraMode ? "voice" : "camera" }
        flash(cameraMode ? s.t("Нажмите и держите — запись видео", "Hold to record video")
                         : s.t("Нажмите и держите — запись голоса", "Hold to record voice"))
    }

    // MARK: Запись

    private var voiceStrip: some View {
        HStack(spacing: 8) {
            if willCancel {
                Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(theme.danger)
            } else {
                BlinkingDot()
            }
            RecordClock(since: { [voice] in voice.startedAt })
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.text)
            if locked {
                // бегущая волна: видно, что запись идёт и микрофон слышит
                LiveWave(color: theme.accentColor, samples: { [voice] in voice.recent })
                    .frame(height: 26)
                    .transition(.opacity)
                cancelLockedButton
            } else {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(willCancel ? s.t("Отпустите — отмена", "Release to cancel") : s.slideToCancel)
                }
                .font(.system(size: 15))
                .foregroundStyle(willCancel ? theme.danger : theme.textSecondary)
                .offset(x: max(-60, min(0, slide / 3)))
                .padding(.trailing, 14)
            }
        }
        .padding(.leading, 14)
        .frame(height: 40)
    }

    private var cancelLockedButton: some View {
        Button { finishRecording(cancel: true) } label: {
            Text(s.t("Отмена", "Cancel"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.danger)
                .padding(.horizontal, 14).frame(height: 40)
        }
        .buttonStyle(.plain)
    }

    private var circleStrip: some View {
        HStack(spacing: 8) {
            if willCancel {
                Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(theme.danger)
            } else {
                BlinkingDot()
            }
            RecordClock(since: { [circle] in circle.startedAt })
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.text)
            Spacer()
            if locked {
                cancelLockedButton
            } else {
                Text(willCancel ? s.t("Отпустите — отмена", "Release to cancel") : s.slideToCancel)
                    .font(.system(size: 15))
                    .foregroundStyle(willCancel ? theme.danger : theme.textSecondary)
                    .padding(.trailing, 14)
            }
        }
        .padding(.leading, 14)
        .frame(height: 40)
    }

    /// Живое «кружок»-превью ближе к центру экрана; всё за ним размыто
    @ViewBuilder
    private var circleOverlay: some View {
        if active == .circle {
            let screenH = UIScreen.main.bounds.height
            let side: CGFloat = 288
            ZStack {
                CameraPreview(session: circle.session)
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .scaleEffect(x: circle.isFront ? -1 : 1, y: 1)       // фронталка — зеркало
                    .overlay {
                        // кольцо-таймер: заполняется за 60 секунд и «дышит» — запись на замке выглядит живой
                        CircleRing(color: willCancel ? theme.danger : theme.accentColor,
                                   startedAt: { [circle] in circle.startedAt }, limit: CircleRecorder.maxDuration)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .allowsHitTesting(false)
                if locked {
                    Button { Haptics.impact(.light); circle.flipCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 46, height: 46).glassCircle(interactive: true)
                    }
                    .buttonStyle(PressStyle())
                    .offset(x: side / 2 - 18, y: side / 2 - 18)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .offset(y: -(screenH * 0.58 - 112))              // центр круга примерно на 42% высоты экрана
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private func beginHold() {
        guard model.canWrite, !recording else { return }
        holding = true
        slide = 0
        slideY = 0
        locked = false
        Haptics.impact(.medium)
        if emojiOpen { emojiOpen = false; controller.resetInputPanel() }
        controller.unfocus()
        if cameraMode {
            Task {
                let ok = await circle.prepare()
                guard ok else {
                    holding = false
                    flash(circle.failure == "denied" ? s.cameraDenied
                          : s.t("Не удалось включить камеру", "Couldn't start the camera"))
                    return
                }
                guard holding || locked else { circle.shutdown(); flash(s.t("Удерживайте кнопку для записи", "Hold the button to record")); return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { active = .circle }
                circle.startRecording()
            }
        } else {
            Task {
                let ok = await voice.start()
                guard ok else { holding = false; flash(s.micDenied); return }
                guard holding || locked else { voice.cancel(); return }
                active = .voice
            }
        }
    }

    private func endHold() {
        holding = false
        if locked { return }                    // запись закреплена замком — ждём «отправить» или «отмена»
        finishRecording(cancel: willCancel)
    }

    private func finishRecording(cancel cancelled: Bool) {
        let mode = active
        if cancelled && mode != .none {
            Haptics.impact(.rigid)
            withAnimation(.easeOut(duration: 0.15)) { trashing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                withAnimation(.easeOut(duration: 0.2)) { trashing = false }
            }
        }
        locked = false
        holding = false
        withAnimation(.easeOut(duration: 0.2)) { active = .none }
        slide = 0
        slideY = 0
        switch mode {
        case .voice:
            if cancelled {
                voice.cancel()
            } else if let r = voice.finish() {
                Haptics.notify(.success)
                model.sendVoice(url: r.url, duration: r.duration, waveform: r.waveform)
                onSent()
            } else {
                flash(s.tooShort)
            }
        case .circle:
            Task {
                let file = await circle.stopRecording()
                circle.shutdown()
                guard let file else {
                    if !cancelled {
                        if circle.lastErrorCode == -11805 {
                            // камера не успела записать ни кадра — обычно запись была слишком короткой
                            flash(s.tooShort)
                        } else {
                            let code = circle.lastErrorCode.map { " (\($0))" } ?? ""
                            flash(s.t("Видео не записалось, попробуйте ещё раз", "Recording failed, try again") + code)
                        }
                    }
                    return
                }
                if cancelled { try? FileManager.default.removeItem(at: file); return }
                let info = await CircleRecorder.thumbnail(for: file)
                guard info.duration >= 1, !info.data.isEmpty else {
                    try? FileManager.default.removeItem(at: file)
                    flash(s.tooShort)
                    return
                }
                Haptics.notify(.success)
                model.sendCircle(url: file, thumb: info.data, duration: info.duration)
                onSent()
            }
        case .none:
            break
        }
    }

    // MARK: Смайлы и стикеры

    private func toggleEmoji() {
        if emojiOpen {
            emojiOpen = false
            controller.resetInputPanel()
        } else {
            emojiOpen = true
            showPanel()
            Task { await model.loadStickers() }
        }
    }

    private func showPanel() {
        let panel = EmojiStickerPanel(
            packs: model.packs,
            onEmoji: { controller.insert($0) },
            onBackspace: { controller.backspace() },
            onSticker: { sticker in
                Haptics.impact(.light)
                model.sendSticker(sticker)
                onSent()
            })
            .environment(\.theme, theme)
            .environment(\.lang, lang)
        controller.setInputPanel(panel)
    }

    // MARK: Отправка

    /// Отложенная отправка: вложения загружаются сразу, сообщение уйдёт в выбранное время
    private func scheduleSend(at date: Date) {
        let snap = controller.snapshot()
        guard !snap.text.isEmpty || !drafts.isEmpty else { return }
        let items = drafts
        drafts = []
        controller.clear()
        Haptics.impact(.light)
        Task {
            do {
                var uploaded: [OutgoingAttachment] = []
                for d in items { uploaded.append(try await model.repo.upload(d.outgoing)) }
                try await session.extras.schedule(peerID: model.peer.id, text: snap.text, entities: snap.entities,
                                                  attachments: uploaded, at: date)
                flash(s.t("Сообщение запланировано", "Message scheduled"))
                Haptics.notify(.success)
            } catch {
                controller.load(text: snap.text, entities: snap.entities, color: UIColor(theme.text))
                drafts = items
                flash(s.t("Не удалось запланировать", "Couldn't schedule"))
            }
        }
    }

    private func send(silent: Bool = false) {
        let snap = controller.snapshot()
        if let target = model.editing {
            controller.clear()
            Task { _ = await model.saveEdit(target, text: snap.text, entities: snap.entities) }
            return
        }
        guard !snap.text.isEmpty || !drafts.isEmpty else { return }
        let items = drafts
        drafts = []
        controller.clear()
        Haptics.impact(.light)
        Task {
            let ok = await model.deliver(text: snap.text, entities: snap.entities,
                                         media: items.map(\.outgoing), placeholders: items.map(\.placeholder), silent: silent)
            if !ok {                                    // не ушло — возвращаем всё в поле
                controller.load(text: snap.text, entities: snap.entities, color: UIColor(theme.text))
                drafts = items
            }
        }
        onSent()
    }

    private func startEditing(_ id: String?) {
        guard let id, let target = model.editing, target.id == id else {
            if id == nil, lastEditID != nil { controller.clear() }
            lastEditID = id
            return
        }
        lastEditID = id
        drafts = []
        controller.load(text: target.text, entities: target.entities, color: UIColor(theme.text))
        controller.focus()
    }

    // MARK: Файлы и фото

    private func addMedia(_ items: [PhotosPickerItem]) {
        preparing += items.count
        Task {
            for item in items {
                do {
                    let media = try await MediaPreparer.prepare(item)
                    drafts.append(DraftAttachment(source: .media(media)))
                } catch MediaError.tooLong {
                    flash(s.t("Видео слишком длинное", "Video is too long"))
                } catch MediaError.tooLarge {
                    flash(s.t("Файл слишком большой", "File is too large"))
                } catch {
                    flash(s.t("Не удалось добавить файл", "Couldn't add the file"))
                }
                preparing -= 1
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 80 * 1024 * 1024 { flash(s.t("Файл больше 80 МБ", "File is over 80 MB")); continue }
            // копия во временную папку: доступ к оригиналу после закрытия окна пропадёт
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let target = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                flash(s.t("Не удалось добавить файл", "Couldn't add the file"))
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ["mp3", "m4a", "aac"].contains(ext) {
                // музыка: читаем теги и обложку, чтобы получателю было что показать
                let name = url.lastPathComponent
                Task { @MainActor in
                    let meta = await AudioMeta.read(target)
                    drafts.append(DraftAttachment(source: .audio(url: target, name: name, title: meta.title, artist: meta.artist,
                                                                 duration: meta.duration, cover: meta.cover, size: size)))
                }
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            drafts.append(DraftAttachment(source: .file(url: target, name: url.lastPathComponent, mime: mime, size: size)))
        }
    }

    private func flash(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if notice == text { withAnimation { notice = nil } }
        }
    }
}

// MARK: - Миниатюра выбранного вложения

private struct DraftThumb: View {
    let draft: DraftAttachment
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let data = draft.preview, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .overlay {
                            if draft.isVideo {
                                Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(.white)
                                    .shadow(radius: 3)
                            }
                        }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(theme.accentColor)
                        Text(draft.fileName ?? "").font(.system(size: 10)).lineLimit(2)
                            .foregroundStyle(theme.textSecondary).padding(.horizontal, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6).padding(.trailing, 6)
    }
}


// MARK: - Волны вокруг кнопки записи

/// Расходящиеся кольца вокруг значка микрофона / камеры; размер «сердцевины» следует за громкостью
/// Счётчик записи с долями секунды: 0:05,42 (как в Telegram). Обновляется сам, без перерисовки строки ввода
struct RecordClock: View {
    let since: () -> Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Text(Self.format(since().map { context.date.timeIntervalSince($0) } ?? 0))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let hundredths = Int(max(0, seconds) * 100)
        return String(format: "%d:%02d,%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// Красная точка, мягко мигающая, пока идёт запись
struct BlinkingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .opacity(0.45 + 0.55 * (0.5 + 0.5 * sin(t * 4.2)))
                .scaleEffect(0.9 + 0.15 * (0.5 + 0.5 * sin(t * 4.2)))
        }
        .frame(width: 14, height: 14)
    }
}

/// Бегущая волна громкости: новые отсчёты появляются справа и уезжают влево
struct LiveWave: View {
    let color: Color
    let samples: () -> [Float]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let data = samples()
            Canvas { ctx, size in
                let count = 42
                let gap: CGFloat = 2.5
                let bar = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                let tail = Array(data.suffix(count))
                for i in 0..<count {
                    // правые столбики — самые свежие; пустые слева — тихая «полочка»
                    let idx = i - (count - tail.count)
                    let v = idx >= 0 ? CGFloat(tail[idx]) : 0
                    let h = max(3, v * size.height)
                    let rect = CGRect(x: CGFloat(i) * (bar + gap), y: (size.height - h) / 2, width: bar, height: h)
                    let age = Double(i) / Double(count)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(color.opacity(0.35 + 0.65 * age)))
                }
            }
        }
    }
}

/// Кольцо вокруг «кружка»: заполняется до лимита записи и пульсирует
struct CircleRing: View {
    let color: Color
    let startedAt: () -> Date?
    let limit: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date
            let t = now.timeIntervalSinceReferenceDate
            let progress = startedAt().map { min(1, now.timeIntervalSince($0) / limit) } ?? 0
            let breath = 0.5 + 0.5 * sin(t * 3.4)
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.004, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().stroke(color.opacity(0.35 * (1 - breath)), lineWidth: 6)
                    .scaleEffect(1 + 0.05 * breath)
            }
        }
        .allowsHitTesting(false)
    }
}

struct RecordPulse: View {
    let color: Color
    var level: () -> CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let lv = level()
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t / 1.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity((1 - phase) * 0.55), lineWidth: 2.5 * (1 - phase) + 0.5)
                        .frame(width: 56, height: 56)
                        .scaleEffect(1 + CGFloat(phase) * 1.55)
                }
                Circle()
                    .fill(color.opacity(0.22))
                    .frame(width: 64, height: 64)
                    .scaleEffect(1 + lv * 0.45)
            }
        }
        .frame(width: 40, height: 40)
    }
}


/// Отмена записи: микрофон падает в мусорку, крышка открывается и закрывается (как в Telegram)
struct TrashCancelAnimation: View {
    let color: Color

    @State private var lid: Double = 0          // угол крышки
    @State private var micY: CGFloat = -26
    @State private var micTilt: Double = 0
    @State private var micScale: CGFloat = 1
    @State private var micOpacity: Double = 1
    @State private var binScale: CGFloat = 0.6
    @State private var binOpacity: Double = 0

    var body: some View {
        ZStack {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
                .scaleEffect(micScale)
                .rotationEffect(.degrees(micTilt))
                .offset(y: micY)
                .opacity(micOpacity)
            TrashBinShape(lid: lid, color: color)
                .frame(width: 26, height: 30)
                .scaleEffect(binScale)
                .opacity(binOpacity)
                .offset(y: 4)
        }
        .frame(width: 44, height: 44)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { binScale = 1; binOpacity = 1 }
            withAnimation(.easeOut(duration: 0.2).delay(0.08)) { lid = -72 }
            withAnimation(.easeIn(duration: 0.34).delay(0.12)) {
                micY = 6; micTilt = -28; micScale = 0.45
            }
            withAnimation(.easeOut(duration: 0.12).delay(0.38)) { micOpacity = 0 }
            withAnimation(.easeInOut(duration: 0.2).delay(0.52)) { lid = 0 }
            withAnimation(.easeIn(duration: 0.2).delay(0.82)) { binOpacity = 0; binScale = 0.8 }
        }
    }
}

private struct TrashBinShape: View {
    let lid: Double
    let color: Color

    var body: some View {
        ZStack(alignment: .top) {
            // корзина: трапеция и три полоски
            Canvas { ctx, size in
                let w = size.width, h = size.height
                var body = Path()
                body.move(to: CGPoint(x: w * 0.14, y: h * 0.30))
                body.addLine(to: CGPoint(x: w * 0.22, y: h * 0.92))
                body.addQuadCurve(to: CGPoint(x: w * 0.30, y: h), control: CGPoint(x: w * 0.23, y: h))
                body.addLine(to: CGPoint(x: w * 0.70, y: h))
                body.addQuadCurve(to: CGPoint(x: w * 0.78, y: h * 0.92), control: CGPoint(x: w * 0.77, y: h))
                body.addLine(to: CGPoint(x: w * 0.86, y: h * 0.30))
                ctx.stroke(body, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                for x in [0.38, 0.5, 0.62] {
                    var line = Path()
                    line.move(to: CGPoint(x: w * x, y: h * 0.46))
                    line.addLine(to: CGPoint(x: w * x, y: h * 0.8))
                    ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
            }
            // крышка с ручкой поворачивается вокруг левого края
            Canvas { ctx, size in
                let w = size.width
                var lidPath = Path()
                lidPath.move(to: CGPoint(x: 0, y: 7))
                lidPath.addLine(to: CGPoint(x: w, y: 7))
                lidPath.move(to: CGPoint(x: w * 0.36, y: 7))
                lidPath.addLine(to: CGPoint(x: w * 0.36, y: 3.5))
                lidPath.addQuadCurve(to: CGPoint(x: w * 0.40, y: 1.6), control: CGPoint(x: w * 0.36, y: 1.6))
                lidPath.addLine(to: CGPoint(x: w * 0.60, y: 1.6))
                lidPath.addQuadCurve(to: CGPoint(x: w * 0.64, y: 3.5), control: CGPoint(x: w * 0.64, y: 1.6))
                lidPath.addLine(to: CGPoint(x: w * 0.64, y: 7))
                ctx.stroke(lidPath, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 12)
            .rotationEffect(.degrees(lid), anchor: UnitPoint(x: 0.05, y: 0.6))
        }
    }
}

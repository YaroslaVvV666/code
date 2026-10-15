import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Изменить профиль (как в Telegram)

struct EditProfileView: View {
    @ObservedObject var store: ProfileStore

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    enum Destination: Hashable { case username, phone }

    @State private var path: [Destination] = []

    // черновик полей
    @State private var first = ""
    @State private var last = ""
    @State private var bio = ""
    @State private var birthday: String?
    @State private var draftLoaded = false

    // фотографии
    @State private var photos: [AvatarPhoto] = []
    @State private var dragging: AvatarPhoto?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploading = 0
    @State private var photoToDelete: AvatarPhoto?

    @State private var saving = false
    @State private var errorText: String?
    @State private var showBirthday = false

    private var s: Strings { Strings(lang: lang) }
    private var profile: UserProfile? { store.profile }

    private var firstClean: String { Validator.normalizeName(first) }
    private var lastClean: String { Validator.normalizeName(last) }

    private var changed: Bool {
        firstClean != (profile?.firstName ?? "")
            || lastClean != (profile?.lastName ?? "")
            || bio.trimmingCharacters(in: .whitespacesAndNewlines) != (profile?.bio ?? "")
            || birthday != profile?.birthday
    }

    private var valid: Bool {
        Validator.isValidName(firstClean)
            && (lastClean.isEmpty || Validator.isValidName(lastClean))
            && bio.count <= 70
    }

    private var usernameText: String {
        if let u = profile?.username, !u.isEmpty { return "@" + u }
        return s.notSet
    }

    private var displayName: String { (firstClean + " " + lastClean).trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 22) {
                    photoHeader
                    if !photos.isEmpty { photoGrid }
                    namesGroup
                    bioGroup
                    accountGroup

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { SpaceBackground(isDark: theme.dark, showStars: false) }
            .navigationTitle(s.editProfile)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(s.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if saving { ProgressView() } else { Text(s.done).fontWeight(.semibold) }
                    }
                    .disabled(!valid || saving)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .username: UsernameEditScreen(store: store)
                case .phone:    ChangePhoneScreen(store: store)
                }
            }
        }
        .onAppear(perform: fillDraft)
        .onChange(of: store.profile) { _, _ in fillDraft() }
        .task { if store.profile == nil { await store.load() } }
        .onChange(of: store.profile?.avatars) { _, new in
            if dragging == nil { photos = new ?? [] }
        }
        .onChange(of: pickerItems) { _, items in upload(items) }
        .onChange(of: bio) { _, new in
            if new.count > 70 { bio = String(new.prefix(70)) }
        }
        .onDisappear(perform: commitOrder)
        .sheet(isPresented: $showBirthday) {
            BirthdaySheet(value: $birthday)
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
        .confirmationDialog(s.deletePhotoQuestion,
                            isPresented: Binding(get: { photoToDelete != nil },
                                                 set: { if !$0 { photoToDelete = nil } }),
                            titleVisibility: .visible) {
            Button(s.deletePhoto, role: .destructive) {
                if let photo = photoToDelete { remove(photo) }
                photoToDelete = nil
            }
            Button(s.cancel, role: .cancel) { photoToDelete = nil }
        }
    }

    // MARK: Фото

    private var photoHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                AvatarView(name: displayName, size: 104, avatarID: photos.first?.mediaID)
                if uploading > 0 {
                    Circle().fill(Color.black.opacity(0.45)).frame(width: 104, height: 104)
                    ProgressView().tint(Color.white)
                }
            }

            PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, 50 - photos.count), matching: .images) {
                Label(s.addPhoto, systemImage: "camera.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .glassCapsule(interactive: true)
            }
        }
    }

    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.profilePhotos.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(photos) { photo in tile(photo) }
            }
            .padding(.horizontal, 16)

            Text(s.reorderHint)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)
        }
    }

    private func tile(_ photo: AvatarPhoto) -> some View {
        let isMain = photo.id == photos.first?.id
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(id: photo.mediaID).clipped() }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                if isMain {
                    Text(s.mainPhoto)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .glassCapsule()
                        .padding(7)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { photoToDelete = photo } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 26, height: 26)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .padding(7)
            }
            .overlay(alignment: .bottom) {
                Text(s.photoDateShort(photo.createdAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .glassCapsule()
                    .padding(7)
            }
            .opacity(dragging == photo ? 0.35 : 1)
            .onDrag {
                dragging = photo
                return NSItemProvider(object: photo.id as NSString)
            }
            .onDrop(of: [UTType.text],
                    delegate: PhotoDropDelegate(item: photo, photos: $photos, dragging: $dragging,
                                                onFinish: commitOrder))
            .contextMenu {
                if !isMain {
                    Button { makeMain(photo) } label: { Label(s.makeMain, systemImage: "star") }
                }
                Button(role: .destructive) { photoToDelete = photo } label: {
                    Label(s.deletePhoto, systemImage: "trash")
                }
            }
    }

    private func upload(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        Task { @MainActor in
            for item in items {
                uploading += 1
                if let data = try? await item.loadTransferable(type: Data.self) {
                    if let error = await store.addPhoto(from: data) { errorText = s.api(error) }
                }
                uploading -= 1
            }
        }
    }

    private func makeMain(_ photo: AvatarPhoto) {
        guard let from = photos.firstIndex(of: photo), from != 0 else { return }
        withAnimation { photos.move(fromOffsets: IndexSet(integer: from), toOffset: 0) }
        commitOrder()
    }

    private func remove(_ photo: AvatarPhoto) {
        withAnimation { photos.removeAll { $0.id == photo.id } }
        Task { @MainActor in
            if let error = await store.removePhoto(photo.id) {
                errorText = s.api(error)
                photos = store.profile?.avatars ?? photos
            }
        }
    }

    /// Отправляет новый порядок на сервер, если он поменялся
    private func commitOrder() {
        dragging = nil
        let ids = photos.map(\.id)
        guard ids != (store.profile?.avatars.map(\.id) ?? []), Set(ids) == Set(store.profile?.avatars.map(\.id) ?? []) else { return }
        Task { @MainActor in
            if let error = await store.reorderPhotos(ids) {
                errorText = s.api(error)
                photos = store.profile?.avatars ?? photos
            }
        }
    }

    // MARK: Поля

    private var namesGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup {
                field(s.firstName, text: $first)
                Rectangle().fill(theme.stroke).frame(height: 1).padding(.leading, 16)
                field(s.lastName, text: $last)
            }
            Text(s.namesHint)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .font(.system(size: 17))
            .foregroundStyle(theme.text)
            .tint(theme.accentColor)
            .padding(.horizontal, 16)
            .frame(height: 52)
    }

    private var bioGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup {
                TextField(s.bioLabel, text: $bio, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.text)
                    .tint(theme.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
            }
            HStack {
                Text(s.bioHint)
                Spacer()
                Text("\(bio.count)/70").monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 30)
        }
    }

    private var accountGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.accountSection.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)

            SettingsGroup {
                SettingsRow(icon: "gift.fill", tint: .pink, title: s.birthday,
                            value: s.birthdayText(birthday) ?? s.addBirthday, showsChevron: true) {
                    showBirthday = true
                }
                SettingsDivider()
                SettingsRow(icon: "phone.fill", tint: .green, title: s.phoneLabel,
                            value: flow.displayPhone, showsChevron: true) { path.append(.phone) }
                SettingsDivider()
                SettingsRow(icon: "at", tint: .blue, title: s.usernameLabel,
                            value: usernameText, showsChevron: true) { path.append(.username) }
            }
        }
    }

    // MARK: Сохранение

    private func fillDraft() {
        guard !draftLoaded else { return }
        guard let profile else {
            // профиль ещё не загрузился — подставим хотя бы имя из аккаунта
            if first.isEmpty { first = flow.userName }
            return
        }
        draftLoaded = true
        first = profile.firstName
        last = profile.lastName
        bio = profile.bio
        birthday = profile.birthday
        photos = profile.avatars
    }

    private func save() {
        guard changed else { dismiss(); return }
        guard valid else { return }
        saving = true
        errorText = nil

        var patch = ProfilePatch()
        if firstClean != profile?.firstName { patch.name = firstClean }
        if lastClean != profile?.lastName { patch.lastName = lastClean }
        if bio.trimmingCharacters(in: .whitespacesAndNewlines) != profile?.bio {
            patch.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if birthday != profile?.birthday { patch.birthday = birthday ?? "" }

        Task { @MainActor in
            defer { saving = false }
            if let error = await store.update(patch) {
                errorText = s.api(error)
                return
            }
            if patch.name != nil || patch.lastName != nil {
                _ = await flow.saveName(store.profile?.name ?? displayName)     // и в локальной базе
            }
            dismiss()
        }
    }
}

// MARK: - Перетаскивание фотографий

struct PhotoDropDelegate: DropDelegate {
    let item: AvatarPhoto
    @Binding var photos: [AvatarPhoto]
    @Binding var dragging: AvatarPhoto?
    let onFinish: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = photos.firstIndex(of: dragging),
              let to = photos.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            photos.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        onFinish()
        return true
    }
}

// MARK: - Имя пользователя

struct UsernameEditScreen: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        ScrollView {
            EditFieldScreen(kind: .username, store: store, back: { dismiss() })
                .padding(.top, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { SpaceBackground(isDark: theme.dark, showStars: false) }
        .navigationTitle(Strings(lang: lang).usernameLabel)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - День рождения

struct BirthdaySheet: View {
    @Binding var value: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var day = 1
    @State private var month = 1
    @State private var year = 2000          // 0 — без года

    private var s: Strings { Strings(lang: lang) }
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    private var daysInMonth: Int {
        switch month {
        case 2:
            let leap = year == 0 || (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private var monthNames: [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: lang.rawValue)
        return f.standaloneMonthSymbols
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(s.removeDate) { value = nil; dismiss() }
                    .foregroundStyle(theme.danger)
                    .opacity(value == nil ? 0 : 1)
                Spacer()
                Text(s.birthday).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.done) { apply() }.fontWeight(.semibold)
            }
            .font(.system(size: 16))
            .padding(.horizontal, 20)
            .padding(.top, 20)

            HStack(spacing: 0) {
                Picker("", selection: $day) {
                    ForEach(1...daysInMonth, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("", selection: $month) {
                    ForEach(1...12, id: \.self) { Text(monthNames[$0 - 1]).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("", selection: $year) {
                    Text(s.withoutYear).tag(0)
                    ForEach((1920...currentYear).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .frame(height: 200)
            .clipped()
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .onAppear(perform: load)
        .onChange(of: month) { _, _ in day = min(day, daysInMonth) }
        .onChange(of: year) { _, _ in day = min(day, daysInMonth) }
    }

    private func load() {
        guard let value else { return }
        let parts = value.components(separatedBy: "-")
        if value.hasPrefix("--"), parts.count == 4 {
            year = 0
            month = Int(parts[2]) ?? 1
            day = Int(parts[3]) ?? 1
        } else if parts.count == 3 {
            year = Int(parts[0]) ?? 2000
            month = Int(parts[1]) ?? 1
            day = Int(parts[2]) ?? 1
        }
    }

    private func apply() {
        day = min(day, daysInMonth)
        value = year == 0
            ? String(format: "--%02d-%02d", month, day)
            : String(format: "%04d-%02d-%02d", year, month, day)
        dismiss()
    }
}

// MARK: - Смена номера телефона

struct ChangePhoneScreen: View {
    @ObservedObject var store: ProfileStore

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var number = ""
    @State private var code = ""
    @State private var mailCode = ""
    @State private var password = ""
    @State private var codeSent = false
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let message = flow.inbox {
                    InboxBanner(message: message)
                        .onTapGesture { flow.inbox = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if !codeSent {
                    TextField("+7 981 799-02-69", text: $number)
                        .keyboardType(.phonePad)
                        .focused($focused)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.text)
                        .tint(theme.accentColor)
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .card(theme, radius: 16)
                        .padding(.horizontal, 16)

                    Text(s.phoneChangeHint)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 30)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if flow.twoFAEnabled {
                        InputField(placeholder: s.t("Пароль двухфакторной защиты", "Two-step password"),
                                   text: $password, icon: "lock.shield", secure: true)
                        if let hint = flow.twoFAHint {
                            Label(s.t("Подсказка: ", "Hint: ") + hint, systemImage: "lightbulb")
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 30).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let mail = flow.linkedEmail {
                        Text(s.t("Для подтверждения мы отправим код на вашу почту \(mail).",
                                 "We will also email a confirmation code to \(mail)."))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 30).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ErrorText(error: flow.error)

                    PrimaryButton(title: s.getCode,
                                  enabled: number.filter(\.isNumber).count >= 7 && (!flow.twoFAEnabled || !password.isEmpty),
                                  loading: flow.isLoading) {
                        focused = false
                        Task { @MainActor in
                            if await flow.requestPhoneChange(number, password: password) {
                                withAnimation { codeSent = true }
                            }
                        }
                    }
                } else {
                    Text(s.codeSentTo(flow.changeTicket?.target ?? ""))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 30)
                        .multilineTextAlignment(.center)

                    TextField(s.codeFromSMS, text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 26, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.text)
                        .tint(theme.accentColor)
                        .frame(height: 60)
                        .card(theme, radius: 16)
                        .padding(.horizontal, 16)

                    if flow.linkedEmail != nil {
                        Text(s.t("Код из письма на \(flow.linkedEmail ?? "")", "Code from the email to \(flow.linkedEmail ?? "")"))
                            .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        TextField(s.t("Код из письма", "Email code"), text: $mailCode)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 26, weight: .medium).monospacedDigit())
                            .foregroundStyle(theme.text)
                            .tint(theme.accentColor)
                            .frame(height: 60)
                            .card(theme, radius: 16)
                            .padding(.horizontal, 16)
                    }

                    ErrorText(error: flow.error)

                    PrimaryButton(title: s.confirm,
                                  enabled: code.count >= 5 && (flow.linkedEmail == nil || mailCode.count >= 5),
                                  loading: flow.isLoading) {
                        focused = false
                        Task { @MainActor in
                            if let newNumber = await flow.confirmPhoneChange(code, emailCode: mailCode) {
                                _ = await store.update(ProfilePatch(phone: newNumber))
                                dismiss()
                            }
                        }
                    }

                    TextActionButton(title: s.phoneChangeTitle) {
                        flow.cancelPhoneChange()
                        code = ""; mailCode = ""
                        withAnimation { codeSent = false }
                    }
                }
            }
            .padding(.top, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { SpaceBackground(isDark: theme.dark, showStars: false) }
        .navigationTitle(s.phoneChangeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await flow.refreshTwoFAHint() }
        .onAppear {
            flow.cancelPhoneChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
        .onDisappear { flow.cancelPhoneChange() }
        .animation(.easeOut(duration: 0.2), value: flow.error)
    }
}

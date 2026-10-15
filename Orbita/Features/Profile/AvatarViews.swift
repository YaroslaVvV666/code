import SwiftUI
import PhotosUI

/// Круглая кнопка «+» у аватарки: добавить фото (или первое)
struct AddPhotoBadge: View {
    @ObservedObject var store: ProfileStore
    var size: CGFloat = 30

    @Environment(\.theme) private var theme
    @State private var item: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?
    @Environment(\.lang) private var lang

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            ZStack {
                Circle().fill(theme.accent)
                if busy {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: size, height: size)
            .overlay(Circle().stroke(theme.sheet, lineWidth: 3))
        }
        .disabled(busy)
        .alert(errorText ?? "", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task { @MainActor in
                busy = true
                if let data = try? await new.loadTransferable(type: Data.self) {
                    if let error = await store.addPhoto(from: data) { errorText = Strings(lang: lang).api(error) }
                }
                busy = false
                item = nil
            }
        }
    }
}

// MARK: - Аватарка в шапке: как в Telegram показывается текущая, остальные — в просмотрщике

struct AvatarPager: View {
    let name: String
    let photos: [AvatarPhoto]
    var size: CGFloat = 112
    @Binding var index: Int                 // оставлен для совместимости, всегда показываем главную
    var addStore: ProfileStore? = nil       // если задан — рядом с аватаркой кнопка «+»
    var onTap: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let first = photos.first {
                RemoteImage(id: first.mediaID)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .onTapGesture(perform: onTap)
            } else {
                AvatarView(name: name, size: size).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            // «+» нужен только пока фото ещё нет; счётчик фотографий убран
            if let addStore, photos.isEmpty {
                AddPhotoBadge(store: addStore, size: max(26, size * 0.3)).offset(x: 4, y: 4)
            }
        }
    }
}

// MARK: - Просмотр на весь экран (как в Telegram): полоски сверху, счётчик, лента миниатюр

struct AvatarViewerRoute: Identifiable {
    let id = UUID()
    let index: Int
}

struct AvatarViewer: View {
    let name: String
    var onReorder: (([String]) -> Void)? = nil      // задано — это мои фото: можно сделать основным / удалить / переставить
    var onDelete: ((String) -> Void)? = nil
    var onClose: (() -> Void)? = nil               // если показан не через fullScreenCover, а поверх экрана

    @State private var photos: [AvatarPhoto]
    @State private var currentID: String?
    @State private var confirmDelete = false
    @State private var showOrder = false
    @State private var shareItems: ShareItems?
    @State private var sharing = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    init(name: String, photos: [AvatarPhoto], start: Int,
         onReorder: (([String]) -> Void)? = nil, onDelete: ((String) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.name = name
        self.onClose = onClose
        self.onReorder = onReorder
        self.onDelete = onDelete
        _photos = State(initialValue: photos)
        _currentID = State(initialValue: photos.indices.contains(start) ? photos[start].id : photos.first?.id)
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    private var s: Strings { Strings(lang: lang) }
    private var index: Int { photos.firstIndex { $0.id == currentID } ?? 0 }
    private var isEditable: Bool { onReorder != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if photos.isEmpty {
                AvatarView(name: name, size: 200).clipShape(Circle())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(photos) { photo in
                            RemoteImage(id: photo.mediaID, fill: false)
                                .containerRelativeFrame(.horizontal)
                                .id(photo.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                topBar
                if photos.count > 1 {
                    Text(s.photoCounter(index + 1, photos.count))
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .glassCapsule()
                }
                Spacer()
                bottomBar
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(s.deletePhotoQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.deletePhoto, role: .destructive) { deleteCurrent() }
            Button(s.cancel, role: .cancel) {}
        }
        .sheet(isPresented: $showOrder) {
            PhotoReorderSheet(photos: photos) { ordered in
                photos = ordered
                currentID = ordered.first?.id
                onReorder?(ordered.map(\.id))
            }
            .environment(\.theme, theme)
            .presentationDetents([.large])
        }
        .sheet(item: $shareItems) { item in
            ActivitySheet(items: item.items).presentationDetents([.medium, .large])
        }
    }

    // Сверху: назад | имя и дата по центру | «Изм.»
    private var topBar: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zIndex(10)

            Spacer(minLength: 8)

            VStack(spacing: 1) {
                Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
                if photos.indices.contains(index) {
                    Text(s.photoDate(photos[index].createdAt))
                        .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            .glassCapsule()

            Spacer(minLength: 8)

            if isEditable, !photos.isEmpty {
                Menu {
                    if index != 0 {
                        Button { makeMain() } label: { Label(s.makeMain, systemImage: "star") }
                    }
                    if photos.count > 1 {
                        Button { showOrder = true } label: { Label(s.t("Изменить порядок", "Reorder"), systemImage: "arrow.up.arrow.down") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(s.deletePhoto, systemImage: "trash")
                    }
                } label: {
                    Text(s.t("Изм.", "Edit"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .glassCapsule()
                }
            } else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 14)
    }

    // Снизу: «поделиться» слева, лента миниатюр по центру, корзина справа
    private var bottomBar: some View {
        VStack(spacing: 12) {
            if photos.count > 1 { thumbnails }
            HStack {
                Button(action: share) {
                    Group {
                        if sharing { ProgressView().tint(.white) } else {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.white)
                    .frame(width: 46, height: 46)
                    .glassCircle()
                }
                .buttonStyle(.plain)
                .disabled(photos.isEmpty || sharing)

                Spacer()

                if isEditable, !photos.isEmpty {
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(width: 46, height: 46)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func share() {
        guard photos.indices.contains(index), !sharing else { return }
        sharing = true
        let id = photos[index].mediaID
        Task {
            defer { sharing = false }
            if let url = await FileDownloader.download(mediaID: id, name: "avatar.jpg") {
                shareItems = ShareItems(items: [url])
            }
        }
    }

    // Лента миниатюр: быстро перейти к любому из многих фото
    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(photos) { photo in
                        let selected = photo.id == currentID
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { currentID = photo.id }
                        } label: {
                            RemoteImage(id: photo.mediaID)
                                .frame(width: selected ? 52 : 44, height: selected ? 52 : 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white, lineWidth: selected ? 2 : 0))
                                .opacity(selected ? 1 : 0.65)
                        }
                        .buttonStyle(.plain)
                        .id("t-" + photo.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 56)
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("t-" + id, anchor: .center) }
            }
            .onAppear {
                if let id = currentID { proxy.scrollTo("t-" + id, anchor: .center) }
            }
        }
    }

    private func makeMain() {
        guard photos.indices.contains(index), index != 0 else { return }
        let photo = photos[index]
        withAnimation {
            photos.remove(at: index)
            photos.insert(photo, at: 0)
            currentID = photo.id
        }
        onReorder?(photos.map(\.id))
    }

    private func deleteCurrent() {
        guard photos.indices.contains(index) else { return }
        let removed = photos[index]
        let next = photos.indices.contains(index + 1) ? photos[index + 1].id : (index > 0 ? photos[index - 1].id : nil)
        withAnimation {
            photos.removeAll { $0.id == removed.id }
            currentID = next
        }
        onDelete?(removed.id)
        if photos.isEmpty { close() }
    }
}

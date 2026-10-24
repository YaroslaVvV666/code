import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

// MARK: - Матрица QR-кода

enum QRMatrix {
    /// Квадратная матрица модулей (true — тёмный). Тихую зону рисует тот, кто показывает код.
    static func make(_ text: String) -> [[Bool]] {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return [] }

        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[y * w + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return [] }
        let side = min(maxX - minX, maxY - minY) + 1
        return (0..<side).map { row in
            (0..<side).map { col in pixels[(minY + row) * w + (minX + col)] < 128 }
        }
    }
}

/// QR с округлыми модулями. Тёмный на светлом: рисуйте на белой плашке.
struct QRCodeView: View {
    let text: String
    var colors: [Color] = [Color(red: 0.07, green: 0.13, blue: 0.55), Color(red: 0.36, green: 0.10, blue: 0.55)]
    var clearRadius: CGFloat = 0            // доля стороны: круг в центре без модулей (под логотип)
    private let matrix: [[Bool]]

    init(text: String, colors: [Color]? = nil, clearRadius: CGFloat = 0) {
        self.text = text
        self.matrix = QRMatrix.make(text)
        if let colors { self.colors = colors }
        self.clearRadius = clearRadius
    }

    var body: some View {
        Canvas { context, size in
            let n = matrix.count
            guard n > 0 else { return }
            let m = min(size.width, size.height) / CGFloat(n)

            func isFinder(_ x: Int, _ y: Int) -> Bool {
                (x < 7 && y < 7) || (x >= n - 7 && y < 7) || (x < 7 && y >= n - 7)
            }

            var path = Path()
            for y in 0..<n {
                for x in 0..<n where matrix[y][x] && !isFinder(x, y) {
                    if clearRadius > 0,
                       hypot(CGFloat(x) + 0.5 - CGFloat(n) / 2, CGFloat(y) + 0.5 - CGFloat(n) / 2) < clearRadius * CGFloat(n) { continue }
                    let rect = CGRect(x: CGFloat(x) * m + m * 0.04, y: CGFloat(y) * m + m * 0.04,
                                      width: m * 0.92, height: m * 0.92)
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: m * 0.32, height: m * 0.32))
                }
            }
            // три «глаза» — кольцо и точка внутри
            for (fx, fy) in [(0, 0), (n - 7, 0), (0, n - 7)] {
                let ox = CGFloat(fx) * m, oy = CGFloat(fy) * m
                path.addRoundedRect(in: CGRect(x: ox, y: oy, width: 7 * m, height: 7 * m),
                                    cornerSize: CGSize(width: 2 * m, height: 2 * m))
                path.addRoundedRect(in: CGRect(x: ox + m, y: oy + m, width: 5 * m, height: 5 * m),
                                    cornerSize: CGSize(width: 1.4 * m, height: 1.4 * m))
                path.addRoundedRect(in: CGRect(x: ox + 2 * m, y: oy + 2 * m, width: 3 * m, height: 3 * m),
                                    cornerSize: CGSize(width: m, height: m))
            }

            let gradient = Gradient(colors: colors)
            context.fill(path,
                         with: .linearGradient(gradient, startPoint: .zero,
                                               endPoint: CGPoint(x: size.width, y: size.height)),
                         style: FillStyle(eoFill: true))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Мой QR (поделиться профилем): только код

struct ProfileQRSheet: View {
    let link: String
    @Environment(\.theme) private var theme

    var body: some View {
        QRCodeView(text: link)
            .padding(24)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            .shadow(color: Color.black.opacity(theme.dark ? 0.4 : 0.12), radius: 24, y: 8)
            .padding(.horizontal, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
    }
}

// MARK: - Сканер

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.onDenied = onDenied
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "orbita.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var locked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else { self?.onDenied?() }
                }
            }
        default:
            onDenied?()
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { onDenied?(); return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        queue.async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !locked,
              let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        locked = true
        Haptics.notify(.success)
        onCode?(code)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.locked = false }
    }
}

struct QRScannerScreen: View {
    /// Вызывается, когда вход подтверждён и экран можно закрывать
    var onApproved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var denied = false
    @State private var link: DeepLink?
    @State private var notice: String?

    private var s: Strings { Strings(lang: lang) }
    private let frameSize: CGFloat = 250

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            QRScannerView(onCode: handle, onDenied: { denied = true })
                .ignoresSafeArea()

            // затемнение с «окном» под код
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .mask(
                    ZStack {
                        Rectangle()
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .frame(width: frameSize, height: frameSize)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                .frame(width: frameSize, height: frameSize)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 42, height: 42)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                Text(notice ?? s.scanHint)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .glassCapsule()
                    .padding(.bottom, 54)
                    .animation(.easeOut(duration: 0.2), value: notice)
            }

            if denied {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.system(size: 30)).foregroundStyle(Color.white.opacity(0.8))
                    Text(s.cameraDenied)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                    Button(s.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .glassCapsule(interactive: true)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $link) { item in
            LinkSheet(link: item) {
                link = nil
                onApproved()
                dismiss()
            }
            .preferredColorScheme(theme.dark ? .dark : .light)
        }
    }

    private func handle(_ code: String) {
        guard link == nil else { return }
        if let parsed = DeepLink(string: code) {
            link = parsed
        } else {
            notice = s.notOrbitaCode
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                notice = nil
            }
        }
    }
}

// MARK: - Что делать со ссылкой Orbita

struct LinkSheet: View {
    let link: DeepLink
    var onFinished: () -> Void = {}

    var body: some View {
        switch link {
        case .login(let id):
            LoginApprovalSheet(qrID: id, onFinished: onFinished)
        case .username(let name):
            PublicProfileSheet(source: .username(name))
        case .userID(let id):
            PublicProfileSheet(source: .id(id))
        case .server(let address):
            ServerLinkSheet(address: address)
        case .post(let id):
            PostLinkSheet(postID: id)
        case .group(let code):
            GroupLinkSheet(code: code)
        case .phone(let number):
            PhoneLookupSheet(phone: number)
        }
    }
}

/// QR-код из терминала: подключает приложение к серверу на Маке
struct ServerLinkSheet: View {
    let address: String
    @EnvironmentObject private var router: LinkRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.accentColor)
                .padding(.top, 34)
            Text(address).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            PrimaryButton(title: Strings(lang: lang).connectServer) {
                router.applyServer(address)
                dismiss()
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(260)])
    }
}

// MARK: - Подтверждение входа другого устройства

struct LoginApprovalSheet: View {
    let qrID: String
    var onFinished: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private enum Phase { case loading, ready, working, done, failed(String) }
    @State private var info: LoginRequestInfo?
    @State private var phase: Phase = .loading

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.accentColor)
                .frame(width: 76, height: 76)
                .glassCircle(interactive: false)
                .padding(.top, 30)

            switch phase {
            case .loading:
                ProgressView().padding(.top, 20)

            case .ready, .working:
                if let info {
                    VStack(spacing: 6) {
                        Text(s.loginRequestTitle)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(s.loginRequestBody(info.device))
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.device).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        Text([info.app, info.system].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        if !info.ip.isEmpty {
                            Text("IP \(info.ip)").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .card(theme, radius: 18)
                    .padding(.horizontal, 20)

                    Text(s.loginWarning)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    PrimaryButton(title: s.approveLogin, enabled: true, loading: isWorking, action: approve)
                    TextActionButton(title: s.cancel) { dismiss() }
                }

            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.green)
                Text(s.deviceConnected)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.text)

            case .failed(let message):
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                TextActionButton(title: s.close) { dismiss() }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private var isWorking: Bool { if case .working = phase { return true }; return false }
    private var icon: String { deviceSymbol(info?.device ?? "") }

    private func load() async {
        do {
            info = try await session.profileRepo.loginRequest(qrID: qrID)
            phase = .ready
        } catch {
            phase = .failed(s.api((error as? APIError) ?? .offline))
        }
    }

    private func approve() {
        phase = .working
        Task { @MainActor in
            do {
                try await session.profileRepo.approveLogin(qrID: qrID, phone: flow.e164)
                phase = .done
                Haptics.notify(.success)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onFinished()
                dismiss()
            } catch {
                phase = .failed(s.api((error as? APIError) ?? .offline))
            }
        }
    }
}

func deviceSymbol(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("ipad") { return "ipad" }
    if lower.contains("iphone") { return "iphone" }
    if lower.contains("mac") { return "laptopcomputer" }
    return "desktopcomputer"
}

// MARK: - Вход по QR на новом устройстве (экран регистрации)

struct QRSheet: View {
    let strings: Strings

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var link: String?
    @State private var errorText: String?
    @State private var qrSession: QRLoginSession?
    @State private var askPassword = false
    @State private var hint = ""
    @State private var password = ""
    @State private var busy = false
    @State private var runID = 0

    var body: some View {
        VStack(spacing: 20) {
            Text(strings.qrTitle)
                .font(.title2.bold())
                .foregroundStyle(theme.text)
                .padding(.top, 28)

            if askPassword {
                passwordBlock
            } else {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.white)
                if let link {
                    QRCodeView(text: link).padding(22).transition(.opacity)
                } else {
                    ProgressView().tint(Color.gray)
                }
            }
            .frame(width: 252, height: 252)
            .animation(.easeInOut(duration: 0.25), value: link)

            VStack(alignment: .leading, spacing: 12) {
                step(1, strings.qrStep1)
                step(2, strings.qrStep2)
                step(3, strings.qrStep3)
            }
            .padding(.horizontal, 30)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: runID) { await run() }
    }

    /// QR подтверждён, в аккаунте есть облачный пароль: без него сервер сеанс не выдаёт
    private var passwordBlock: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.accentColor)
                .padding(.top, 8)
            Text(strings.qrPasswordSub)
                .font(.system(size: 15))
                .foregroundStyle(theme.text.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            InputField(placeholder: strings.password, text: $password, icon: "key", secure: true)

            if !hint.isEmpty {
                Label(strings.t("Подсказка: ", "Hint: ") + hint, systemImage: "lightbulb")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).frame(maxWidth: .infinity, alignment: .leading)
            }

            ErrorText(error: flow.error)

            PrimaryButton(title: strings.signIn, enabled: !password.isEmpty, loading: busy) {
                Task { await submitPassword() }
            }
            .padding(.top, 4)
        }
        .onChange(of: password) { _, _ in if flow.error != nil { flow.error = nil } }
    }

    private func submitPassword() async {
        guard let session = qrSession else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await QRLoginClient.submitPassword(session, password: password)
            await flow.finishQRLogin(result)
            dismiss()
        } catch let error as AuthError {
            Haptics.notify(.error)
            password = ""
            if error == .codeExpired {
                // QR успел устареть: показываем новый
                askPassword = false
                flow.error = nil
                runID += 1
            } else {
                flow.error = error
            }
        } catch {
            flow.error = .unknown
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentColor)
                .frame(width: 26, height: 26)
                .background(theme.accentColor.opacity(0.14), in: Circle())
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
        }
    }

    /// Показываем код и ждём подтверждения; устаревший код заменяем новым
    private func run() async {
        while !Task.isCancelled {
            do {
                let session = try await QRLoginClient.start()
                qrSession = session
                link = session.link
                errorText = nil
                let deadline = Date().addingTimeInterval(session.expiresIn)
                poll: while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    switch try await QRLoginClient.poll(session) {
                    case .approved(let result):
                        await flow.finishQRLogin(result)
                        dismiss()
                        return
                    case .expired:
                        break poll
                    case .needsPassword(let h):
                        hint = h
                        password = ""
                        flow.error = nil
                        askPassword = true
                        return
                    case .pending:
                        continue poll
                    }
                }
                link = nil
            } catch is CancellationError {
                return
            } catch {
                link = nil
                errorText = strings.api((error as? APIError) ?? .offline)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
}

// MARK: - Чужой профиль (по ссылке или QR)

struct PublicProfileSheet: View {
    enum Source { case username(String), id(String) }
    let source: Source
    /// Если задано — профиль лежит не в окне, а внутри другого экрана (шторка из шортсов), и закрывается этим действием
    var onClose: (() -> Void)? = nil
    /// Кнопка «назад» слева сверху вместо крестика справа (профиль друга из пузыря)
    var backButton = true            // везде стрелка «назад» слева сверху и выход свайпом, без крестика

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private func close() { if let onClose { onClose() } else { dismiss() } }

    var body: some View {
        let page: UserPageModel.Source = {
            switch source {
            case .username(let name): return .username(name)
            case .id(let id):         return id.lowercased() == session.serverID ? .me : .id(id)
            }
        }()
        ZStack(alignment: backButton ? .topLeading : .topTrailing) {
            ScrollView(showsIndicators: false) {
                UserPageView(source: page, session: session)
                    .padding(.top, TopInset.value)
            }
            .coordinateSpace(name: "pageScroll")
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(edges: .top)              // цвет профиля доходит до самого верха, без тёмной полосы
            .environment(\.pageTopInset, TopInset.value)

            Button { close() } label: {
                Image(systemName: backButton ? "chevron.left" : "xmark")
                    .font(.system(size: backButton ? 16 : 13, weight: .bold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .glassCircle()
                    .frame(width: 52, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(backButton ? 8 : 6)
            .padding(.top, backButton ? 22 : 0)          // кнопка «назад» ниже, подальше от статус-бара
            .zIndex(10)
        }
        .edgeSwipeBack(enabled: onClose == nil) { dismiss() }
    }
}

// MARK: - Пост по ссылке (orbita://post/… или http://сервер/p/…)

struct PostLinkSheet: View {
    let postID: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var post: Post?
    @State private var failed = false
    @State private var commentsPost: Post?
    @State private var openedAuthor: AuthorRoute?

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let post, post.media.first?.kind == .video {
                // видео-пост открывается в шортсах: лента начинается с этого ролика (как в TikTok)
                ReelsView(onOpenAuthor: { openedAuthor = AuthorRoute(id: $0.id) }, suspended: openedAuthor != nil, pinned: post)
                    .ignoresSafeArea()
            } else {
            ScrollView {
                if let post {
                    PostCard(post: post, autoplay: false,
                             onLike: toggleLike,
                             onComments: { commentsPost = post },
                             onDelete: { delete(post) },
                             onOpenAuthor: { openedAuthor = AuthorRoute(id: $0.id) })
                        .padding(.top, 44)
                } else if failed {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.questionmark").font(.system(size: 32, weight: .light))
                            .foregroundStyle(theme.textSecondary)
                        Text(s.postUnavailable).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                        Text(s.postUnavailableHint).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40).padding(.top, 120)
                    .frame(maxWidth: .infinity)
                } else {
                    ProgressView().padding(.top, 120).frame(maxWidth: .infinity)
                }
            }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.text)
                    .frame(width: 34, height: 34)
                    .glassCircle()
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .zIndex(10)
        }
        .task {
            do { post = try await session.feedRepo.post(id: postID) } catch { failed = true }
        }
        .sheet(item: $commentsPost, onDismiss: { Task { post = try? await session.feedRepo.post(id: postID) } }) { p in
            CommentsSheet(post: p, vm: session.feed)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .fullScreenCover(item: $openedAuthor) { route in
            PublicProfileSheet(source: .id(route.id))
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func toggleLike() {
        guard var p = post else { return }
        p.likedByMe.toggle()
        p.likes += p.likedByMe ? 1 : -1
        post = p
        let liked = p.likedByMe, id = p.id
        Task { try? await session.feedRepo.setLike(postID: id, liked: liked) }
    }

    private func delete(_ p: Post) {
        Task {
            try? await session.feedRepo.deletePost(id: p.id)
            session.feed.forget(p.id)
            dismiss()
        }
    }
}

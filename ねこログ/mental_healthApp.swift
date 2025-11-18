import SwiftUI
import UserNotifications
import Combine

// MARK: - KeyboardResponder (iOS14〜16対応)
final class KeyboardResponder: ObservableObject {
    @Published var currentHeight: CGFloat = 0
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        let willShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect }
            .map { $0.height }
        
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }
        
        willShow
            .merge(with: willHide)
            .sink { [weak self] height in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self?.currentHeight = height
                    }
                }
            }
            .store(in: &cancellables)
    }
}


// MARK: - App
@main
struct MentalHealthApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var userInfo = UserInfo()   // ← ここで作成
    @State private var processedImage: UIImage? = nil
    @State private var isUserInfoEntered = false
    @State private var showHealingMode = false
    @StateObject private var langManager = LanguageManager()
    @State private var aiInput = ""
    @State private var aiReply = ""
    @State private var isThinking = false
    @State private var animateDots = false
    @State private var isInputVisible = true

    @State private var appLocale: Locale = Locale(identifier: "ja") // 初期は既存の言語に合わせてもOK
    @StateObject private var keyboard = KeyboardResponder()
    
    @State private var debugLog: String = ""
    
    private let characterSetting = """
    ユーザーが入力した言語で返答してください。
    ただしキャラ設定は維持してください。
    小学生低学年レベルの返答。45文字以内。
    難しい話は『猫に聞かれてもわからんにゃ』と返す。
    語尾は必ず「にゃ」をつける。
    必ず応援する返答にする。
    """
    
    init() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if granted { print("通知許可 OK") }
            else if let error = error { print("通知エラー: \(error)") }
        }

        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "isFirstLaunch")
        appState.isFirstLaunch = true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group { // ← ここで全体をラップ
                if appState.isFirstLaunch {
                    FirstLaunchView()
                        .environmentObject(appState)
                        .environmentObject(subscriptionManager)
                        .environmentObject(userInfo)
                        .environmentObject(langManager)
                } else if !isUserInfoEntered {
                    UserInfoView(processedImage: $processedImage, isPresented: $isUserInfoEntered)
                        .environmentObject(userInfo)
                        .environmentObject(langManager)
                } else {
                    ZStack {
                        ContentView(
                            showHealingMode: $showHealingMode,
                            characterSetting: characterSetting
                        )
                        .edgesIgnoringSafeArea(.all)
                        
                        if showHealingMode {
                            healingModeOverlay
                        }
                    }
                    .onAppear {
                        scheduleMidnightReset()
                    }
                    .environmentObject(appState)
                    .environmentObject(subscriptionManager)
                    .environmentObject(userInfo)
                    .environmentObject(langManager)
                }
            }
            .id(langManager.current) // ← これで全体が言語変更時に再構築
        }
        .environment(\.locale, Locale(identifier: langManager.current.rawValue))
    }

    // MARK: - 毎日0時にAI返信リセット
    private func scheduleMidnightReset() {
        let calendar = Calendar.current
        let now = Date()
        guard let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour:0, minute:0, second:0),
            matchingPolicy: .nextTime
        ) else { return }
        
        let interval = nextMidnight.timeIntervalSince(now)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            aiReply = ""
            isInputVisible = true
            scheduleMidnightReset()
        }
    }
    
    // MARK: - 癒しモードオーバーレイ
    @ViewBuilder
    private var healingModeOverlay: some View {
        VStack {
            Spacer()
            
            // AIの返答表示
            if !aiReply.isEmpty {
                Text(aiReply)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(UIColor.systemBackground).opacity(0.9))
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
            
            // 入力欄
            if isInputVisible {
                VStack(spacing: 8) {
                    TextField("AIに質問...", text: $aiInput)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .disableAutocorrection(true)
                    
                    HStack {
                        Spacer()
                        Button {
                            startAIFlowSafe() // ← 安全版の呼び出し
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            aiInput = ""
                            withAnimation { isInputVisible = false }
                        } label: {
                            Text(langManager.localized("send"))

                                .bold()
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background((aiInput.isEmpty || isThinking) ? Color.gray.opacity(0.4) : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(aiInput.isEmpty || isThinking)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 12)
                .background(BlurView())
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            // デバッグログ
            ScrollView {
                Text(debugLog)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(height: 150)
            .background(Color(UIColor.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        
        // 送信中オーバーレイ
        if isThinking {
            Color.black.opacity(0.25)
                .edgesIgnoringSafeArea(.all)
            Text("・・・")
                .font(.system(size: 64, weight: .bold))
                .foregroundColor(.white)
                .opacity(animateDots ? 1.0 : 0.25)
                .scaleEffect(animateDots ? 1.05 : 0.95)
                .onAppear { animateDots = true }
                .onDisappear { animateDots = false }
                .animation(
                    Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: animateDots
                )
        }
    }

    // MARK: - 安全版 startAIFlow
    func startAIFlowSafe() {
        guard !aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isThinking else { return }

        isThinking = true
        animateDots = true
        aiReply = ""

        Task {
            await appendLog("startAIFlowSafe: ユーザー入力 -> \(aiInput)")

            try? await Task.sleep(nanoseconds: 200_000_000)

            // fetchAIReply が内部で aiReply を更新する場合
            await fetchAIReply(for: aiInput)

            // メインスレッドでフラグだけ更新
            await MainActor.run {
                isThinking = false
                animateDots = false
            }
        }
    }


    
    @MainActor
    private func fetchAIReply(for prompt: String) async {
        await appendLog("fetchAIReply: 送信するプロンプト -> \(prompt)")
        let fullPrompt = "\(characterSetting)\nユーザー: \(prompt)"

        #if DEBUG
        let baseURL = "http://localhost:8787"
        #else
        let baseURL = "https://my-worker.app-lab-nanato.workers.dev"
        #endif

        guard let url = URL(string: baseURL) else {
            updateReplyOnMain("URLが無効にゃ")
            return
        }


        let body: [String: Any] = ["prompt": fullPrompt]
        let data = try? JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        var success = false

        for _ in 1...3 {
            if let (responseData, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let reply = json["reply"] as? String {
                updateReplyOnMain(reply)
                success = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if !success {
            updateReplyOnMain(langManager.localized("server_unreachable"))
        }


    }


    @MainActor
    private func updateReplyOnMain(_ reply: String) {
        aiReply = reply
        isThinking = false
        animateDots = false
    }
    
    @MainActor
    private func appendLog(_ message: String) async {
        debugLog += message + "\n"
    }
    
    // MARK: - BlurView
    fileprivate struct BlurView: UIViewRepresentable {
        func makeUIView(context: Context) -> UIVisualEffectView {
            UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        }
        func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
    }
}

// MARK: - 初回起動ビュー
struct FirstLaunchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var langManager: LanguageManager
    @EnvironmentObject var userInfo: UserInfo

    // ✅ 一時選択用
    @State private var tempLang: AppLanguage = .japanese

    // ✅ fullScreenCover 用のフラグ
    @State private var showTerms = false

    var body: some View {
        VStack(spacing: 30) {

            // ✅ 確定前の言語で表示
            Text(langManager.localized("select_language_prompt"))
                .font(.headline)

            // ✅ Picker は tempLang のみに変更（確定前）
            Picker("言語 / Language", selection: $tempLang) {
                Text(langManager.localized("japanese")).tag(AppLanguage.japanese)
                Text(langManager.localized("english")).tag(AppLanguage.english)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()

            // ✅ ボタンで TermsView を fullScreenCover 表示
            Button(langManager.localized("read_terms")) {
                showTerms = true
            }
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .cornerRadius(8)

            Spacer()
        }
        .padding()
        .fullScreenCover(isPresented: $showTerms) {
            TermsView_v2(pendingLang: tempLang)
                .environmentObject(appState)
                .environmentObject(subscriptionManager)
                .environmentObject(userInfo)
                .environmentObject(langManager)
        }
        .onAppear {
            // ✅ 既存言語を初期値として設定
            tempLang = langManager.current
            print("[DEBUG] FirstLaunchView temp =", tempLang.rawValue)
        }
        .navigationTitle(langManager.localized("initial_setup"))
    }
}

// MARK: - 利用規約表示（改名）
struct TermsView_v2: View {
    @EnvironmentObject var langManager: LanguageManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var userInfo: UserInfo
    @Environment(\.presentationMode) var presentationMode

    // ✅ 追加：確定待ちの言語（パターンA）
    let pendingLang: AppLanguage

    var body: some View {
        VStack {
            ScrollView {
                // ✅ ここは確定前なので現在の langManager.current を使う
                Text(langManager.current == .japanese ? TermsOfServiceText.japanese : TermsOfServiceText.english)
                    .padding()
            }

            Button(action: {
                // ✅ 言語をここで初めて確定する（重要）
                langManager.current = pendingLang
                print("[DEBUG] Language FIXED to =", pendingLang.rawValue)

                // ✅ 初回完了
                appState.markLaunched()
                presentationMode.wrappedValue.dismiss()

                Task {
                    await subscriptionManager.purchase(userInfo: userInfo)
                }

            }) {
                // ボタンテキストは確定前の現在言語で表示
                Text(langManager.current == .japanese ? "同意して開始する" : "Agree and Start")
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
                    .padding()
            }
        }
        .navigationTitle(langManager.current == .japanese ? "利用規約" : "Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }
}

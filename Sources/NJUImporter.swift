import SwiftUI
import WebKit
import Security

private enum NJUCredentialStore {
    private static let service = "local.schedule.widget.nju-login"
    private struct Credential: Codable {
        let username: String
        let password: String
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("课程小部件", isDirectory: true)
    }

    private static var file: URL { folder.appendingPathComponent("nju-login.json") }

    static func load() -> (username: String, password: String)? {
        if let data = try? Data(contentsOf: file),
           let credential = try? JSONDecoder().decode(Credential.self, from: data) {
            return (credential.username, credential.password)
        }
        // 将旧版本存在钥匙串中的记录迁移到本 App 的专用数据文件。
        if let legacy = loadLegacyKeychain() {
            try? save(username: legacy.username, password: legacy.password)
            deleteLegacyKeychain()
            return legacy
        }
        return nil
    }

    static func save(username: String, password: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let data = try JSONEncoder().encode(Credential(username: username, password: password))
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        deleteLegacyKeychain()
    }

    static func delete() {
        try? FileManager.default.removeItem(at: file)
        deleteLegacyKeychain()
    }

    private static func loadLegacyKeychain() -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let username = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (username, password)
    }

    private static func deleteLegacyKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct NJUImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let academicYearStart: Int
    let semesterNumber: Int
    let semesterWeekCount: Int
    let onImport: ([Course]) -> Void

    @State private var status = ""
    @State private var importedCourses: [Course] = []
    @State private var readRequestID: UUID?
    @State private var reloadRequestID: UUID?
    @State private var isReading = false
    @State private var showingCredentialSettings = false
    @State private var credentialFillRequestID: UUID?

    private var termCode: String {
        "\(academicYearStart)-\(academicYearStart + 1)-\(semesterNumber)"
    }

    private var uniqueCourseCount: Int {
        Set(importedCourses.map(\.title)).count
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("南京大学教务课表导入").font(.title3.bold())
                }
                Spacer()
                Button { showingCredentialSettings = true } label: {
                    Label("登录信息", systemImage: "key")
                }
                .disabled(isReading)
                Button("重新加载") { reloadRequestID = UUID() }
                    .disabled(isReading)
                Button {
                    importedCourses = []
                    isReading = true
                    status = "正在准备读取课表…"
                    readRequestID = UUID()
                } label: {
                    if isReading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在读取…")
                        }
                    } else {
                        Text("读取当前课表")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isReading)
                Button("完成") { dismiss() }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(importedCourses.isEmpty ? Color.secondary : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NJUCourseWebView(
                termCode: termCode,
                semesterWeekCount: semesterWeekCount,
                readRequestID: readRequestID,
                reloadRequestID: reloadRequestID,
                credentialFillRequestID: credentialFillRequestID,
                status: $status,
                courses: $importedCourses,
                isReading: $isReading
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.25)))

            if !importedCourses.isEmpty {
                VStack(spacing: 8) {
                    HStack {
                        Text("导入预览").font(.headline)
                        Text("\(uniqueCourseCount) 门课程·\(importedCourses.count) 个上课时段")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("确认导入") {
                            onImport(importedCourses)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(importedCourses) { course in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(course.title).font(.caption.bold()).lineLimit(1)
                                    Text("周\(course.weekday + 1)·第\(course.start)-\(course.end)节·\(course.startWeek ?? 1)-\(course.endWeek ?? semesterWeekCount)周")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                    if !course.room.isEmpty {
                                        Text(course.room).font(.system(size: 10)).lineLimit(1)
                                    }
                                }
                                .padding(8)
                                .frame(width: 190, alignment: .leading)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .frame(height: 92)
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 760)
        .sheet(isPresented: $showingCredentialSettings) {
            NJUCredentialSettingsView {
                credentialFillRequestID = UUID()
            }
        }
    }
}

private struct NJUCredentialSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var passwordIsVisible = false
    @State private var hasSavedCredential = false
    @State private var errorMessage = ""
    let onSaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("南京大学登录信息").font(.title3.bold())
                    Text("账号和密码保存在本 App 的专用数据目录中，不使用钥匙串")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Form {
                TextField("学号 / 工号", text: $username)
                HStack(spacing: 8) {
                    ZStack {
                        SecureField("密码", text: $password)
                            .opacity(passwordIsVisible ? 0 : 1)
                            .allowsHitTesting(!passwordIsVisible)
                        TextField("密码", text: $password)
                            .opacity(passwordIsVisible ? 1 : 0)
                            .allowsHitTesting(passwordIsVisible)
                    }
                    .textFieldStyle(.plain)
                    .frame(height: 22)
                    Button {
                        passwordIsVisible.toggle()
                    } label: {
                        Image(systemName: passwordIsVisible ? "eye" : "eye.slash")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(passwordIsVisible ? "隐藏密码" : "显示密码")
                    .help(passwordIsVisible ? "隐藏密码" : "显示密码")
                }
                .frame(height: 24)
                Text("打开统一认证页面时会自动填充，但不会自动提交登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if hasSavedCredential {
                    Button("清除已保存信息", role: .destructive) {
                        NJUCredentialStore.delete()
                        username = ""
                        password = ""
                        hasSavedCredential = false
                        errorMessage = ""
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并填充") {
                    do {
                        try NJUCredentialStore.save(
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            password: password
                        )
                        onSaved()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470, height: 310)
        .onAppear {
            if let saved = NJUCredentialStore.load() {
                username = saved.username
                password = saved.password
                hasSavedCredential = true
            }
        }
    }
}

struct NJUCourseWebView: NSViewRepresentable {
    let termCode: String
    let semesterWeekCount: Int
    let readRequestID: UUID?
    let reloadRequestID: UUID?
    let credentialFillRequestID: UUID?
    @Binding var status: String
    @Binding var courses: [Course]
    @Binding var isReading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: "njuImport")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let url = URL(string: "https://ehallapp.nju.edu.cn/jwapp/sys/wdkb/*default/index.do#/xskcb") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let reloadRequestID, context.coordinator.lastReloadID != reloadRequestID {
            context.coordinator.lastReloadID = reloadRequestID
            view.reload()
        }
        if let readRequestID, context.coordinator.lastReadID != readRequestID {
            context.coordinator.lastReadID = readRequestID
            context.coordinator.readCourses(from: view)
        }
        if let credentialFillRequestID, context.coordinator.lastCredentialFillID != credentialFillRequestID {
            context.coordinator.lastCredentialFillID = credentialFillRequestID
            context.coordinator.fillSavedCredential(in: view)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "njuImport")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: NJUCourseWebView
        var lastReadID: UUID?
        var lastReloadID: UUID?
        var lastCredentialFillID: UUID?

        init(parent: NJUCourseWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let host = webView.url?.host ?? ""
            let message = host.contains("authserver")
                ? ""
                : "页面已加载；确认看到课表后，点击“读取当前课表”"
            DispatchQueue.main.async { self.parent.status = message }
            if host == "authserver.nju.edu.cn" {
                fillSavedCredential(in: webView)
            }
        }

        func fillSavedCredential(in webView: WKWebView) {
            guard webView.url?.host == "authserver.nju.edu.cn",
                  let credential = NJUCredentialStore.load(),
                  let usernameJSON = Self.javaScriptLiteral(credential.username),
                  let passwordJSON = Self.javaScriptLiteral(credential.password) else { return }
            let script = """
            (() => {
              const username = document.querySelector('#username, input[name="username"], input[autocomplete="username"], input[type="text"]');
              const password = document.querySelector('#password, input[name="password"], input[autocomplete="current-password"], input[type="password"]');
              if (!username || !password) return false;
              const setValue = (element, value) => {
                const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                setter.call(element, value);
                element.dispatchEvent(new Event('input', {bubbles:true}));
                element.dispatchEvent(new Event('change', {bubbles:true}));
              };
              setValue(username, \(usernameJSON));
              setValue(password, \(passwordJSON));
              return true;
            })();
            """
            webView.evaluateJavaScript(script) { result, _ in
                guard (result as? Bool) == true else { return }
                DispatchQueue.main.async {
                    self.parent.status = "已从应用内保存的信息自动填充，请检查后点击登录"
                }
            }
        }

        private static func javaScriptLiteral(_ value: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isReading = false
                self.parent.status = "页面加载失败：\(error.localizedDescription)"
            }
        }

        func readCourses(from webView: WKWebView) {
            guard webView.url?.host == "ehallapp.nju.edu.cn" else {
                DispatchQueue.main.async {
                    self.parent.isReading = false
                    self.parent.status = "请先完成登录并等待课表页面加载完成"
                }
                return
            }
            let escapedTerm = parent.termCode.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            (() => {
              const endpoints = [
                '/jwapp/sys/wdkb/modules/xskcb/xskcb.do',
                '/jwapp/sys/wdkb/modules/xskcb/xsllsykb.do'
              ];
              const pickRows = json => {
                const datas = json && json.datas;
                if (!datas) return null;
                return (datas.xskcb && datas.xskcb.rows) ||
                       (datas.xsllsykb && datas.xsllsykb.rows) || null;
              };
              const safeRow = row => ({
                KCM: row.KCM, SKJS: row.SKJS, JASMC: row.JASMC, JASDM: row.JASDM,
                JXLDM_DISPLAY: row.JXLDM_DISPLAY, SKXQ: row.SKXQ, KSJC: row.KSJC,
                JSJC: row.JSJC, SKZC: row.SKZC, ZCMC: row.ZCMC, WID: row.WID, KBID: row.KBID
              });
              (async () => {
                let lastStatus = 0;
                for (const endpoint of endpoints) {
                  const collected = new Map();
                  let endpointWorks = false;
                  for (let week = 1; week <= \(parent.semesterWeekCount); week++) {
                    const body = new URLSearchParams({ XNXQDM: '\(escapedTerm)', SKZC: String(week) }).toString();
                    const response = await fetch(endpoint, {
                      method: 'POST', credentials: 'same-origin',
                      headers: {'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8','X-Requested-With':'XMLHttpRequest'},
                      body
                    });
                    lastStatus = response.status;
                    if (!response.ok) { endpointWorks = false; break; }
                    let json;
                    try { json = await response.json(); } catch (_) { endpointWorks = false; break; }
                    const rows = pickRows(json);
                    if (!Array.isArray(rows)) { endpointWorks = false; break; }
                    endpointWorks = true;
                    window.webkit.messageHandlers.njuImport.postMessage({type:'progress', week, total:\(parent.semesterWeekCount)});
                    for (const row of rows) {
                      const key = [row.WID || row.KBID || row.KCM, row.SKXQ, row.KSJC, row.JSJC, row.SKZC, row.JASMC || row.JASDM].join('|');
                      collected.set(key, safeRow(row));
                    }
                  }
                  if (endpointWorks) {
                    const text = JSON.stringify({datas:{xsllsykb:{rows:Array.from(collected.values())}}});
                    window.webkit.messageHandlers.njuImport.postMessage({ok:true, status:200, text});
                    return;
                  }
                }
                window.webkit.messageHandlers.njuImport.postMessage({ok:false, status:lastStatus, text:''});
              })().catch(error => window.webkit.messageHandlers.njuImport.postMessage({ok:false, status:0, text:String(error)}));
              return true;
            })();
            """
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        self.parent.isReading = false
                        self.parent.status = "无法读取：\(error.localizedDescription)"
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any] else { return }
            if (payload["type"] as? String) == "progress" {
                let week = (payload["week"] as? NSNumber)?.intValue ?? 0
                let total = (payload["total"] as? NSNumber)?.intValue ?? parent.semesterWeekCount
                DispatchQueue.main.async {
                    self.parent.isReading = true
                    self.parent.status = "正在读取第 \(week)/\(total) 周…"
                }
                return
            }
            guard let text = payload["text"] as? String else { return }
            guard (payload["ok"] as? Bool) == true else {
                DispatchQueue.main.async {
                    self.parent.isReading = false
                    self.parent.status = "课表接口请求失败，请确认已登录后重试"
                }
                return
            }
            do {
                let parsed = try Self.parseCourses(from: text, maxWeek: parent.semesterWeekCount)
                DispatchQueue.main.async {
                    self.parent.isReading = false
                    self.parent.courses = parsed
                    self.parent.status = parsed.isEmpty
                        ? "没有读取到课程，请确认教务页面已显示当前学期课表"
                        : "读取成功，请在下方预览后确认导入"
                }
            } catch {
                DispatchQueue.main.async {
                    self.parent.isReading = false
                    self.parent.status = "返回内容不是课表数据，登录可能已过期，请重新登录"
                }
            }
        }

        static func parseCourses(from text: String, maxWeek: Int) throws -> [Course] {
            guard let data = text.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let datas = root["datas"] as? [String: Any],
                  let table = datas["xsllsykb"] as? [String: Any],
                  let rows = table["rows"] as? [[String: Any]] else {
                throw ImportError.invalidResponse
            }
            var result: [Course] = []
            let palette = ["蓝", "紫", "绿", "橙", "粉", "红"]
            for row in rows {
                guard let title = string(row["KCM"]), !title.isEmpty,
                      let weekdayValue = integer(row["SKXQ"]), (1...7).contains(weekdayValue),
                      let start = integer(row["KSJC"]), let end = integer(row["JSJC"]) else { continue }
                let teacher = string(row["SKJS"]) ?? ""
                let room = string(row["JASMC"]) ?? string(row["JASDM"]) ?? ""
                let building = string(row["JXLDM_DISPLAY"]) ?? ""
                let ranges = weekRanges(mask: string(row["SKZC"]), description: string(row["ZCMC"]), maxWeek: maxWeek)
                let colorIndex = title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
                for range in ranges {
                    result.append(Course(
                        title: title, teacher: teacher, room: room, building: building,
                        weekday: weekdayValue - 1, start: min(12, max(1, start)), end: min(12, max(start, end)),
                        color: palette[colorIndex], titleSize: "特大", startWeek: range.lowerBound, endWeek: range.upperBound
                    ))
                }
            }
            var seen = Set<String>()
            return result.filter { course in
                let key = "\(course.title)|\(course.weekday)|\(course.start)|\(course.end)|\(course.startWeek ?? 1)|\(course.endWeek ?? maxWeek)|\(course.room)"
                return seen.insert(key).inserted
            }
        }

        static func weekRanges(mask: String?, description: String?, maxWeek: Int) -> [ClosedRange<Int>] {
            if let mask {
                let flags = Array(mask.prefix(maxWeek)).map { $0 == "1" }
                var ranges: [ClosedRange<Int>] = []
                var start: Int?
                for index in 0...flags.count {
                    let active = index < flags.count ? flags[index] : false
                    if active, start == nil { start = index + 1 }
                    if !active, let rangeStart = start {
                        ranges.append(rangeStart...index)
                        start = nil
                    }
                }
                if !ranges.isEmpty { return ranges }
            }
            if let description {
                let numbers = description.split { !$0.isNumber }.compactMap { Int($0) }
                if numbers.count >= 2 {
                    return [max(1, numbers[0])...min(maxWeek, numbers[1])]
                }
                if let first = numbers.first { return [first...first] }
            }
            return [1...maxWeek]
        }

        static func string(_ value: Any?) -> String? {
            if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        static func integer(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }

        enum ImportError: Error { case invalidResponse }
    }
}

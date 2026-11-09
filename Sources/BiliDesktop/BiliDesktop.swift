import SwiftUI
import AppKit
import Darwin
import CryptoKit

struct Video: Identifiable, Hashable, Codable {
    var id: String { bvid }
    let bvid: String
    let title: String
    let uploader: String
    let duration: Int
    let cover: URL?
    let pageCount: Int
    let published: Int
    let views: Int
    let ownerID: Int
    var durationText: String { String(format: "%d:%02d", duration / 60, duration % 60) }
}

struct Creator: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let fans: Int
}

enum SearchMode: String, CaseIterable { case videos = "关键词搜索", creator = "UP 主作品", creatorKeyword = "UP 主 + 关键词" }
enum VideoOrder: String, CaseIterable { case newest = "最新发布", popular = "播放最多" }

enum Section: String, CaseIterable { case discover = "发现视频", creators = "常用 UP 主", favorites = "我的收藏", downloads = "下载记录" }
struct DownloadRecord: Codable, Identifiable {
    var id: String { video.id }
    let video: Video
    let path: String
    let date: Date
}
struct Library: Codable {
    var creators: [Creator] = []
    var favorites: [Video] = []
    var downloads: [DownloadRecord] = []
    var searches: [String] = []
    var directory: String? = nil
    var importedDirectories: [String] = []
    init() {}
    enum CodingKeys: String, CodingKey { case creators, favorites, downloads, searches, directory, importedDirectories }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creators = try c.decodeIfPresent([Creator].self, forKey: .creators) ?? []
        favorites = try c.decodeIfPresent([Video].self, forKey: .favorites) ?? []
        downloads = try c.decodeIfPresent([DownloadRecord].self, forKey: .downloads) ?? []
        searches = try c.decodeIfPresent([String].self, forKey: .searches) ?? []
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        importedDirectories = try c.decodeIfPresent([String].self, forKey: .importedDirectories) ?? []
    }
}

enum BiliError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

struct BiliAPI {
    static func request(path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        let endpoint = "https://api.bilibili.com" + path
        // Anonymous Bilibili requests can intermittently return 412 even when an
        // immediate repeat succeeds. Retry only transient failures, with backoff.
        for attempt in 0..<4 {
            let response = try await Task.detached(priority: .userInitiated) { try curl(endpoint: endpoint, query: query) }.value
            let (data, status, exitCode) = response
            let transientHTTP = [412, 429, 500, 502, 503, 504].contains(status)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = obj?["code"] as? Int
            let transientAPI = code == -352 || code == -412
            if (exitCode != 0 || transientHTTP || transientAPI) && attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(800_000_000 * (1 << attempt)))
                continue
            }
            guard exitCode == 0, status == 200 else {
                if status == 412 || status == 429 { throw BiliError.message("B 站暂时限制了搜索请求（HTTP \(status)），已自动重试。请稍后再试，或直接输入 BV 号。") }
                throw BiliError.message("无法连接 B 站（HTTP \(status)，网络错误 \(exitCode)）。请检查网络后重试。")
            }
            guard let obj else { throw BiliError.message("无法解析 B 站返回的数据。") }
            guard code == 0 || (path == "/x/web-interface/nav" && code == -101) else {
                throw BiliError.message("B 站返回：\(obj["message"] as? String ?? "请求失败")（代码 \(code.map(String.init) ?? "未知")）。请稍后重试。")
            }
            return obj
        }
        throw BiliError.message("请求失败，请稍后重试。")
    }
    static func curl(endpoint: String, query: [URLQueryItem]) throws -> (Data, Int, Int32) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let marker = "\n__BILI_HTTP_STATUS__="
        var arguments = ["-sS", "--connect-timeout", "5", "--max-time", "15", "-w", marker + "%{http_code}", "-A", "Mozilla/5.0", "-e", "https://www.bilibili.com/", "--get"]
        for item in query { arguments.append(contentsOf: ["--data-urlencode", item.name + "=" + (item.value ?? "")]) }
        arguments.append(endpoint); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard let markerRange = output.range(of: Data(marker.utf8), options: .backwards),
              let status = Int(String(decoding: output[markerRange.upperBound...], as: UTF8.self)) else {
            return (output, 0, process.terminationStatus)
        }
        return (Data(output[..<markerRange.lowerBound]), status, process.terminationStatus)
    }
    static func parse(_ d: [String: Any], search: Bool) -> Video? {
        guard let id = d["bvid"] as? String, id.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil, let title = d["title"] as? String else { return nil }
        let clean = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        let owner = (d["owner"] as? [String: Any])?["name"] as? String ?? d["author"] as? String ?? "未知 UP 主"
        let duration: Int
        if let n = d["duration"] as? Int { duration = n }
        else { duration = (d["duration"] as? String ?? "0").split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) } }
        let pic = (d["pic"] as? String ?? "").replacingOccurrences(of: "//", with: "https://", options: .anchored).replacingOccurrences(of: "http://", with: "https://", options: .anchored)
        return Video(bvid: id, title: clean, uploader: owner, duration: duration, cover: URL(string: pic), pageCount: (d["pages"] as? [[String: Any]])?.count ?? 1, published: d["pubdate"] as? Int ?? d["created"] as? Int ?? 0, views: d["play"] as? Int ?? Int(d["play"] as? String ?? "") ?? (d["stat"] as? [String: Any])?["view"] as? Int ?? 0, ownerID: d["mid"] as? Int ?? (d["owner"] as? [String: Any])?["mid"] as? Int ?? 0)
    }
    static func lookup(_ id: String) async throws -> Video {
        let obj = try await request(path: "/x/web-interface/view", query: [.init(name: "bvid", value: id)])
        guard let d = obj["data"] as? [String: Any], let v = parse(d, search: false) else { throw BiliError.message("没有找到该视频。") }
        return v
    }
    static func search(_ keyword: String, page: Int, order: VideoOrder) async throws -> [Video] {
        let obj = try await request(path: "/x/web-interface/search/type", query: [.init(name: "search_type", value: "video"), .init(name: "keyword", value: keyword), .init(name: "order", value: order == .newest ? "pubdate" : "click"), .init(name: "page", value: String(page))])
        let data = obj["data"] as? [String: Any]
        return (data?["result"] as? [[String: Any]] ?? []).compactMap { parse($0, search: true) }
    }
    static func creators(_ keyword: String) async throws -> [Creator] {
        let obj = try await request(path: "/x/web-interface/search/type", query: [.init(name: "search_type", value: "bili_user"), .init(name: "keyword", value: keyword), .init(name: "page", value: "1")])
        let data = obj["data"] as? [String: Any]
        return (data?["result"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["mid"] as? Int, let name = d["uname"] as? String else { return nil }
            return Creator(id: id, name: name.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), fans: d["fans"] as? Int ?? 0)
        }
    }
    static func creatorVideos(_ creator: Creator, keyword: String, page: Int, order: VideoOrder) async throws -> [Video] {
        let nav = try await request(path: "/x/web-interface/nav", query: [])
        guard let data = nav["data"] as? [String: Any], let image = data["wbi_img"] as? [String: String], let a = image["img_url"], let b = image["sub_url"] else { throw BiliError.message("无法获取 UP 主作品查询所需的签名信息。") }
        let raw = [a, b].map { URL(string: $0)?.deletingPathExtension().lastPathComponent ?? "" }.joined()
        let indexes = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
        let chars = Array(raw); guard chars.count > 63 else { throw BiliError.message("签名信息无效。") }
        let key = String(indexes.prefix(32).map { chars[$0] })
        let cleanedKeyword = keyword.filter { !"!'()*".contains($0) }
        let params = ["mid": String(creator.id), "ps": "30", "pn": String(page), "order": order == .newest ? "pubdate" : "click", "keyword": cleanedKeyword, "platform": "web", "web_location": "1550101", "wts": String(Int(Date().timeIntervalSince1970))]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+") }
        let canonical = params.keys.sorted().map { "\(encode($0))=\(encode(params[$0]!))" }.joined(separator: "&")
        let signature = Insecure.MD5.hash(data: Data((canonical + key).utf8)).map { String(format: "%02x", $0) }.joined()
        let query = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) } + [.init(name: "w_rid", value: signature)]
        let obj = try await request(path: "/x/space/wbi/arc/search", query: query)
        let data2 = obj["data"] as? [String: Any]; let list = data2?["list"] as? [String: Any]
        return (list?["vlist"] as? [[String: Any]] ?? []).compactMap { item in
            var item = item; item["author"] = creator.name; item["duration"] = item["length"]
            return parse(item, search: false)
        }
    }

}

@MainActor final class AppModel: ObservableObject {
    @Published var section: Section = .discover
    @Published var library = Library()
    @Published var storageError: String?
    private let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BiliAudio/library.json")
    private var libraryWritable = true
    init() {
        do {
            if FileManager.default.fileExists(atPath: libraryURL.path) {
                library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
                if let path = library.directory { directory = URL(fileURLWithPath: path, isDirectory: true) }
            }
        } catch {
            libraryWritable = false
            storageError = "无法读取本地记录：\(error.localizedDescription)。原记录已保留，本次更改无法保存。"
        }
        if libraryWritable { importCatalog(in: directory) }
    }
    // Import legacy catalog entries once per directory, without touching the files.
    func importCatalog(in directory: URL) {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard !library.importedDirectories.contains(key),
              let csv = try? String(contentsOf: directory.appendingPathComponent("catalog.csv"), encoding: .utf8) else { return }
        var rows: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false
        let chars = Array(csv); var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if ch == "," && !quoted { row.append(field); field = "" }
            else if ch.isNewline && !quoted { row.append(field); field = ""; if !row.isEmpty { rows.append(row) }; row = [] }
            else { field.append(ch) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard rows.first?.count ?? 0 >= 7, rows.first?.first?.contains("BV") == true else { return }
        for values in rows.dropFirst() where values.count >= 7 && values[4] == "audio" {
            let id = values[0]; let name = values[5]
            guard id.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil,
                  name == URL(fileURLWithPath: name).lastPathComponent,
                  !library.downloads.contains(where: { $0.id == id }) else { continue }
            let file = directory.appendingPathComponent(name)
            guard validFile(file) else { continue }
            let video = Video(bvid: id, title: values[1], uploader: values[2], duration: Int(values[3]) ?? 0, cover: nil, pageCount: 1, published: 0, views: 0, ownerID: 0)
            let date = ISO8601DateFormatter().date(from: values[6]) ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            library.downloads.append(DownloadRecord(video: video, path: file.path, date: date))
        }
        library.downloads.sort { $0.date > $1.date }
        library.importedDirectories.append(key); saveLibrary()
    }
    func saveLibrary() {
        guard libraryWritable else { return }
        do {
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: libraryURL, options: .atomic)
            storageError = nil
        } catch { storageError = "无法保存本地记录：\(error.localizedDescription)" }
    }
    func remember(_ creator: Creator) {
        library.creators.removeAll { $0.id == creator.id }; library.creators.insert(creator, at: 0); saveLibrary()
    }
    func forget(_ creator: Creator) { library.creators.removeAll { $0.id == creator.id }; saveLibrary() }
    func useCreator(_ creator: Creator) {
        section = .discover; mode = .creator; creatorQuery = creator.name; creators = [creator]; self.creator = creator
        remember(creator)
    }
    func toggleFavorite(_ video: Video) {
        if library.favorites.contains(where: { $0.id == video.id }) { library.favorites.removeAll { $0.id == video.id }; if section == .favorites { selection.remove(video.id) } }
        else { library.favorites.insert(video, at: 0) }
        saveLibrary()
    }
    func record(_ video: Video, file: URL) {
        library.downloads.removeAll { $0.id == video.id }; library.downloads.insert(DownloadRecord(video: video, path: file.path, date: Date()), at: 0); saveLibrary()
    }
    func removeRecord(_ video: Video) { library.downloads.removeAll { $0.id == video.id }; selection.remove(video.id); saveLibrary() }
    func validFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }
    func downloadedFile(_ video: Video) -> URL? {
        guard let record = library.downloads.first(where: { $0.id == video.id }) else { return nil }
        let file = URL(fileURLWithPath: record.path)
        return validFile(file) ? file : nil
    }
    func existingFile(_ video: Video, in directory: URL) -> URL? {
        if let file = downloadedFile(video) { return file }
        // Recognize earlier app downloads even before a history record exists.
        let suffix = " [\(video.bvid)].mp3"
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.lastPathComponent.hasSuffix(suffix) && validFile($0) }
    }
    var shownVideos: [Video] {
        switch section { case .discover: return results; case .favorites: return library.favorites; case .downloads: return library.downloads.map(\.video); case .creators: return [] }
    }
    func rememberSearch(_ value: String) {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        library.searches.removeAll { $0 == term }; library.searches.insert(term, at: 0)
        if library.searches.count > 12 { library.searches = Array(library.searches.prefix(12)) }
        saveLibrary()
    }
    @Published var query = ""
    @Published var creatorQuery = ""
    @Published var mode: SearchMode = .videos
    @Published var order: VideoOrder = .newest
    @Published var creators: [Creator] = []
    @Published var creator: Creator?
    @Published var findingCreators = false
    var lastSearchKey = ""
    var searchKey: String { "\(mode.rawValue)|\(query)|\(creator?.id ?? 0)|\(order.rawValue)" }
    func findCreators() {
        let input = creatorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { message = "请输入 UP 主名称。"; return }
        message = "正在查找 UP 主；如遇临时限制会自动重试。"
        findingCreators = true; creator = nil; creators = []; results = []; selection = []; canNext = false
        Task {
            defer { findingCreators = false }
            do { creators = try await BiliAPI.creators(input); message = creators.isEmpty ? "没有找到 UP 主。" : "请选择 UP 主，再搜索作品。" }
            catch { message = error.localizedDescription }
        }
    }
    @Published var results: [Video] = []
    @Published var selection = Set<String>()
    @Published var searching = false
    @Published var running = false
    @Published var message = "输入关键词搜索，或粘贴视频链接 / BV 号。"
    @Published var log = ""
    @Published var status: [String: String] = [:]
    @Published var directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.appendingPathComponent("Bili 音频")
    @Published var page = 1
    @Published var canNext = false
    @Published var usingFallback = false
    var activeProcess: Process?
    var cancelled = false
    let toolPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/miniconda3/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    var missing: [String] { ["you-get", "ffmpeg", "python3"].filter { name in !toolPath.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: String($0) + "/" + name) } } }
    func search(next: Bool = false) {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .videos && input.isEmpty { message = "请输入关键词、视频链接或 BV 号。"; return }
        if mode != .videos && creator == nil { message = "请先查找并选择 UP 主。"; return }
        if mode == .creatorKeyword && input.isEmpty { message = "请输入要在 UP 主作品中搜索的关键词。"; return }
        if next && searchKey != lastSearchKey { message = "搜索条件已更改，请重新搜索。"; return }
        let currentKey = searchKey; let chosenMode = mode; let chosenCreator = creator; let chosenOrder = order
        if !next { results = []; selection = []; canNext = false; usingFallback = false }
        searching = true
        message = "正在搜索；如遇临时限制会自动重试。"
        let targetPage = next ? page + 1 : 1
        Task {
            defer { searching = false }
            do {
                let regex = try NSRegularExpression(pattern: "BV[0-9A-Za-z]{10}", options: .caseInsensitive)
                let range = NSRange(input.startIndex..., in: input)
                if chosenMode == .videos, let match = regex.firstMatch(in: input, range: range), let r = Range(match.range, in: input) {
                    let raw = String(input[r]); let id = "BV" + raw.dropFirst(2)
                    let v = try await BiliAPI.lookup(id)
                    results = [v]; selection = []; page = 1; canNext = false
                } else {
                    var found: [Video] = []
                    var hasMore = false
                    if chosenMode == .videos {
                        found = try await BiliAPI.search(input, page: targetPage, order: chosenOrder); hasMore = !found.isEmpty
                    } else {
                        if !usingFallback {
                            do { found = try await BiliAPI.creatorVideos(chosenCreator!, keyword: chosenMode == .creatorKeyword ? input : "", page: targetPage, order: chosenOrder); hasMore = !found.isEmpty }
                            catch { usingFallback = true }
                        }
                        if usingFallback {
                            let publicResults = try await BiliAPI.search(chosenCreator!.name, page: targetPage, order: chosenOrder)
                            hasMore = !publicResults.isEmpty
                            found = publicResults.filter { $0.ownerID == chosenCreator!.id && (chosenMode != .creatorKeyword || $0.title.localizedCaseInsensitiveContains(input)) }
                        }
                    }
                    if next { results.append(contentsOf: found.filter { !results.contains($0) }) } else { results = found; selection = [] }
                    page = targetPage; canNext = hasMore
                }
                if !next && chosenMode == .videos { rememberSearch(input) }
                lastSearchKey = currentKey
                if usingFallback { message = "空间接口受限，正在按公开搜索结果筛选 UID 和标题；结果可能不完整。已找到 \(results.count) 个视频。" }
                else { message = results.isEmpty ? "没有找到视频，试试其他关键词或直接输入 BV 号。" : "找到 \(results.count) 个视频，选择需要转换的内容。" }
            } catch { message = error.localizedDescription }
        }
    }
    func clearResults() { results = []; selection = []; canNext = false; message = "搜索条件已更改，请重新搜索。" }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = directory.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { directory = url; library.directory = url.path; importCatalog(in: url); saveLibrary() }
    }
    func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
    func start() {
        guard !running, !selection.isEmpty else { return }
        guard missing.isEmpty else { message = "缺少依赖：\(missing.joined(separator: "、"))。请先安装，详见 README。"; return }
        let jobs = shownVideos.filter { selection.contains($0.id) }
        let out = directory
        do { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) } catch { message = "无法创建保存目录：\(error.localizedDescription)"; return }
        guard let resources = Bundle.main.url(forResource: "DownloadScripts", withExtension: nil) ?? Bundle.module.url(forResource: "Resources", withExtension: nil) else { message = "找不到下载组件。"; return }
        running = true; cancelled = false; log = ""; status = [:]
        Task {
            for (index, video) in jobs.enumerated() {
                if cancelled { break }
                if let existing = existingFile(video, in: out) {
                    if downloadedFile(video) == nil { record(video, file: existing) }
                    status[video.id] = "已下载"
                    log += "[SKIP] \(video.bvid)：已有文件 \(existing.path)\n"
                    continue
                }
                status[video.id] = "下载中"
                message = "正在处理 \(index + 1) / \(jobs.count)：\(video.title)"
                do {
                    let detail = try await BiliAPI.lookup(video.bvid)
                    if detail.pageCount > 1 {
                        status[video.id] = "分 P 暂不支持"
                        log += "[SKIP] \(video.bvid)：包含 \(detail.pageCount) 个分 P，当前版本暂不支持选择分 P。\n"
                        continue
                    }
                } catch {
                    status[video.id] = "失败"
                    log += "[ERROR] \(video.bvid)：无法核实视频信息：\(error.localizedDescription)\n"
                    continue
                }
                if cancelled { status[video.id] = "已停止"; break }
                let result = await run(script: resources.appendingPathComponent("bili-dl.sh"), video: video, output: out)
                if cancelled { status[video.id] = "已停止"; break }
                let safeTitle = video.title.map { "/\\:*?\"<>|\n\r\t".contains($0) ? "_" : String($0) }.joined() + " [\(video.bvid)]"
                let file = out.appendingPathComponent(safeTitle + ".mp3")
                let state = result.output.contains("[CHARGED] SKIP") ? "付费跳过" : (result.code == 0 && validFile(file) ? "已完成" : "失败")
                status[video.id] = state
                if state == "已完成" { record(video, file: file) }
                if state != "失败" { appendCatalog(video: video, output: out, state: state) }
                if index + 1 < jobs.count { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            running = false; activeProcess = nil
            let counts = status.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            message = cancelled ? "已停止；已完成的文件保留在保存目录。" : "处理结束：完成 \(counts["已完成", default: 0])，跳过 \(counts["付费跳过", default: 0] + counts["分 P 暂不支持", default: 0] + counts["已下载", default: 0])，失败 \(counts["失败", default: 0])。"
        }
    }
    func run(script: URL, video: Video, output: URL) async -> (code: Int32, output: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Include the BV number to prevent two videos with the same title colliding.
        process.arguments = [script.path, "audio", video.bvid, output.path, video.title + " [" + video.bvid + "]"]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = toolPath + ":" + (env["PATH"] ?? ""); env["PYTHONIOENCODING"] = "utf-8"; process.environment = env
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        activeProcess = process
        do { try process.run() } catch { log += "\(error.localizedDescription)\n"; return (-1, "") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var all = Data()
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    all.append(data)
                    let chunk = String(decoding: data, as: UTF8.self)
                    Task { @MainActor in self.log += chunk }
                }
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: all, as: UTF8.self)))
            }
        }
    }
    func stop() {
        cancelled = true
        if let process = activeProcess, process.isRunning {
            // GUI-launched processes may already lead a process group, so setsid()
            // can fail. Terminate only this job's descendants, then its shell.
            let listing = Process(); listing.executableURL = URL(fileURLWithPath: "/bin/ps")
            listing.arguments = ["-axo", "pid=,ppid="]
            let pipe = Pipe(); listing.standardOutput = pipe
            if (try? listing.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); listing.waitUntilExit()
                let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (pid_t, pid_t)? in
                    let numbers = line.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
                    return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
                }
                var descendants: [pid_t] = [process.processIdentifier]
                var index = 0
                while index < descendants.count {
                    let parent = descendants[index]
                    descendants.append(contentsOf: pairs.filter { $0.1 == parent && !descendants.contains($0.0) }.map { $0.0 })
                    index += 1
                }
                for pid in descendants.reversed() { _ = kill(pid, SIGTERM) }
            } else { process.terminate() }
        }
        message = "正在停止…"
    }
    func appendCatalog(video: Video, output: URL, state: String) {
        let url = output.appendingPathComponent("catalog.csv")
        let safeTitle = video.title.map { "/\\:*?\"<>|\n\r\t".contains($0) ? "_" : String($0) }.joined() + " [\(video.bvid)]"
        let fields = [video.bvid, video.title, video.uploader, String(video.duration), state == "付费跳过" ? "skipped-charged" : "audio", state == "付费跳过" ? "" : safeTitle + ".mp3", ISO8601DateFormatter().string(from: Date())]
        let row = fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") + "\n"
        if !FileManager.default.fileExists(atPath: url.path) { try? "BV号,标题,UP主,时长(秒),下载类型,文件名,下载时间\n".write(to: url, atomically: true, encoding: .utf8) }
        if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(row.utf8)) }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 14) {
                header
                if let error = model.storageError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if model.section == .discover { searchControls }
                if model.section == .creators { creatorList } else { videoList }
                if model.running { ProgressView().controlSize(.small) }
                DisclosureGroup("处理日志") {
                    ScrollView { Text(model.log.isEmpty ? "下载开始后将在这里显示详细信息。" : model.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
                }.font(.caption)
                if model.section != .creators { downloadBar }
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 900, minHeight: 650)
        .onChange(of: model.mode) { _ in model.clearResults() }
        .onChange(of: model.order) { _ in model.clearResults() }
        .onChange(of: model.creator) { value in model.clearResults(); if let creator = value { model.remember(creator) } }
        .onChange(of: model.section) { _ in model.selection.removeAll() }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) { Image(systemName: "waveform.circle.fill").font(.system(size: 30)).foregroundStyle(.pink); VStack(alignment: .leading) { Text("Bili 音频").font(.title2.bold()); Text("VIDEO TO MP3").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(.secondary) } }
            Divider()
            VStack(spacing: 5) {
                nav(.discover, icon: "magnifyingglass", count: nil)
                nav(.creators, icon: "person.crop.circle", count: model.library.creators.count)
                nav(.favorites, icon: "heart", count: model.library.favorites.count)
                nav(.downloads, icon: "arrow.down.circle", count: model.library.downloads.count)
            }
            if !model.library.searches.isEmpty {
                Divider()
                HStack { Text("最近搜索").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button("清除") { model.library.searches = []; model.saveLibrary() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).disabled(model.running || model.searching) }
                ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(model.library.searches, id: \.self) { term in
                    Button { model.section = .discover; model.mode = .videos; model.query = term; model.search() } label: { Label(term, systemImage: "clock.arrow.circlepath").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).font(.caption).disabled(model.running || model.searching)
                } } }.frame(maxHeight: 160)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("保存位置").font(.caption.bold()).foregroundStyle(.secondary)
                Text(model.directory.path).font(.caption).lineLimit(3).textSelection(.enabled)
                HStack { Button("更改…") { model.chooseDirectory() }.disabled(model.running); Button("打开") { NSWorkspace.shared.open(model.directory) } }
            }
            Divider()
            Label(model.missing.isEmpty ? "依赖已就绪" : "缺少：\(model.missing.joined(separator: ", "))", systemImage: model.missing.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.caption).foregroundStyle(model.missing.isEmpty ? .green : .orange)
        }.padding(20).frame(width: 220).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .controlBackgroundColor))
    }
    func nav(_ section: Section, icon: String, count: Int?) -> some View {
        Button { model.section = section } label: {
            HStack { Label(section.rawValue, systemImage: icon); Spacer(); if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) } }
                .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.section == section ? Color.pink.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(model.section == section ? Color.pink : Color.primary)
        }.buttonStyle(.plain).disabled(model.running || model.searching || model.findingCreators)
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.section == .discover ? "发现好声音" : model.section.rawValue).font(.system(size: 28, weight: .bold))
            Text({ switch model.section { case .discover: return "搜索视频，选择喜欢的内容，转换为 MP3。"; case .creators: return "选择过的 UP 主会自动保存在这里。"; case .favorites: return "把喜欢的视频留在这里，随时回来下载。"; case .downloads: return "查看已下载的音频和文件位置。" } }()).foregroundStyle(.secondary)
        }
    }
    var searchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("搜索方式", selection: $model.mode) { ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(model.searching || model.running)
            if model.mode != .videos {
                HStack {
                    TextField("输入 UP 主名称", text: $model.creatorQuery).textFieldStyle(.roundedBorder)
                    Button("查找 UP 主") { model.findCreators() }.disabled(model.findingCreators || model.running || model.searching)
                    if model.findingCreators { ProgressView().controlSize(.small) }
                }
                if !model.creators.isEmpty {
                    Picker("选择 UP 主", selection: $model.creator) {
                        Text("请选择 UP 主").tag(nil as Creator?)
                        ForEach(model.creators) { creator in Text("\(creator.name) · UID \(creator.id) · \(creator.fans) 粉丝").tag(Optional(creator)) }
                    }.disabled(model.running || model.searching)
                }
            }
            HStack {
                if model.mode != .creator {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.mode == .videos ? "关键词、视频链接或 BV 号" : "输入作品关键词", text: $model.query).textFieldStyle(.plain).onSubmit { model.search() }
                }
                Picker("排序", selection: $model.order) { ForEach(VideoOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize().disabled(model.searching || model.running)
                if model.searching { ProgressView().controlSize(.small) }
                Button("搜索视频") { model.search() }.keyboardShortcut(.return, modifiers: []).disabled(model.searching || model.running || model.findingCreators)
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    var creatorList: some View {
        Group {
            if model.library.creators.isEmpty { emptyState("还没有记忆的 UP 主", detail: "在发现页面查找并选择 UP 主后，会自动出现在这里。") }
            else { ScrollView { LazyVStack(spacing: 8) { ForEach(model.library.creators) { creator in
                HStack {
                    Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.pink)
                    VStack(alignment: .leading, spacing: 4) { Text(creator.name).font(.headline); Text("UID \(creator.id) · \(creator.fans) 粉丝").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("查看作品") { model.useCreator(creator) }.disabled(model.running)
                    Button { model.forget(creator) } label: { Image(systemName: "trash") }.help("移除 UP 主记录").disabled(model.running)
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            } } } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) { Image(systemName: "music.note.list").font(.system(size: 42)).foregroundStyle(.pink.opacity(0.6)); Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.section == .discover && model.canNext { Button("继续查找下一页") { model.search(next: true) }.disabled(model.searching || model.running || model.searchKey != model.lastSearchKey) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var videoList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("视频列表").font(.headline); Text("\(model.shownVideos.count)").font(.caption.bold()).foregroundStyle(.secondary); Spacer()
                Button(model.selection.count == model.shownVideos.count && !model.shownVideos.isEmpty ? "取消全选" : "全选") { if model.selection.count == model.shownVideos.count { model.selection.removeAll() } else { model.selection = Set(model.shownVideos.map(\.id)) } }.disabled(model.shownVideos.isEmpty || model.running)
            }
            if model.shownVideos.isEmpty {
                emptyState(model.section == .discover ? "从一次搜索开始" : (model.section == .favorites ? "还没有收藏的视频" : "还没有下载记录"), detail: model.section == .discover ? model.message : (model.section == .favorites ? "点击视频旁的爱心即可收藏。" : "下载成功后会自动记录在这里。"))
            } else {
                ScrollView { LazyVStack(spacing: 8) {
                    ForEach(model.shownVideos) { video in videoRow(video) }
                    if model.section == .discover && model.canNext { Button("加载更多") { model.search(next: true) }.disabled(model.searching || model.running || model.searchKey != model.lastSearchKey).padding(6) }
                } }
                if model.section == .discover || model.running { Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }.frame(maxHeight: .infinity)
    }
    func videoRow(_ video: Video) -> some View {
        HStack(spacing: 12) {
            Button { model.toggle(video.id) } label: { Image(systemName: model.selection.contains(video.id) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(model.selection.contains(video.id) ? .pink : .secondary) }.buttonStyle(.plain).disabled(model.running).help("选择视频")
            AsyncImage(url: video.cover) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Rectangle().fill(Color.gray.opacity(0.15)).overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary)) }.frame(width: 100, height: 62).clipped().cornerRadius(6)
            VStack(alignment: .leading, spacing: 5) {
                Text(video.title).font(.callout.bold()).lineLimit(2)
                Text("\(video.uploader)  ·  \(video.durationText)  ·  \(video.bvid)").font(.caption).foregroundStyle(.secondary)
                if model.section == .downloads, let record = model.library.downloads.first(where: { $0.id == video.id }) {
                    Text("下载于 \(record.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                } else if video.published > 0 {
                    Text("播放 \(video.views)  ·  \(Date(timeIntervalSince1970: TimeInterval(video.published)).formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                if let state = model.status[video.id] { Text(state).font(.caption.bold()).foregroundStyle(state == "失败" ? .red : .secondary) }
                else if model.downloadedFile(video) != nil { Text("已下载").font(.caption.bold()).foregroundStyle(.green) }
                else if model.section == .downloads { Text("文件不存在").font(.caption).foregroundStyle(.orange) }
                HStack {
                    if let file = model.downloadedFile(video) { Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示") }
                    Button { model.toggleFavorite(video) } label: { Image(systemName: model.library.favorites.contains(where: { $0.id == video.id }) ? "heart.fill" : "heart").foregroundStyle(.pink) }.help(model.library.favorites.contains(where: { $0.id == video.id }) ? "取消收藏" : "收藏视频").disabled(model.running)
                    if model.section == .downloads { Button { model.removeRecord(video) } label: { Image(systemName: "trash") }.help("移除记录，保留文件").disabled(model.running) }
                }.buttonStyle(.plain)
            }
        }.padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
    var downloadBar: some View {
        VStack {
            Divider()
            HStack { Text("已选择 \(model.selection.count) 个视频").foregroundStyle(.secondary); Spacer(); if model.running { Button("停止") { model.stop() } }; Button { model.start() } label: { Label("下载并转换 MP3", systemImage: "arrow.down.circle.fill").padding(.horizontal, 8).padding(.vertical, 4) }.buttonStyle(.borderedProminent).tint(.pink).disabled(model.selection.isEmpty || model.running) }
        }
    }
}
@main struct BiliDesktopApp: App {
    var body: some Scene { WindowGroup { ContentView() }.windowStyle(.titleBar) }
}

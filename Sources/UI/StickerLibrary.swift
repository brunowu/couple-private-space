#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation
import CryptoKit
import ImageIO
import UIKit
import QuickLook

struct StickerPackManifest: Codable {
    let formatVersion: Int
    let packID: String
    let title: String
    let category: String?
    let stickers: [StickerRecord]
}

struct StickerRecord: Codable, Identifiable, Hashable {
    let id: String
    let file: String
    let mediaType: String
    let byteCount: Int
    let width: Int
    let height: Int
    let keywords: [String]
}

struct InstalledSticker: Identifiable {
    let packID: String
    let packTitle: String
    let record: StickerRecord
    let mediaURL: URL
    let thumbnailURL: URL
    var id: String { record.id }
}

enum StickerImportError: Error {
    case invalidPackage, unsafePath, capacity, integrity, unsupported
}

@MainActor final class StickerLibrary: ObservableObject {
    @Published private(set) var stickers: [InstalledSticker] = []
    @Published private(set) var packTitles: [String] = []
    @Published private(set) var packCategories: [String: String] = [:]
    @Published var importing = false
    @Published var status: String?
    @Published private(set) var recentStickerIDs: [String] = []
    @Published private(set) var searchChoices: [String: [String]] = [:]

    private static let recentKey = "couple.stickers.recent.v1"
    private static let searchChoicesKey = "couple.stickers.searchChoices.v1"
    private static let importedCollectionKey = "couple.stickers.importedCollection.v1"

    init() {
        var seenRecent = Set<String>()
        recentStickerIDs = (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])
            .filter { seenRecent.insert($0).inserted }
        if let data = UserDefaults.standard.data(forKey: Self.searchChoicesKey),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            searchChoices = saved
        }
        reload()
        Task { autoImportInstalledCollectionIfNeeded() }
    }

    func markUsed(_ sticker: InstalledSticker, query: String? = nil) {
        recentStickerIDs.removeAll { $0 == sticker.id }
        recentStickerIDs.insert(sticker.id, at: 0)
        if recentStickerIDs.count > 60 { recentStickerIDs.removeLast(recentStickerIDs.count - 60) }
        UserDefaults.standard.set(recentStickerIDs, forKey: Self.recentKey)
        let term = Self.normalizedSearchTerm(query ?? "")
        if !term.isEmpty {
            var choices = searchChoices[term] ?? []
            choices.removeAll { $0 == sticker.id }; choices.insert(sticker.id, at: 0)
            searchChoices[term] = Array(choices.prefix(20))
            if let data = try? JSONEncoder().encode(searchChoices) {
                UserDefaults.standard.set(data, forKey: Self.searchChoicesKey)
            }
        }
    }

    private static func normalizedSearchTerm(_ value: String) -> String {
        var result = value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        while let last = result.last, "了呀啊呢嘛哦啦喽吧".contains(last) { result.removeLast() }
        return result
    }

    var transferredPackAvailable: Bool {
        !Self.transferredPackURLs.isEmpty
    }

    func sticker(id: String) -> InstalledSticker? {
        stickers.first { $0.id == id }
    }

    func isSharedBuiltIn(_ sticker: InstalledSticker) -> Bool {
        Self.bundledPackIDs.contains(sticker.packID)
    }

    func importTransferredPack() {
        importTransferredPack(signature: Self.transferredCollectionSignature)
    }

    private func autoImportInstalledCollectionIfNeeded() {
        let signature = Self.installedCollectionSignature
        guard !signature.isEmpty,
              UserDefaults.standard.string(forKey: Self.importedCollectionKey) != signature else { return }
        importPackCollection(Self.installedPackURLs, signature: signature, reportStatus: false)
    }

    private func importTransferredPack(signature: String) {
        let sources = Self.transferredPackURLs
        guard !sources.isEmpty else {
            status = "没有找到通过电脑传入的 family.stickerpack。"
            return
        }
        importPackCollection(sources, signature: signature, reportStatus: true)
    }

    private func importPackCollection(_ sources: [URL], signature: String, reportStatus: Bool) {
        guard !sources.isEmpty, !importing else { return }
        importing = true; status = nil
        Task {
            do {
                try await Task.detached {
                    var imported = Set<String>()
                    for source in sources { imported.insert(try Self.performImport(source)) }
                    if imported.contains(where: { $0.hasPrefix("wechat-emoticon-") }) {
                        try Self.removeObsoleteCuratedPacks(keeping: imported)
                    }
                }.value
                reload()
                if !signature.isEmpty { UserDefaults.standard.set(signature, forKey: Self.importedCollectionKey) }
                if reportStatus { status = "已安全导入 \(sources.count) 个表情包。" }
            } catch {
                status = "导入失败：数据包损坏、超出限制或包含不安全路径。"
            }
            importing = false
        }
    }

    func importPack(_ source: URL) {
        guard !importing else { return }
        importing = true; status = nil
        let accessed = source.startAccessingSecurityScopedResource()
        Task {
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await Task.detached { try Self.performImport(source) }.value
                reload(); status = "表情包已安全导入。"
            } catch {
                status = "导入失败：数据包损坏、超出限制或包含不安全路径。"
            }
            importing = false
        }
    }

    func reload() {
        do {
            let root = try Self.packRoot()
            var loaded: [InstalledSticker] = [], titles: [String] = [], categories: [String: String] = [:]
            for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let manifestURL = directory.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(StickerPackManifest.self, from: data) else { continue }
                titles.append(manifest.title)
                if let category = manifest.category, !category.isEmpty { categories[manifest.title] = category }
                for record in manifest.stickers {
                    loaded.append(InstalledSticker(packID: manifest.packID, packTitle: manifest.title, record: record,
                        mediaURL: directory.appendingPathComponent(record.file),
                        thumbnailURL: Self.thumbnailRoot().appendingPathComponent(Self.digest(from: record.id) + ".jpg")))
                }
            }
            stickers = loaded; packTitles = titles.sorted(); packCategories = categories
        } catch { stickers = []; packTitles = []; packCategories = [:] }
    }

    nonisolated private static var transferredPackURLs: [URL] {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let direct = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let imports = root.appendingPathComponent("StickerImports", isDirectory: true)
        let nested = (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? []
        return (direct + nested).filter { $0.pathExtension.lowercased() == "stickerpack" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static var bundledPackURLs: [URL] {
        guard let resourceRoot = Bundle.module.resourceURL else { return [] }
        let root = resourceRoot.appendingPathComponent("BundledStickerPacks", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "stickerpack" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static let bundledPackIDs: Set<String> = {
        Set(bundledPackURLs.compactMap { url in
            guard let archive = try? Archive(url: url, accessMode: .read),
                  let entry = archive["manifest.json"] else { return nil }
            var data = Data()
            guard (try? archive.extract(entry) { data.append($0) }) != nil,
                  let manifest = try? JSONDecoder().decode(StickerPackManifest.self, from: data) else { return nil }
            return manifest.packID
        })
    }()

    nonisolated private static var installedPackURLs: [URL] {
        let bundled = bundledPackURLs
        let bundledNames = Set(bundled.map(\.lastPathComponent))
        return bundled + transferredPackURLs.filter { !bundledNames.contains($0.lastPathComponent) }
    }

    nonisolated private static var transferredCollectionSignature: String {
        collectionSignature(for: transferredPackURLs)
    }

    nonisolated private static var installedCollectionSignature: String {
        collectionSignature(for: installedPackURLs)
    }

    nonisolated private static func collectionSignature(for urls: [URL]) -> String {
        let description = urls.map { url -> String in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(url.lastPathComponent):\(size)"
        }.joined(separator: "|")
        guard !description.isEmpty else { return "" }
        return SHA256.hash(data: Data(description.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func performImport(_ source: URL) throws -> String {
        let fm = FileManager.default, root = try packRoot()
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let archive = try Archive(url: source, accessMode: .read)
        let entries = Array(archive)
        guard !entries.isEmpty, entries.count <= 2_000 else { throw StickerImportError.capacity }
        var total: UInt64 = 0
        for entry in entries {
            guard safe(entry.path), entry.type != .symlink else { throw StickerImportError.unsafePath }
            guard entry.uncompressedSize <= 10 * 1024 * 1024 else { throw StickerImportError.capacity }
            total += entry.uncompressedSize
            guard total <= 500 * 1024 * 1024 else { throw StickerImportError.capacity }
            if entry.compressedSize > 0 {
                guard entry.uncompressedSize / entry.compressedSize <= 100 else { throw StickerImportError.capacity }
            }
            let target = staging.appendingPathComponent(entry.path)
            guard target.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
                throw StickerImportError.unsafePath
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }
        let manifestURL = staging.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        guard manifestData.count <= 5 * 1024 * 1024 else { throw StickerImportError.capacity }
        let manifest = try JSONDecoder().decode(StickerPackManifest.self, from: manifestData)
        guard manifest.formatVersion == 1, !manifest.packID.isEmpty, manifest.packID.utf8.count <= 128,
              !manifest.title.isEmpty, manifest.title.utf8.count <= 256,
              manifest.stickers.count <= 2_000 else { throw StickerImportError.invalidPackage }
        var ids = Set<String>(), files = Set<String>()
        for sticker in manifest.stickers {
            guard ids.insert(sticker.id).inserted, files.insert(sticker.file).inserted,
                  sticker.file.hasPrefix("media/"), safe(sticker.file),
                  ["image/gif", "image/png", "image/jpeg"].contains(sticker.mediaType),
                  (1...10 * 1024 * 1024).contains(sticker.byteCount),
                  (1...4096).contains(sticker.width), (1...4096).contains(sticker.height),
                  sticker.keywords.count <= 64 else { throw StickerImportError.invalidPackage }
            let digest = digest(from: sticker.id)
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw StickerImportError.integrity }
            let url = staging.appendingPathComponent(sticker.file)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == sticker.byteCount,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest,
                  try validateImage(data, expectedType: sticker.mediaType,
                                    width: sticker.width, height: sticker.height) else { throw StickerImportError.integrity }
            try makeThumbnail(data, name: digest)
        }
        let directoryName = SHA256.hash(data: Data(manifest.packID.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        let destination = root.appendingPathComponent(directoryName, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: destination.path)
        return manifest.packID
    }

    /// Replacing the curated GitHub collection must not touch private favorites,
    /// received stickers, or the standard emoji pack. Only obsolete packs created
    /// by build_wechat_emoticon_packs.py share this namespace.
    nonisolated private static func removeObsoleteCuratedPacks(keeping imported: Set<String>) throws {
        let fm = FileManager.default, root = try packRoot()
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(StickerPackManifest.self, from: data),
                  manifest.packID.hasPrefix("wechat-emoticon-"),
                  !imported.contains(manifest.packID) else { continue }
            try fm.removeItem(at: directory)
        }
    }

    nonisolated private static func packRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("StickerPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    nonisolated private static func thumbnailRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("StickerThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    nonisolated private static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
    nonisolated static func digest(from id: String) -> String {
        id.hasPrefix("sha256:") ? String(id.dropFirst(7)).lowercased() : ""
    }
    nonisolated private static func validateImage(_ data: Data, expectedType: String,
                                                   width: Int, height: Int) throws -> Bool {
        let magic: String
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { magic = "image/gif" }
        else if data.starts(with: Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])) { magic = "image/png" }
        else if data.starts(with: Data([0xff,0xd8,0xff])) { magic = "image/jpeg" }
        else { return false }
        guard magic == expectedType,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = values[kCGImagePropertyPixelWidth] as? Int,
              let h = values[kCGImagePropertyPixelHeight] as? Int else { return false }
        return w == width && h == height
    }
    nonisolated private static func makeThumbnail(_ data: Data, name: String) throws {
        let target = thumbnailRoot().appendingPathComponent(name + ".jpg")
        if FileManager.default.fileExists(atPath: target.path) { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82) else {
            throw StickerImportError.unsupported
        }
        try jpeg.write(to: target, options: .atomic)
    }
}

struct StickerLibraryView: View {
    @ObservedObject var library: StickerLibrary
    var onSend: ((InstalledSticker) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var preview: InstalledSticker?
    @State private var query = ""
    @State private var selectedPack: String?
    @State private var selectedCategory = "全部"
    private let type = UTType(filenameExtension: "stickerpack") ?? .zip

    private var filteredStickers: [InstalledSticker] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let terms = searchTerms(for: trimmed)
            // Score each item once. Re-running score inside a sort comparator made every
            // keystroke needlessly expensive with a library of a few thousand stickers.
            let matches = library.stickers.compactMap { sticker -> (InstalledSticker, Int)? in
                let score = matchScore(sticker, terms: terms, raw: trimmed)
                return score > 0 ? (sticker, score) : nil
            }
            let learned = library.searchChoices[normalize(trimmed)] ?? []
            var rank: [String: Int] = [:]
            for (index, id) in learned.enumerated() where rank[id] == nil { rank[id] = index }
            return matches.sorted {
                let leftLearned = rank[$0.0.id] ?? Int.max, rightLearned = rank[$1.0.id] ?? Int.max
                if leftLearned != rightLearned { return leftLearned < rightLearned }
                return $0.1 > $1.1
            }.map(\.0)
        }
        if selectedPack == Self.recentTitle {
            var byID: [String: InstalledSticker] = [:]
            for sticker in library.stickers where byID[sticker.id] == nil { byID[sticker.id] = sticker }
            return library.recentStickerIDs.compactMap { byID[$0] }
        }
        guard let selectedPack else { return library.stickers }
        return library.stickers.filter { $0.packTitle == selectedPack }
    }

    private static let recentTitle = "最近"
    private static let categories = ["全部", "情侣撒娇", "软萌日常", "萌宠陪伴"]

    private var visiblePackTitles: [String] {
        guard selectedCategory != "全部" else { return library.packTitles }
        return library.packTitles.filter { library.packCategories[$0] == selectedCategory }
    }

    private func normalize(_ value: String) -> String {
        var result = value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        while let last = result.last, "了呀啊呢嘛哦啦喽吧".contains(last) { result.removeLast() }
        return result
    }

    private func searchTerms(for value: String) -> Set<String> {
        let term = normalize(value)
        var terms: Set<String> = [term]
        let groups = Self.semanticGroups
        for group in groups where group.contains(where: { normalize($0) == term }) {
            terms.formUnion(group.map(normalize))
        }
        return terms.filter { !$0.isEmpty }
    }

    private static let semanticGroups = [
        ["哈哈哈", "哈哈", "笑死", "大笑", "好笑", "开心"],
        ["爱你", "爱你呀", "我爱你", "喜欢你", "喜欢", "比心"],
        ["想你", "想你了", "好想你", "想念", "思念"],
        ["抱抱", "抱一下", "拥抱", "抱紧", "求抱抱"],
        ["亲亲", "亲一下", "亲吻", "么么哒", "啵啵"],
        ["撒娇", "卖萌", "可爱", "萌萌哒", "乖巧"],
        ["害羞", "脸红", "不好意思", "羞羞"],
        ["委屈", "可怜", "难过", "伤心", "心碎"],
        ["哭", "哭哭", "流泪", "呜呜", "泪奔"],
        ["生气", "气死", "发火", "愤怒", "哼"],
        ["无语", "服了", "离谱", "没眼看"],
        ["晚安", "睡觉", "睡了", "困了", "做梦"],
        ["早安", "早上好", "起床", "醒醒"],
        ["吃饭", "开饭", "饿了", "好吃", "干饭"],
        ["谢谢", "感谢", "爱你谢谢"],
        ["对不起", "抱歉", "错了", "求原谅"],
        ["加油", "冲鸭", "努力", "你可以"],
        ["安慰", "摸摸", "心疼", "陪你", "别难过"],
        ["好的", "好呀", "可以", "收到", "没问题"],
        ["不要", "不行", "拒绝", "才不要"],
        ["期待", "等你", "快回来", "盼望"],
        ["约会", "见面", "一起玩", "出去玩"],
        ["回家", "到家", "回来了", "欢迎回来"],
        ["忙", "工作", "辛苦了", "休息"],
        ["累", "没力气", "躺平", "疲惫"],
        ["惊讶", "震惊", "天啊", "哇"],
        ["疑问", "什么", "为什么", "问号"],
        ["得意", "骄傲", "厉害", "真棒"],
        ["调皮", "吐舌", "搞怪", "坏笑"],
        ["偷笑", "嘿嘿", "暗中观察", "看戏"],
        ["拜托", "求求", "行不行", "答应我"],
        ["生日", "生日快乐", "蛋糕", "庆祝"],
        ["红包", "发红包", "钱钱", "发财"],
        ["喝水", "多喝水", "照顾自己"],
        ["亲爱的", "宝贝", "老婆", "老公"],
        ["在干嘛", "干嘛呢", "忙什么"],
        ["吃醋", "嫉妒", "酸了"],
        ["不理你", "走开", "再见", "拜拜"],
        ["点赞", "赞", "优秀", "同意"],
        ["发呆", "无聊", "等着", "看着你"]
    ]

    private func matchScore(_ sticker: InstalledSticker, terms: Set<String>, raw: String) -> Int {
        let requested = normalize(raw)
        if normalize(sticker.packTitle) == requested { return 120 }
        var best = 0
        for keyword in sticker.record.keywords {
            let candidate = normalize(keyword)
            guard !candidate.isEmpty else { continue }
            if candidate == requested { best = max(best, 100) }
            else if terms.contains(candidate) { best = max(best, 85) }
            else if candidate.count >= 2 && terms.contains(where: { $0.count >= 2 && (candidate.contains($0) || $0.contains(candidate)) }) {
                best = max(best, 55)
            }
        }
        return best
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.stickers.isEmpty {
                    VStack(spacing: 18) {
                        ContentUnavailableView("还没有表情包", systemImage: "face.smiling",
                            description: Text("导入 family.stickerpack 后即可离线使用。"))
                        if library.transferredPackAvailable {
                            Button {
                                library.importTransferredPack()
                            } label: {
                                Label("导入手机中的表情包", systemImage: "iphone.and.arrow.forward")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(library.importing)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("搜索：哈哈哈、爱你、晚安…", text: $query)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !query.isEmpty {
                                Button { query = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14).frame(height: 42)
                        .background(SpaceStyle.softSurface, in: RoundedRectangle(cornerRadius: 13))
                        .padding(.horizontal, 16).padding(.top, 10)
                        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("找到 \(filteredStickers.count) 个表情")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18).padding(.top, 6)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.categories, id: \.self) { category in
                                    categoryButton(category)
                                }
                            }.padding(.horizontal, 16).padding(.top, 10)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                packButton(Self.recentTitle, systemImage: "clock")
                                ForEach(visiblePackTitles, id: \.self) { title in
                                    packButton(title)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                        Divider()
                        ScrollView {
                            if filteredStickers.isEmpty {
                                ContentUnavailableView(query.isEmpty ? "这里还没有最近使用" : "没有匹配的表情",
                                    systemImage: query.isEmpty ? "clock" : "magnifyingglass",
                                    description: Text(query.isEmpty ? "发送过的表情会出现在这里。" : "换一个提示词试试。"))
                                    .padding(.top, 48)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 12)], spacing: 12) {
                            ForEach(filteredStickers) { sticker in
                                Button {
                                    if let onSend { library.markUsed(sticker, query: query); onSend(sticker); dismiss() }
                                    else { preview = sticker }
                                } label: {
                                    LocalStickerThumbnail(url: sticker.thumbnailURL)
                                    .frame(height: 82).frame(maxWidth: .infinity)
                                    .background(SpaceStyle.softSurface, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    EmptyView()
                                } preview: {
                                    StickerPeekPreview(sticker: sticker)
                                }
                            }
                            }
                        }.padding(16)
                        }
                    }
            }
            .navigationTitle("我的表情")
            .safeAreaInset(edge: .bottom) {
                if library.transferredPackAvailable && !library.stickers.isEmpty {
                    Button {
                        library.importTransferredPack()
                    } label: {
                        Label("重新导入手机中的表情包", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.importing)
                    .padding(.vertical, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .disabled(library.importing).accessibilityLabel("导入表情包")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [type, .zip]) { result in
                if case .success(let url) = result { library.importPack(url) }
            }
            .overlay { if library.importing { ProgressView("正在验证并导入…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .alert("表情包", isPresented: Binding(get: { library.status != nil }, set: { if !$0 { library.status = nil } })) {
                Button("好") { library.status = nil }
            } message: { Text(library.status ?? "") }
            .sheet(item: $preview) { sticker in StickerPreview(sticker: sticker) }
        }
    }

    @ViewBuilder private func packButton(_ title: String, systemImage: String? = nil) -> some View {
        let selected = selectedPack == title
        Button {
            selectedPack = selected ? nil : title
            query = ""
        } label: {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? SpaceStyle.accent : SpaceStyle.softSurface,
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func categoryButton(_ category: String) -> some View {
        let selected = selectedCategory == category
        Button {
            selectedCategory = category
            if let selectedPack, category != "全部", library.packCategories[selectedPack] != category {
                self.selectedPack = nil
            }
            query = ""
        } label: {
            Text(category).font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundStyle(selected ? SpaceStyle.accent : .secondary)
                .background(selected ? SpaceStyle.accent.opacity(0.12) : Color.clear, in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct LocalStickerThumbnail: View {
    let url: URL
    var body: some View {
        if let image = StickerThumbnailCache.image(at: url) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "face.smiling").foregroundStyle(.secondary)
        }
    }
}

private enum StickerThumbnailCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    static func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(image, forKey: key, cost: cost)
        return image
    }
}

private struct StickerPreview: View {
    let sticker: InstalledSticker
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            QuickLookSticker(url: sticker.mediaURL)
                .navigationTitle(sticker.packTitle).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

/// Native press-and-hold preview: no intermediary menu item and no second window.
private struct StickerPeekPreview: View {
    let sticker: InstalledSticker
    @State private var data: Data?

    var body: some View {
        Group {
            if let data {
                if sticker.record.mediaType == "image/gif" {
                    AnimatedStickerImage(data: data, cacheKey: "peek-\(sticker.id)", animate: true)
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: 220, height: 220)
        .padding(18)
        .background(SpaceStyle.surface)
        .task(id: sticker.id) {
            data = try? Data(contentsOf: sticker.mediaURL, options: .mappedIfSafe)
        }
        .accessibilityLabel("预览表情")
    }
}

private struct QuickLookSticker: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: NSURL
        init(url: URL) { item = url as NSURL }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
    }
}
#endif

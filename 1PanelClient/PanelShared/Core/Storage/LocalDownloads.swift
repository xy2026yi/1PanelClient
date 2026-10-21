//
//  LocalDownloads.swift
//  1PanelClient
//
//  下载/导出落盘统一入口：全部写入 Documents/<分类>/，同名自动加序号。
//  Documents 经 Info.plist UIFileSharingEnabled 暴露到「文件」App →
//  我的 iPhone/1PanelClient/<分类>/，用户在那里取用、移动或分享。
//  纯 Foundation（同时编入 App 与 Widget target，不得引入 UIKit）。
//

import Foundation

nonisolated enum LocalDownloads {
    /// 保存分类 = Documents 下的子文件夹名。固定英文，不随界面语言变化
    /// （否则切换语言会在「文件」App 里出现两套文件夹）
    enum Category: String, CaseIterable, Sendable {
        case backups      = "Backups"
        case certificates = "Certificates"
        case logs         = "Logs"
        case files        = "Files"
        case sshKeys      = "SSH Keys"
        case exports      = "Exports"
        case diagnostics  = "Diagnostics"
    }

    struct Saved: Sendable {
        let url: URL
        let category: Category

        var fileName: String { url.lastPathComponent }

        /// 「文件」App 内的相对路径："1PanelClient/Backups/site.tar.gz"
        var displayPath: String { "\(appFolderName)/\(category.rawValue)/\(fileName)" }

        /// 全部下载/导出入口共用的成功提示
        var successMessage: String { L10n.f("已保存到「文件」App：%@", displayPath) }
    }

    /// 「文件」App 中显示的 App 文件夹名（= 产品名，项目未设 CFBundleDisplayName）
    static let appFolderName = "1PanelClient"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 分类目录，不存在则创建。base 可注入供测试使用临时目录
    static func directory(for category: Category, base: URL = documentsDirectory) throws -> URL {
        let dir = base.appendingPathComponent(category.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 写入内存数据
    static func save(data: Data, fileName: String, category: Category,
                     base: URL = documentsDirectory) throws -> Saved {
        let url = try destination(fileName: fileName, category: category, base: base)
        try data.write(to: url, options: .atomic)
        return Saved(url: url, category: category)
    }

    /// 移入已落盘的临时文件（如 APIClient.downloadFile 产物）；任一步失败都清理临时文件
    static func move(tempFile: URL, fileName: String, category: Category,
                     base: URL = documentsDirectory) throws -> Saved {
        do {
            let url = try destination(fileName: fileName, category: category, base: base)
            try FileManager.default.moveItem(at: tempFile, to: url)
            return Saved(url: url, category: category)
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw error
        }
    }

    /// 复制已有本地文件，源文件保留（如 MetricKit 诊断数据）
    static func copy(file: URL, fileName: String, category: Category,
                     base: URL = documentsDirectory) throws -> Saved {
        let url = try destination(fileName: fileName, category: category, base: base)
        try FileManager.default.copyItem(at: file, to: url)
        return Saved(url: url, category: category)
    }

    private static func destination(fileName: String, category: Category, base: URL) throws -> URL {
        let dir = try directory(for: category, base: base)
        return dir.appendingPathComponent(uniqueFileName(sanitizedFileName(fileName), in: dir))
    }

    /// 本地文件系统合法名：只取最后一段路径（防服务端异常数据拼出目录穿越），
    /// 替换 iOS 非法字符；defaultExtension 非空且原名无该扩展名时补上
    static func sanitizedFileName(_ name: String, defaultExtension: String? = nil) -> String {
        var safe = (name as NSString).lastPathComponent
        for ch in ["/", ":", "\0"] where safe.contains(ch) {
            safe = safe.replacingOccurrences(of: ch, with: "_")
        }
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        if let ext = defaultExtension, !ext.isEmpty,
           !safe.lowercased().hasSuffix(".\(ext.lowercased())") {
            safe += ".\(ext)"
        }
        return safe
    }

    /// 目标目录下不冲突的文件名：同名时追加序号（"a.txt" → "a 1.txt"、"a 2.txt"）
    static func uniqueFileName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
    }
}

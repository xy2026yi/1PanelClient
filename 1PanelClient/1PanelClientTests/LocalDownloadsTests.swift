//
//  LocalDownloadsTests.swift
//  1PanelClientTests
//
//  下载/导出统一落盘工具：文件名合法化（防目录穿越 / 补扩展名）、
//  同名加序号、分类子目录自动创建、save/move/copy 三种来源与失败清理
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("本机下载落盘")
struct LocalDownloadsTests {
    /// 每个用例独立的临时根目录，结束后整目录删除
    private func makeBase() -> (URL, () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("localdownloads.tests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, { try? FileManager.default.removeItem(at: base) })
    }

    private func touch(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    }

    // MARK: - uniqueFileName

    @Test("无冲突原名返回")
    func uniqueNoConflict() {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        #expect(LocalDownloads.uniqueFileName("a.txt", in: base) == "a.txt")
    }

    @Test("冲突追加序号 1、2")
    func uniqueAppendsIndex() {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        touch(base.appendingPathComponent("a.txt"))
        #expect(LocalDownloads.uniqueFileName("a.txt", in: base) == "a 1.txt")
        touch(base.appendingPathComponent("a 1.txt"))
        #expect(LocalDownloads.uniqueFileName("a.txt", in: base) == "a 2.txt")
    }

    @Test("无扩展名直接在末尾加序号")
    func uniqueNoExtension() {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        touch(base.appendingPathComponent("README"))
        #expect(LocalDownloads.uniqueFileName("README", in: base) == "README 1")
    }

    @Test("多段扩展名只按最后一段处理（Finder 同款）")
    func uniqueMultiDot() {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        touch(base.appendingPathComponent("site.tar.gz"))
        #expect(LocalDownloads.uniqueFileName("site.tar.gz", in: base) == "site.tar 1.gz")
    }

    // MARK: - sanitizedFileName

    @Test("只取最后一段路径，防目录穿越")
    func sanitizeStripsPath() {
        #expect(LocalDownloads.sanitizedFileName("../../etc/passwd") == "passwd")
        #expect(LocalDownloads.sanitizedFileName("/var/log/nginx/access.log") == "access.log")
    }

    @Test("替换 iOS 非法字符 : 和 NUL")
    func sanitizeReplacesIllegal() {
        #expect(LocalDownloads.sanitizedFileName("a:b") == "a_b")
        #expect(LocalDownloads.sanitizedFileName("a\0b") == "a_b")
    }

    @Test("空名 / . / .. 兜底为 file")
    func sanitizeFallback() {
        #expect(LocalDownloads.sanitizedFileName("") == "file")
        #expect(LocalDownloads.sanitizedFileName(".") == "file")
        #expect(LocalDownloads.sanitizedFileName("..") == "file")
        #expect(LocalDownloads.sanitizedFileName("foo/..") == "file")
    }

    @Test("缺扩展名时补上，已有时不重复补（忽略大小写）")
    func sanitizeDefaultExtension() {
        #expect(LocalDownloads.sanitizedFileName("example.com", defaultExtension: "zip") == "example.com.zip")
        #expect(LocalDownloads.sanitizedFileName("site.zip", defaultExtension: "zip") == "site.zip")
        #expect(LocalDownloads.sanitizedFileName("site.ZIP", defaultExtension: "zip") == "site.ZIP")
        #expect(LocalDownloads.sanitizedFileName("plain", defaultExtension: nil) == "plain")
        #expect(LocalDownloads.sanitizedFileName("plain", defaultExtension: "") == "plain")
    }

    // MARK: - save

    @Test("save：自动建分类目录、写入内容、displayPath 形如 1PanelClient/<分类>/<名>")
    func saveCreatesCategoryDir() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        let saved = try LocalDownloads.save(
            data: Data("hello".utf8), fileName: "note.txt", category: .backups, base: base)

        #expect(saved.fileName == "note.txt")
        #expect(saved.category == .backups)
        #expect(saved.displayPath == "1PanelClient/Backups/note.txt")
        #expect(saved.url == base.appendingPathComponent("Backups").appendingPathComponent("note.txt"))
        #expect(try String(contentsOf: saved.url, encoding: .utf8) == "hello")
        #expect(saved.successMessage.contains("1PanelClient/Backups/note.txt"))
    }

    @Test("save：同名二次保存自动加序号")
    func saveUniquifies() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        let first = try LocalDownloads.save(data: Data(), fileName: "a.json", category: .exports, base: base)
        let second = try LocalDownloads.save(data: Data(), fileName: "a.json", category: .exports, base: base)
        #expect(first.fileName == "a.json")
        #expect(second.fileName == "a 1.json")
    }

    @Test("save：文件名带路径段时被合法化，不会逃出分类目录")
    func saveSanitizesTraversal() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        let saved = try LocalDownloads.save(
            data: Data(), fileName: "../../evil.txt", category: .logs, base: base)
        #expect(saved.fileName == "evil.txt")
        #expect(saved.url == base.appendingPathComponent("Logs").appendingPathComponent("evil.txt"))
        #expect(FileManager.default.fileExists(atPath: saved.url.path))
    }

    @Test("每个分类都能独立建目录")
    func allCategoriesCreateDirs() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        for category in LocalDownloads.Category.allCases {
            let dir = try LocalDownloads.directory(for: category, base: base)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
            #expect(dir.lastPathComponent == category.rawValue)
        }
    }

    // MARK: - move

    @Test("move：临时文件移入分类目录，原位置消失")
    func moveRelocatesTemp() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        let temp = base.appendingPathComponent("tmp-\(UUID().uuidString)")
        try Data("payload".utf8).write(to: temp)

        let saved = try LocalDownloads.move(tempFile: temp, fileName: "dump.sql", category: .files, base: base)

        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(saved.displayPath == "1PanelClient/Files/dump.sql")
        #expect(try String(contentsOf: saved.url, encoding: .utf8) == "payload")
    }

    @Test("move：目标目录无法创建时抛错并清理临时文件")
    func moveCleansTempOnFailure() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        // base 本身是个普通文件，在其下 createDirectory 必失败（ENOTDIR）
        let blocker = base.appendingPathComponent("blocked")
        touch(blocker)
        let temp = base.appendingPathComponent("tmp-\(UUID().uuidString)")
        try Data("payload".utf8).write(to: temp)

        #expect(throws: (any Error).self) {
            try LocalDownloads.move(tempFile: temp, fileName: "x.bin", category: .backups, base: blocker)
        }
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    // MARK: - copy

    @Test("copy：源文件保留，目标在分类目录内")
    func copyKeepsSource() throws {
        let (base, cleanup) = makeBase()
        defer { cleanup() }
        let source = base.appendingPathComponent("diagnostic-2026.json")
        try Data("{}".utf8).write(to: source)

        let saved = try LocalDownloads.copy(
            file: source, fileName: source.lastPathComponent, category: .diagnostics, base: base)

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(saved.displayPath == "1PanelClient/Diagnostics/diagnostic-2026.json")
        #expect(try String(contentsOf: saved.url, encoding: .utf8) == "{}")
    }
}

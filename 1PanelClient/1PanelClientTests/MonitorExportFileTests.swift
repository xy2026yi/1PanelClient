//
//  MonitorExportFileTests.swift
//  1PanelClientTests
//
//  监控导出文件生成测试：CSV 转义（BOM/CRLF/公式注入）、JSON 结构、
//  ZIP/XLSX 容器签名与条目、数值文本、文件命名（对齐网页端产物规则）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("监控导出文件生成")
struct MonitorExportFileTests {

    private static func sampleTable() -> MonitorExportTable {
        MonitorExportTable(
            name: "base",
            fields: ["time", "cpu", "memory"],
            headers: ["日期", "CPU (%)", "内存 (%)"],
            rows: [
                [.date(Date(timeIntervalSince1970: 1_766_000_000)), .number(5.5), .empty],
                [.text("a,b"), .text("=SUM(A1)"), .text("-异常")],
            ])
    }

    // MARK: CSV

    @Test("CSV 带 BOM 与 CRLF，表头在首行")
    func csvBasics() {
        let text = MonitorExportFileBuilder.csv(Self.sampleTable())
        #expect(text.hasPrefix("\u{FEFF}"))
        let lines = text.dropFirst().components(separatedBy: "\r\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "日期,CPU (%),内存 (%)")
    }

    @Test("CSV 转义：逗号/引号/换行加引号，公式注入前缀单引号，负数值不转义")
    func csvEscaping() {
        let text = MonitorExportFileBuilder.csv(Self.sampleTable())
        let lines = text.dropFirst().components(separatedBy: "\r\n")
        // 含逗号单元格加引号转义；=/- 开头非数值前置单引号防公式注入（文本行为第 3 行）
        #expect(lines[2].contains("\"a,b\""))
        #expect(lines[2].contains("'=SUM(A1)"))
        #expect(lines[2].contains("'-异常"))
    }

    @Test("纯数值即使以 - 开头也不加引号（可被公式引擎识别为数字）")
    func csvNegativeNumber() {
        let table = MonitorExportTable(name: "t", fields: ["v"], headers: ["v"],
                                       rows: [[.number(-12.5)]])
        let text = MonitorExportFileBuilder.csv(table).dropFirst()
        #expect(text == "v\r\n-12.5")
    }

    @Test("引号内双引号翻倍转义")
    func csvQuoteEscape() {
        let table = MonitorExportTable(name: "t", fields: ["v"], headers: ["v"],
                                       rows: [[.text("说\"你好\",好的")]])
        let text = MonitorExportFileBuilder.csv(table).dropFirst()
        #expect(text == "v\r\n\"说\"\"你好\"\",好的\"")
    }

    // MARK: JSON

    @Test("JSON 按表名分组，日期转 RFC3339 字符串、缺失字段为 null")
    func jsonStructure() throws {
        let json = MonitorExportFileBuilder.jsonDocument([Self.sampleTable()])
        let data = try #require(json.data(using: .utf8))
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(parsed["base"] as? [[String: Any]])
        #expect(rows.count == 2)
        let first = try #require(rows.first)
        let time = try #require(first["time"] as? String)
        // RFC3339：可再解析回同一时刻（本地时区带偏移）
        let parsedBack = MonitorExportFileBuilder.rfc3339.date(from: time)
        #expect(parsedBack == Date(timeIntervalSince1970: 1_766_000_000))
        #expect(first["cpu"] as? Double == 5.5)
        #expect(first["memory"] is NSNull)
    }

    // MARK: ZIP / XLSX 容器

    @Test("ZIP 容器：本地头签名 + EOCD 记录条目数")
    func zipStructure() {
        let data = MonitorExportFileBuilder.zipArchive([
            MonitorExportFileBuilder.ZipEntry(name: "monitor-base.csv", content: Data("a,b".utf8)),
            MonitorExportFileBuilder.ZipEntry(name: "monitor-io.csv", content: Data("c".utf8)),
        ])
        #expect(data.count > 0)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))            // PK\x03\x04
        // EOCD 在尾部 22 字节：签名 PK\x05\x06 + 总条目数（低位在前）
        let eocd = data.suffix(22)
        #expect(eocd.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        #expect(eocd.dropFirst(8).prefix(2) == Data([0x02, 0x00]))
        // 条目名以 UTF-8 原文出现在本地头
        #expect(String(decoding: data, as: UTF8.self).contains("monitor-base.csv"))
    }

    @Test("CRC32 标准校验向量")
    func crc32Vector() {
        #expect(MonitorExportFileBuilder.crc32(Data("123456789".utf8)) == 0xCBF43926)
        #expect(MonitorExportFileBuilder.crc32(Data()) == 0)
    }

    @Test("XLSX 为合法 ZIP，包含工作簿/样式/逐表工作表部件")
    func xlsxStructure() {
        let file = MonitorExportFileBuilder.build(
            tables: [Self.sampleTable(),
                     MonitorExportTable(name: "io", fields: ["time"], headers: ["日期"],
                                        rows: [[.number(1)]])],
            format: .xlsx)
        #expect(file.fileName.hasSuffix(".xlsx"))
        #expect(file.truncatedTables.isEmpty)
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(text.contains("[Content_Types].xml"))
        #expect(text.contains("xl/workbook.xml"))
        #expect(text.contains("xl/styles.xml"))
        #expect(text.contains("xl/worksheets/sheet1.xml"))
        #expect(text.contains("xl/worksheets/sheet2.xml"))
        #expect(text.contains("<sheet name=\"base\""))
        #expect(text.contains("<sheet name=\"io\""))
        // 日期单元格走 s="1" 样式（yyyy-mm-dd hh:mm:ss）
        #expect(text.contains("s=\"1\""))
    }

    // MARK: 命名与格式

    @Test("文件命名对齐网页端：单表 CSV 带表名、多表 CSV 打包 zip、JSON/xlsx 直扩展名")
    func fileNaming() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 23
        components.hour = 11; components.minute = 47; components.second = 3
        let date = try #require(Calendar.current.date(from: components))
        let single = MonitorExportFileBuilder.build(tables: [Self.sampleTable()], format: .csv, date: date)
        #expect(single.fileName == "1panel-monitor-20261023114703-base.csv")

        let multi = MonitorExportFileBuilder.build(
            tables: [Self.sampleTable(),
                     MonitorExportTable(name: "network", fields: ["up"], headers: ["上行"],
                                        rows: [[.number(1)]])],
            format: .csv, date: date)
        #expect(multi.fileName == "1panel-monitor-20261023114703.zip")

        let json = MonitorExportFileBuilder.build(tables: [Self.sampleTable()], format: .json, date: date)
        #expect(json.fileName == "1panel-monitor-20261023114703.json")

        let xlsx = MonitorExportFileBuilder.build(tables: [Self.sampleTable()], format: .xlsx, date: date)
        #expect(xlsx.fileName == "1panel-monitor-20261023114703.xlsx")
    }

    @Test("数值文本最小表示（对齐 JS String(number)）")
    func numberText() {
        #expect(MonitorExportFileBuilder.numberText(5) == "5")
        #expect(MonitorExportFileBuilder.numberText(-12.5) == "-12.5")
        #expect(MonitorExportFileBuilder.numberText(5.025125628139443) == "5.025125628139443")
    }
}

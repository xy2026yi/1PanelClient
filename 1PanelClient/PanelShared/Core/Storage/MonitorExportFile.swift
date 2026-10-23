//
//  MonitorExportFile.swift
//  1PanelClient
//
//  监控导出文件生成（v2.4.0，对齐网页端 frontend/src/utils/monitor-export.ts）：
//  数据由客户端从 /hosts/monitor/search 拉取后在本地组表落盘，
//  支持 CSV（单表单文件 / 多表打包 ZIP）、JSON（单文件）、Excel（xlsx 多工作表）。
//  纯 Foundation（同 LocalDownloads，编入 App 与 Widget target，不引入 UIKit）。
//

import Foundation

// MARK: - 表模型

/// 单元格值：日期（RFC3339 / xlsx 日期序列导出）、数值、文本、空（JSON null / CSV 空串）
enum MonitorExportCell: Equatable, Sendable {
    case date(Date)
    case number(Double)
    case text(String)
    case empty
}

/// 一张导出表：name 为表名（base/io/network，同时用作 CSV 文件名与 xlsx 工作表名），
/// fields 为字段名（JSON 键），headers 为本地化列头，rows 与 headers 按列对齐
struct MonitorExportTable: Equatable, Sendable {
    let name: String
    let fields: [String]
    let headers: [String]
    /// var 供超 Excel 行数上限时截断（build 内局部副本）
    var rows: [[MonitorExportCell]]
}

/// 导出格式（对齐网页端导出表单三选）
enum MonitorExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case json
    case xlsx

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .json: return "JSON"
        case .xlsx: return "Excel (xlsx)"
        }
    }
}

/// 生成产物：落盘文件名 + 文件内容 + 因 Excel 行数上限被截断的表名
struct MonitorExportFile: Sendable {
    let fileName: String
    let data: Data
    let truncatedTables: [String]
}

/// 导出文件生成错误
enum MonitorExportError: LocalizedError {
    /// 单表内容超出 ZIP 32 位长度上限（≥4GiB，打包器无 ZIP64 扩展）
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge:
            return L10n.t("导出数据过大（单表超出 4GiB），请缩短时间范围后重试")
        }
    }
}

// MARK: - 生成入口

nonisolated enum MonitorExportFileBuilder {

    /// Excel 单工作表数据行上限（含表头共 1,048,576 行）
    static let xlsxMaxDataRows = 1_048_575

    /// 按格式生成导出文件。文件名对齐网页端：1panel-monitor-yyyyMMddHHmmss[.扩展名]，
    /// 单表 CSV 额外带表名后缀（-base/-io/-network）。
    /// 超出 ZIP 32 位长度上限（单表 ≥4GiB）抛 archiveTooLarge 而非生成损坏文件
    static func build(tables: [MonitorExportTable], format: MonitorExportFormat,
                      date: Date = Date()) throws -> MonitorExportFile {
        let stamp = fileNameStampText(date)
        let baseName = "1panel-monitor-\(stamp)"
        switch format {
        case .json:
            return MonitorExportFile(fileName: baseName + ".json",
                                     data: Data(jsonDocument(tables).utf8),
                                     truncatedTables: [])
        case .xlsx:
            var limited = tables
            var truncated: [String] = []
            for i in limited.indices where limited[i].rows.count > xlsxMaxDataRows {
                truncated.append(limited[i].name)
                limited[i].rows = Array(limited[i].rows.prefix(xlsxMaxDataRows))
            }
            return MonitorExportFile(fileName: baseName + ".xlsx",
                                     data: try zipArchive(xlsxEntries(limited)),
                                     truncatedTables: truncated)
        case .csv:
            if tables.count == 1, let only = tables.first {
                return MonitorExportFile(fileName: "\(baseName)-\(only.name).csv",
                                         data: Data(csv(only).utf8),
                                         truncatedTables: [])
            }
            let bundle = try zipArchive(tables.map {
                ZipEntry(name: "monitor-\($0.name).csv", content: Data(csv($0).utf8))
            })
            return MonitorExportFile(fileName: baseName + ".zip", data: bundle, truncatedTables: [])
        }
    }

    // MARK: CSV

    /// CSV 文本：UTF-8 BOM + CRLF 行尾（Excel 打开兼容）；
    /// 含 ", 换行的单元格加双引号转义；以 = + - @ 或控制符开头且非纯数值的单元格
    /// 前置单引号，防公式注入（对齐网页端 escape 实现）
    static func csv(_ table: MonitorExportTable) -> String {
        var lines = [table.headers.map(escapeCSV).joined(separator: ",")]
        for row in table.rows {
            lines.append(row.map { escapeCSV(cellText($0)) }.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    /// 单元格文本：日期 RFC3339、数值最小表示、空 → ""
    private static func cellText(_ cell: MonitorExportCell) -> String {
        switch cell {
        case .date(let date): return rfc3339.string(from: date)
        case .number(let value): return numberText(value)
        case .text(let string): return string
        case .empty: return ""
        }
    }

    private static func escapeCSV(_ value: String) -> String {
        var sanitized = value
        if let first = sanitized.first,
           ["=", "+", "-", "@", "\t"].contains(first),
           Double(sanitized) == nil {
            sanitized = "'" + sanitized
        }
        if sanitized.contains(where: { "\",\n\r".contains($0) }) {
            sanitized = "\"" + sanitized.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return sanitized
    }

    // MARK: JSON

    /// JSON 文档：{表名: [{字段: 值}]}；日期转 RFC3339 字符串、空为 null、
    /// 2 空格缩进 + 键排序（对齐 JSON.stringify(data, null, 2) 的网页端产物）
    static func jsonDocument(_ tables: [MonitorExportTable]) -> String {
        var data: [String: Any] = [:]
        for table in tables {
            data[table.name] = table.rows.map { row in
                var item: [String: Any] = [:]
                for (i, field) in table.fields.enumerated() {
                    switch row[i] {
                    case .date(let date): item[field] = rfc3339.string(from: date)
                    case .number(let value): item[field] = value
                    case .text(let string): item[field] = string
                    case .empty: item[field] = NSNull()
                    }
                }
                return item
            }
        }
        guard JSONSerialization.isValidJSONObject(data),
              let output = try? JSONSerialization.data(withJSONObject: data,
                                                       options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: XLSX

    /// xlsx 为 ZIP 包内的 OOXML 部件集合（工作簿/样式/逐表工作表），
    /// 结构对齐网页端 buildMonitorXLSX：s=1 单元格样式为 yyyy-mm-dd hh:mm:ss 日期格式。
    /// 各部件先拼成显式 String 常量再转 Data——长链拼接会让类型检查超时
    private static func xlsxEntries(_ tables: [MonitorExportTable]) -> [ZipEntry] {
        let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let sheetType = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
        let worksheetRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"

        let sheets: String = tables.enumerated().map { i, table in
            "<sheet name=\"\(xmlEscape(table.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        let overrides: String = tables.indices.map { i in
            "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"\(sheetType)\"/>"
        }.joined()
        let sheetRels: String = tables.indices.map { i in
            "<Relationship Id=\"rId\(i + 1)\" Type=\"\(worksheetRel)\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }.joined()

        let contentTypes: String =
            xmlHead +
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
            "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" +
            overrides + "</Types>"

        let rootRels: String =
            xmlHead +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>" +
            "</Relationships>"

        let workbook: String =
            xmlHead +
            "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" +
            "<sheets>\(sheets)</sheets></workbook>"

        let workbookRels: String =
            xmlHead +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            sheetRels +
            "<Relationship Id=\"rId\(tables.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" +
            "</Relationships>"

        let styles: String =
            xmlHead +
            "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" +
            "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd hh:mm:ss\"/></numFmts>" +
            "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>" +
            "<fills count=\"2\"><fill><patternFill/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>" +
            "<borders count=\"1\"><border/></borders>" +
            "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
            "<cellXfs count=\"2\">" +
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" +
            "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
            "</cellXfs>" +
            "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>" +
            "</styleSheet>"

        var entries = [
            ZipEntry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            ZipEntry(name: "_rels/.rels", content: Data(rootRels.utf8)),
            ZipEntry(name: "xl/workbook.xml", content: Data(workbook.utf8)),
            ZipEntry(name: "xl/_rels/workbook.xml.rels", content: Data(workbookRels.utf8)),
            ZipEntry(name: "xl/styles.xml", content: Data(styles.utf8)),
        ]
        for (i, table) in tables.enumerated() {
            entries.append(ZipEntry(name: "xl/worksheets/sheet\(i + 1).xml",
                                    content: Data(xlsxSheet(table).utf8)))
        }
        return entries
    }

    /// 工作表 XML：首行表头 inlineStr；数据行日期用 s="1" 日期序列、数值裸值、其余 inlineStr
    private static func xlsxSheet(_ table: MonitorExportTable) -> String {
        var parts = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>",
        ]
        parts.append(rowXML(1, table.headers.map { .text($0) }, isHeader: true))
        for (i, row) in table.rows.enumerated() {
            parts.append(rowXML(i + 2, row, isHeader: false))
        }
        parts.append("</sheetData></worksheet>")
        return parts.joined()
    }

    private static func rowXML(_ index: Int, _ cells: [MonitorExportCell], isHeader: Bool) -> String {
        var xml = "<row r=\"\(index)\">"
        for (i, cell) in cells.enumerated() {
            let ref = "\(xlsxColumnName(i))\(index)"
            switch cell {
            case .date(let date) where !isHeader:
                // Excel 序列值按本地墙钟换算，显示与面板 UI 一致（对齐网页端）
                let serial = (date.timeIntervalSince1970
                              + Double(TimeZone.current.secondsFromGMT(for: date))) / 86400 + 25569
                xml += "<c r=\"\(ref)\" s=\"1\"><v>\(numberText(serial))</v></c>"
            case .number(let value) where !isHeader:
                xml += "<c r=\"\(ref)\"><v>\(numberText(value))</v></c>"
            default:
                xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(xmlEscape(cellText(cell)))</t></is></c>"
            }
        }
        return xml + "</row>"
    }

    /// 列号 → 列名（0 → A、25 → Z、26 → AA）
    private static func xlsxColumnName(_ index: Int) -> String {
        var name = ""
        var n = index
        while true {
            name = String(UnicodeScalar(65 + n % 26)!) + name
            n = n / 26 - 1
            if n < 0 { return name }
        }
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: ZIP（仅 store，不压缩）

    struct ZipEntry: Sendable {
        let name: String
        let content: Data
    }

    /// 最小 ZIP 打包器（store 方式）：本地文件头 + 中央目录 + EOCD，
    /// CRC32 校验必需；条目名按 UTF-8（GPB 0x0800）。
    /// 无 ZIP64：单条目或累计偏移超 UInt32.max 抛错（此前 clamp 会静默产出损坏包、
    /// 偏移累加会直接越界崩溃）
    static func zipArchive(_ entries: [ZipEntry]) throws -> Data {
        var chunks: [Data] = []
        var central: [Data] = []
        var offset: UInt32 = 0
        let dos = dosDateTime(Date())

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.content)
            guard entry.content.count <= UInt32.max else { throw MonitorExportError.archiveTooLarge }
            let size = UInt32(entry.content.count)
            let entryLength = 30 + nameBytes.count + entry.content.count
            guard UInt32(entryLength) <= UInt32.max - offset else { throw MonitorExportError.archiveTooLarge }

            var local = Data(count: 30)
            local.withUnsafeMutableBytes { ptr in
                let v = ptr.bindMemory(to: UInt8.self)
                writeU32(v, 0, 0x04034B50)
                writeU16(v, 4, 20)            // version needed
                writeU16(v, 6, 0x0800)        // UTF-8 names
                writeU16(v, 8, 0)             // method: store
                writeU16(v, 10, dos.time)
                writeU16(v, 12, dos.day)
                writeU32(v, 14, crc)
                writeU32(v, 18, size)
                writeU32(v, 22, size)
                writeU16(v, 26, UInt16(nameBytes.count))
                writeU16(v, 28, 0)            // extra length
            }
            chunks.append(local)
            chunks.append(nameBytes)
            chunks.append(entry.content)

            var header = Data(count: 46)
            header.withUnsafeMutableBytes { ptr in
                let v = ptr.bindMemory(to: UInt8.self)
                writeU32(v, 0, 0x02014B50)
                writeU16(v, 4, 20)            // version made by
                writeU16(v, 6, 20)            // version needed
                writeU16(v, 8, 0x0800)
                writeU16(v, 10, 0)
                writeU16(v, 12, dos.time)
                writeU16(v, 14, dos.day)
                writeU32(v, 16, crc)
                writeU32(v, 20, size)
                writeU32(v, 24, size)
                writeU16(v, 28, UInt16(nameBytes.count))
                writeU32(v, 42, offset)
            }
            central.append(header)
            central.append(nameBytes)
            offset += UInt32(entryLength)
        }

        var centralSize: UInt32 = 0
        for chunk in central { centralSize += UInt32(chunk.count) }
        var end = Data(count: 22)
        end.withUnsafeMutableBytes { ptr in
            let v = ptr.bindMemory(to: UInt8.self)
            writeU32(v, 0, 0x06054B50)
            writeU16(v, 8, UInt16(entries.count))
            writeU16(v, 10, UInt16(entries.count))
            writeU32(v, 12, centralSize)
            writeU32(v, 16, offset)
        }

        var result = Data()
        result.reserveCapacity(Int(offset) + Int(centralSize) + 22)
        for chunk in chunks + central { result.append(chunk) }
        result.append(end)
        return result
    }

    private static func writeU16(_ buffer: UnsafeMutableBufferPointer<UInt8>, _ i: Int, _ v: UInt16) {
        buffer[i] = UInt8(v & 0xFF)
        buffer[i + 1] = UInt8(v >> 8)
    }

    private static func writeU32(_ buffer: UnsafeMutableBufferPointer<UInt8>, _ i: Int, _ v: UInt32) {
        buffer[i] = UInt8(v & 0xFF)
        buffer[i + 1] = UInt8((v >> 8) & 0xFF)
        buffer[i + 2] = UInt8((v >> 16) & 0xFF)
        buffer[i + 3] = UInt8(v >> 24)
    }

    /// ZIP 时间戳（DOS 格式，本地时区；秒按 2 秒粒度）
    private static func dosDateTime(_ date: Date) -> (time: UInt16, day: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16(((c.hour ?? 0) & 0x1F) << 11)
            | UInt16(((c.minute ?? 0) & 0x3F) << 5)
            | UInt16(((c.second ?? 0) >> 1) & 0x1F)
        let day = UInt16((((c.year ?? 1980) - 1980) & 0x7F) << 9)
            | UInt16(((c.month ?? 1) & 0xF) << 5)
            | UInt16((c.day ?? 1) & 0x1F)
        return (time, day)
    }

    /// 标准 CRC32（ZIP 校验用）
    static func crc32(_ data: Data) -> UInt32 {
        var c = ~UInt32(0)
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return ~c
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    // MARK: 文本表示

    /// 数值最小文本（与 JS String(number) 对齐：整数值不带小数点）
    static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return String(Double(value).description) }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return value.description
    }

    /// RFC3339 本地时间带偏移（对齐网页端 dateFormatRFC3339：导出时间戳跨夏令时无歧义）。
    /// ISO8601DateFormatter 按 Foundation 文档线程安全，nonisolated(unsafe) 仅为通过并发检查
    nonisolated(unsafe) static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    /// 文件名时间戳 yyyyMMddHHmmss（对齐网页端 dateFormatForName）；
    /// DateFormatter 非线程安全，按次创建不做共享
    static func fileNameStampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}

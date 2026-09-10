//
//  DiskModelsTests.swift
//  1PanelClientTests
//
//  磁盘管理模型与请求编解码验证：
//  向量取自网页端抓包（logs/SSH服务管理.md）与 1Panel 源码 response/disk.go
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("磁盘管理模型")
struct DiskModelsTests {
    @Test("DisksResponse：hosts/disks 总览解码（含系统盘分区与未分区盘）")
    func decodeDisksOverview() throws {
        let json = """
        {"disks":null,
         "unpartitionedDisks":[{"device":"sdb","size":"1G","model":"1Panel-2 SSD","diskType":"SSD",
           "isRemovable":false,"isSystem":false,"filesystem":"","used":"","avail":"","usePercent":0,
           "mountPoint":"","isMounted":false,"serial":"5DZV46V6DAQ47DZ0K478"}],
         "systemDisks":[{"device":"sda","size":"64G","model":"1Panel-0 SSD","diskType":"SSD",
           "isRemovable":false,"isSystem":true,"filesystem":"","used":"","avail":"","usePercent":0,
           "mountPoint":"","isMounted":false,"serial":"XWQY3ES94TK43F7SC37Q",
           "partitions":[
             {"device":"/dev/sda2","size":"977M","model":"","diskType":"SSD","isRemovable":false,
              "isSystem":true,"filesystem":"vfat","used":"9.6M","avail":"968M","usePercent":1,
              "mountPoint":"/boot/efi","isMounted":true,"serial":""},
             {"device":"/dev/sda4","size":"932M","model":"","diskType":"SSD","isRemovable":false,
              "isSystem":false,"filesystem":"swap","used":"0","avail":"932M","usePercent":0,
              "mountPoint":"[SWAP]","isMounted":true,"serial":""}]}],
         "totalDisks":2,"totalCapacity":69793218560}
        """
        let resp = try JSONDecoder().decode(DisksResponse.self, from: Data(json.utf8))
        #expect(resp.disks == nil)
        #expect(resp.totalDisks == 2)
        #expect(resp.totalCapacity == 69793218560)

        let unpartitioned = try #require(resp.unpartitionedDisks)
        #expect(unpartitioned.count == 1)
        #expect(unpartitioned[0].device == "sdb")
        #expect(unpartitioned[0].shortDevice == "sdb")

        let systemDisk = try #require(resp.systemDisks?.first)
        #expect(systemDisk.shortDevice == "sda")
        let partitions = try #require(systemDisk.partitions)
        #expect(partitions.count == 2)
        #expect(partitions[0].shortDevice == "sda2")
        #expect(partitions[0].mountPoint == "/boot/efi")
        #expect(partitions[1].isSwap == true)
        #expect(partitions[1].isMounted == true)
    }

    @Test("DiskPartitionRequest：立即分区（文件系统二选一 + 双开关默认开）")
    func encodePartition() throws {
        let req = DiskPartitionRequest(
            device: "sdb", filesystem: "ext4",
            autoMount: true, noFail: true, mountPoint: "/1G"
        )
        let dict = try encodeToDict(req)
        #expect(dict["device"] as? String == "sdb")
        #expect(dict["filesystem"] as? String == "ext4")
        #expect(dict["autoMount"] as? Bool == true)
        #expect(dict["noFail"] as? Bool == true)
        #expect(dict["mountPoint"] as? String == "/1G")
        #expect(dict["label"] as? String == "")
    }

    @Test("DiskMountRequest：挂载用分区设备全名，文件系统沿用分区格式")
    func encodeMount() throws {
        let req = DiskMountRequest(
            device: "/dev/sdb1", mountPoint: "/1G",
            filesystem: "ext4", autoMount: true, noFail: true
        )
        let dict = try encodeToDict(req)
        #expect(dict["device"] as? String == "/dev/sdb1")
        #expect(dict["filesystem"] as? String == "ext4")
        #expect(dict["noFail"] as? Bool == true)
    }

    @Test("DiskUnmountRequest：按挂载点取消挂载")
    func encodeUnmount() throws {
        let dict = try encodeToDict(DiskUnmountRequest(mountPoint: "/1G"))
        #expect(dict["mountPoint"] as? String == "/1G")
    }

    private func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }
}

//
//  KVMModelsTests.swift
//  1PanelClientTests
//
//  KVM 虚拟机管理模型测试：环境检测 / 虚拟机与资源解码（抓包样本）、
//  电源操作可用性矩阵、监控采样求差（CPU% 与速率）、创建·编辑请求编码形状
//  （模版启动 vs 普通）、快照命名、资源更新单字段提交、健康检查解码、
//  详情 checkDisks 可扩容判定与磁盘扩容请求形状
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("KVM 虚拟机管理模型")
struct KVMModelsTests {

    // MARK: 环境检测

    @Test("environment 抓包样本：未就绪 / 就绪判定")
    func decodeEnvironment() throws {
        let notReady = """
        {"arch":"amd64","archSupported":true,"ready":false,"helperExist":true,"helperMessage":"",
         "kvmExist":false,"kvmMessage":"stat /dev/kvm: no such file or directory",
         "libvirtExist":false,"libvirtActive":false,
         "libvirtMessage":"virError(Code=1, Domain=0, Message='Failed to open libvirt.so.0')",
         "storageExist":false,"storageMessage":"stat /var/lib/libvirt/images: no such file or directory"}
        """
        let env = try JSONDecoder().decode(KVMEnvironment.self, from: Data(notReady.utf8))
        #expect(!env.isReady)
        #expect(env.archSupported == true)
        // 门控行判定：libvirt 需存在且运行、kvm 看 kvmExist、storage 看 storageExist
        #expect(!(env.libvirtExist == true && env.libvirtActive == true))
        #expect(env.kvmExist == false)
        #expect(env.storageExist == false)
        #expect(env.storageMessage?.contains("libvirt/images") == true)

        let ready = """
        {"arch":"amd64","archSupported":true,"ready":true,"helperExist":true,"helperMessage":"",
         "kvmExist":true,"kvmMessage":"/dev/kvm","libvirtExist":true,"libvirtActive":true,
         "libvirtMessage":"","storageExist":true,"storageMessage":"/var/lib/libvirt/images"}
        """
        let readyEnv = try JSONDecoder().decode(KVMEnvironment.self, from: Data(ready.utf8))
        #expect(readyEnv.isReady)
        #expect(readyEnv.libvirtExist == true && readyEnv.libvirtActive == true)
        #expect(readyEnv.kvmExist == true)
        #expect(readyEnv.storageExist == true)
    }

    // MARK: 虚拟机解码与状态

    @Test("search 抓包样本解码：running 虚拟机含磁盘 / 网卡 / 图形控制台")
    func decodeVirtualMachine() throws {
        let json = """
        {"id":1,"name":"test","uuid":"b9a42186-982f-4764-93fc-2912ec3015e9","cpu":1,"memory":1024,
         "diskSize":5,"diskBus":"virtio","diskPath":"/var/lib/libvirt/images/test.qcow2",
         "storagePool":"default","isoPaths":["/home/ios/alpine-virt-3.21.3-x86_64.iso"],
         "imagePath":"","network":"default","bootOrder":"hd,cdrom","autoStart":false,
         "status":"running",
         "disks":[{"capacity":0,"format":"qcow2","readOnly":false,"shareable":false,
                   "resizeBlocked":"","device":"disk","type":"file",
                   "source":"/var/lib/libvirt/images/test.qcow2","target":"vda","bus":"virtio"},
                  {"capacity":0,"format":"raw","readOnly":true,"shareable":false,
                   "resizeBlocked":"","device":"cdrom","type":"file",
                   "source":"/home/ios/alpine-virt-3.21.3-x86_64.iso","target":"sda","bus":"sata"}],
         "interfaces":[{"type":"network","source":"default","model":"virtio",
                        "mac":"52:54:00:ec:36:51","ip":""}],
         "graphics":{"type":"vnc","port":"5900","listen":"127.0.0.1"},
         "taskID":"c9896abc-4f3d-4569-8ebb-e4c73cbf9c63",
         "createTaskID":"c9896abc-4f3d-4569-8ebb-e4c73cbf9c63","description":""}
        """
        let vm = try JSONDecoder().decode(KVMVirtualMachine.self, from: Data(json.utf8))
        #expect(vm.displayName == "test")
        #expect(vm.isRunning)
        #expect(!vm.isShutOff)
        #expect(vm.disks?.count == 2)
        #expect(vm.disks?[1].readOnly == true)
        #expect(vm.interfaces?.first?.mac == "52:54:00:ec:36:51")
        #expect(vm.graphics?.port == "5900")
        #expect(vm.bootOrder == "hd,cdrom")
    }

    @Test("电源操作可用性矩阵：按状态给出可用操作")
    func operateAvailability() throws {
        func make(_ status: String) -> KVMVirtualMachine {
            try! JSONDecoder().decode(KVMVirtualMachine.self,
                                      from: Data(#"{"id":1,"name":"a","status":"\#(status)"}"#.utf8))
        }
        #expect(KVMOperate.available(for: make("running")).map(\.rawValue)
                == ["shutdown", "reboot", "suspend", "destroy"])
        #expect(KVMOperate.available(for: make("shut off")).map(\.rawValue) == ["start"])
        #expect(KVMOperate.available(for: make("paused")).map(\.rawValue) == ["resume", "destroy"])
        #expect(KVMOperate.available(for: make("crashed")).contains(.start))
        // shut off 大小写变体（libvirt 部分版本回 shutoff）
        #expect(make("Shut Off").isShutOff)
        #expect(make("pmsuspended").isPaused)
    }

    // MARK: 监控采样求差

    @Test("stats 解码与速率推导：CPU% / 磁盘网络速率由相邻采样求差")
    func statsRates() throws {
        let currentJSON = """
        {"name":"test","status":"running","timestamp":1792722447658,"cpuTime":4987876000,"vcpu":1,
         "memory":{"availableKiB":995892,"unusedKiB":938908,"usableKiB":868520,
                   "rssKiB":259912,"actualKiB":1048576},
         "disk":{"readBytes":5296640,"writeBytes":0,"readReqs":218,"writeReqs":0},
         "network":{"rxBytes":90,"txBytes":0,"rxPackets":1,"txPackets":0}}
        """
        let current = try JSONDecoder().decode(KVMStats.self, from: Data(currentJSON.utf8))
        #expect(current.vcpu == 1)
        // 内存：已用 = actual - unused = 109668 KiB（≈10.46%）
        let expectedUsedKiB: Int64 = 109_668   // 1_048_576 - 938_908
        #expect(current.memory?.usedKiB == expectedUsedKiB)
        let usedPercent = current.memory?.usedPercent ?? 0
        #expect(usedPercent > 10 && usedPercent < 11)

        // 3 秒后的第二次采样：cpuTime +1.5e9 ns → 单核 50%；磁盘读 +3MB → 1MB/s
        let next = KVMStats(
            name: "test", status: "running",
            timestamp: current.timestamp! + 3000,
            cpuTime: current.cpuTime! + 1_500_000_000, vcpu: 1,
            memory: current.memory,
            disk: KVMDiskStats(readBytes: current.disk!.readBytes! + 3 * 1024 * 1024,
                               writeBytes: 0, readReqs: 220, writeReqs: 0),
            network: KVMNetworkStats(rxBytes: 90, txBytes: 0, rxPackets: 1, txPackets: 0))
        #expect(abs((KVMStats.cpuPercent(previous: current, current: next) ?? 0) - 50) < 0.001)
        let rate = KVMStats.rate(previous: (current.disk?.readBytes, current.timestamp),
                                 current: (next.disk?.readBytes, next.timestamp))
        #expect(abs((rate ?? 0) - 1024 * 1024) < 1)

        // 首个采样无前值 / 计数回绕 → nil
        #expect(KVMStats.cpuPercent(previous: nil, current: next) == nil)
        #expect(KVMStats.rate(previous: (100, 1000), current: (90, 2000)) == nil)
    }

    // MARK: 创建 / 编辑请求编码

    @Test("创建请求形状对齐抓包：普通创建 bootOrder=hd,cdrom 无 templateID")
    func encodeCreateRequest() throws {
        let request = KVMCreateRequest(
            name: "test", cpu: 1, memory: 1024, diskSize: 5, osType: "linux", diskBus: "virtio",
            storagePool: "default",
            isoPaths: ["/home/ios/alpine-virt-3.21.3-x86_64.iso"],
            network: "default", bootOrder: "hd,cdrom",
            startAfterCreate: true, autoStart: false, description: "",
            taskID: "c9896abc-4f3d-4569-8ebb-e4c73cbf9c63")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(obj["name"] as? String == "test")
        #expect(obj["templateID"] == nil)
        #expect(obj["isoPaths"] as? [String] == ["/home/ios/alpine-virt-3.21.3-x86_64.iso"])
        #expect(obj["bootOrder"] as? String == "hd,cdrom")
        #expect(obj["startAfterCreate"] as? Bool == true)
        #expect(obj["diskPath"] as? String == "")
    }

    @Test("从模版启动创建：携 templateID、isoPaths 空数组、bootOrder=hd")
    func encodeTemplateCreate() throws {
        let request = KVMCreateRequest(
            name: "test", cpu: 1, memory: 1024, diskSize: 5, osType: "linux", diskBus: "virtio",
            templateID: 1,
            storagePool: "default",
            isoPaths: [],
            network: "default", bootOrder: "hd",
            startAfterCreate: true, autoStart: false, description: "",
            taskID: "9d03e6fd-2752-4c24-a51f-34c4a6769a42")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(obj["templateID"] as? Int == 1)
        #expect(obj["bootOrder"] as? String == "hd")
        #expect(obj["isoPaths"] as? [String] == [])
        #expect(obj["startAfterCreate"] as? Bool == true)
    }

    @Test("编辑请求仅含更新字段（名称不可改，无磁盘相关键）")
    func encodeUpdateRequest() throws {
        let request = KVMUpdateRequest(
            taskID: "21249e95-6fa3-47af-9212-b42fa0d0ad62",
            name: "test1", cpu: 1, memory: 1024,
            isoPaths: ["/home/ios/alpine-virt-3.21.3-x86_64.iso"],
            network: "default", bootOrder: "hd,cdrom",
            autoStart: false, description: "")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(obj.count == 9)
        #expect(obj["diskBus"] == nil)
        #expect(obj["diskSize"] == nil)
        #expect(obj["storagePool"] == nil)
    }

    // MARK: 快照 / 健康检查

    @Test("快照列表解码与默认命名 snap-yyyyMMddHHmmss")
    func snapshots() throws {
        let json = """
        [{"name":"snap-20261023103301","description":"","createdAt":1792722873,
          "state":"disk-snapshot","parent":"","path":"/var/lib/libvirt/images/test-snapshots/snap-20261023103301.qcow2",
          "size":196688,"current":true,"children":0}]
        """
        let list = try JSONDecoder().decode([KVMSnapshot].self, from: Data(json.utf8))
        #expect(list.count == 1)
        #expect(list[0].current == true)
        #expect(list[0].createdDate == Date(timeIntervalSince1970: 1_792_722_873))

        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 23
        components.hour = 10; components.minute = 33; components.second = 1
        let date = Calendar.current.date(from: components)!
        #expect(KVMSnapshotNaming.defaultName(date) == "snap-20261023103301")
    }

    @Test("健康检查解码：计数与检查项（params 形态不符不丢项）")
    func decodeHealth() throws {
        let json = """
        {"pass":10,"warn":0,"fail":0,"items":[
          {"level":"PASS","check":"architecture","params":{"subject":"x86_64"}},
          {"level":"PASS","check":"virtualizationType","params":{"subject":"kvm"}},
          {"level":"PASS","check":"bootOrder"},
          {"level":"WARN","check":"network","params":{"subject":"default"}}]}
        """
        let report = try JSONDecoder().decode(KVMHealthReport.self, from: Data(json.utf8))
        #expect(report.pass == 10)
        #expect(report.items?.count == 4)
        #expect(report.items?[0].subject == "x86_64")
        #expect(report.items?[2].params == nil)
        #expect(report.items?[3].checkDisplay != "network")  // 已本地化为「网络」

        // params 值为数字时整项不丢（subject 置 nil）
        let odd = #"{"level":"PASS","check":"blockDevice","params":{"subject":"disk vda virtio","count":2}}"#
        let item = try JSONDecoder().decode(KVMHealthItem.self, from: Data(odd.utf8))
        #expect(item.check == "blockDevice")
        #expect(item.params == nil)
    }

    // MARK: 网络 / 存储池 / 镜像

    @Test("网络抓包样本解码：usedIPs 为 null 不致解码失败，关联虚拟机判定")
    func decodeNetwork() throws {
        let json = """
        {"id":1,"name":"default","type":"nat","bridgeName":"virbr0","sourceInterface":"",
         "cidr":"192.168.122.0/24","gateway":"192.168.122.1","dhcpStart":"192.168.122.2",
         "dhcpEnd":"192.168.122.254","autoStart":true,"description":"",
         "createdAt":"2026-10-23 10:11:07","status":"Running","vmCount":1,
         "vms":[{"id":2,"name":"test"}],"registered":true,"usedIPs":null,"error":""}
        """
        let network = try JSONDecoder().decode(KVMNetwork.self, from: Data(json.utf8))
        #expect(network.displayName == "default")
        #expect(network.isActive)
        #expect(network.hasVMs)
        #expect(network.usedIPs == nil)
        #expect(network.vms?.first?.name == "test")
    }

    @Test("网络 usedIPs 对象数组解码（2026-10-24 抓包：{ip, vmName, mac, source}）")
    func decodeNetworkUsedIPs() throws {
        let json = """
        {"id":1,"name":"default","type":"nat","bridgeName":"virbr0","sourceInterface":"",
         "cidr":"192.168.122.0/24","gateway":"192.168.122.1","dhcpStart":"192.168.122.2",
         "dhcpEnd":"192.168.122.254","autoStart":true,"description":"",
         "createdAt":"2026-10-23 10:11:07","status":"Running","vmCount":1,
         "vms":[{"id":4,"name":"teat1"}],"registered":true,
         "usedIPs":[{"ip":"192.168.122.169","vmName":"teat1","mac":"52:54:00:96:83:c8","source":"default"}],
         "error":""}
        """
        let network = try JSONDecoder().decode(KVMNetwork.self, from: Data(json.utf8))
        let used = try #require(network.usedIPs?.first)
        #expect(used.ip == "192.168.122.169")
        #expect(used.vmName == "teat1")
        #expect(used.mac == "52:54:00:96:83:c8")
        #expect(used.source == "default")
        #expect(used.displayIP == "192.168.122.169")
    }

    @Test("孤立数据候选项解码与清理请求体回写（字段同构，clean 复用扫描项）")
    func decodeOrphans() throws {
        let json = """
        [{"type":"orphan_domain_disk","path":"/var/lib/libvirt/images/test.qcow2","size":0,"modifiedAt":1792805521}]
        """
        let items = try JSONDecoder().decode([KVMOrphanItem].self, from: Data(json.utf8))
        let item = try #require(items.first)
        #expect(item.typeDisplayName == L10n.t("孤立虚拟机磁盘"))
        #expect(item.modifiedAtText != nil)
        #expect(item.id == "orphan_domain_disk|/var/lib/libvirt/images/test.qcow2")

        // 未知类型原样展示
        let unknown = KVMOrphanItem(type: "orphan_iso", path: "/x.iso", size: 1, modifiedAt: nil)
        #expect(unknown.typeDisplayName == "orphan_iso")
        #expect(unknown.modifiedAtText == nil)

        // 清理请求体字段与扫描项同构（{items:[...]} 逐字段还原）
        let body = try JSONEncoder().encode(KVMOrphansCleanRequest(items: items))
        let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let envelopeItems = try #require(envelope?["items"] as? [[String: Any]])
        #expect(envelopeItems.count == 1)
        #expect(envelopeItems[0]["type"] as? String == "orphan_domain_disk")
        #expect(envelopeItems[0]["path"] as? String == "/var/lib/libvirt/images/test.qcow2")
        #expect(envelopeItems[0]["size"] as? Int64 == 0)
        #expect(envelopeItems[0]["modifiedAt"] as? Int64 == 1792805521)
    }

    @Test("存储池解码：用量与百分比派生")
    func decodeStorage() throws {
        let json = """
        {"id":1,"name":"default","type":"dir","path":"/var/lib/libvirt/images","autoStart":true,
         "description":"","createdAt":"2026-10-23 10:20:13","status":"Running",
         "capacity":213872054272,"available":213469642752,"vmCount":1,
         "vms":[{"id":2,"name":"test"}],"error":""}
        """
        let pool = try JSONDecoder().decode(KVMStoragePool.self, from: Data(json.utf8))
        #expect(pool.isActive)
        let expectedUsed: Int64 = 402_411_520   // 213872054272 - 213469642752
        #expect(pool.usedBytes == expectedUsed)
        #expect((pool.usedPercent ?? 0) > 0 && (pool.usedPercent ?? 1) < 1)
        #expect(pool.hasVMs)
    }

    @Test("镜像解码与类型显示（未知类型回退原值；oraclelinux 为网页确认 rawValue）")
    func decodeISO() throws {
        let json = """
        {"id":1,"type":"archlinux","name":"alpine-virt-3.21.3-x86_64.iso",
         "path":"/home/ios/alpine-virt-3.21.3-x86_64.iso","isExist":true,"size":66060288,
         "status":"ready","error":"","tempFileID":"","tempFileType":"",
         "createdAt":"2026-10-23T10:16:56.502943569+08:00","description":""}
        """
        let iso = try JSONDecoder().decode(KVMISOImage.self, from: Data(json.utf8))
        #expect(iso.isReady)
        #expect(iso.size == 66_060_288)
        #expect(KVMISOType.display("archlinux") == "Arch Linux")
        #expect(KVMISOType.display("debian") == "Debian")
        #expect(KVMISOType.display("ubuntu") == "Ubuntu")
        // 网页请求确认的 rawValue（2026-10-23）：oraclelinux 而非 oracle
        #expect(KVMISOType(rawValue: "oraclelinux") == .oraclelinux)
        #expect(KVMISOType.display("oraclelinux") == "Oracle Linux")
        #expect(KVMISOType(rawValue: "oracle") == nil)
        #expect(KVMISOType.display("someNewDistro") == "someNewDistro")
        #expect(KVMISOType.display(nil) == "-")
    }

    @Test("镜像导入登记形状：上传携 tempFileType、下载携空 tempFileID")
    func encodeISOImport() throws {
        let upload = KVMISOImportStartRequest(
            type: "debian", name: "test",
            path: "/var/lib/libvirt/images/vm-iso/alpine-virt-3.21.3-x86_64.iso",
            status: "uploading", tempFileID: "1792726262940-3mi2qv0cwdc",
            tempFileType: "upload", description: "")
        let uploadObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any])
        #expect(uploadObj["tempFileID"] as? String == "1792726262940-3mi2qv0cwdc")
        #expect(uploadObj["tempFileType"] as? String == "upload")

        let download = KVMISOImportStartRequest(
            type: "debian", name: "alpine",
            path: "/var/lib/libvirt/images/vm-iso/alpine.iso",
            status: "downloading", tempFileID: "", description: "")
        let downloadObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(download)) as? [String: Any])
        #expect(downloadObj["tempFileType"] == nil)
        #expect(downloadObj["tempFileID"] as? String == "")

        // 状态回写：下载中带 key，就绪仅 status
        let withKey = KVMISOImportUpdateRequest(id: 4, status: "downloading",
                                                tempFileID: "file-wget-a34e9bfe", tempFileType: "download")
        let withKeyObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(withKey)) as? [String: Any])
        #expect(withKeyObj["tempFileID"] as? String == "file-wget-a34e9bfe")
        let ready = KVMISOImportUpdateRequest(id: 6, status: "ready")
        let readyObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as? [String: Any])
        #expect(readyObj["tempFileID"] == nil && readyObj["tempFileType"] == nil)
    }

    // MARK: 资源单字段更新

    @Test("网络 / 存储池单字段提交：启停只带 status、自启只带 autoStart")
    func encodeResourceUpdate() throws {
        let stop = KVMResourceUpdateRequest(id: 2, status: "inactive")
        let stopObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stop)) as? [String: Any])
        #expect(stopObj["id"] as? Int == 2)
        #expect(stopObj["status"] as? String == "inactive")
        #expect(stopObj["autoStart"] == nil)

        let autoOff = KVMResourceUpdateRequest(id: 2, autoStart: false)
        let autoObj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(autoOff)) as? [String: Any])
        #expect(autoObj["autoStart"] as? Bool == false)
        #expect(autoObj["status"] == nil)
    }

    // MARK: 详情 / 磁盘扩容

    @Test("info(checkDisks) 抓包样本：resizeBlocked 非空不可扩容，容量换算 GiB")
    func decodeInfoDisks() throws {
        let json = """
        {"id":4,"name":"teat1","cpu":1,"memory":1024,"diskSize":6,"status":"shut off",
         "disks":[{"capacity":6442450944,"format":"qcow2","readOnly":false,"shareable":false,
                   "resizeBlocked":"backing","device":"disk","type":"file",
                   "source":"/var/lib/libvirt/images/teat1-snapshots/snap-20261023150216.qcow2",
                   "target":"vda","bus":"virtio"},
                  {"capacity":0,"format":"raw","readOnly":true,"shareable":false,
                   "resizeBlocked":"","device":"cdrom","type":"file",
                   "source":"/var/lib/libvirt/images/vm-iso/alpine-virt-3.21.3-x86_64.iso",
                   "target":"sda","bus":"sata"}],
         "taskID":"0c909393-7dc8-4c16-9611-7efe1caade31"}
        """
        let vm = try JSONDecoder().decode(KVMVirtualMachine.self, from: Data(json.utf8))
        let disks = try #require(vm.disks)
        #expect(disks.count == 2)
        #expect(disks[0].capacityGiB == 6)          // 6442450944 B = 6 GiB
        #expect(!disks[0].isResizable)              // resizeBlocked = "backing"
        #expect(disks[0].resizeBlockedDisplay == L10n.t("存在快照链（backing 文件）"))
        #expect(!disks[1].isResizable)              // cdrom
        #expect(disks[1].capacityGiB == nil)        // capacity = 0

        // 可扩容盘：disk + resizeBlocked 为空
        let plain = #"{"capacity":5368709120,"format":"qcow2","device":"disk","target":"vda","bus":"virtio","resizeBlocked":""}"#
        let disk = try JSONDecoder().decode(KVMDisk.self, from: Data(plain.utf8))
        #expect(disk.isResizable)
        #expect(disk.capacityGiB == 5)
    }

    @Test("磁盘扩容请求形状对齐抓包：{name, target, sizeGiB, taskID}")
    func encodeDiskResize() throws {
        let request = KVMDiskResizeRequest(name: "teat1", target: "vda", sizeGiB: 6,
                                           taskID: "0c909393-7dc8-4c16-9611-7efe1caade31")
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(obj.count == 4)
        #expect(obj["name"] as? String == "teat1")
        #expect(obj["target"] as? String == "vda")
        #expect(obj["sizeGiB"] as? Int == 6)
        #expect(obj["taskID"] as? String == "0c909393-7dc8-4c16-9611-7efe1caade31")
    }

    @Test("info 请求形状：{name, checkDisks}")
    func encodeInfoRequest() throws {
        let obj = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(KVMInfoRequest(name: "teat1", checkDisks: true))) as? [String: Any])
        #expect(obj["name"] as? String == "teat1")
        #expect(obj["checkDisks"] as? Bool == true)
    }

    @Test("网桥 / 宿主机网卡解码：recommended 门禁与地址列表")
    func decodeBridgesAndInterfaces() throws {
        let bridgesJSON = """
        [{"name":"nat0","recommended":true,"description":""},
         {"name":"br-ac5b02204a32","recommended":false,"description":"docker"},
         {"name":"docker0","recommended":false,"description":"docker"},
         {"name":"virbr0","recommended":false,"description":"libvirt"}]
        """
        let bridges = try JSONDecoder().decode([KVMBridge].self, from: Data(bridgesJSON.utf8))
        #expect(bridges.count == 4)
        #expect(bridges.filter(\.isSelectable).count == 1)
        #expect(bridges[0].isSelectable)
        #expect(bridges[1].displayLabel == "br-ac5b02204a32 · docker")
        #expect(bridges[0].displayLabel == "nat0")   // 无描述回退纯名称

        let interfacesJSON = """
        [{"name":"ens32","addresses":["192.168.50.21/24","fd4d:bdb8:9948:0:20c:29ff:fe0f:e394/64"]},
         {"name":"ens34","addresses":["fe80::20c:29ff:fe0f:e39e/64"]}]
        """
        let interfaces = try JSONDecoder().decode([KVMHostInterface].self, from: Data(interfacesJSON.utf8))
        #expect(interfaces.count == 2)
        #expect(interfaces[0].addresses?.first == "192.168.50.21/24")
    }

    // MARK: 端点

    @Test("KVM 端点路径与方法（environment 为 GET，其余 POST）")
    func endpoints() {
        #expect(APIEndpoint.kvmEnvironment.path == "/api/v2/xpack/vms/environment")
        #expect(APIEndpoint.kvmEnvironment.method == "GET")
        #expect(APIEndpoint.kvmCreate.path == "/api/v2/xpack/vms")
        #expect(APIEndpoint.kvmDelete.path == "/api/v2/xpack/vms/del")
        #expect(APIEndpoint.kvmStats.path == "/api/v2/xpack/vms/stats")
        #expect(APIEndpoint.kvmHealthCheck.path == "/api/v2/xpack/vms/health/check")
        #expect(APIEndpoint.kvmSnapshotList.path == "/api/v2/xpack/vms/snapshots/list")
        #expect(APIEndpoint.kvmSnapshotRecover.path == "/api/v2/xpack/vms/snapshots/recover")
        #expect(APIEndpoint.kvmInfo.path == "/api/v2/xpack/vms/info")
        #expect(APIEndpoint.kvmInfo.method == "POST")
        #expect(APIEndpoint.kvmDiskResize.path == "/api/v2/xpack/vms/disks/resize")
        #expect(APIEndpoint.kvmDiskResize.method == "POST")
        #expect(APIEndpoint.kvmISOImportStart.path == "/api/v2/xpack/vms/iso/import/start")
        #expect(APIEndpoint.kvmISOImportUpdate.path == "/api/v2/xpack/vms/iso/import/update")
        #expect(APIEndpoint.kvmTemplateCreate.path == "/api/v2/xpack/vms/templates")
        #expect(APIEndpoint.kvmTemplateDelete.path == "/api/v2/xpack/vms/templates/del")
        #expect(APIEndpoint.kvmNetworkUpdate.path == "/api/v2/xpack/vms/networks/update")
        #expect(APIEndpoint.kvmNetworkBridges.path == "/api/v2/xpack/vms/networks/bridges")
        #expect(APIEndpoint.kvmNetworkBridges.method == "GET")
        #expect(APIEndpoint.kvmNetworkInterfaces.path == "/api/v2/xpack/vms/networks/interfaces")
        #expect(APIEndpoint.kvmNetworkInterfaces.method == "GET")
        #expect(APIEndpoint.kvmStorageCreate.path == "/api/v2/xpack/vms/storages")
        #expect(APIEndpoint.kvmOperate.method == "POST")
        #expect(APIEndpoint.kvmSync.method == "POST")
        #expect(APIEndpoint.kvmOrphansScan.path == "/api/v2/xpack/vms/orphans/scan")
        #expect(APIEndpoint.kvmOrphansClean.path == "/api/v2/xpack/vms/orphans/clean")
    }

    @Test("KVM 入高级功能门禁与管理分组")
    func gating() {
        #expect(AdvancedFeatureGate.isGated(.kvm))
        #expect(ManageItem.groups.first { $0.items.contains(.kvm) }?.title == L10n.t("高级功能"))
    }

    // MARK: 概览统计（网页端同源数据，抓包 2026-10-24 数值逐项核对）

    private func makeVM(_ id: Int, status: String, cpu: Int? = nil, memory: Int? = nil) -> KVMVirtualMachine {
        let json = """
        {"id":\(id),"name":"vm\(id)","status":"\(status)"
        \(cpu.map { ",\"cpu\":\($0)" } ?? "")\(memory.map { ",\"memory\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(KVMVirtualMachine.self, from: Data(json.utf8))
    }

    @Test("概览统计：状态分桶计数（含挂起独立桶）+ CPU/内存分配求和与百分比")
    func overviewCompute() throws {
        let hostJSON = """
        {"cpuTotal":2,"memoryTotal":8294105088}
        """
        let host = try JSONDecoder().decode(DashboardCurrent.self, from: Data(hostJSON.utf8))
        let vms = [
            makeVM(1, status: "running", cpu: 1, memory: 1024),   // 抓包 teat1
            makeVM(2, status: "running", cpu: 1, memory: 2048),
            makeVM(3, status: "shut off"),
            makeVM(4, status: "creating"),
            makeVM(5, status: "paused"),
            makeVM(6, status: "crashed"),
            makeVM(7, status: "in shutdown"),
        ]
        let overview = KVMOverview.compute(vms: vms, host: host)
        #expect(overview.totalCount == 7)
        #expect(overview.runningCount == 2)
        #expect(overview.stoppedCount == 1)
        #expect(overview.creatingCount == 2)      // creating + in shutdown
        #expect(overview.pausedCount == 1)        // 挂起独立桶，不并入异常
        #expect(overview.errorCount == 1)         // crashed
        #expect(overview.allocatedCPU == 2)
        #expect(overview.allocatedMemoryMB == 3072)
        // 抓包核对：Σmemory 1024MB ÷ 8294105088B = 12.95%（网页精确一致）
        let single = KVMOverview.compute(vms: [vms[0]], host: host)
        #expect(abs((single.memoryPercent ?? 0) - 12.95) < 0.01)
        #expect(single.cpuPercent == 50)

        // 宿主机信息缺失 → 百分比降级为 nil
        let noHost = KVMOverview.compute(vms: vms, host: nil)
        #expect(noHost.cpuPercent == nil)
        #expect(noHost.memoryPercent == nil)
    }

    @Test("概览风险规则：异常 VM / 池未启用 / 池超用 / 池报错 / CPU·内存超分配")
    func overviewRisks() throws {
        let hostJSON = """
        {"cpuTotal":2,"memoryTotal":1073741824}
        """
        let host = try JSONDecoder().decode(DashboardCurrent.self, from: Data(hostJSON.utf8))
        // CPU 3 > 2 核；内存 2048MB > 1GB → 双超分配
        let overcommit = KVMOverview.compute(
            vms: [makeVM(1, status: "running", cpu: 3, memory: 2048)], host: host)

        let poolJSON = """
        [{"id":1,"name":"p-inactive","status":"inactive","capacity":1000,"available":1000},
         {"id":2,"name":"p-full","status":"Running","capacity":1000,"available":5},
         {"id":3,"name":"p-error","status":"Running","capacity":1000,"available":1000,"error":"boom"}]
        """
        let pools = try JSONDecoder().decode([KVMStoragePool].self, from: Data(poolJSON.utf8))

        let risks = KVMOverviewRisks.compute(overview: overcommit, pools: pools)
        // 5 条 = 池未启用 + 池使用率>90% + 池报错 + CPU 超配 + 内存超配（无异常 VM）
        #expect(risks.count == 5)
        #expect(risks.contains { $0.message.contains("p-inactive") })
        #expect(risks.contains { $0.message.contains("p-full") })
        #expect(risks.contains { $0.message.contains("p-error") })
        // 断言用 L10n 同源解析（CI 模拟器为英文 locale，硬编码中文子串会失效）
        #expect(risks.contains { $0.message == L10n.f("CPU 分配（%ld 核）超过宿主机总量（%ld 核）", 3, 2) })
        #expect(risks.contains { $0.message == L10n.t("内存分配超过宿主机总量") })

        // 健康场景：无风险
        let healthy = KVMOverview.compute(
            vms: [makeVM(1, status: "running", cpu: 1, memory: 512)], host: host)
        let healthyPoolJSON = """
        [{"id":1,"name":"ok","status":"Running","capacity":1000,"available":900}]
        """
        let healthyPools = try JSONDecoder().decode([KVMStoragePool].self, from: Data(healthyPoolJSON.utf8))
        #expect(KVMOverviewRisks.compute(overview: healthy, pools: healthyPools).isEmpty)
    }
}

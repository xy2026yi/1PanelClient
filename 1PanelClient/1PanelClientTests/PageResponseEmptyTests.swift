//
//  PageResponseEmptyTests.swift
//  1PanelClientTests
//
//  PageResponse 空回退：服务端空列表序列化为 data:null（或裸回显无 items）时，
//  列表页应得到空页显示「暂无数据」而非报错/死循环（WAF 封锁记录回归向量）
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("PageResponse 空回退")
struct PageResponseEmptyTests {
    @Test("emptyInstance 返回空页")
    func emptyInstanceIsEmpty() {
        let empty: PageResponse<WAFBlockItem> = PageResponse.emptyInstance()
        #expect(empty.items?.isEmpty == true)
        #expect(empty.total == 0)
    }

    @Test("data:null 信封解码后 data 为 nil（走 EmptyInitializable 回退的前提）")
    func dataNullDecodesToNil() throws {
        let json = #"{"code":200,"data":null,"message":""}"#
        let resp = try JSONDecoder().decode(APIResponse<PageResponse<WAFBlockItem>>.self, from: Data(json.utf8))
        #expect(resp.isSuccess)
        #expect(resp.data == nil)
    }

    @Test("裸回显（无 items 字段）可直接解码为空页")
    func bareEchoWithoutItemsDecodes() throws {
        // WAF block/search 抓包向量：响应与请求同形，无 code 信封、无 items
        let json = #"{"page":1,"pageSize":20,"total":0,"ip":""}"#
        let page = try JSONDecoder().decode(PageResponse<WAFBlockItem>.self, from: Data(json.utf8))
        #expect(page.items == nil)
        #expect(page.total == 0)
    }
}

//
//  AppIconView.swift
//  1PanelClient
//
//  已安装应用图标视图：
//  - 通过 GET /api/v2/apps/icon/{appID}?operateNode=local 拉取二进制图片
//  - 全局内存缓存（NSCache）避免重复请求
//  - 失败 / appID 缺失时回退到 IconBadge（基于状态色）
//

import SwiftUI
import UIKit

/// 应用图标内存缓存（按 baseURL + appID 区分）
actor AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// 已安装应用图标视图：优先显示远程图标，失败回退到 IconBadge
struct AppIconView: View {
    let appID: Int?
    let baseURL: String
    /// 回退用的状态图标和颜色
    let fallbackIcon: String
    let fallbackColor: Color
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?
    @State private var didFail = false

    private var cacheKey: String? {
        guard let appID, appID > 0 else { return nil }
        return "\(baseURL)#\(appID)"
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                IconBadge(
                    systemName: fallbackIcon,
                    color: fallbackColor,
                    size: size,
                    cornerRadius: cornerRadius
                )
            }
        }
        .task(id: cacheKey) {
            await load()
        }
    }

    private func load() async {
        guard let key = cacheKey else {
            image = nil
            didFail = true
            return
        }
        if let cached = await AppIconCache.shared.image(forKey: key) {
            image = cached
            return
        }
        // 用临时 APIClient 拉取图标
        let path = APIEndpoint.appsIcon.path.replacingOccurrences(of: ":appID", with: String(appID ?? 0))
        let server = ServerManager.shared.current ?? ServerConfig(name: "", baseURL: baseURL, apiKey: "")
        let client = APIClient(server: server)
        do {
            let data = try await client.fetchImage(
                path: path,
                queryItems: [URLQueryItem(name: "operateNode", value: "local")]
            )
            if let img = UIImage(data: data) {
                await AppIconCache.shared.setImage(img, forKey: key)
                image = img
            } else {
                didFail = true
            }
        } catch {
            didFail = true
        }
    }
}

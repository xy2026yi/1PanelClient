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
    /// 应用 key（如 "mysql"），用于 appID 缺失时按 key 拉取图标
    var appKey: String? = nil
    /// 回退用的状态图标和颜色
    let fallbackIcon: String
    let fallbackColor: Color
    /// 图标加载失败时的字母回退（取首字母），优先级高于 fallbackIcon
    var fallbackText: String? = nil
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?
    @State private var didFail = false

    private var cacheKey: String? {
        if let appID, appID > 0 {
            return "\(baseURL)#id:\(appID)"
        }
        if let appKey, !appKey.isEmpty {
            return "\(baseURL)#key:\(appKey)"
        }
        return nil
    }

    /// 用于字母回退的首字母（大写）
    private var fallbackLetter: String? {
        guard let text = fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = text.first else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if let letter = fallbackLetter {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fallbackColor.opacity(0.18))
                        .frame(width: size, height: size)
                    Text(letter)
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(fallbackColor)
                }
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
        // 确定路径参数：优先用 appID，其次用 appKey
        let pathParam: String
        if let appID, appID > 0 {
            pathParam = String(appID)
        } else if let appKey, !appKey.isEmpty {
            pathParam = appKey
        } else {
            image = nil
            didFail = true
            return
        }
        let path = APIEndpoint.appsIcon.path.replacingOccurrences(of: ":appID", with: pathParam)
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

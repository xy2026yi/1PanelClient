//
//  BrandIcon.swift
//  1PanelClient
//
//  内置品牌图标：Docker / OpenResty / MySQL / MariaDB / PostgreSQL / Redis。
//  图标素材存放在 Assets.xcassets（brand-* imageset），不依赖服务器图标接口，
//  离线可用。Docker 是容器运行时（非 1Panel 应用，无服务器图标），
//  OpenResty/MySQL 等虽是应用，但内置图标避免每次网络拉取。
//

import SwiftUI

/// 支持的品牌类型
enum Brand: String {
    case docker
    case openresty
    case mysql
    case mariadb
    case postgresql
    case redis
    case mongodb

    /// Assets.xcassets 中的 imageset 名称（MariaDB 复用 MySQL 图标）
    var imageName: String {
        switch self {
        case .docker:      return "brand-docker"
        case .openresty:   return "brand-openresty"
        case .mysql:       return "brand-mysql"
        case .mariadb:     return "brand-mysql"      // 复用 MySQL 图标
        case .postgresql:  return "brand-postgresql"
        case .redis:       return "brand-redis"
        case .mongodb:     return "brand-mongodb"
        }
    }

    /// 配色（用于背景色块/ fallback）
    var color: Color {
        switch self {
        case .docker:      return Color(red: 0.09, green: 0.50, blue: 0.79)   // Docker 蓝
        case .openresty:   return Color(red: 0.27, green: 0.52, blue: 0.27)   // 深绿
        case .mysql:       return Color(red: 0.16, green: 0.36, blue: 0.58)
        case .mariadb:     return Color(red: 0.00, green: 0.47, blue: 0.69)   // MariaDB 青
        case .postgresql:  return Color(red: 0.16, green: 0.32, blue: 0.55)   // PG 深蓝
        case .redis:       return Color(red: 0.72, green: 0.00, blue: 0.00)   // Redis 红
        case .mongodb:     return Color(red: 0.00, green: 0.47, blue: 0.30)   // Mongo 绿
        }
    }

    /// 由数据库服务名（type/database 字段，如 "mysql"/"postgresql"/"redis"/"mongodb"）推断品牌
    static func from(dbType: String) -> Brand? {
        switch dbType.lowercased() {
        case "mysql", "mysql-cluster":            return .mysql
        case "mariadb":                            return .mariadb
        case "postgresql", "postgresql-cluster":   return .postgresql
        case "redis", "redis-cluster":             return .redis
        case "mongodb", "mongodb-cluster":         return .mongodb
        default:                                   return nil
        }
    }
}

/// 品牌图标视图。
/// - PNG 图标（mysql/openresty/postgresql/redis）：保留原色，按比例缩放到给定尺寸。
/// - Docker SVG（单色矢量）：作为 template 渲染，颜色随主题自适应（浅色模式深色、深色模式浅色）。
struct BrandIcon: View {
    let brand: Brand
    var size: CGFloat = 44

    var body: some View {
        if brand == .docker {
            // Docker SVG 是单色 logo，用 template 渲染自适应颜色
            Image(brand.imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
        } else {
            // 彩色品牌 logo，保留原色，按比例填充圆角方框
            Image(brand.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}

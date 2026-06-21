//
//  LoginSetting.swift
//  1PanelClient
//

import Foundation

/// 登录页配置（对应 /api/v2/core/auth/setting，公开接口）
struct LoginSetting: Decodable {
    let isDemo: Bool
    let isIntl: Bool
    let isOffLine: Bool
    let isFxplay: Bool
    let language: String
    let menuTabs: String
    let panelName: String
    let theme: String
    let needCaptcha: Bool
}

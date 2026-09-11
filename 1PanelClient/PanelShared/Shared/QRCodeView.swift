//
//  QRCodeView.swift
//  1PanelClient
//
//  文本二维码渲染（微信扫码对接等）：CIFilter 生成位图，
//  白底圆角容器 + 无插值缩放保证码点清晰
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let text: String
    var side: CGFloat = 180

    /// 码点→像素倍率（模块数 × 倍率 = 位图像素尺寸）
    private static let pixelScale: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white)
            .frame(width: side, height: side)
            .overlay {
                if let cg = Self.render(text: text) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .padding(side * 0.08)
                } else {
                    Text(L10n.t("二维码生成失败"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
    }

    static func render(text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, !output.extent.isEmpty else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: pixelScale, y: pixelScale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

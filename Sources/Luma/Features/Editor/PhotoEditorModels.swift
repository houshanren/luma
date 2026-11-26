import SwiftUI
import CoreImage
import LumaCore
import AppKit
import UniformTypeIdentifiers

struct EditState: Equatable, Codable {
    var rotation: Int = 0
    var flipH = false
    var flipV = false
    var crop = EditState.fullCrop
    var aspect: CropAspect = .original
    var filter: FilterPreset = .none
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0
    var noiseReduction: Double = 0
    var autoEnhance = false

    // 高级调整：曲线、HSL、局部蒙版、修复点、镜头与透视。
    var curvePoints: [EditCurvePoint] = EditCurvePoint.identity
    var curveRed: [EditCurvePoint] = EditCurvePoint.identity
    var curveGreen: [EditCurvePoint] = EditCurvePoint.identity
    var curveBlue: [EditCurvePoint] = EditCurvePoint.identity
    var hslAdjustments: [Double] = Array(repeating: 0, count: 24)
    /// 色彩分级：阴影 / 中间调 / 高光三段，各一条色相 + 饱和 + 亮度。
    var gradingBands: [EditGradeBand] = [.neutral, .neutral, .neutral]
    var masks: [EditMask] = []
    var healSpots: [EditHealSpot] = []
    var lensDistortion: Double = 0
    var perspectiveV: Double = 0
    var perspectiveH: Double = 0
    var lensProfile: EditLensProfile = .none
    var lensVignetteFix: Double = 0
    /// 拉直角度（度）：正数顺时针。
    var straighten: Double = 0
    /// 风格：3D LUT、胶片颗粒 / 光晕 / 漏光 / 褪色。
    var lutName: String?
    var lutStrength: Double = 0.8
    var grain: Double = 0
    var halation: Double = 0
    var lightLeak: Double = 0
    var fade: Double = 0
    /// 创意虚化与画框。
    var tiltBlur: Double = 0
    var zoomBlur: Double = 0
    var frameStyle: EditFrameStyle = .none

    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    init() {}

    enum CodingKeys: String, CodingKey {
        case rotation, flipH, flipV, crop, aspect, filter
        case exposure, brightness, contrast, saturation, highlights, shadows
        case warmth, tint, sharpness, vignette, noiseReduction, autoEnhance
        case curvePoints, curveRed, curveGreen, curveBlue
        case hslAdjustments, gradingBands, masks, healSpots
        case lensDistortion, perspectiveV, perspectiveH, straighten
        case lensProfile, lensVignetteFix
        case lutName, lutStrength, grain, halation, lightLeak, fade
        case tiltBlur, zoomBlur, frameStyle
    }

    /// 旧配方没有高级字段，缺省即默认值；不能因为新增字段让老编辑点解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        flipH = try container.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try container.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        crop = try container.decodeIfPresent(CGRect.self, forKey: .crop) ?? EditState.fullCrop
        aspect = try container.decodeIfPresent(CropAspect.self, forKey: .aspect) ?? .original
        filter = try container.decodeIfPresent(FilterPreset.self, forKey: .filter) ?? .none
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        autoEnhance = try container.decodeIfPresent(Bool.self, forKey: .autoEnhance) ?? false
        curvePoints = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curvePoints)
            ?? EditCurvePoint.identity
        curveRed = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curveRed)
            ?? EditCurvePoint.identity
        curveGreen = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curveGreen)
            ?? EditCurvePoint.identity
        curveBlue = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curveBlue)
            ?? EditCurvePoint.identity
        var hsl = try container.decodeIfPresent([Double].self, forKey: .hslAdjustments) ?? []
        if hsl.count != 24 { hsl = Array(repeating: 0, count: 24) }
        hslAdjustments = hsl
        var grading = try container.decodeIfPresent([EditGradeBand].self, forKey: .gradingBands) ?? []
        if grading.count != 3 { grading = [.neutral, .neutral, .neutral] }
        gradingBands = grading
        masks = try container.decodeIfPresent([EditMask].self, forKey: .masks) ?? []
        healSpots = try container.decodeIfPresent([EditHealSpot].self, forKey: .healSpots) ?? []
        lensDistortion = try container.decodeIfPresent(Double.self, forKey: .lensDistortion) ?? 0
        perspectiveV = try container.decodeIfPresent(Double.self, forKey: .perspectiveV) ?? 0
        perspectiveH = try container.decodeIfPresent(Double.self, forKey: .perspectiveH) ?? 0
        lensProfile = try container.decodeIfPresent(EditLensProfile.self, forKey: .lensProfile) ?? .none
        lensVignetteFix = try container.decodeIfPresent(Double.self, forKey: .lensVignetteFix) ?? 0
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        lutName = try container.decodeIfPresent(String.self, forKey: .lutName)
        lutStrength = try container.decodeIfPresent(Double.self, forKey: .lutStrength) ?? 0.8
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        halation = try container.decodeIfPresent(Double.self, forKey: .halation) ?? 0
        lightLeak = try container.decodeIfPresent(Double.self, forKey: .lightLeak) ?? 0
        fade = try container.decodeIfPresent(Double.self, forKey: .fade) ?? 0
        tiltBlur = try container.decodeIfPresent(Double.self, forKey: .tiltBlur) ?? 0
        zoomBlur = try container.decodeIfPresent(Double.self, forKey: .zoomBlur) ?? 0
        frameStyle = try container.decodeIfPresent(EditFrameStyle.self, forKey: .frameStyle) ?? .none
    }

    var isModified: Bool {
        rotation != 0 || flipH || flipV || crop != EditState.fullCrop || filter != .none
            || exposure != 0 || brightness != 0 || contrast != 0 || saturation != 0
            || highlights != 0 || shadows != 0 || warmth != 0 || tint != 0
            || sharpness != 0 || vignette != 0 || noiseReduction != 0 || autoEnhance
            || !EditCurve.isIdentity(curvePoints)
            || !EditCurve.isIdentity(curveRed)
            || !EditCurve.isIdentity(curveGreen)
            || !EditCurve.isIdentity(curveBlue)
            || hslAdjustments.contains { abs($0) > 0.0001 }
            || gradingBands.contains { !$0.isNeutral }
            || !masks.isEmpty || !healSpots.isEmpty
            || lensDistortion != 0 || perspectiveV != 0 || perspectiveH != 0
            || lensVignetteFix != 0
            || straighten != 0
            || lutName != nil
            || grain != 0 || halation != 0 || lightLeak != 0 || fade != 0
            || tiltBlur != 0 || zoomBlur != 0
            || frameStyle != .none
    }

    func cropless() -> EditState {
        var copy = self
        copy.crop = EditState.fullCrop
        return copy
    }
}

extension EditState {
    /// 序列化为 JSON，供复制/粘贴编辑点与再次打开编辑器时恢复。
    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EditState.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

enum EditTool: String, CaseIterable, Identifiable {
    case adjust = "调整"
    case curve = "曲线"
    case hsl = "颜色"
    case presets = "预设"
    case style = "风格"
    case mask = "蒙版"
    case heal = "修复"
    case optics = "镜头"
    case creative = "创意"
    case filters = "滤镜"
    case crop = "裁剪"
    case poster = "海报"
    case beauty = "美化"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .hsl: return "paintpalette"
        case .presets: return "square.grid.2x2"
        case .style: return "camera.filters"
        case .mask: return "circle.dashed"
        case .heal: return "bandage"
        case .optics: return "camera.aperture"
        case .creative: return "sparkles"
        case .filters: return "camera.metering.center.weighted"
        case .crop: return "crop"
        case .poster: return "doc.richtext"
        case .beauty: return "wand.and.stars"
        }
    }

    /// 蒙版 / 修复需要看到未裁剪的整图，坐标才不会被裁掉。
    var needsFullFrame: Bool {
        self == .crop || self == .mask || self == .heal
    }
}

enum PhotoRenderer {
    static let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    static func loadBase(url: URL) -> CIImage? {
        if RawFormats.isRaw(url) {
            if let image = RawFormats.ciImage(url: url, maxPixel: 8000) {
                return normalized(image)
            }
        }
        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .cacheImmediately: true
        ]
        guard let image = CIImage(contentsOf: url, options: options) else { return nil }
        return normalized(image)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        if extent.origin != .zero {
            return image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                           y: -extent.origin.y))
        }
        return image
    }

    static func render(base: CIImage, state: EditState, maxPixel: CGFloat?) -> NSImage? {
        guard let cgImage = renderCG(base: base, state: state, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func renderCG(base: CIImage, state: EditState, maxPixel: CGFloat?) -> CGImage? {
        var ci = base

        let steps = (((state.rotation % 360) + 360) % 360) / 90
        if steps != 0 {
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(steps) * .pi / 2))
            ci = normalized(ci)
        }
        if state.flipH {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            ci = normalized(ci)
        }
        if state.flipV {
            ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            ci = normalized(ci)
        }
        if state.straighten != 0 {
            ci = straightened(ci, degrees: state.straighten)
        }

        if state.noiseReduction > 0 {
            ci = ci.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.01 + state.noiseReduction * 0.08,
                "inputSharpness": 0.4
            ])
        }
        if state.autoEnhance {
            for filter in ci.autoAdjustmentFilters() {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    ci = output
                }
            }
        }
        if state.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: state.exposure])
        }
        if state.highlights != 0 || state.shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": min(1, max(0, 1 - state.highlights)),
                "inputShadowAmount": min(1, max(-1, state.shadows))
            ])
        }
        if state.warmth != 0 || state.tint != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + state.warmth * 2600, y: state.tint * 120)
            ])
        }
        if state.brightness != 0 || state.contrast != 0 || state.saturation != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: state.brightness,
                kCIInputContrastKey: 1 + state.contrast,
                kCIInputSaturationKey: 1 + state.saturation
            ])
        }
        if state.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: state.sharpness * 1.2
            ])
        }
        if let filterName = state.filter.ciName {
            ci = ci.applyingFilter(filterName)
        }
        if state.vignette != 0 {
            ci = ci.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: state.vignette * 1.6,
                kCIInputRadiusKey: 1.6
            ])
        }

        // 曲线 / HSL / 局部蒙版 / 修复 / 镜头透视：都在裁剪之前处理。
        ci = applyAdvanced(ci, state: state)

        let extent = ci.extent
        if state.crop != EditState.fullCrop {
            let rect = CGRect(
                x: extent.minX + state.crop.minX * extent.width,
                y: extent.minY + (1 - state.crop.maxY) * extent.height,
                width: max(1, state.crop.width * extent.width),
                height: max(1, state.crop.height * extent.height)
            ).integral
            ci = ci.cropped(to: rect)
            ci = normalized(ci)
        }

        if let maxPixel {
            let width = ci.extent.width
            let height = ci.extent.height
            let scale = min(1, maxPixel / max(width, height))
            if scale < 1 {
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                ci = normalized(ci)
            }
        }

        if state.frameStyle != .none {
            ci = applyFrame(ci, style: state.frameStyle)
        }

        return context.createCGImage(ci, from: ci.extent)
    }

    /// 拉直：绕中心旋转后裁出最大的同比例内接矩形，避免四角露黑。
    static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, abs(degrees) > 0.001 else { return image }
        let angle = CGFloat(degrees) * .pi / 180
        let cw = cos(abs(angle))
        let sw = sin(abs(angle))
        let width = extent.width
        let height = extent.height
        let scale = min(width / (width * cw + height * sw),
                        height / (width * sw + height * cw))
        let target = CGSize(width: width * scale, height: height * scale)
        let cropRect = CGRect(x: -target.width / 2, y: -target.height / 2,
                              width: target.width, height: target.height).integral
            .insetBy(dx: 1, dy: 1)
        let rotated = image
            .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
            .transformed(by: CGAffineTransform(rotationAngle: angle))
            .cropped(to: cropRect)
        return normalized(rotated)
    }
}

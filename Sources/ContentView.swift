import SwiftUI
import PhotosUI
import Photos
import CoreImage
import ImageIO

// MARK: - 18 Pro 影像
// 不是相框、不是加个文字边框，而是把整张照片处理成"像新一代相机系统拍出来的"画面：
// 冷色科技调色 + 高级动态范围 + 镜头镀膜反光 + 轻微胶片颗粒，
// 再把半透明的设备信息叠层和极简水印直接合成进画面。

struct ImagingStyle: Identifiable, Equatable {
    let id: String
    let name: String
    let desc: String
    var cool: Double        // 冷色程度 0...1
    var hdr: Double         // 动态范围 0...1
    var flare: Double       // 镀膜反光 0...1
    var grain: Double       // 颗粒 0...1
    var filmCurve: Double   // 胶片曲线 0...1

    static let all: [ImagingStyle] = [
        ImagingStyle(id: "standard", name: "标准影像", desc: "均衡的 18 Pro 出厂质感",
                     cool: 0.35, hdr: 0.55, flare: 0.15, grain: 0.25, filmCurve: 0.0),
        ImagingStyle(id: "cyber", name: "冷色科技", desc: "冷调、高动态、带镀膜辉光",
                     cool: 0.85, hdr: 0.8, flare: 0.5, grain: 0.2, filmCurve: 0.0),
        ImagingStyle(id: "coating", name: "镀膜幻彩", desc: "镜头镀膜的彩色反光是主角",
                     cool: 0.45, hdr: 0.5, flare: 1.0, grain: 0.15, filmCurve: 0.0),
        ImagingStyle(id: "film", name: "胶片纪实", desc: "胶片曲线 + 明显颗粒",
                     cool: 0.15, hdr: 0.45, flare: 0.0, grain: 0.8, filmCurve: 0.8)
    ]
}

struct OverlayInfo {
    var dateText: String
    var resolutionText: String
}

enum ImagingEngine {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func grade(_ input: CIImage, style: ImagingStyle, intensity: Double) -> CIImage {
        var img = input
        let extent = input.extent
        let k = intensity

        // 高级动态范围：压高光、提暗部，再过一条温和的 S 曲线
        if style.hdr > 0.01, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(NSNumber(value: -0.55 * style.hdr * k), forKey: "inputHighlightAmount")
            f.setValue(NSNumber(value: 0.55 * style.hdr * k), forKey: "inputShadowAmount")
            img = f.outputImage ?? img
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            let c = 0.06 * k
            curve.setValue(img, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.25 - c * 0.5), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.75 + c * 0.5), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
            img = curve.outputImage ?? img
        }

        // 冷色科技调色：整体往冷端推，饱和略收、对比略升
        if style.cool > 0.01, let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(img, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: CGFloat(6500 - 1500 * style.cool * k), y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            img = temp.outputImage ?? img
        }
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(img, forKey: kCIInputImageKey)
            cc.setValue(NSNumber(value: 1.0 - 0.06 * style.cool * k + 0.04 * k), forKey: kCIInputSaturationKey)
            cc.setValue(NSNumber(value: 1.0 + 0.07 * k), forKey: kCIInputContrastKey)
            img = cc.outputImage ?? img
        }

        // 胶片曲线（胶片纪实）
        if style.filmCurve > 0.01, let curve = CIFilter(name: "CIToneCurve") {
            let lift = 0.05 * style.filmCurve * k
            curve.setValue(img, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0, y: CGFloat(lift)), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: CGFloat(0.25 + lift * 0.5)), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.73), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1, y: CGFloat(1.0 - 0.04 * style.filmCurve * k)), forKey: "inputPoint4")
            img = curve.outputImage ?? img
        }

        // 镜头镀膜反光：两团彩色辉光（青品 + 绿）+ 一道很淡的斜向耀光，滤色叠加
        if style.flare > 0.01 {
            img = addFlare(img, extent: extent, amount: style.flare * k)
        }

        // 清晰度：轻微锐化，模拟新传感器细节
        if let sharp = CIFilter(name: "CIUnsharpMask") {
            sharp.setValue(img, forKey: kCIInputImageKey)
            sharp.setValue(NSNumber(value: 0.45 * k), forKey: kCIInputIntensityKey)
            sharp.setValue(NSNumber(value: 1.6), forKey: kCIInputRadiusKey)
            img = sharp.outputImage ?? img
        }

        // 轻微胶片颗粒
        if style.grain > 0.01 {
            img = addGrain(img, extent: extent, amount: style.grain * k)
        }

        return img.cropped(to: extent)
    }

    private static func addFlare(_ img: CIImage, extent: CGRect, amount: Double) -> CIImage {
        var base = img
        let w = extent.width, h = extent.height
        // 主辉光：右上方，青→品红的镀膜色
        if let glow = radialGlow(center: CIVector(x: extent.minX + w * 0.78, y: extent.minY + h * 0.80),
                                 radius: max(w, h) * 0.55,
                                 color: CIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: CGFloat(0.30 * amount)),
                                 extent: extent) {
            base = screenBlend(glow, over: base)
        }
        // 副辉光：左下方，较小的绿色鬼影
        if let ghost = radialGlow(center: CIVector(x: extent.minX + w * 0.24, y: extent.minY + h * 0.22),
                                  radius: max(w, h) * 0.30,
                                  color: CIColor(red: 0.55, green: 1.0, blue: 0.70, alpha: CGFloat(0.16 * amount)),
                                  extent: extent) {
            base = screenBlend(ghost, over: base)
        }
        // 斜向耀光带
        if let grad = CIFilter(name: "CILinearGradient") {
            grad.setValue(CIVector(x: extent.minX, y: extent.maxY), forKey: "inputPoint0")
            grad.setValue(CIVector(x: extent.maxX, y: extent.minY), forKey: "inputPoint1")
            grad.setValue(CIColor(red: 1, green: 0.85, blue: 0.95, alpha: CGFloat(0.05 * amount)), forKey: "inputColor0")
            grad.setValue(CIColor(red: 1, green: 0.85, blue: 0.95, alpha: 0), forKey: "inputColor1")
            if let streak = grad.outputImage?.cropped(to: extent) {
                base = screenBlend(streak, over: base)
            }
        }
        return base.cropped(to: extent)
    }

    private static func radialGlow(center: CIVector, radius: CGFloat, color: CIColor, extent: CGRect) -> CIImage? {
        guard let f = CIFilter(name: "CIRadialGradient") else { return nil }
        f.setValue(center, forKey: kCIInputCenterKey)
        f.setValue(NSNumber(value: 0.0), forKey: "inputRadius0")
        f.setValue(NSNumber(value: radius), forKey: "inputRadius1")
        f.setValue(color, forKey: "inputColor0")
        f.setValue(CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0), forKey: "inputColor1")
        return f.outputImage?.cropped(to: extent)
    }

    private static func screenBlend(_ fg: CIImage, over bg: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIScreenBlendMode") else { return bg }
        f.setValue(fg, forKey: kCIInputImageKey)
        f.setValue(bg, forKey: kCIInputBackgroundImageKey)
        return f.outputImage ?? bg
    }

    private static func addGrain(_ img: CIImage, extent: CGRect, amount: Double) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: extent),
              let mono = CIFilter(name: "CIColorMonochrome") else { return img }
        mono.setValue(noise, forKey: kCIInputImageKey)
        mono.setValue(CIColor(red: 0.5, green: 0.5, blue: 0.5), forKey: "inputColor")
        mono.setValue(NSNumber(value: 1.0), forKey: kCIInputIntensityKey)
        guard let grainImg = mono.outputImage,
              let matrix = CIFilter(name: "CIColorMatrix") else { return img }
        matrix.setValue(grainImg, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.05 + 0.13 * amount)), forKey: "inputAVector")
        guard let faint = matrix.outputImage,
              let soft = CIFilter(name: "CISoftLightBlendMode") else { return img }
        soft.setValue(faint, forKey: kCIInputImageKey)
        soft.setValue(img, forKey: kCIInputBackgroundImageKey)
        return (soft.outputImage ?? img).cropped(to: extent)
    }

    static func renderCG(_ ciImage: CIImage) -> CGImage? {
        context.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: 设备信息叠层 + 极简水印（直接合成进画面）

    static func compositeOverlay(_ image: UIImage, info: OverlayInfo, showOverlay: Bool, showWatermark: Bool) -> UIImage {
        guard showOverlay || showWatermark else { return image }
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            image.draw(at: .zero)
            let u = size.width / 1200.0          // 相对单位，任意分辨率下比例一致
            let margin = 42 * u
            let white = UIColor.white

            if showOverlay {
                // 顶部设备信息条：半透明芯片
                let chipText = "iPhone 18 Pro · 48MP Fusion"
                let chipFont = UIFont.monospacedSystemFont(ofSize: 30 * u, weight: .medium)
                let chipAttrs: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: white.withAlphaComponent(0.92)]
                let chipSize = (chipText as NSString).size(withAttributes: chipAttrs)
                let chipRect = CGRect(x: margin, y: margin, width: chipSize.width + 36 * u, height: chipSize.height + 22 * u)
                ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.20).cgColor)
                UIBezierPath(roundedRect: chipRect, cornerRadius: chipRect.height / 2).fill()
                (chipText as NSString).draw(at: CGPoint(x: chipRect.minX + 18 * u, y: chipRect.minY + 11 * u), withAttributes: chipAttrs)

                // 右上角状态点
                let dotR = 9 * u
                ctx.cgContext.setFillColor(UIColor.systemGreen.withAlphaComponent(0.9).cgColor)
                ctx.cgContext.fillEllipse(in: CGRect(x: size.width - margin - dotR * 2, y: margin + 6 * u, width: dotR * 2, height: dotR * 2))

                // 四角取景框线（相机 HUD，不是相框）
                ctx.cgContext.setStrokeColor(white.withAlphaComponent(0.55).cgColor)
                ctx.cgContext.setLineWidth(3.2 * u)
                let L = 54 * u
                let inset = 26 * u
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (CGPoint(x: inset, y: inset), 1, 1),
                    (CGPoint(x: size.width - inset, y: inset), -1, 1),
                    (CGPoint(x: inset, y: size.height - inset), 1, -1),
                    (CGPoint(x: size.width - inset, y: size.height - inset), -1, -1)
                ]
                for (p, sx, sy) in corners {
                    ctx.cgContext.move(to: CGPoint(x: p.x + L * sx, y: p.y))
                    ctx.cgContext.addLine(to: p)
                    ctx.cgContext.addLine(to: CGPoint(x: p.x, y: p.y + L * sy))
                }
                ctx.cgContext.strokePath()

                // 底部左侧：拍摄参数行（日期取自照片 EXIF，其余为该影像系统的标志参数）
                let infoText = "\(info.dateText)  ·  24mm  ƒ/1.6  ISO 50"
                let infoFont = UIFont.monospacedSystemFont(ofSize: 27 * u, weight: .regular)
                let infoAttrs: [NSAttributedString.Key: Any] = [.font: infoFont, .foregroundColor: white.withAlphaComponent(0.85)]
                (infoText as NSString).draw(at: CGPoint(x: margin, y: size.height - margin - 30 * u), withAttributes: infoAttrs)
            }

            if showWatermark {
                // 底部右侧极简水印
                let wm = "18 PRO IMAGING"
                let wmFont = UIFont.systemFont(ofSize: 26 * u, weight: .semibold)
                let wmAttrs: [NSAttributedString.Key: Any] = [
                    .font: wmFont,
                    .foregroundColor: white.withAlphaComponent(0.62),
                    .kern: 4.5 * u
                ]
                let wmSize = (wm as NSString).size(withAttributes: wmAttrs)
                (wm as NSString).draw(at: CGPoint(x: size.width - margin - wmSize.width, y: size.height - margin - 30 * u), withAttributes: wmAttrs)
            }
        }
    }

    static func overlayInfo(for data: Data, ciImage: CIImage) -> OverlayInfo {
        var dateText = ""
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            // EXIF 格式 "2026:11:22 14:32:05" → "2026.11.22"
            let parts = raw.split(separator: " ")
            if let d = parts.first {
                dateText = d.replacingOccurrences(of: ":", with: ".")
            }
        }
        if dateText.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy.MM.dd"
            dateText = f.string(from: Date())
        }
        let res = "\(Int(ciImage.extent.width))×\(Int(ciImage.extent.height))"
        return OverlayInfo(dateText: dateText, resolutionText: res)
    }
}

// MARK: - 界面

struct ContentView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalCI: CIImage?
    @State private var info = OverlayInfo(dateText: "", resolutionText: "")
    @State private var preview: UIImage?
    @State private var style: ImagingStyle = ImagingStyle.all[1]
    @State private var intensity: Double = 0.85
    @State private var showOverlay = true
    @State private var showWatermark = true
    @State private var showOriginal = false
    @State private var saving = false
    @State private var savedTip: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    photoArea
                    if originalCI != nil {
                        stylePicker
                        controls
                        saveButton
                    } else {
                        Text("选一张照片，给它换上 iPhone 18 Pro 的影像系统质感：冷色调、高动态范围、镜头镀膜反光和轻颗粒，画面里还会带上半透明的设备信息层。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(16)
            }
            .navigationTitle("18 Pro 影像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label(originalCI == nil ? "选照片" : "换一张", systemImage: "photo.on.rectangle.angled")
                    }
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                Task { await load(newItem) }
            }
            .onChange(of: style) { _, _ in refreshPreview() }
            .onChange(of: intensity) { _, _ in refreshPreview() }
            .onChange(of: showOverlay) { _, _ in refreshPreview() }
            .onChange(of: showWatermark) { _, _ in refreshPreview() }
        }
    }

    private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 40))
                        Text("从相册选一张照片")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .overlay(alignment: .bottomTrailing) {
            if originalCI != nil {
                Button {
                    showOriginal.toggle()
                    refreshPreview()
                } label: {
                    Text(showOriginal ? "看效果" : "看原图")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .padding(10)
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新影像风格")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ImagingStyle.all) { s in
                    Button {
                        style = s
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name)
                                .font(.headline)
                            Text(s.desc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            style.id == s.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(style.id == s.id ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("风格强度")
                    .font(.subheadline)
                Slider(value: $intensity, in: 0.2...1.0, step: 0.05)
                Text("\(Int(intensity * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 44)
            }
            Toggle(isOn: $showOverlay) {
                Text("设备信息叠层")
                    .font(.subheadline)
            }
            Toggle(isOn: $showWatermark) {
                Text("极简水印")
                    .font(.subheadline)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var saveButton: some View {
        VStack(spacing: 8) {
            Button {
                Task { await save() }
            } label: {
                Label(saving ? "保存中…" : "保存到相册", systemImage: saving ? "hourglass" : "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(saving)
            if let savedTip {
                Text(savedTip)
                    .font(.caption)
                    .foregroundStyle(savedTip.hasPrefix("已") ? .green : .red)
            }
        }
    }

    // MARK: - 处理

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        savedTip = nil
        showOriginal = false
        if let data = try? await item.loadTransferable(type: Data.self),
           let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            originalCI = ci
            info = ImagingEngine.overlayInfo(for: data, ciImage: ci)
            refreshPreview()
        }
    }

    private func currentRender(from ci: CIImage, maxSide: CGFloat?) -> UIImage? {
        var src = ci
        if let maxSide {
            let scale = min(1.0, maxSide / max(ci.extent.width, ci.extent.height))
            if scale < 1.0 {
                src = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        if showOriginal {
            guard let cg = ImagingEngine.renderCG(src) else { return nil }
            return UIImage(cgImage: cg)
        }
        let graded = ImagingEngine.grade(src, style: style, intensity: intensity)
        guard let cg = ImagingEngine.renderCG(graded) else { return nil }
        let base = UIImage(cgImage: cg)
        return ImagingEngine.compositeOverlay(base, info: info, showOverlay: showOverlay, showWatermark: showWatermark)
    }

    private func refreshPreview() {
        guard let originalCI else { return }
        let snapshot = originalCI
        DispatchQueue.global(qos: .userInitiated).async {
            let ui = currentRender(from: snapshot, maxSide: 1100)
            DispatchQueue.main.async { preview = ui }
        }
    }

    private func save() async {
        guard let originalCI else { return }
        saving = true
        savedTip = nil
        let snapshot = originalCI
        let rendered = await Task.detached(priority: .userInitiated) {
            self.currentRender(from: snapshot, maxSide: nil)
        }.value
        guard let image = rendered else {
            saving = false
            savedTip = "处理失败，换一张照片试试"
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saving = false
            savedTip = "没有相册写入权限，去系统设置里允许一下"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            savedTip = "已保存到相册"
        } catch {
            savedTip = "保存失败，再试一次"
        }
        saving = false
    }
}

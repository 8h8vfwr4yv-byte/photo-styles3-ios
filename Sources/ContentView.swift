import SwiftUI
import PhotosUI
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - iPhone 18 Pro 摄影风格 3（Photographic Styles 3）模拟
// 风格 3 的新东西：Texture 质感（标准 / 柔肤 / 光晕 / 胶片）+ Grain 颗粒开关，
// 叠加在原有的色调（Tone）/ 色彩（Color）调色板之上。
// 本 App 用 Core Image 后期模拟这套效果；原机是在拍摄管线里结合场景语义算的，效果接近但不完全相同。

enum TextureKind: String, CaseIterable, Identifiable {
    case standard = "标准"
    case softSkin = "柔肤"
    case glow = "光晕"
    case film = "胶片"
    var id: String { rawValue }
}

struct StyleSettings: Equatable {
    var tone: Double = 0          // -50 ... 50
    var color: Double = 0         // -50 ... 50
    var texture: TextureKind = .film
    var textureIntensity: Double = 60   // 0 ... 100
    var grain: Bool = true
}

enum StyleEngine {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func apply(_ input: CIImage, settings s: StyleSettings) -> CIImage {
        var img = input
        let extent = input.extent

        // 1) 调色板：色调 / 色彩
        let controls = CIFilter.colorControls()
        controls.inputImage = img
        controls.saturation = Float(1.0 + s.color / 100.0 * 0.55)
        controls.contrast = Float(1.0 + (-s.tone) / 100.0 * 0.22)
        controls.brightness = Float(s.tone / 100.0 * 0.06)
        img = controls.outputImage ?? img

        let temp = CIFilter.temperatureAndTint()
        temp.inputImage = img
        temp.neutral = CIVector(x: 6500 + CGFloat(s.color) * 14.0, y: 0)
        temp.targetNeutral = CIVector(x: 6500, y: 0)
        img = temp.outputImage ?? img

        // 2) 质感 Texture
        let k = s.textureIntensity / 100.0
        if k > 0.01 {
            switch s.texture {
            case .standard:
                break
            case .softSkin:
                // 柔肤：高斯柔化后低透明叠回，磨皮但保留整体锐度观感
                if let blurred = blur(img, radius: 5.0 * k + 1.0),
                   let blended = blend(blurred, over: img, alpha: 0.42 * k) {
                    img = blended.cropped(to: extent)
                }
            case .glow:
                // 光晕：大半径模糊用滤色模式叠加，高光发光
                if let blurred = blur(img, radius: 16.0 * k + 2.0) {
                    let screen = CIFilter.screenBlendMode()
                    screen.inputImage = withAlpha(blurred, alpha: 0.5 * k)
                    screen.backgroundImage = img
                    img = (screen.outputImage ?? img).cropped(to: extent)
                }
            case .film:
                // 胶片：抬黑场、压高光的曲线 + 轻微暖调降饱和
                let curve = CIFilter.toneCurve()
                curve.inputImage = img
                let lift = CGFloat(0.055 * k)
                let roll = CGFloat(1.0 - 0.05 * k)
                curve.point0 = CGPoint(x: 0, y: lift)
                curve.point1 = CGPoint(x: 0.25, y: 0.25 + lift * 0.55)
                curve.point2 = CGPoint(x: 0.5, y: 0.5)
                curve.point3 = CGPoint(x: 0.75, y: 0.75 - (1 - roll) * 0.4)
                curve.point4 = CGPoint(x: 1, y: roll)
                img = curve.outputImage ?? img

                let warm = CIFilter.colorControls()
                warm.inputImage = img
                warm.saturation = Float(1.0 - 0.10 * k)
                img = warm.outputImage ?? img
            }
        }

        // 3) 颗粒 Grain（风格 3 里是开关，没有强度滑杆，这里同样处理）
        if s.grain {
            let noise = CIFilter.randomGenerator().outputImage?.cropped(to: extent)
            if let noise {
                let mono = CIFilter.colorMonochrome()
                mono.inputImage = noise
                mono.color = CIColor(red: 0.5, green: 0.5, blue: 0.5)
                mono.intensity = 1.0
                if let grainImg = mono.outputImage {
                    let soft = CIFilter.softLightBlendMode()
                    soft.inputImage = withAlpha(grainImg, alpha: 0.16)
                    soft.backgroundImage = img
                    img = (soft.outputImage ?? img).cropped(to: extent)
                }
            }
        }

        return img.cropped(to: extent)
    }

    private static func blur(_ img: CIImage, radius: Double) -> CIImage? {
        let f = CIFilter.gaussianBlur()
        f.inputImage = img
        f.radius = Float(radius)
        return f.outputImage?.cropped(to: img.extent)
    }

    private static func withAlpha(_ img: CIImage, alpha: Double) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = img
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
        return m.outputImage ?? img
    }

    private static func blend(_ fg: CIImage, over bg: CIImage, alpha: Double) -> CIImage? {
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = withAlpha(fg, alpha: alpha)
        over.backgroundImage = bg
        return over.outputImage
    }

    static func renderUIImage(_ ciImage: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 界面

struct ContentView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalData: Data?
    @State private var originalCI: CIImage?
    @State private var preview: UIImage?
    @State private var settings = StyleSettings()
    @State private var showOriginal = false
    @State private var saving = false
    @State private var savedTip: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    photoArea
                    if originalCI != nil {
                        controls
                        saveButton
                        Text("模拟 iPhone 18 Pro「摄影风格 3」的质感与颗粒（后期处理，与原机拍摄管线效果接近，但不完全相同）。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    } else {
                        Text("选一张老机型拍的照片，给它加上 iPhone 18 Pro 新的影像风格：质感（柔肤 / 光晕 / 胶片）和颗粒，再保存到相册。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(16)
            }
            .navigationTitle("摄影风格 3")
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
            .onChange(of: settings) { _, _ in refreshPreview() }
        }
    }

    private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
            if let preview {
                Image(uiImage: showOriginal ? (originalCI.flatMap { StyleEngine.renderUIImage($0) } ?? preview) : preview)
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
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .overlay(alignment: .bottomTrailing) {
            if originalCI != nil {
                Button {
                    // 按住看原图用手势更顺手，这里用开关切换
                    showOriginal.toggle()
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("质感 Texture（风格 3 新增）")
                .font(.subheadline.weight(.semibold))
            Picker("质感", selection: $settings.texture) {
                ForEach(TextureKind.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)

            if settings.texture != .standard {
                HStack {
                    Text("质感强度")
                        .font(.subheadline)
                    Slider(value: $settings.textureIntensity, in: 0...100, step: 1)
                    Text("\(Int(settings.textureIntensity))")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 30)
                }
            }

            Toggle(isOn: $settings.grain) {
                Text("颗粒 Grain（风格 3 新增）")
                    .font(.subheadline.weight(.semibold))
            }

            Divider()

            HStack {
                Text("色调")
                    .font(.subheadline)
                Slider(value: $settings.tone, in: -50...50, step: 1)
                Text("\(Int(settings.tone))")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 30)
            }
            HStack {
                Text("色彩")
                    .font(.subheadline)
                Slider(value: $settings.color, in: -50...50, step: 1)
                Text("\(Int(settings.color))")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 30)
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
                if saving {
                    Label("保存中…", systemImage: "hourglass")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
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
            originalData = data
            originalCI = ci
            refreshPreview()
        }
    }

    private func refreshPreview() {
        guard let originalCI else { return }
        let s = settings
        // 预览用缩小图，滑动滑杆才跟手
        let maxSide: CGFloat = 1100
        let scale = min(1.0, maxSide / max(originalCI.extent.width, originalCI.extent.height))
        let small = originalCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        DispatchQueue.global(qos: .userInitiated).async {
            let out = StyleEngine.apply(small, settings: s)
            let ui = StyleEngine.renderUIImage(out)
            DispatchQueue.main.async { preview = ui }
        }
    }

    private func save() async {
        guard let originalCI else { return }
        saving = true
        savedTip = nil
        let s = settings
        let full = await Task.detached(priority: .userInitiated) {
            StyleEngine.apply(originalCI, settings: s)
        }.value
        guard let image = StyleEngine.renderUIImage(full) else {
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

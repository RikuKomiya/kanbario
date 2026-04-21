import SwiftUI

// Claude Design (claude.ai/design) の Kanban wireframe handoff を Swift で再現した
// テーマ層。HTML 版 `wireframe-primitives.jsx` / `llm-primitives.jsx` の WF/SketchBox/
// Hand/EvalMeter/Metric/Pill 等を SwiftUI 相当に翻訳している。
//
// デザインの sketchy / hand-drawn 美学は:
//   - 紙色 #fbfaf7 + ink #1d1d1f の高コントラスト
//   - Noteworthy / Marker Felt (macOS 標準、登録不要)
//   - 1.3〜1.5px の黒実線 + `shadow radius:0 x:2 y:3` の hard shadow
//     (HTML の `boxShadow: '2px 3px 0 rgba(29,29,31,0.08)'` と等価)
// で表現する。SVG filter ベースの wobble は SwiftUI で再現困難なので
// ここでは影とストロークで sketchy 感を出す。

// MARK: - Palette

enum WF {
    static let ink     = Color(red: 0x1d/255, green: 0x1d/255, blue: 0x1f/255)
    static let ink2    = Color(red: 0x51/255, green: 0x51/255, blue: 0x54/255)
    static let ink3    = Color(red: 0x86/255, green: 0x86/255, blue: 0x8b/255)
    static let line    = Color(red: 0x1d/255, green: 0x1d/255, blue: 0x1f/255)
    static let paper   = Color(red: 0xfb/255, green: 0xfa/255, blue: 0xf7/255)
    static let paperAlt = Color(red: 0xf2/255, green: 0xf0/255, blue: 0xea/255)
    static let canvas  = Color(red: 0xf0/255, green: 0xee/255, blue: 0xe9/255)
    static let accent  = Color(red: 0x0a/255, green: 0x84/255, blue: 0xff/255)
    static let accentSoft = Color(red: 0xcf/255, green: 0xe3/255, blue: 0xff/255)
    static let warn    = Color(red: 0xff/255, green: 0x9f/255, blue: 0x0a/255)
    static let done    = Color(red: 0x30/255, green: 0xd1/255, blue: 0x58/255)
    static let pink    = Color(red: 0xff/255, green: 0x37/255, blue: 0x5f/255)
    static let purple  = Color(red: 0xbf/255, green: 0x5a/255, blue: 0xf2/255)
    static let shellBg = Color(red: 0x1c/255, green: 0x1c/255, blue: 0x1e/255)
    static let shellDivider = Color(red: 0x3a/255, green: 0x3a/255, blue: 0x3c/255)
    static let cardShadow = Color.black.opacity(0.08)
}

// MARK: - Fonts

/// HTML 版の `'Kalam', 'Caveat', cursive` を macOS 標準の handwriting family に
/// 置き換えたラッパ。PostScript 名で Font.custom に渡す。fallback は sans-serif。
enum WFFont {
    /// 小〜中サイズの本文手書き (Kalam 相当)。Noteworthy-Light。
    static func hand(_ size: CGFloat, weight: Weight = .regular) -> Font {
        switch weight {
        case .bold:  return .custom("Noteworthy-Bold", size: size)
        case .regular: return .custom("Noteworthy-Light", size: size)
        }
    }
    /// 強調用手書きディスプレイ (Caveat 相当)。Noteworthy-Bold をタイトに見せる。
    static func display(_ size: CGFloat) -> Font {
        .custom("Noteworthy-Bold", size: size)
    }
    /// code / metric 用 monospace。SF Mono。
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
    enum Weight { case regular, bold }
}

// MARK: - SketchBox modifier

/// `wireframe-primitives.jsx` の <SketchBox> 相当。紙色塗り + 黒 1.5px stroke +
/// hard drop-shadow (radius:0) で hand-drawn box を再現する。
struct SketchBoxStyle: ViewModifier {
    var fill: Color = WF.paper
    var stroke: Color = WF.line
    var strokeWidth: CGFloat = 1.5
    var radius: CGFloat = 10
    var shadow: Bool = true

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(stroke, lineWidth: strokeWidth)
            )
            .shadow(color: shadow ? WF.cardShadow : .clear, radius: 0, x: 2, y: 3)
    }
}

extension View {
    /// 紙ベースの手書き風カードに仕立てるショートカット。
    func sketchBox(
        fill: Color = WF.paper,
        stroke: Color = WF.line,
        strokeWidth: CGFloat = 1.5,
        radius: CGFloat = 10,
        shadow: Bool = true
    ) -> some View {
        modifier(SketchBoxStyle(
            fill: fill, stroke: stroke,
            strokeWidth: strokeWidth, radius: radius, shadow: shadow
        ))
    }
}

// MARK: - Squiggle divider

/// タイトル下などに敷く手書き波線。HTML 版の SVG Path をベジェで再現。
struct Squiggle: View {
    var width: CGFloat = 80
    var color: Color = WF.ink2

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let w = size.width
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h/2))
            let seg = w / 4
            for i in 0..<4 {
                let x0 = CGFloat(i) * seg
                let cx = x0 + seg/2
                let cy: CGFloat = i.isMultiple(of: 2) ? 0 : h
                path.addQuadCurve(
                    to: CGPoint(x: x0 + seg, y: h/2),
                    control: CGPoint(x: cx, y: cy)
                )
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .frame(width: width, height: 6)
    }
}

// MARK: - Handwritten text

/// HTML 版 <Hand> 相当。size / weight / color を一箇所で束ねる。
struct Hand: View {
    let text: String
    var size: CGFloat = 16
    var color: Color = WF.ink
    var weight: WFFont.Weight = .regular

    init(_ text: String, size: CGFloat = 16, color: Color = WF.ink, weight: WFFont.Weight = .regular) {
        self.text = text
        self.size = size
        self.color = color
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(WFFont.hand(size, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(1)
    }
}

// MARK: - Colored dot

struct WFDot: View {
    var color: Color = WF.accent
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - Pill

/// HTML 版 <Pill> — 円角枠 + 手書き小テキスト。内側に optional dot / icon を置ける。
struct WFPill<Content: View>: View {
    let color: Color
    let bg: Color
    let content: Content

    init(color: Color = WF.ink2, bg: Color = .clear, @ViewBuilder content: () -> Content) {
        self.color = color
        self.bg = bg
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(color, lineWidth: 1))
            .font(WFFont.hand(12))
            .foregroundStyle(color)
    }
}

// MARK: - Avatar (initial circle)

struct WFAvatar: View {
    let initial: String
    var size: CGFloat = 22
    var bg: Color = WF.accentSoft
    var color: Color = WF.accent

    var body: some View {
        Text(initial)
            .font(WFFont.hand(size * 0.55, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(bg, in: Circle())
            .overlay(Circle().stroke(WF.line, lineWidth: 1))
    }
}

// MARK: - LLM category tag

/// カードの RAG / Agent / Extract 等のタグピル。色はカテゴリごとに決まる。
struct LLMTagPill: View {
    let tag: LLMTag
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tag.color).frame(width: 5, height: 5)
            Text(tag.rawValue)
                .font(WFFont.hand(size))
        }
        .foregroundStyle(tag.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .overlay(Capsule().stroke(tag.color, lineWidth: 1))
    }
}

// MARK: - Risk badge

/// 三角警告マーク + ラベル。ラベルは Low/Med/High。
struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 4) {
            Triangle()
                .stroke(risk.color, lineWidth: 1.2)
                .frame(width: 10, height: 10)
            Text(risk.label)
                .font(WFFont.hand(11))
        }
        .foregroundStyle(risk.color)
    }
}

/// RiskBadge の三角シェイプ。上向き三角。
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - EvalMeter (circular score 0..1)

struct EvalMeter: View {
    let score: Double?
    var size: CGFloat = 32

    var body: some View {
        if let score {
            ZStack {
                Circle()
                    .stroke(WF.paperAlt, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0, min(1, score)))
                    .stroke(
                        meterColor(score),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(Int((score * 100).rounded()))")
                    .font(WFFont.mono(size * 0.32))
                    .fontWeight(.semibold)
                    .foregroundStyle(WF.ink)
            }
            .frame(width: size, height: size)
        } else {
            Text("—")
                .font(WFFont.hand(9))
                .foregroundStyle(WF.ink3)
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(WF.ink3, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                )
        }
    }

    private func meterColor(_ s: Double) -> Color {
        if s >= 0.85 { return WF.done }
        if s >= 0.7  { return WF.warn }
        return WF.pink
    }
}

// MARK: - Metric cell (label + mono value)

struct Metric: View {
    let label: String
    let value: String
    var color: Color = WF.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(WFFont.hand(11))
                .foregroundStyle(WF.ink3)
                .lineLimit(1)
            Text(value)
                .font(WFFont.mono(12))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

// MARK: - Small icon views

/// HTML 版 <IconPlus>。単色ストロークアイコンのショートカット。
struct WFIcon {
    static func plus(size: CGFloat = 12, color: Color = WF.ink2) -> some View {
        Image(systemName: "plus")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }
    static func search(size: CGFloat = 14, color: Color = WF.ink2) -> some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
    static func sidebar(size: CGFloat = 14, color: Color = WF.ink2) -> some View {
        Image(systemName: "sidebar.left")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
    static func openShell(size: CGFloat = 12, color: Color = WF.ink2) -> some View {
        // HTML 版の手書きターミナルアイコン相当。SF Symbols の terminal を流用。
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
    static func close(size: CGFloat = 14, color: Color = WF.ink2) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }
}

// MARK: - TrafficLights (macOS signal dots)

/// HTML 版タイトルバーの赤/黄/緑の信号ボタン。close 用の action だけを赤に取る。
struct TrafficLights: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            lightButton(color: Color(red: 1, green: 0.37, blue: 0.34), action: onClose)
            light(color: Color(red: 0.996, green: 0.737, blue: 0.18))
            light(color: Color(red: 0.157, green: 0.784, blue: 0.251))
        }
    }

    private func light(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(WF.line, lineWidth: 1))
    }

    private func lightButton(color: Color, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            light(color: color)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - PaperBackground

/// 全ウィンドウ共通の紙色背景。SwiftUI の `Color(.windowBackgroundColor)` を置換する。
struct PaperBackground: View {
    var body: some View {
        WF.paper.ignoresSafeArea()
    }
}

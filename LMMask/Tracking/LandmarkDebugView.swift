import SwiftUI
import simd

// Alignment overlay: shows the composited OUTPUT frame (exactly what Zoom gets) and draws, in output pixels,
//   yellow  = face rect, cyan = the user's eye centres, pink = outer lips,
//   orange  = projected bounding box of the mask, magenta = projected eye sockets of the mask,
//   white lines join each socket to the user's eye it should cover.
// Goal of the placement: magenta rings sit on the cyan rings. If they do not, see docs/rendering.md "Placement".

/// Geometry of one frame for the overlay. Everything is in OUTPUT pixels (top-left origin) except `sourceSize`.
struct PlacementDebugInfo: Sendable {
    var sourceSize: SIMD2<Float>
    var cropScale: Float
    /// nil when no face is being tracked (resting pose).
    var face: Face?
    var maskBounds: CGRect
    var socketL: SIMD2<Float>
    var socketR: SIMD2<Float>
    /// Headpiece outline in output px; empty unless "Show silhouette outline" is on (Tune panel).
    var silhouette: [SIMD2<Float>] = []
    /// Scare trigger readings (mouth / eyes vs thresholds) for the HUD.
    var scare = ScareReadout()

    struct Face: Sendable {
        var rect: CGRect
        var leftEye: SIMD2<Float>
        var rightEye: SIMD2<Float>
        var lips: [SIMD2<Float>]
        var yaw: Float, pitch: Float, roll: Float
    }
}

/// Hand-off between the render queue (writer, only while someone is looking) and the debug view (reader).
final class PlacementDebugHub: @unchecked Sendable {
    static let shared = PlacementDebugHub()
    /// `@AppStorage` key for "Mirror preview" (affects ONLY what the app shows, never the output).
    static let mirrorPreviewKey = "mirrorPreview"

    private let lock = NSLock()
    private var _wanted = false
    private var _image: CGImage?
    private var _info: PlacementDebugInfo?

    var wanted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _wanted }
        set { lock.lock(); _wanted = newValue; lock.unlock() }
    }

    func store(image: CGImage, info: PlacementDebugInfo?) {
        lock.lock(); _image = image; _info = info; lock.unlock()
    }

    func latest() -> (image: CGImage, info: PlacementDebugInfo?)? {
        lock.lock(); defer { lock.unlock() }
        guard let i = _image else { return nil }
        return (i, _info)
    }
}

struct LandmarkDebugView: View {
    @AppStorage(PlacementDebugHub.mirrorPreviewKey) private var mirrored = false
    @State private var showOverlay = true
    @State private var frame: (image: CGImage, info: PlacementDebugInfo?)?
    private let outputSize = CGSize(width: Int(FrameFormat.width), height: Int(FrameFormat.height))
    private let timer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let frame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        // Aspect-FIT (letterbox), never stretch.
                        .aspectRatio(outputSize.width / outputSize.height, contentMode: .fit)
                        .overlay {
                            if showOverlay, let info = frame.info {
                                Canvas { ctx, size in draw(ctx, size, info) }
                            }
                        }
                        // Mirrors the image AND the overlay together; the output stream is never mirrored.
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                } else {
                    Text("Waiting for frames...").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

            HStack(spacing: 16) {
                Toggle("Mirror preview", isOn: $mirrored)
                Toggle("Alignment overlay", isOn: $showOverlay)
                Spacer()
                if let info = frame?.info {
                    Text(String(format: "src %.0fx%.0f  fill x%.2f", info.sourceSize.x, info.sourceSize.y, info.cropScale))
                    if let f = info.face {
                        Text(String(format: "yaw %.0f  pitch %.0f  roll %.0f", f.yaw * 180 / .pi,
                                    f.pitch * 180 / .pi, f.roll * 180 / .pi))
                    } else {
                        Text("No face")
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)

            if let s = frame?.info?.scare {
                scareHUD(s)
            }
        }
        .onAppear { PlacementDebugHub.shared.wanted = true }
        .onDisappear { PlacementDebugHub.shared.wanted = false }
        .onReceive(timer) { _ in frame = PlacementDebugHub.shared.latest() }
    }

    /// "Why did / didn't it scare": live mouth and eye readings against the trigger thresholds. A reading that meets its
    /// threshold is shown in orange; the state shows hold progress while the trigger is arming.
    private func scareHUD(_ s: ScareReadout) -> some View {
        let state = !s.enabled ? "OFF" : s.active ? (s.forced ? "ACTIVE (forced)" : "ACTIVE")
            : s.holdProgress > 0 ? String(format: "arming %.0f%%", s.holdProgress * 100) : "idle"
        let eyes = min(s.leftEye, s.rightEye)
        return HStack(spacing: 16) {
            Text("SCARE \(state)").fontWeight(.semibold).foregroundStyle(s.active ? Color.orange : Color.secondary)
            Text(String(format: "mouth %.2f / %.2f", s.mouth, s.mouthThreshold))
                .foregroundStyle(s.mouth >= s.mouthThreshold ? Color.orange : Color.secondary)
            Text(String(format: "eyes L %.2f R %.2f / %.2f", s.leftEye, s.rightEye, s.eyeThreshold))
                .foregroundStyle(eyes >= s.eyeThreshold ? Color.orange : Color.secondary)
            Text(String(format: "amount %.2f", s.amount)).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ info: PlacementDebugInfo) {
        let s = size.width / outputSize.width  // output px -> points
        func pt(_ v: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(v.x) * s, y: CGFloat(v.y) * s) }
        func ring(_ c: CGPoint, _ r: CGFloat, _ color: Color, _ w: CGFloat = 2) {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color), lineWidth: w)
        }

        let b = info.maskBounds
        ctx.stroke(Path(CGRect(x: b.minX * s, y: b.minY * s, width: b.width * s, height: b.height * s)),
                   with: .color(.orange), lineWidth: 1.5)
        if let first = info.silhouette.first {
            var outline = Path()
            outline.move(to: pt(first))
            for v in info.silhouette.dropFirst() { outline.addLine(to: pt(v)) }
            outline.closeSubpath()
            ctx.stroke(outline, with: .color(.green), lineWidth: 1)
        }
        let sl = pt(info.socketL), sr = pt(info.socketR)
        ring(sl, 9, .pink); ring(sr, 9, .pink)

        guard let f = info.face else { return }
        ctx.stroke(Path(CGRect(x: f.rect.minX * s, y: f.rect.minY * s, width: f.rect.width * s, height: f.rect.height * s)),
                   with: .color(.yellow), lineWidth: 1)
        if let first = f.lips.first {
            var path = Path()
            path.move(to: pt(first))
            for v in f.lips.dropFirst() { path.addLine(to: pt(v)) }
            path.closeSubpath()
            ctx.stroke(path, with: .color(.pink.opacity(0.7)), lineWidth: 1)
        }
        let el = pt(f.leftEye), er = pt(f.rightEye)
        ring(el, 6, .cyan); ring(er, 6, .cyan)
        // Join each socket with the nearest-by-x eye (eye order from Vision is irrelevant here).
        let eyes = el.x <= er.x ? [el, er] : [er, el]
        let sockets = sl.x <= sr.x ? [sl, sr] : [sr, sl]
        for (a, e) in zip(sockets, eyes) {
            var p = Path(); p.move(to: a); p.addLine(to: e)
            ctx.stroke(p, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
    }
}

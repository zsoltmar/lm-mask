import AppKit
import SwiftUI

/// Right-hand inspector with every `MaskStyle` parameter. Edits go straight to `pipeline.style` (persisted, applied live;
/// geometry changes rebuild the mesh after a ~150 ms pause). Sections match `MaskStyle`: Inflatable, Vinyl, Print, Windows,
/// Placement, Scare.
struct TunePanel: View {
    let pipeline: any MaskPipelineControlling

    @State private var openInflatable = true
    @State private var openVinyl = false
    @State private var openPrint = false
    @State private var openWindows = true
    @State private var openPlacement = false
    @State private var openScare = false
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                DisclosureGroup("Inflatable", isExpanded: $openInflatable) {
                    row("Finger padding", \.fingerPad, MaskStyle.Limits.fingerPad, "%.1f cm")
                    row("Finger thickness", \.fingerDepth, MaskStyle.Limits.fingerDepth, "%.1f cm")
                    row("Palm thickness", \.bodyDepth, MaskStyle.Limits.bodyDepth, "%.0f cm")
                    row("Palm left", \.bodyLeft, MaskStyle.Limits.bodyLeft, "%.0f")
                    row("Palm right", \.bodyRight, MaskStyle.Limits.bodyRight, "%.0f")
                    row("Palm top", \.bodyTop, MaskStyle.Limits.bodyTop, "%.0f")
                    row("Palm bottom", \.bodyBottom, MaskStyle.Limits.bodyBottom, "%.0f")
                    row("Corner radius", \.cornerRadius, MaskStyle.Limits.cornerRadius, "%.0f cm")
                    Toggle("Collar", isOn: flag(\.showCollar))
                    hint("Each logo bar is its own round tube; the palm sits behind them. Palm edges are in logo units (the logo is 72 wide, the eyes at y 30, the mouth at y 66). Rebuilds the mesh about 0.15 s after you stop moving a slider.")
                }
            }
            Section {
                DisclosureGroup("Vinyl", isExpanded: $openVinyl) {
                    ColorPicker("Colour", selection: color(\.bodyColor), supportsOpacity: false)
                    row("Roughness", \.roughness, MaskStyle.Limits.roughness, "%.2f")
                    row("Clear coat", \.clearcoat, MaskStyle.Limits.clearcoat, "%.2f")
                }
            }
            Section {
                DisclosureGroup("Print", isExpanded: $openPrint) {
                    Toggle("Teal to blue gradient", isOn: flag(\.printGradient))
                    row("Print inset", \.printInset, MaskStyle.Limits.printInset, "%.1f cm")
                    hint("The blue logo is printed on the right bar and the swoosh. Inset also sizes the two eye windows.")
                }
            }
            Section {
                DisclosureGroup("Windows", isExpanded: $openWindows) {
                    ColorPicker("Tint", selection: color(\.tintColor), supportsOpacity: false)
                    row("Tint opacity", \.tintOpacity, MaskStyle.Limits.tintOpacity, percent: true)
                    Picker("Mouth", selection: mouthMode) {
                        ForEach(MaskStyle.MouthMode.allCases, id: \.self) { m in
                            Text(Self.title(of: m)).tag(m)
                        }
                    }
                    row("Mouth window width", \.mouthWindowWidth, MaskStyle.Limits.mouthWindowWidth, "%.0f cm")
                    row("Mouth window height", \.mouthWindowHeight, MaskStyle.Limits.mouthWindowHeight, "%.1f cm")
                    hint("The two middle bars are see-through windows for your eyes (level eyes land in them); the swoosh has a window that shows your real mouth, cropped sharply around your lips.")
                }
            }
            Section {
                DisclosureGroup("Placement", isExpanded: $openPlacement) {
                    row("Horizontal position", \.horizontalOffset, MaskStyle.Limits.horizontalOffset, "%+.2f")
                    hint("Fraction of face height. Vertical position lives in the main window.")
                }
            }
            Section {
                DisclosureGroup("Scare", isExpanded: $openScare) {
                    Toggle("Scare mode", isOn: flag(\.scare.enabled))
                    HStack {
                        Button("Test scare") { pipeline.testScare() }
                            .disabled(!pipeline.style.scare.enabled)
                        Spacer()
                        if pipeline.scareActive {
                            Text("Active").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    row("Mouth opens at", \.scare.mouthThreshold, MaskStyle.Limits.scareMouthThreshold, "%.2f")
                    row("Eyes open at", \.scare.eyeThreshold, MaskStyle.Limits.scareEyeThreshold, "%.2f")
                    row("Hold", \.scare.holdMs, MaskStyle.Limits.scareHoldMs, "%.0f ms")
                    row("Vignette", \.scare.vignette, MaskStyle.Limits.scareVignette, percent: true)
                    hint("Opens mouth wide and eyes wide at the same time: the windows go pitch black, the print turns black and a jagged black demon face appears on the white vinyl. Levels are fractions of your calibrated range (tick Preview > Show tracking overlay to see the live readings). Test scare also works with the Mask menu, Option-Command-S.")
                }
            }
            Section {
                HStack(spacing: 8) {
                    Button("Reset style") { pipeline.resetStyle(); note = "Reset" }
                    Spacer(minLength: 8)
                    Button("Copy as JSON") { copyJSON() }
                    Button("Paste") { pasteJSON() }
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    private func row(_ title: String, _ kp: WritableKeyPath<MaskStyle, Double>, _ range: ClosedRange<Double>,
                     _ format: String) -> some View {
        TuneSlider(title: title, value: number(kp), range: range) { String(format: format, $0) }
    }

    private func row(_ title: String, _ kp: WritableKeyPath<MaskStyle, Double>, _ range: ClosedRange<Double>,
                     percent: Bool) -> some View {
        TuneSlider(title: title, value: number(kp), range: range) { "\(Int(($0 * 100).rounded()))%" }
    }

    private static func title(of mode: MaskStyle.MouthMode) -> String {
        switch mode {
        case .window: "Window (your mouth)"
        case .off: "Off (solid blue)"
        }
    }

    private var mouthMode: Binding<MaskStyle.MouthMode> {
        Binding(get: { pipeline.style.mouthMode }, set: { pipeline.style.mouthMode = $0 })
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Bindings

    private func number(_ kp: WritableKeyPath<MaskStyle, Double>) -> Binding<Double> {
        Binding(get: { pipeline.style[keyPath: kp] }, set: { pipeline.style[keyPath: kp] = $0 })
    }

    private func flag(_ kp: WritableKeyPath<MaskStyle, Bool>) -> Binding<Bool> {
        Binding(get: { pipeline.style[keyPath: kp] }, set: { pipeline.style[keyPath: kp] = $0 })
    }

    private func color(_ kp: WritableKeyPath<MaskStyle, HexColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: pipeline.style[keyPath: kp].nsColor) },
                set: { pipeline.style[keyPath: kp] = HexColor(nsColor: NSColor($0)) })
    }

    // MARK: JSON

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pipeline.style.jsonString, forType: .string)
        note = "Copied style JSON"
    }

    private func pasteJSON() {
        if let text = NSPasteboard.general.string(forType: .string), let style = MaskStyle.decode(json: text) {
            pipeline.style = style
            note = "Applied style from clipboard"
        } else {
            note = "Clipboard does not hold a style JSON"
        }
    }
}

/// Title and live value on one line, slider underneath: 4 pt between lines, 8 pt row padding.
private struct TuneSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Tune panel") {
    TunePanel(pipeline: MockPipeline())
        .frame(width: 320, height: 640)
}

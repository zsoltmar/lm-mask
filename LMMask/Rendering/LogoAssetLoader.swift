// LogoAssetLoader.swift
// LM Mask - builds the logo node tree. The inflatable glove only exists in the in-code builder (it is driven live by
// `MaskStyle`), so a bundled `lm-mark.usdz` is no longer loaded; the Source enum stays so callers do not change.

import Foundation
import SceneKit

@MainActor
enum LogoAssetLoader {

    enum Source: Sendable { case usdz, fallback }

    struct Result {
        /// Detached root node named "lmMark", scale 0.01 (children in cm), mark-centred, +y up, front toward +z.
        let node: SCNNode
        let source: Source
    }

    /// Returns the logo node tree. Throws only if the builder itself fails (malformed embedded path data).
    static func load(style: MaskStyle = MaskStyle()) throws -> Result {
        Result(node: try LogoMeshBuilder.makeMark(style: style), source: .fallback)
    }
}

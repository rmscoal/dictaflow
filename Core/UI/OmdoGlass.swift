import SwiftUI

/// A tint over the shared backdrop. Detached surfaces can supply their own material.
struct OmdoGlass<Surface: InsettableShape>: View {
    let shape: Surface
    var tint = AppTheme.glass
    var tintOpacity = 0.30
    var opaqueTint: Color?
    var material: Material?
    var showsRim = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if !reduceTransparency, let material {
                shape.fill(material)
            }
            shape.fill(reduceTransparency ? opaqueTint ?? tint : tint.opacity(tintOpacity))
            if showsRim {
                shape.strokeBorder(
                    colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.14),
                    lineWidth: 1
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct OmdoControlSurface<Surface: InsettableShape>: View {
    let shape: Surface

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            shape
                .fill(reduceTransparency ? AppTheme.opaqueControlFill : .black.opacity(0.16))
                .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        } else {
            shape.fill(reduceTransparency ? AppTheme.opaqueControlFill : .black.opacity(0.07))
        }
    }
}

enum OmdoWindowSurface {
    case workspace
    case menuBar
    case overlay

    func tintOpacity(for colorScheme: ColorScheme) -> Double {
        switch self {
        case .workspace: colorScheme == .dark ? 0.35 : 0.40
        case .menuBar: 0.12
        case .overlay: colorScheme == .dark ? 0.28 : 0.72
        }
    }
}

private struct OmdoWindowTint<Surface: InsettableShape>: View {
    let shape: Surface
    let surface: OmdoWindowSurface
    let showsRim: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let usesOverlayTint = surface == .overlay && colorScheme == .light
        OmdoGlass(
            shape: shape,
            tint: usesOverlayTint ? Color(white: 0.67) : AppTheme.background,
            tintOpacity: surface.tintOpacity(for: colorScheme),
            opaqueTint: AppTheme.background,
            showsRim: showsRim
        )
    }
}

extension View {
    func omdoWindowTint<S: InsettableShape>(
        in shape: S, surface: OmdoWindowSurface = .workspace, showsRim: Bool = true
    ) -> some View {
        background { OmdoWindowTint(shape: shape, surface: surface, showsRim: showsRim) }
    }

    func omdoFloatingWindowBackground<S: InsettableShape>(
        in shape: S, surface: OmdoWindowSurface = .workspace, showsRim: Bool = true
    ) -> some View {
        background {
            OmdoWindowTint(shape: shape, surface: surface, showsRim: showsRim)
                .background { OmdoWindowBackdrop().clipShape(shape) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    func omdoSheetBackground() -> some View {
        presentationBackground {
            Color.clear.omdoFloatingWindowBackground(in: Rectangle(), showsRim: false)
        }
    }

    func omdoControlBackground<S: InsettableShape>(in shape: S) -> some View {
        background {
            OmdoControlSurface(shape: shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    func omdoSelectionBackground<S: InsettableShape>(
        in shape: S, isSelected: Bool = true, showsRim: Bool = true
    ) -> some View {
        background {
            if isSelected {
                OmdoGlass(
                    shape: shape,
                    tint: AppTheme.accent,
                    tintOpacity: 0.14,
                    opaqueTint: AppTheme.selectedFill,
                    showsRim: showsRim
                )
            }
        }
    }

    func omdoGlassBackground<S: InsettableShape>(
        in shape: S,
        tint: Color = AppTheme.glass,
        tintOpacity: Double = 0.30,
        material: Material? = nil,
        showsRim: Bool = true
    ) -> some View {
        background {
            OmdoGlass(
                shape: shape,
                tint: tint,
                tintOpacity: tintOpacity,
                material: material,
                showsRim: showsRim
            )
        }
    }
}

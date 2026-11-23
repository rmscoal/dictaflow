import SwiftUI

/// A tint over the shared backdrop. Detached surfaces can supply their own material.
struct OmdoGlass<Surface: InsettableShape>: View {
    let shape: Surface
    var tint = AppTheme.glass
    var tintOpacity = 0.30
    var material: Material?
    var showsRim = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if !reduceTransparency, let material {
                shape.fill(material)
            }
            shape.fill(tint.opacity(reduceTransparency ? 1 : tintOpacity))
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
            shape.fill(AppTheme.controlFill)
        }
    }
}

private struct OmdoWindowTint<Surface: InsettableShape>: View {
    let shape: Surface
    let showsRim: Bool
    var strongerLightTint = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // A stronger neutral tint keeps floating controls readable over bright content.
        let usesStrongerTint = strongerLightTint && colorScheme == .light && !reduceTransparency
        OmdoGlass(
            shape: shape,
            tint: usesStrongerTint ? Color(white: 0.67) : AppTheme.background,
            tintOpacity: usesStrongerTint ? 0.72 : 0.28,
            showsRim: showsRim
        )
    }
}

extension View {
    func omdoWindowTint<S: InsettableShape>(in shape: S, showsRim: Bool = true) -> some View {
        background { OmdoWindowTint(shape: shape, showsRim: showsRim) }
    }

    func omdoFloatingWindowBackground<S: InsettableShape>(
        in shape: S, showsRim: Bool = true, strongerLightTint: Bool = false
    ) -> some View {
        background {
            OmdoWindowTint(shape: shape, showsRim: showsRim, strongerLightTint: strongerLightTint)
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

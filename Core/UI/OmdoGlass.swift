import SwiftUI

/// A translucent tint over the window's shared backdrop. Detached surfaces
/// can supply their own material when they need an independent background.
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
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.white.opacity(0.24), .white.opacity(0.08)]
                            : [.white.opacity(0.9), .black.opacity(0.17)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OmdoGlass(
            shape: shape,
            tint: AppTheme.background,
            tintOpacity: colorScheme == .dark ? 0.36 : 0.26,
            showsRim: showsRim
        )
    }
}

extension View {
    func omdoWindowTint<S: InsettableShape>(in shape: S, showsRim: Bool = true) -> some View {
        background { OmdoWindowTint(shape: shape, showsRim: showsRim) }
    }

    func omdoFloatingWindowBackground<S: InsettableShape>(in shape: S, showsRim: Bool = true) -> some View {
        background {
            OmdoWindowTint(shape: shape, showsRim: showsRim)
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

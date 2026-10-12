import SwiftUI

/// An icon slot a theme can fill with its own artwork: `icons/<name>.png`
/// (or `.svg`) in the theme's folder — the real thing's tray icons, folder
/// icons, and so on — falling back to an SF Symbol when the theme ships
/// none, so every theme keeps working with no extra files.
struct ThemeGlyph: View {
    let theme: Theme?
    let name: String
    let fallbackSymbol: String
    let size: CGFloat
    var color: Color = .primary

    var body: some View {
        if let url = theme?.iconURL(name), let image = ThemeIconLoader.image(at: url, tinted: "#FFFFFF") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.9))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}

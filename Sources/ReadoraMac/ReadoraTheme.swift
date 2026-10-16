import SwiftUI
import ReadoraCore
import ReadoraRendering

extension View {
    func readoraTheme(_ theme: ReaderTheme) -> some View {
        preferredColorScheme(theme == .night ? .dark : .light)
            .environment(\.colorScheme, theme == .night ? .dark : .light)
            .tint(LibraryPalette.accent(theme))
            .accentColor(LibraryPalette.accent(theme))
            .toolbarBackground(LibraryPalette.canvas(theme), for: .windowToolbar)
            .foregroundStyle(Color(nsColor: ReaderTypography.textColor(theme)))
            .background(LibraryPalette.canvas(theme).ignoresSafeArea())
    }
    func readoraForm(_ theme: ReaderTheme) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(LibraryPalette.canvas(theme))
    }
}

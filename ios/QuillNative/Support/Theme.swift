import SwiftUI

enum Theme {
    /// The one accent colour, matched to the app icon. Everything else is system colour.
    static let tint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.82, green: 0.69, blue: 0.86, alpha: 1)
            : UIColor(red: 0.32, green: 0.20, blue: 0.34, alpha: 1)
    })
}

// Shared Settings view helpers.

import SwiftUI

extension View {
    /// Consistent pane padding: CotEditor-style breathing room (scene padding at
    /// the top, a little more on the sides and bottom).
    func settingsPanePadding() -> some View {
        self.padding(EdgeInsets(top: 20, leading: 28, bottom: 28, trailing: 28))
            .frame(width: 600, alignment: .leading)
            // Don't auto-focus (and draw a focus ring around) the first control
            // when a pane opens — Settings has no use for keyboard-focus rings.
            .focusEffectDisabled()
    }
}

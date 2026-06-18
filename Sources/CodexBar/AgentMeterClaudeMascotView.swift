import AppKit
import SwiftUI

struct AgentMeterClaudeMascotView: View {
    let image: NSImage
    @State private var isLifted = false

    var body: some View {
        Image(nsImage: self.image)
            .resizable()
            .interpolation(.none)
            .frame(width: 18, height: 18)
            .offset(y: self.isLifted ? -1 : 1)
            .rotationEffect(.degrees(self.isLifted ? -2 : 2))
            .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: self.isLifted)
            .task {
                self.isLifted = true
            }
            .accessibilityHidden(true)
    }
}

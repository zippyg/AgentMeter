import SwiftUI
import WidgetKit

@main
struct AgentMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentMeterWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            AgentMeterLiveActivity()
        }
    }
}

import PingFrontAdapty
import PingFrontCore
import Testing

@Suite("Adapty module")
struct AdaptyModuleTests {
    @Test("The README's setup compiles and names the module pingfront.adapty")
    func module() {
        let options = AdaptyOptions(placements: ["winback"], identity: .customerUserId { "user_42" }, observerMode: true) { _ in .pending }
        let modules: [PingFrontModule] = [.adapty(placements: ["winback", "settings_paywall"]), .adapty(options)]
        #expect(modules.map(\.id) == ["pingfront.adapty", "pingfront.adapty"])
        #expect(options.presentsPaywalls && options.reportsEntitlement && options.observerMode)
    }
}

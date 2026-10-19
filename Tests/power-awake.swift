import Foundation

@main
struct PowerAwakeTests {
    static func main() {
        let status = PowerAwakeStatus(output: """
        Service: enabled
        Lifecycle: app-bound
        Power source: battery
        Battery charge: 50%
        System sleep disabled: 1 (1=blocked, 0=allowed)
        Update pending: run power-awake on
        """)!
        assert(status.enabled && status.sleepDisabled == true && status.onAC == false)
        assert(status.batteryPercent == 50 && status.updatePending)
        assert(status.appBound)
        let disabled = PowerAwakeStatus(output: """
        Service: disabled
        Power source: ac
        Battery charge: unknown%
        System sleep disabled: 1 (1=blocked, 0=allowed)
        """)!
        assert(!disabled.enabled && disabled.sleepDisabled == true && disabled.onAC == true)
        assert(disabled.batteryPercent == nil)
        assert(!disabled.appBound)
        assert(PowerAwakeStatus(output: "Service: disabled\nBattery charge: 101%")?.batteryPercent == nil)
        assert(PowerAwakeStatus(output: "Service: unknown") == nil)
        assert(PowerAwakeStatus(output: "permission denied") == nil)
        assert(PowerAwakeController.authorizationScript.contains("quoted form of helperPath"))
        assert(PowerAwakeController.authorizationScript.contains("with administrator privileges"))
        print("PASS status parsing, unknown/error states and authorization argument handling")
        if CommandLine.arguments.count == 2 {
            let bundle = Bundle(path: CommandLine.arguments[1])!
            let controller = PowerAwakeController(bundle: bundle)
            var completed = false
            controller.onChange = { if controller.status != nil { completed = true } }
            controller.refresh()
            let deadline = Date().addingTimeInterval(10)
            while !completed && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            assert(completed, controller.errorMessage ?? "status callback did not complete")
            assert(controller.canChange && !controller.isBusy)
            print("PASS bundled resource and asynchronous live status refresh (read-only)")
        }
    }
}

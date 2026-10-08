import AppKit

@main
struct WindowLayoutMemoryTests {
    static func main() throws {
        let layout = RememberedWindowLayout(x: 1700, y: 900, width: 800, height: 600,
            screenID: 1, screenX: 0, screenY: 0)
        let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        assert(layout.fitted(to: area, sameScreen: true) == CGRect(x: 1120, y: 480, width: 800, height: 600))
        let small = CGRect(x: -1024, y: 0, width: 640, height: 480)
        assert(layout.fitted(to: small, sameScreen: false) == small)
        let relocated = RememberedWindowLayout(x: 2100, y: 100, width: 500, height: 400,
            screenID: 2, screenX: 1920, screenY: 25)
        assert(relocated.fitted(to: area, sameScreen: false).origin == CGPoint(x: 180, y: 100))
        let encoded = try JSONEncoder().encode(["test.app": layout])
        let decoded = try JSONDecoder().decode([String: RememberedWindowLayout].self, from: encoded)
        assert(decoded["test.app"] == layout)
        print("PASS bounds, display relocation and layout serialization")
    }
}

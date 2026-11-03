import Foundation

/// Both backends use this normalizer; neither leaks its native tree format into agent tools.
public enum PhoneAccessibility {
    public static func elements(from source: Any, width: Int, height: Int) -> [PhoneElement] {
        var elements: [PhoneElement] = []
        func string(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty else { return nil }
            return value
        }
        func boolean(_ value: Any?, fallback: Bool = true) -> Bool {
            if let number = value as? NSNumber { return number.boolValue }
            if let text = value as? String {
                switch text.lowercased() {
                case "0", "false", "no": return false
                case "1", "true", "yes": return true
                default: break
                }
            }
            return fallback
        }
        func visit(_ value: Any) {
            if let list = value as? [Any] { list.forEach(visit); return }
            guard let node = value as? [String: Any] else { return }
            let rect = (node["frame"] ?? node["rect"]) as? [String: Any] ?? [:]
            func number(_ key: String) -> Double { (rect[key] as? NSNumber)?.doubleValue ?? 0 }
            let bounds = PhoneBounds(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            let type = string(node["type"]) ?? string(node["role"]) ?? "unknown"
            let role = normalizedRole(type)
            let label = string(node["AXLabel"]) ?? string(node["label"]) ?? string(node["name"])
            let identifier = string(node["AXUniqueId"]) ?? string(node["rawIdentifier"]) ?? string(node["identifier"])
            let visible = boolean(node["isVisible"] ?? node["visible"])
            if visible, bounds.intersects(width: width, height: height),
               label != nil || identifier != nil || !["application", "window", "other", "unknown"].contains(role) {
                let secure = type.lowercased().contains("secure") || boolean(node["secure"], fallback: false)
                elements.append(PhoneElement(role: role, identifier: identifier, label: label,
                                             value: string(node["AXValue"]) ?? string(node["value"]), bounds: bounds,
                                             enabled: boolean(node["isEnabled"] ?? node["enabled"]),
                                             secure: secure))
            }
            (node["children"] as? [Any])?.forEach(visit)
        }
        visit(source)
        return elements
    }

    public static func normalizedRole(_ raw: String) -> String {
        let role = raw.replacingOccurrences(of: "XCUIElementType", with: "").replacingOccurrences(of: "AX", with: "").lowercased()
        switch role {
        case "statictext", "text": return "text"
        case "textfield", "securetextfield", "text field", "secure text field", "searchfield": return "textfield"
        case "textview", "text view": return "textview"
        case "scrollview", "scroll view": return "scrollview"
        case "cell", "tablecell": return "cell"
        default: return role
        }
    }
}

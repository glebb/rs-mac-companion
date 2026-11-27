// Checks of how app/Sources/Rig.swift reads tunings (stock and RS Extended Range charts); run by
// tests/run_extended_range_test.sh. Usage: harness [<folder of Mac fixture packages>]
// Without a folder only the synthetic manifests are checked.
import Foundation

@main struct Harness {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    /// A manifest's attributes: Tuning string0.. from offsets, ExtendedRange if extended.
    static func attributes(_ offsets: [Double], extended: Bool, cents: Double = 0) -> [String: Any] {
        var t: [String: Any] = [:]
        for (i, x) in offsets.enumerated() { t["string\(i)"] = NSNumber(value: x) }
        var a: [String: Any] = ["Tuning": t, "CentOffset": NSNumber(value: cents)]
        if extended { a["ExtendedRange"] = ["Version": 1] }
        return a
    }

    static func expect(_ what: String, _ offsets: [Double], bass: Bool = false, extended: Bool = false,
                       cents: Double = 0, name: String?, strings: Int = 0, low: Double = 0, stock: [Double]? = nil) {
        let t = Rig.tuning(attributes(offsets, extended: extended, cents: cents), bass: bass)
        guard let name else { return check(t == nil, "\(what): read as \(String(describing: t))") }
        guard let t else { return check(false, "\(what): not read") }
        check(t.name == name, "\(what): name \(t.name), expected \(name)")
        check(t.strings == strings, "\(what): \(t.strings) strings, expected \(strings)")
        check(abs(t.lowString - low) < 1e-9, "\(what): lowString \(t.lowString), expected \(low)")
        check(t.extended == (strings > (bass ? 4 : 6)), "\(what): extended \(t.extended)")
        check(t.positional == (t.extended ? offsets : []), "\(what): positional \(t.positional)")
        if let stock { check(t.stock == stock, "\(what): stock \(t.stock), expected \(stock)") }
    }

    static func main() {
        // Stock arrangements: names as before.
        expect("stock drop D", [-2, 0, 0, 0, 0, 0], name: "Drop D", strings: 6, low: -2, stock: [-2, 0, 0, 0, 0, 0])
        expect("stock Eb standard", [-1, -1, -1, -1, -1, -1], cents: -50, name: "Eb standard", strings: 6, low: -1.5)
        expect("stock C# drop B", [-5, -3, -3, -3, -3, -3], name: "Drop B", strings: 6, low: -5)
        expect("stock custom", [0, 0, 0, 0, 2, 0], name: "custom", strings: 6, low: 0)
        expect("stock bass (6 entries, 4 count)", [-2, 0, 0, 0, 5, 7], bass: true, name: "Drop D", strings: 4, low: -2,
               stock: [-2, 0, 0, 0, 5, 7])
        expect("stock bass, only 4 entries", [0, 0, 0, 0], bass: true, name: "E standard", strings: 4, low: 0,
               stock: [0, 0, 0, 0, 0, 0])
        expect("a 7th entry without ExtendedRange is stock", [0, 0, 0, 0, 0, 0, -2], name: "E standard", strings: 6, low: 0)
        expect("ExtendedRange with 6 strings is stock", [-2, 0, 0, 0, 0, 0], extended: true, name: "Drop D", strings: 6,
               low: -2)
        expect("ExtendedRange bass with 4 strings is stock", [0, 0, 0, 0], bass: true, extended: true,
               name: "E standard", strings: 4, low: 0)
        expect("guitar with 5 entries", [0, 0, 0, 0, 0], name: nil)
        expect("no Tuning", [], name: nil)

        // RS Extended Range charts: positional offsets, the stock six (guitar) or four (bass) inside them.
        expect("7-string B standard", [0, 0, 0, 0, 0, 0, 0], extended: true, name: "B standard (7-string)", strings: 7,
               low: -5, stock: [0, 0, 0, 0, 0, 0])
        expect("7-string drop A", [-2, 0, 0, 0, 0, 0, 0], extended: true, name: "Drop A (7-string)", strings: 7, low: -7)
        expect("7-string A standard, a quarter down", [-2, -2, -2, -2, -2, -2, -2], extended: true, cents: -50,
               name: "A standard (7-string)", strings: 7, low: -7.5)
        expect("8-string F# standard", [0, 0, 0, 0, 0, 0, 0, 0], extended: true, name: "F# standard (8-string)",
               strings: 8, low: -10)
        expect("8-string drop E", [-2, 0, 0, 0, 0, 0, 0, 0], extended: true, name: "Drop E (8-string)", strings: 8,
               low: -12, stock: [0, 0, 0, 0, 0, 0])
        expect("8-string custom", [0, 0, 0, 0, 0, 0, -1, 0], extended: true, name: "custom (8-string)", strings: 8,
               low: -10, stock: [0, 0, 0, 0, -1, 0])
        expect("5-string bass B standard", [0, 0, 0, 0, 0], bass: true, extended: true, name: "B standard (5-string)",
               strings: 5, low: -5, stock: [0, 0, 0, 0, 0, 0])
        expect("5-string bass drop A", [-2, 0, 0, 0, 0], bass: true, extended: true, name: "Drop A (5-string)",
               strings: 5, low: -7)
        expect("6-string bass B standard", [0, 0, 0, 0, 0, 0], bass: true, extended: true, name: "B standard (6-string)",
               strings: 6, low: -5, stock: [0, 0, 0, 0, 0, 0])
        expect("6-string bass A standard", [-2, -2, -2, -2, -2, -2], bass: true, extended: true,
               name: "A standard (6-string)", strings: 6, low: -7, stock: [-2, -2, -2, -2, -2, 0])
        expect("9 guitar strings", [0, 0, 0, 0, 0, 0, 0, 0, 0], extended: true, name: nil)
        expect("7 bass strings", [0, 0, 0, 0, 0, 0, 0], bass: true, extended: true, name: nil)

        // The fixture packages (Mac), as the app reads them: name, lowString, tones and changes.
        if CommandLine.arguments.count > 1 {
            let dir = CommandLine.arguments[1]
            let cases: [(file: String, prefix: String, name: String, tuning: String, low: Double, tones: Int, changes: Int)] = [
                ("Nickelback_Burn-It-To-The-Ground_Dell_v2_3_rsxr_m.psarc", "dellnickelbackburnittotheground7stringv23",
                 "dellnickelbackburnittotheground7stringv23_lead", "B standard (7-string)", -5, 2, 2),
                ("Nickelback_Burn-It-To-The-Ground_Dell_v2_3_rsxr_m.psarc", "dellnickelbackburnittotheground7stringv23",
                 "dellnickelbackburnittotheground7stringv23_rhythm", "Drop B", -5, 2, 2),
                ("Nickelback_Burn-It-To-The-Ground_Dell_v2_3_rsxr_m.psarc", "dellnickelbackburnittotheground7stringv23",
                 "dellnickelbackburnittotheground7stringv23_bass", "B standard (5-string)", -5, 1, 0),
                ("Fear-Factory_Soul-Hacker_Dell_v0_2_rsxr_m.psarc", "dellfearfactorysoulhacker8stringt2",
                 "dellfearfactorysoulhacker8stringt2_lead", "F# standard (8-string)", -10, 1, 0),
                ("Jinjer_Wallflower_Dell_v2_2_rsxr_m.psarc", "delljinjerwallflower5stringbassv22",
                 "delljinjerwallflower5stringbassv22_bass", "Drop A (5-string)", -7, 1, 0),
                ("Nirvana-TerritorialPissings_m.psarc", "territorialspissings", "territorialspissings_lead",
                 "E standard", 0, 3, 4),
                ("Nirvana-TerritorialPissings_m.psarc", "territorialspissings", "territorialspissings_bass",
                 "E standard", 0, 1, 0),
                ("GameTestAlternates_m.psarc", "gametestalternates", "gametestalternates_lead2", "Drop B", -5, 2, 2),
                ("GameTestAlternates_m.psarc", "gametestalternates", "gametestalternates_bass", "E standard", 0, 1, 0),
            ]
            for c in cases {
                guard let arrs = Rig.read(archive: "\(dir)/\(c.file)", prefix: c.prefix) else {
                    check(false, "\(c.file) not read"); continue
                }
                guard let a = arrs.first(where: { $0.name == c.name }) else { check(false, "\(c.name) missing"); continue }
                check(Rig.tuningName(a) == c.tuning, "\(c.name): \(Rig.tuningName(a) ?? "nil"), expected \(c.tuning)")
                check(a.lowString == c.low, "\(c.name): lowString \(a.lowString), expected \(c.low)")
                check(Set(a.tones.map(\.key)).count == c.tones, "\(c.name): \(a.tones.count) tones, expected \(c.tones)")
                check(a.changes.count == c.changes, "\(c.name): \(a.changes.count) changes, expected \(c.changes)")
                print("app: \(c.name): \(Rig.tuningName(a) ?? "nil"), lowString \(a.lowString), "
                      + "\(a.tones.count) tones, \(a.changes.count) changes")
            }
            // The song's heaviness counts the 7-string's low B as a low string (Rhythm, Drop B, comes first anyway).
            if let arrs = Rig.read(archive: "\(dir)/Nickelback_Burn-It-To-The-Ground_Dell_v2_3_rsxr_m.psarc",
                                   prefix: "dellnickelbackburnittotheground7stringv23") {
                let lead = arrs.filter { $0.path == "Lead" }
                if let h = Rig.heaviness(lead), let t = Rig.tone(lead[0], key: lead[0].slots[0]), let d = Rig.drive(t) {
                    check(abs(h - min(d + 0.1, 1)) < 1e-9, "7-string lead's heaviness \(h) without the low-string 0.1")
                }
            }
        }
        print(failures == 0 ? "rig harness: all checks passed" : "rig harness: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

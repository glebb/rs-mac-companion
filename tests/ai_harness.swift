// For tests/run_ai_app_test.sh: asks the stand-in server (tests/stub_responses.py) about a song with
// AIClassifier, saves the answer and prints what Presets then does with it, one "name: value" per line.
import Foundation

@main
struct Harness {
    static func main() async {
        let dir = CommandLine.arguments[1], url = URL(string: CommandLine.arguments[2])!
        let p = Presets(path: dir + "/presets.json", defaults: nil)
        func show(_ name: String, _ arrangement: String, _ key: String, artist: String = "Bon Jovi") {
            let m = p.match(arrangement: arrangement, slot: "B", tone: .init(key: key, descriptors: []), artist: artist)
            print("\(name): \(m.category.name) (\(m.reason))")
        }
        show("before", "bonjoviprayer_rhythm", "riff_dist")
        let song = AIClassifier.Song(songKey: "BonJoviPrayer", artist: "Bon Jovi", title: "Livin' on a Prayer",
                                     tuning: "E standard", tempo: 123, heaviness: 0.81, ruleStyle: "Metal",
                                     ruleCategories: ["Heavy": 2, "Crunch": 1], amps: ["MarshallJCM800"])
        print("line: " + AIClassifier.describe(song))
        do {
            let answer = try await AIClassifier.classify(song, styles: p.styleList, model: "test-model", key: "sk-test",
                                                         endpoint: url)
            AIClassifier.save(answer, songKey: "BonJoviPrayer", to: p.answersPath)
        } catch {
            print("error: \(error)")
        }
        p.reload()
        print("answer: \(p.answer("bonjoviprayer").map { "\($0.style) \($0.distortion) \($0.confidence)" } ?? "none")")
        show("after", "bonjoviprayer_rhythm", "riff_dist")
        show("other song by artist (suggestions)", "bonjovirunaway_rhythm", "riff_dist")
        print("style: " + p.style(heaviness: 0.81, artist: "Bon Jovi", songKey: "bonjoviprayer"))
        print("style without ai: " + p.style(heaviness: 0.81, artist: "Bon Jovi", songKey: "bonjoviprayer", ai: false))
        p.setRejected("bonjoviprayer", true)
        show("rejected", "bonjoviprayer_rhythm", "riff_dist")
        print("style rejected: " + p.style(heaviness: 0.81, artist: "Bon Jovi", songKey: "bonjoviprayer"))
        p.setRejected("bonjoviprayer", false)
        show("used again", "bonjoviprayer_rhythm", "riff_dist")
        do {
            _ = try await AIClassifier.classify(song, styles: p.styleList, model: "test-model", key: "sk-bad", endpoint: url)
        } catch {
            print("bad key: \(error)")
        }
        // A hand edit that breaks presets.json: the last mapping stays in use and nothing is saved over it.
        let file = dir + "/presets.json", good = try! String(contentsOfFile: file, encoding: .utf8)
        let broken = "{\"rules\": [ oops"
        try! broken.write(toFile: file, atomically: true, encoding: .utf8)
        p.reload()
        print("broken error: \(p.error ?? "none")")
        p.setRejected("bonjoviprayer", true)
        p.set([("bonjoviprayer_rhythm", "B")], key: "riff_dist", to: .clean)
        print("broken file kept: \((try? String(contentsOfFile: file, encoding: .utf8)) == broken)")
        show("broken mapping", "bonjoviprayer_rhythm", "riff_dist")
        try! good.write(toFile: file, atomically: true, encoding: .utf8)
        p.reload()
        print("fixed error: \(p.error ?? "none")")
        p.set([("bonjoviprayer_rhythm", "B")], key: "riff_dist", to: .clean)
        show("fixed override", "bonjoviprayer_rhythm", "riff_dist")
    }
}

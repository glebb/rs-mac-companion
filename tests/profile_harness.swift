// Unit checks of device profiles (app/Sources/Profile.swift); run by tests/run_profile_test.sh.
// Usage: harness <folder of bundled profiles>
import Foundation

@main struct Harness {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    static func load(_ dir: String, _ id: String) -> Profile {
        try! Profile.parse(FileManager.default.contents(atPath: "\(dir)/\(id).json")!, id: id)
    }

    static func rejects(_ json: String, _ why: String) {
        do {
            _ = try Profile.parse(Data(json.utf8), id: "x")
            check(false, "accepted \(json)")
        } catch {
            let said = (error as? Profile.Invalid)?.why ?? ""
            check(said.contains(why), "\(json): said \"\(said)\", expected \"\(why)\"")
        }
    }

    static func main() {
        let dir = CommandLine.arguments[1]
        let plain = load(dir, "program-changes"), stagehand = load(dir, "stagehand"), stomp = load(dir, "hx-stomp")

        // The plain profile is the fallback's output.
        check(plain.sendsTheSame(as: .plain), "program-changes.json differs from Profile.plain")
        check(!plain.needsSongData, "plain profile shouldn't need song data")
        check(plain.toneSteps(category: .heavy, toneIndex: 1, effectKinds: ["delay"]) == [.pc(2)], "plain Heavy")

        // Stagehand: the song's tone wins over the category, which stays for anything else.
        check(stagehand.toneSteps(category: .clean, toneIndex: 2, effectKinds: []) == [.pc(10)], "Stagehand song tone")
        check(stagehand.toneSteps(category: .lead, toneIndex: nil, effectKinds: []) == [.pc(3)], "Stagehand fallback")
        check(stagehand.songLoadSteps(style: "Metal") == [.songTonesMessage], "\"*\" applies to any style")
        check(stagehand.songLoadAgain, "Stagehand gets the message again")

        // HX Stomp: a preset by style, a snapshot, then every effect CC, on or off, in order.
        check(stomp.destination == .device("HX Stomp"), "Stomp destination")
        check(stomp.songLoadSteps(style: "Classic rock") == [.pc(1), .wait(500)], "Stomp style preset, then time to load it")
        check(stomp.songLoadSteps(style: "Unknown").isEmpty, "a style without a sequence sends nothing")
        check(!stomp.songLoadAgain, "Stomp isn't switched while a song plays")
        check(stomp.toneSteps(category: .lead, toneIndex: 0, effectKinds: ["chorus", "reverb"])
              == [.cc(69, 2), .cc(20, 127), .cc(21, 127), .cc(22, 0), .cc(23, 0), .cc(24, 0), .cc(25, 127)], "Stomp Lead")
        // Kinds on one CC are one switch: flanger on must not be undone by chorus off.
        let flanger = stomp.toneSteps(category: .clean, toneIndex: nil, effectKinds: ["flanger"])
        check(flanger.filter { $0 == .cc(21, 127) }.count == 1 && !flanger.contains(.cc(21, 0)), "shared CC")
        check(stomp.toneSteps(category: .clean, toneIndex: nil, effectKinds: ["ring modulator"]).contains(.cc(21, 0)),
              "an unmapped kind switches nothing on")

        // Settings from before profiles.
        check(Profile.legacy(json: [:]).sendsTheSame(as: plain), "no settings = Program Changes")
        check(Profile.legacy(json: ["song_tones": true]).sendsTheSame(as: stagehand), "song tones on = Stagehand")
        let custom = Profile.legacy(json: ["midi_channel": 2, "programs": ["Clean": 4, "Crunch": 5, "Heavy": 6, "Lead": 7],
                                           "song_tones": true, "song_tone_programs": false])
        check(custom.channel == 2 && custom.category[3] == [.pc(7)] && custom.toneFirstProgram == nil, "custom settings")
        check(custom.songLoad["*"] == [.songTonesMessage], "song tones without their programs")
        // A migrated profile's file reads back the same, and every step type survives.
        var all = custom
        all.category[0] = [.pc(1), .wait(50), .cc(7, 100), .bytes([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]), .bytes([0xC0, 3])]
        all.effects = ["delay": 30]
        all.destination = .device("Some Amp")
        check((try? Profile.parse(all.json, id: all.id)) == all, "file round trip")

        // Mistakes say what's wrong instead of doing nothing.
        rejects("not json", "not valid JSON")
        rejects("{}", "name")
        rejects(#"{"name": "x", "chanel": 2}"#, "unknown key \"chanel\"")
        rejects(#"{"name": "x", "channel": 17}"#, "channel")
        rejects(#"{"name": "x", "category": {"Dirty": []}}"#, "unknown category")
        rejects(#"{"name": "x", "category": {"Clean": [{"pc": 128}]}}"#, "pc")
        rejects(#"{"name": "x", "category": {"Clean": [{"cc": 69}]}}"#, "unknown step")
        rejects(#"{"name": "x", "category": {"Clean": [{"cc": 69, "value": 200}]}}"#, "cc value")
        rejects(#"{"name": "x", "category": {"Clean": [{"bytes": "F0 7E"}]}}"#, "one MIDI message")
        rejects(#"{"name": "x", "category": {"Clean": [{"bytes": "B0 45"}]}}"#, "one MIDI message")
        rejects(#"{"name": "x", "category": {"Clean": [{"bytes": "zz"}]}}"#, "bad bytes")
        rejects(#"{"name": "x", "effects": {"wah": 3}}"#, "unknown effect")

        print(failures == 0 ? "PASS (unit)" : "FAIL (unit): \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

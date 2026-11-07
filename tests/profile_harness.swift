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

        // Amp load: the listed amp that plays longest, amps on one sequence adding up, else the style.
        let byAmp = try! Profile.parse(Data(#"""
            {"name": "x", "song_load": {"*": [{"pc": 1}]},
             "amp_load": {"Amp_A": [{"pc": 10}], "Amp_B": [{"pc": 11}], "Amp_C": [{"pc": 11}]},
             "effects": {"delay": 24},
             "knobs": [{"cc": 30, "from": "drive"}, {"cc": 31, "from": "delay_time", "range": [100, 1100]},
                       {"cc": 32, "from": "reverb_mix", "default": 5}, {"cc": 33, "from": "gain", "range": [100, 0]}]}
            """#.utf8), id: "x")
        check(byAmp.needsSongData, "knobs and amps need the song's gear")
        check(byAmp.songLoadSteps(style: "Soft") == [.pc(1)], "no amps: the style")
        check(byAmp.songLoadSteps(style: "Soft", amps: [("Amp_Z", 90)]) == [.pc(1)], "an amp not listed: the style")
        check(byAmp.songLoadSteps(style: "Soft", amps: [("Amp_Z", 90), ("Amp_A", 5)]) == [.pc(10)], "the longest of those listed")
        check(byAmp.songLoadSteps(style: "Soft", amps: [("Amp_A", 50), ("Amp_B", 30), ("Amp_C", 30)]) == [.pc(11)],
              "amps on one sequence add up")
        check(byAmp.songLoadSteps(style: "Soft", amps: [("Amp_A", 30), ("Amp_B", 30)]) == [.pc(10)], "a tie goes to the first played")

        // Knobs: after the sound, before the effects; clamped; a missing value sends its default or nothing.
        check(byAmp.toneSteps(category: .clean, toneIndex: 0, effectKinds: ["delay"],
                              knobValues: ["drive": 0.5, "delay_time": 5000, "gain": 25])
              == [.cc(30, 64), .cc(31, 127), .cc(32, 5), .cc(33, 95), .cc(24, 127)], "knob steps")
        check(byAmp.toneSteps(category: .clean, toneIndex: nil, effectKinds: []) == [.cc(32, 5), .cc(24, 0)], "a tone without values")

        // The drive: the AI moves distorted tones, clean ones stay, and the category has the last word.
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        check(near(Rig.corrected(0.8, offset: 0, category: .heavy), 0.8), "no correction")
        check(near(Rig.corrected(0.8, offset: 1, category: .crunch), 0.4667), "a step down")
        check(near(Rig.corrected(0.2, offset: 1, category: .clean), 0.2), "a clean tone stays")
        check(near(Rig.corrected(0.8, offset: 0, category: .clean), 1.0 / 3), "an override to Clean stays clean")
        check(near(Rig.corrected(0.1, offset: 0, category: .heavy), 2.0 / 3), "an override to Heavy is heavy")
        check(near(Rig.corrected(0.95, offset: 0, category: .lead), 0.95), "Lead has no band")
        check(near(Rig.corrected(0.9, offset: -1, category: .lead), 1), "at most 1")

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
        all.ampLoad = ["Amp_CA100": [.pc(9), .wait(500)]]
        all.knobs = [.init(cc: 40, from: "drive", range: [0, 1], fallback: nil), .init(cc: 41, from: "reverb_mix", range: [50, 0], fallback: 3)]
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

        rejects(#"{"name": "x", "amp_load": {"CA100": []}}"#, "isn't an amp")
        rejects(#"{"name": "x", "knobs": {}}"#, "is a list")
        rejects(#"{"name": "x", "knobs": [{"cc": 30, "from": "volume"}]}"#, "\"from\"")
        rejects(#"{"name": "x", "knobs": [{"cc": 300, "from": "drive"}]}"#, "knob cc")
        rejects(#"{"name": "x", "knobs": [{"cc": 30, "from": "drive", "scale": 2}]}"#, "unknown knob key")
        rejects(#"{"name": "x", "knobs": [{"cc": 30, "from": "drive", "range": [1, 1]}]}"#, "range")
        rejects(#"{"name": "x", "knobs": [{"cc": 30, "from": "drive", "default": 128}]}"#, "knob default")
        rejects(#"{"name": "x", "knobs": [{"cc": 30, "from": "drive"}, {"cc": 30, "from": "gain"}]}"#, "two knobs")
        rejects(#"{"name": "x", "effects": {"delay": 30}, "knobs": [{"cc": 30, "from": "drive"}]}"#, "both a knob and an effect")

        print(failures == 0 ? "PASS (unit)" : "FAIL (unit): \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

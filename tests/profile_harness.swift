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
        check(stomp.toneSteps(category: .lead, toneIndex: 0, effectKinds: ["chorus", "reverb"], knobValues: ["drive": 0.8])
              == [.cc(69, 2), .cc(20, 127), .cc(38, 127), .cc(21, 127), .cc(22, 0), .cc(23, 0), .cc(24, 127), .cc(25, 127)],
              "Stomp Lead: lift, push, and a delay of its own")
        check(stomp.toneSteps(category: .lead, toneIndex: 0, effectKinds: ["chorus"], knobValues: ["drive": 0.2])
              == [.cc(69, 0), .cc(20, 127), .cc(38, 0), .cc(21, 127), .cc(22, 0), .cc(23, 0), .cc(24, 0), .cc(25, 0)],
              "Stomp clean Lead: the Clean snapshot, lifted, no push and no added delay")
        check(stomp.toneSteps(category: .heavy, toneIndex: 0, effectKinds: [])
              == [.cc(69, 2), .cc(20, 0), .cc(38, 0), .cc(21, 0), .cc(22, 0), .cc(23, 0), .cc(24, 0), .cc(25, 0)], "Stomp Heavy")
        // Kinds on one CC are one switch: flanger on must not be undone by chorus off.
        let flanger = stomp.toneSteps(category: .clean, toneIndex: nil, effectKinds: ["flanger"])
        check(flanger.filter { $0 == .cc(21, 127) }.count == 1 && !flanger.contains(.cc(21, 0)), "shared CC")
        check(stomp.toneSteps(category: .clean, toneIndex: nil, effectKinds: ["ring modulator"]).contains(.cc(21, 0)),
              "an unmapped kind switches nothing on")

        // HX Stomp by amp: the song's amp picks the preset, the style only when no preset has it.
        let amps = load(dir, "hx-stomp-amps")
        check(amps.songLoadSteps(style: "Metal", amps: [("Amp_GB100", 60)]) == [.pc(3), .wait(500)], "the amp's preset")
        check(amps.songLoadSteps(style: "Metal", amps: [("Amp_Unknown", 60)]) == [.pc(2), .wait(500)], "the style's preset")
        // As rs-tonehost: the amp's Drive and input by the gain, faster with a boost pedal, and a level per amp and tone
        func value(_ steps: [Profile.Step], _ n: Int) -> Int? {
            steps.lazy.compactMap { if case .cc(n, let v) = $0 { v } else { nil } }.first
        }
        let jcm = amps.toneSteps(category: .lead, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.8, "gain": 100],
                                 tempo: 120, amp: "Amp_MarshallJCM800")
        check(jcm.prefix(3) == [.cc(69, 2), .cc(20, 127), .cc(38, 127)], "Stomp Lead: snapshot, lift, push")
        check(value(jcm, 26) == 127 && value(jcm, 39) == 90 && value(jcm, 24) == 127 && value(jcm, 40) == 0,
              "gain 100: Drive at its top, input at 28 of 39.5 dB, a delay added, no boost: \(jcm)")
        check(value(jcm, 37) != nil && value(amps.toneSteps(category: .lead, toneIndex: 0, effectKinds: [],
                                                             knobValues: ["drive": 0.8, "gain": 100]), 37) == nil,
              "the level comes from the song's amp; a song a style's preset plays has none")
        // An amp that goes silent near the bottom of its gain (Plexi Brt, which Amp_MarshallPlexi plays) keeps
        // tonehost's least Drive; the others follow the gain all the way down
        let plexi = { (g: Double) in value(amps.toneSteps(category: .clean, toneIndex: 0, effectKinds: [],
                                                          knobValues: ["drive": 0.1, "gain": g], amp: "Amp_MarshallPlexi"), 26) }
        check(plexi(0) == plexi(10) && plexi(0)! > 10 && plexi(60) == 76,
              "a least gain: \(String(describing: plexi(0))), \(String(describing: plexi(10))), \(String(describing: plexi(60)))")
        check(value(amps.toneSteps(category: .clean, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.1, "gain": 0],
                                   amp: "Amp_GB100"), 26) == 0, "no least gain on an amp that plays at the bottom of its gain")
        // A Lo-Fi Filter: the cab's cuts towards a band limit by its mix; without one, the cab's own (CC 0)
        let cuts = { (v: [String: Double]) in
            let s = amps.toneSteps(category: .clean, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.1, "gain": 30].merging(v) { $1 },
                                   amp: "Amp_MarshallJCM800")
            return [value(s, 45), value(s, 46)]
        }
        check(cuts([:]) == [0, 0] && cuts(["lofi": 100]) == [127, 127] && cuts(["lofi": 50]).allSatisfy { ($0 ?? 0) > 10 && ($0 ?? 0) < 100 },
              "the cab's cuts: \(cuts([:])), \(cuts(["lofi": 100])), \(cuts(["lofi": 50]))")
        // The tone knobs with the EQ folded in, on CC 27-29
        check(value(amps.toneSteps(category: .clean, toneIndex: 0, effectKinds: [],
                                   knobValues: ["drive": 0.1, "gain": 30, "bass": 60, "bass_eq": 80], amp: "Amp_MarshallJCM800"), 27) == 102,
              "CC 27 follows the bass with the EQ in it")
        let boosted = amps.toneSteps(category: .heavy, toneIndex: 0, effectKinds: ["overdrive"],
                                     knobValues: ["drive": 0.8, "gain": 100, "overdrive_gain": 50], amp: "Amp_MarshallJCM800")
        check(value(boosted, 39) == 127 && value(boosted, 40) == 127 && value(boosted, 41) == 64 && value(boosted, 37) != value(jcm, 37),
              "with a boost pedal: the input's full rise, the Minotaur on at the pedal's gain, its own level: \(boosted)")
        // A lead with no delay gets one, a dotted eighth of the song's tempo; Heavy doesn't, and the push is off.
        let lead = amps.toneSteps(category: .lead, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.7], tempo: 120)
        check(lead.contains(.cc(31, 24)) && lead.contains(.cc(34, 25)) && lead.contains(.cc(33, 25)) && lead.contains(.cc(24, 127)),
              "Stomp Lead gets a delay")
        let heavy = amps.toneSteps(category: .heavy, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.7], tempo: 120)
        check(heavy.prefix(3) == [.cc(69, 2), .cc(20, 0), .cc(38, 0)] && heavy.contains(.cc(24, 0)) && !heavy.contains(.cc(31, 24)),
              "Stomp Heavy: no lift, no push, no delay")

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

        // A delay for a category's tones that have none: on, timed by the song's tempo, with the given mix and feedback.
        let added = try! Profile.parse(Data(#"""
            {"name": "x", "effects": {"delay": 24, "reverb": 25},
             "knobs": [{"cc": 31, "from": "delay_time"}, {"cc": 33, "from": "delay_feedback"}, {"cc": 34, "from": "delay_mix"}],
             "add_delay": {"Lead": {"beats": 0.75, "mix": 20, "feedback": 25}}}
            """#.utf8), id: "x")
        check(added.toneSteps(category: .lead, toneIndex: 0, effectKinds: ["reverb"], tempo: 120)
              == [.cc(31, 24), .cc(33, 32), .cc(34, 25), .cc(24, 127), .cc(25, 127)], "a lead gets a dotted eighth: 375 ms at 120 bpm")
        check(added.toneSteps(category: .lead, toneIndex: 0, effectKinds: [], tempo: 60).first == .cc(31, 48), "750 ms at 60 bpm")
        check(added.toneSteps(category: .lead, toneIndex: nil, effectKinds: []).first == .cc(31, 24), "no tempo: 120 bpm")
        check(added.toneSteps(category: .lead, toneIndex: 0, effectKinds: ["delay"],
                              knobValues: ["delay_time": 1000, "delay_mix": 50, "delay_feedback": 0], tempo: 120)
              == [.cc(31, 64), .cc(33, 0), .cc(34, 64), .cc(24, 127), .cc(25, 0)], "a lead's own delay stays as it is")
        check(added.toneSteps(category: .heavy, toneIndex: 0, effectKinds: [], tempo: 120) == [.cc(24, 0), .cc(25, 0)],
              "other categories get none")
        check((try? Profile.parse(added.json, id: "x")) == added, "add_delay round trip")

        // Drive pedals: a boost or overdrive, and a distortion, metal or fuzz pedal, each the one with the most gain.
        let pedals = Rig.Tone(key: "t", gear: [
            "Amp": .init(key: "Amp_MarshallJCM800", knobs: ["Gain": 60]),
            "PrePedal1": .init(key: "Pedal_SuperDrive", knobs: ["Gain": 40, "Tone": 20]),
            "PrePedal2": .init(key: "Pedal_RangeBooster", knobs: ["Boost": 70]),
            "PrePedal3": .init(key: "Pedal_MetalDistortion", knobs: ["Gain": 55]),
        ])
        let fx = Rig.effects(pedals), pv = Rig.values(pedals)
        check(fx.kinds == ["overdrive", "distortion"], "pedal kinds: \(fx.kinds)")
        check(fx.overdrive?.key == "Pedal_RangeBooster" && pv["overdrive_gain"] == 70 && pv["overdrive_tone"] == nil,
              "the overdrive with the most gain, a booster's Boost as its gain")
        check(pv["distortion_gain"] == 55, "distortion gain")
        let ungained = Rig.effects(Rig.Tone(key: "t", gear: [
            "PrePedal1": .init(key: "Pedal_LineDrive", knobs: [:]),
            "PrePedal2": .init(key: "Pedal_SuperDrive", knobs: [:]),
        ]))
        check(ungained.overdrive?.key == "Pedal_LineDrive", "pedals without a gain: the first in slot order")
        let inDB = Rig.values(Rig.Tone(key: "t", gear: ["Amp": .init(key: "Bass_Amp_EdenWT550",
                                                                     knobs: ["Bass": -12, "Mid": 0, "Treble": 6, "Pres": 40])]))
        check(inDB["bass"] == 0 && inDB["mid"] == 50 && inDB["treble"] == 75 && inDB["presence"] == 40,
              "an amp's tone knobs in dB on the 0-100 of the others': \(inDB)")
        check(pv["bass"] == nil && Rig.values(Rig.Tone(key: "t", gear: ["Amp": .init(key: "Bass_Amp_BT600B", knobs: ["Bass": 30])]))["bass"] == 30,
              "other amps' tone knobs as they are")

        // EQs: their broad shape onto the amp's tone knobs, and a Lo-Fi Filter's mix
        let amp60 = Rig.Gear(key: "Amp_MarshallJCM800", knobs: ["Bass": 60, "Mid": 50, "Treble": 40])
        let graphic = Rig.Tone(key: "t", gear: ["Amp": amp60, "PrePedal1": .init(key: "Pedal_EQ5",
            knobs: ["63": 6, "250": 0, "750": -4, "2200": 8, "5700": 4])])
        let g = Rig.eqShape(graphic)
        check(g?.low == 3 && g?.mid == -4 && g?.high == 6, "a graphic EQ's bands averaged by region: \(String(describing: g))")
        let gv = Rig.values(graphic)
        check(gv["bass_eq"] == 72.5 && gv["mid_eq"] == 50 - 4 * 100 / 24.0 && gv["treble_eq"] == 65 && gv["bass"] == 60,
              "the shape on the knobs, ±12 dB half their travel; the amp's own knobs as they are: \(gv)")
        let studio = Rig.Tone(key: "t", gear: ["Amp": amp60, "Rack1": .init(key: "Rack_StudioEQ",
            knobs: ["Bass": -12, "BassFreq": 120, "LoMid": 6, "LoMidFreq": 800, "HiMid": 10, "HiMidFreq": 4, "Treble": 9, "TrebleFreq": 5]),
            "Rack2": .init(key: "Rack_StudioEQ", knobs: ["Bass": -6, "BassFreq": 100])])
        let st = Rig.eqShape(studio)
        check(st?.low == -12 && st?.mid == 3 && st?.high == 12, "shelves in full, peaks by half, two EQs added, ±12 at most: \(String(describing: st))")
        check(Rig.values(studio)["bass_eq"] == 10 && Rig.values(studio)["treble_eq"] == 90, "clamped to the knob")
        check(Rig.eqShape(pedals) == nil && pv["bass_eq"] == nil && pv["lofi"] == nil, "no EQ, no amp knob: nothing")
        let lofi = Rig.Tone(key: "t", gear: ["Amp": amp60, "PostPedal1": .init(key: "Pedal_LoFiFilter", knobs: ["Mix": 22, "FilterType": 77])])
        check(Rig.values(lofi)["lofi"] == 22 && Rig.values(lofi)["bass_eq"] == 60, "a Lo-Fi Filter: its mix, and no EQ shape")

        // Knobs: a range for a tone with an effect, and sums of terms.
        let formula = try! Profile.parse(Data(#"""
            {"name": "x", "effects": {"overdrive": 40, "delay": 24},
             "amp_load": {"Amp_A": [{"pc": 3}], "Amp_B": [{"pc": 4}]},
             "category": {"Lead": [{"cc": 69, "value": 2}], "Lead clean": [{"cc": 69, "value": 0}]},
             "knobs": [{"cc": 39, "from": "gain", "range": [0, 200], "with": {"overdrive": [0, 100]}},
                       {"cc": 37, "range": [-10, 10], "sum": [{"add": 2}, {"from": "gain", "points": [[0, 0], [50, -4], [100, -6]]},
                                                               {"from": "gain", "with": "overdrive", "points": [[0, 0], [100, -2]]}]}],
             "amp_knobs": {"Amp_B": [{"cc": 37, "range": [-10, 10], "sum": [{"from": "bass", "points": [[0, 10]]}]}]},
             "add_delay": {"Lead crunch": {"beats": 1, "mix": 20, "feedback": 20}}}
            """#.utf8), id: "x")
        func cc(_ steps: [Profile.Step], _ n: Int) -> Int? {
            steps.lazy.compactMap { if case .cc(n, let v) = $0 { v } else { nil } }.first
        }
        let plainTone = formula.toneSteps(category: .heavy, toneIndex: 0, effectKinds: [], knobValues: ["gain": 50])
        check(cc(plainTone, 39) == 32 && cc(plainTone, 37) == 51, "gain 50: range 0-200 gives 32; 2 - 4 = -2 dB of -10..10 gives 51")
        let withOD = formula.toneSteps(category: .heavy, toneIndex: 0, effectKinds: ["overdrive"], knobValues: ["gain": 50])
        check(cc(withOD, 39) == 64 && cc(withOD, 37) == 44 && cc(withOD, 40) == 127,
              "with an overdrive: its range, its term (-3 dB gives 44), and its switch: \(withOD)")
        check(cc(formula.toneSteps(category: .heavy, toneIndex: nil, effectKinds: []), 37) == nil, "no values: a sum sends nothing")
        check(formula.songAmp([("Amp_Z", 90), ("Amp_B", 30), ("Amp_A", 20)]) == "Amp_B", "the song's amp: the longest listed")
        let ampB = formula.toneSteps(category: .heavy, toneIndex: 0, effectKinds: [], knobValues: ["gain": 50, "bass": 0], amp: "Amp_B")
        check(cc(ampB, 37) == 127 && cc(ampB, 39) == 32, "an amp's own knob on a CC in place of the shared one")
        // A category's steps for a band of the tone's drive, and its added delay
        let cleanLead = formula.toneSteps(category: .lead, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.2], tempo: 120)
        let crunchLead = formula.toneSteps(category: .lead, toneIndex: 0, effectKinds: [], knobValues: ["drive": 0.5], tempo: 120)
        check(cleanLead.first == .cc(69, 0) && cc(cleanLead, 24) == 0, "a clean lead: Lead clean's steps, no delay")
        check(crunchLead.first == .cc(69, 2) && cc(crunchLead, 24) == 127, "a crunch lead: Lead's steps and Lead crunch's delay")
        check(formula.categorySteps(.lead, drive: 0.2) == [.cc(69, 0)] && formula.categorySteps(.lead, drive: nil) == [.cc(69, 2)],
              "the steps the window shows: the band's, or the category's without a drive")
        check((try? Profile.parse(formula.json, id: "x")) == formula, "formula round trip")
        // A band's steps need the tone's drive, so the song's data is read for them.
        let bandOnly = try! Profile.parse(Data(#"{"name": "x", "category": {"Lead clean": [{"pc": 5}]}}"#.utf8), id: "x")
        check(bandOnly.needsSongData, "a profile with a band's steps reads the song's data")

        // The drive: the tone's gear, kept in its category's band.
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        check(near(Rig.corrected(0.8, category: .heavy), 0.8), "in its band")
        check(near(Rig.corrected(0.8, category: .crunch), 2.0 / 3), "an override to Crunch is at most crunch")
        check(near(Rig.corrected(0.8, category: .clean), 1.0 / 3), "an override to Clean stays clean")
        check(near(Rig.corrected(0.1, category: .heavy), 2.0 / 3), "an override to Heavy is heavy")
        check(near(Rig.corrected(0.4, category: .lead), 0.4), "Lead has no band")
        check(Category.allCases.allSatisfy { c in
            [0, 0.2, 1.0 / 3, 0.5, 2.0 / 3, 0.8, 1].allSatisfy { d in
                c == .lead || Rig.band(Rig.corrected(d, category: c)) == ["clean", "crunch", "heavy"][c.rawValue]
            }
        }, "a corrected drive is in its category's band, at the band's top too")

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

        rejects(#"{"name": "x", "add_delay": {"Lead": {"beats": 1, "mix": 20, "feedback": 20}}}"#, "needs a delay CC")
        rejects(#"{"name": "x", "effects": {"delay": 24}, "add_delay": {"Solo": {"beats": 1, "mix": 20, "feedback": 20}}}"#,
                "unknown category")
        rejects(#"{"name": "x", "effects": {"delay": 24}, "add_delay": {"Lead": {"beats": 1, "mix": 200, "feedback": 20}}}"#,
                "add_delay mix")
        rejects(#"{"name": "x", "effects": {"delay": 24}, "add_delay": {"Lead": {"beats": 1, "mix": 20}}}"#, "add_delay feedback")
        rejects(#"{"name": "x", "effects": {"delay": 24}, "add_delay": {"Lead": {"beats": 1, "mix": 20, "feedback": 20, "time": 3}}}"#,
                "unknown add_delay key")
        rejects(#"{"name": "x", "category": {"Lead loud": []}}"#, "unknown category")
        rejects(#"{"name": "x", "knobs": [{"cc": 37, "sum": [{"add": 1}]}]}"#, "needs a \"range\"")
        rejects(#"{"name": "x", "knobs": [{"cc": 37, "from": "gain", "sum": [{"add": 1}], "range": [0, 1]}]}"#, "a \"from\" or a \"sum\"")
        rejects(#"{"name": "x", "knobs": [{"cc": 37, "range": [0, 1], "sum": [{"from": "gain", "points": [[50, 1], [0, 2]]}]}]}"#,
                "by rising value")
        rejects(#"{"name": "x", "knobs": [{"cc": 37, "range": [0, 1], "sum": [{"from": "gain", "points": [[0, 1]], "with": "wah"}]}]}"#,
                "\"with\" is an effect")
        rejects(#"{"name": "x", "knobs": [{"cc": 39, "from": "gain", "with": {"wah": [0, 1]}}]}"#, "unknown effect")
        rejects(#"{"name": "x", "amp_knobs": {"Amp_A": []}}"#, "isn't in amp_load")
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

import Foundation

/// The four tone categories the companion switches between; the device profile says what each
/// one sends.
enum Category: Int, CaseIterable {
    case clean = 0, crunch, heavy, lead

    var name: String { ["Clean", "Crunch", "Heavy", "Lead"][rawValue] }
}

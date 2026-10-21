import Foundation

/// Errors for pet pack zip import / extract (M10).
/// Display strings: use `localizationKey` with app L10n; English fallback for kit tests.
public enum PetPackError: Error, Equatable, LocalizedError {
    case invalidManifest
    case missingSpritesheet
    case unzipFailed
    case archiveTooLarge
    case tooManyEntries
    case expandedTooLarge
    case imageTooLarge
    case unzipTimedOut
    case packExists
    case importFailed

    /// App Localizable.strings key (en + zh-Hans).
    public var localizationKey: String {
        switch self {
        case .invalidManifest: return "pet.error.invalid_manifest"
        case .missingSpritesheet: return "pet.error.missing_spritesheet"
        case .unzipFailed: return "pet.error.unzip_failed"
        case .archiveTooLarge: return "pet.error.archive_too_large"
        case .tooManyEntries: return "pet.error.too_many_entries"
        case .expandedTooLarge: return "pet.error.expanded_too_large"
        case .imageTooLarge: return "pet.error.image_too_large"
        case .unzipTimedOut: return "pet.error.unzip_timed_out"
        case .packExists: return "pet.error.pack_exists"
        case .importFailed: return "pet.error.import_failed"
        }
    }

    /// English fallback for unit tests / non-UI contexts.
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Pet pack is missing a valid pet.json"
        case .missingSpritesheet: return "Pet pack is missing a spritesheet image"
        case .unzipFailed: return "Could not extract zip"
        case .archiveTooLarge: return "ZIP must be at most 100 MB"
        case .tooManyEntries: return "Pet pack cannot exceed 500 entries"
        case .expandedTooLarge: return "Expanded pet pack cannot exceed 500 MB"
        case .imageTooLarge: return "Pet image cannot exceed 64 megapixels"
        case .unzipTimedOut: return "Extract timed out; import stopped"
        case .packExists: return "A pack with this id already exists; not overwritten"
        case .importFailed: return "Import failed"
        }
    }
}

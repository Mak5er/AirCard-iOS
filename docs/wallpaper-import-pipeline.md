# Wallpaper import pipeline

This branch is the first working local milestone for importing `.tendies` wallpapers through AirCard. The installed app is a test build; the source and installation journal should be preserved separately.

## Flow

1. Import a `.tendies` archive into the app's Documents/Tendies library.
2. Select the imported file and flash it. AirCard extracts each descriptor, writes an ownership record, installs it, refreshes PosterBoard, and resprings.
3. Remove an installed descriptor from its own row in Installed Templates. Removal uses that record's device, provider, and descriptor UUID; it does not remove every row with the same display name.

Collections descriptors receive a unique numeric wallpaper identifier. Mercury descriptors keep the original provider identifier (for example `d23`), because the system renderer uses it to choose the wallpaper. Both cases get a unique descriptor UUID and an ownership receipt for safe removal.

## Duplicate protection

The installation journal stores the SHA-256 of the imported archive for new installs. Before flashing, AirCard checks active records on the current device for matching file names or archive hashes, including two identical archives selected in the same batch. For older records without a stored hash, it hashes the corresponding file still in the imported library. After a successful flash, the selected files are deselected.

This detects byte-identical archives even when renamed. Repacked archives with changed ZIP metadata may have different hashes. Older records whose imported file has been deleted can be compared by file name only. Existing duplicate installations are not removed automatically; each has its own ownership record and must be removed individually.

## Rebuild and verification

- `./build-ios.sh` rebuilds the tracked Rust XCFramework when Rust source changes.
- Build the Xcode project for a physical iPhone using the developer's own signing settings.
- Run `cargo test --offline exploit::templates --lib` in `rust-core` with the toolchain and dependency cache configured.
- Preserve or export the installation journal before reinstalling the app or changing devices. The app currently exports the journal but cannot import it after reinstalling.

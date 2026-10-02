# AirCard-iOS

<p align="center">
  <img src="ios-app/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128" alt="AirCard-iOS Icon" style="border-radius: 28px; box-shadow: 0 8px 24px rgba(0,0,0,0.18);" />
</p>

<p align="center">
  Apple Wallet card skins, lock screen passcode themes, and PosterBoard wallpapers directly on iOS 27+.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2027+-blue?style=flat-square&logo=apple" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-5.0-orange?style=flat-square&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Rust-FFI%20Core-red?style=flat-square&logo=rust" alt="Rust" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License" />
  <a href="https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y"><img src="https://img.shields.io/badge/Donate-PayPal-00457C?style=flat-square&logo=paypal" alt="Donate with PayPal" /></a>
</p>

## Overview

AirCard-iOS customizes Apple Wallet card artwork, lock screen passcode dialers, and lock screen wallpapers on device without a jailbreak.

The app communicates with internal system services over a local loopback tunnel (`10.7.0.1` or `127.0.0.1`) provided by LocalDevVPN. File operations are handled by `AirliftFFI`, a Rust library that interfaces with the AirTraffic service.

> **Compatibility**: AirCard-iOS currently requires **iOS 27.0 or newer (iOS 27+)**.

## Features

### Apple Wallet card skins
- Writes custom card artwork to Passbook caches (`cardBackgroundCombined@3x.png`, `@2x.png`, and `cardBackgroundCombined.pdf` for transit cards like Suica).
- Flushes front-face and thumbnail caches so new artwork appears immediately when Wallet opens.
- Detects card identifiers in real time when you bring up Apple Pay.
- Apply artwork to individual cards or batch-flash every detected card.

### Passcode dialer themes
- Live dialer preview with touch panning and zoom framing.
- Full poster layout across all ten buttons, or individual circular button cutouts.
- Targets system dialer caches (`TelephonyUI-10`).
- Localized number subtext options, including Ukrainian and Russian Cyrillic layouts.
- Import and export themes as `.passthm` files.

### PosterBoard wallpapers (.tendies)
- Import and unpack `.tendies` wallpaper archives directly from the Files app.
- Auto-detects PosterBoard wallpaper containers and active descriptor UUIDs.
- Injects wallpaper configurations and assets into PosterBoard storage.
- Automatically triggers a NeoSpring respring after flashing to apply wallpapers without rebooting your iPhone.

### Pairing options
- **Import pairing file**: Supports pairing files (`.mobiledevicepairing`, `.plist`, `.mobilepair`) from **SideStore**, **LiveContainer**, **iLoader**, **AltStore**, **Jitterbug**, or exported from Mac/PC.
- **On-device pairing (iOS 27+)**: Advertises locally over Bonjour so the phone can pair with itself via Settings > Privacy & Security > Developer Mode > Pair with AirCard-iOS.
- **Safe unpairing**: Easily delete the active pairing file to re-pair or switch pairing credentials at any time.

## Community Resources

- [AirCards](https://aircards.org/) — An independent community for discovering
  and sharing Apple Wallet card artwork. Browse designs, download artwork
  for use with AirCard-iOS, or share your own creations.

AirCards is maintained independently and is not affiliated with the
AirCard-iOS project.

## Prerequisites

1. **iOS 27+** (for on-device Settings pairing) or **Any supported iOS version** when using an imported pairing file (e.g. from SideStore / iLoader).
2. **LocalDevVPN / WireGuard**: Running in loopback mode (`10.7.0.1` or `127.0.0.1`) so local connections can reach internal device services.
3. **Pairing record**: Either on-device pairing or an imported pairing file.

## Pairing Setup Guide

AirCard-iOS requires a pairing record to communicate with device lockdown services. Choose the method that best matches your setup:

### Option A: SideStore (Recommended)
If you already use SideStore on your device, it has already created a valid pairing file:
1. Open **AirCard-iOS** and go to the **Pairing** tab.
2. Tap **Import Pairing File…**.
3. In the Files document picker, navigate to:
   ```text
   On My iPhone › SideStore › ALTPairingFile.mobiledevicepairing
   ```
4. Select `ALTPairingFile.mobiledevicepairing`. The app will load it immediately (`Pairing file loaded ✅`).

### Option B: LiveContainer (with SideStore inside)
If you run SideStore inside LiveContainer:
1. Open **AirCard-iOS** › **Pairing** tab › tap **Import Pairing File…**.
2. In the Files document picker, navigate to:
   ```text
   On My iPhone › LiveContainer › SideStore › Documents › ALTPairingFile.mobiledevicepairing
   ```
   *(depending on your LiveContainer version, you can also check `On My iPhone › LiveContainer › Data › App › ... › SideStore › Documents`)*
3. Select `ALTPairingFile.mobiledevicepairing`.

### Option C: iLoader / Jitterbug / AltStore / Computer
- **iLoader / Jitterbug**: In the respective app, export your pairing file (`<UDID>.mobiledevicepairing`) into the Files app, then import it in AirCard-iOS.
- **Mac / PC**: Generate a pairing record using `jitterbugpair`, `pymobiledevice3`, or copy it from your computer (`/var/db/lockdown/<UDID>.plist` on macOS or `%ProgramData%\Apple\Lockdown\<UDID>.plist` on Windows), AirDrop/transfer it to your device, and import it into AirCard-iOS.
- **Manual placement**: You can also drop any `.mobiledevicepairing` or `.plist` directly into `On My iPhone › AirCard-iOS` via the Files app; it will appear under *Discovered in Documents* ready to use.

### Option D: On-Device Pairing (iOS 27+ only)
On devices running iOS 27 or newer:
1. In the **Pairing** tab, tap **Pair This iPhone**.
2. Note the 6-digit PIN displayed on screen.
3. Open **Settings › Privacy & Security › Developer Mode › Pair with AirCard-iOS**.
4. Enter the PIN to approve the pairing. AirCard-iOS will complete the handshake and save the credentials.

## Installation

Install `AirCard-iOS.ipa` using your preferred sideloading method:

- SideStore or AltStore
- TrollStore
- LiveContainer
- Xcode or iOS App Signer

## Building from source

### Requirements
- macOS 14.0 or newer with Xcode 16 or newer
- XcodeGen (`brew install xcodegen`)
- Rust toolchain (only needed if rebuilding `rust-core`)

### Build the IPA
```bash
git clone https://github.com/mak5er/AirCard-iOS.git
cd AirCard-iOS
./build-ipa.sh
```

The completed package is written to `build/AirCard-iOS.ipa`.

### Rebuilding the Rust framework
To compile changes in `rust-core`:
```bash
./build-ios.sh
```

## Repository structure

```
AirCard-iOS/
├── ios-app/                   # SwiftUI application
│   ├── AirCardApp.swift       # App entry point and lifecycle
│   ├── AppViewModel.swift     # State management and exploit orchestration
│   ├── ContentView.swift      # Main UI views
│   ├── TendiesView.swift      # PosterBoard wallpaper view
│   ├── TendiesEngine.swift    # Tendies extraction and injection logic
│   ├── RespringHelper.swift   # NeoSpring WebKit respring implementation
│   ├── Models.swift           # Image slicing, theme layout, archive packing
│   ├── PairingController.swift# Bonjour host and pairing sync
│   ├── NetworkStatus.swift    # VPN loopback detection
│   ├── Utilities.swift        # Background keep-alive and helper functions
│   ├── GrappaHelper.[h,m]     # ATC protocol helpers
│   ├── Info.plist             # Bundle configuration
│   └── Assets.xcassets/       # App icons and image sets
├── AirliftFFI.xcframework/    # Compiled arm64 Rust static library and headers
├── rust-core/                 # Rust core source code
├── project.yml                # XcodeGen project definition
├── build-ipa.sh               # IPA build script
├── build-ios.sh               # Rust framework build script
├── LICENSE                    # MIT License
└── README.md                  # Project documentation
```

## Credits

- **[@mak5er](https://github.com/mak5er)**: Lead developer, UI, passcode theming, Tendies engine, on-device pairing.
- **[@merybist](https://github.com/merybist)**: Initial base port.
- **[AirLift](https://github.com/0xjohnnydev/airlift)** by **[0xjohnny (@0xjohnnydev)](https://github.com/0xjohnnydev)**: AirTraffic and ATAirlock sandbox escape research underlying `AirliftFFI`.
- **[NeoSpring](https://github.com/rooootdev/neospring)**: Swift implementation by **[@skadz108](https://github.com/skadz108)** and **[@rooootdev](https://github.com/rooootdev)**, and **[@neonmodder123](https://github.com/neonmodder123)** for the WebKit GPU process respring technique.
- Built upon concepts from the **AirCard** project.

## Support & Donations

If you want to support AirCard-iOS development by **[@mak5er](https://github.com/mak5er)**:

- **Twitter / X**: [@mak5er](https://x.com/mak5er)
- **GitHub**: [@mak5er](https://github.com/mak5er)
- **PayPal**: [Donate via PayPal (Maksym Reva)](https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y)
- **TON**: `UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r`
- **USDT (TRC20)**: `TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n`
- **USDT / BNB (BEP20)**: `0x0954dc491c502849d04956ef74634aa5931a08e8`

## License

MIT License. See [LICENSE](LICENSE) for details.

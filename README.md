<p align="center">
  <img src="Design/AppIcon.svg" width="128" height="128" alt="TaskBarForMac icon">
</p>

<h1 align="center">TaskBarForMac</h1>

<p align="center">
  A KDE Plasma-style taskbar that replaces the macOS Dock.
</p>

<p align="center">
  🇬🇧 English | 🇫🇷 <a href="README.fr.md">Français</a>
</p>

## Overview

TaskBarForMac replaces the macOS Dock with a real Windows/KDE-style taskbar: open-app icons, a start button with an application menu, a clock, pinning — all customizable through a folder-based JSON theming system, no code required.

Personal project, not affiliated with KDE or Microsoft — just inspired by their look.

## Features

- **Taskbar**: open windows' icons (grouped when an app has several), pinning apps, minimize-all, clock (with an optional date), trash.
- **Icon editing**: press and hold any icon (or right-click the bar → **Edit Mode**) to make every icon jiggle, iOS-style — while in that mode you can drag icons to reorder them (live preview, only written to the real Dock once you're done), tap an icon to give it a custom picture, and drag an app straight from Finder onto the bar to pin it.
- **Icon size & spacing**: both adjustable as a percentage, independent of the bar's own height.
- **Alignment**: icons left-aligned, centered, or centered together with the start button.
- **Auto-hide**: the bar can retract automatically, like on Windows.
- **Start menu**, pick one:
  - **Kickoff** (Plasma-style): search, categories, app grid.
  - **Windows 11**: search, pinned or full app grid.
  - **Windows 7**: pinned/all-programs list sorted by most recently launched, account photo, quick links.
  - **Spotlight**: opens the real macOS Spotlight directly, no UI of its own.
  - Every style shows your real macOS account picture and is fully keyboard-navigable (arrows + Enter), and its picture opens **System Settings → Apple Account** when clicked.
- **Themes**: Breeze (light/dark), macOS, Windows 7, Windows 10, Windows 11, Windows XP — each with an independent Light / Dark / Automatic (follows the system) mode, separate from the theme choice itself.
- **Liquid Glass**: translucent background with adjustable intensity.
- **Multilingual**: French, English, Spanish, Russian (or follows the system language).
- **Launch at login**, via the native macOS API.

Every setting is available by right-clicking the bar → **Settings…**.

## Screenshots

**Windows 7**
![Windows 7 theme](Design/screenshots/windows-7.webp)

**macOS**
![macOS theme](Design/screenshots/macos.webp)

**Breeze (KDE)**
![Breeze theme](Design/screenshots/breeze.webp)

**Windows 11** (centered icons)
![Windows 11 theme, centered icons](Design/screenshots/windows-11.webp)

## Installation

1. Download `TaskBarForMac-Installer.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag `TaskBarForMac.app` into the **Applications** folder.
3. On first launch, macOS will block it (the app isn't notarized by Apple — this is a personal, self-signed project): **right-click the app → Open → Open** in the dialog. Only needed once.
4. Grant **Accessibility** access when macOS asks (needed to manage other apps' windows).

## Building from source

Only needs the Command Line Tools (no full Xcode required) and macOS 14+.

```bash
git clone https://github.com/Kosnix/TaskBarForMac.git
cd TaskBarForMac
swift build
```

To get a real, installable `.app` (icon, Info.plist, signature) instead of a bare executable:

```bash
bash Scripts/build-app.sh --install
```

Tip: run `bash Scripts/setup-signing-identity.sh` once first — it creates a stable local signing identity, so macOS doesn't ask for Accessibility permission again on every rebuild.

## Creating your own themes

Each theme is a plain folder under `Sources/Resources/Themes/<name>/` containing:
- `theme.json` — name, author, variant (`light`/`dark`)
- `tokens.json` — colors, sizes, spacing
- `layout.json` — which modules appear in which zone of the bar
- `icons/` — recolorable SVG icons

A `<name>-light` and `<name>-dark` pair sharing the same prefix automatically become a single entry in the theme picker, with light/dark handled separately.

## Disclaimer

A personal hobby project, not a distributed or maintained product. The app isn't notarized by Apple and changes system settings (Dock, permissions). Use at your own judgment.

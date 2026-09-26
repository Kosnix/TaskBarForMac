import SwiftUI

/// Everything that used to be a right-click menu row, as a real settings
/// window instead — grouped the same way a normal macOS preferences pane
/// would be, using plain system styling (this window isn't themed the way
/// the bar itself is; it's a tool for configuring it).
struct SettingsView: View {
    @Bindable var themeStore: ThemeStore

    private enum Alignment: Hashable {
        case left, center, centerWithStart

        var label: String {
            switch self {
            case .left: L("settings.alignment.left")
            case .center: L("settings.alignment.center")
            case .centerWithStart: L("settings.alignment.center_with_start")
            }
        }
    }

    private var alignment: Binding<Alignment> {
        Binding(
            get: {
                if themeStore.centerTaskListEnabled {
                    return themeStore.centerIncludesStartButton ? .centerWithStart : .center
                }
                return .left
            },
            set: { newValue in
                switch newValue {
                case .left:
                    themeStore.centerTaskListEnabled = false
                    themeStore.centerIncludesStartButton = false
                case .center:
                    themeStore.centerTaskListEnabled = true
                    themeStore.centerIncludesStartButton = false
                case .centerWithStart:
                    themeStore.centerTaskListEnabled = true
                    themeStore.centerIncludesStartButton = true
                }
            }
        )
    }

    private var panelHeight: Binding<Double> {
        Binding(
            get: { themeStore.panelHeightOverride ?? Double(themeStore.effectivePanelHeight) },
            set: { themeStore.panelHeightOverride = $0 }
        )
    }

    private var taskDisplayStyle: Binding<String> {
        Binding(
            get: { themeStore.effectiveTaskDisplayStyle },
            set: { themeStore.taskDisplayStyleOverride = $0 }
        )
    }

    private var activeFamilyID: Binding<String> {
        Binding(
            get: { themeStore.selectedFamilyID },
            set: { themeStore.setActiveFamily($0) }
        )
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { themeStore.languageOverride ?? Self.systemLanguageTag },
            set: { themeStore.languageOverride = $0 == Self.systemLanguageTag ? nil : $0 }
        )
    }

    /// Stands in for "follow the system language" in the picker — never a
    /// real language code, so it can't collide with one.
    private static let systemLanguageTag = "system"

    /// The label for "follow the system language", same wording the old
    /// menu-based language switcher used.
    private var systemLanguageLabel: String {
        let systemLanguage = Localization.supportedLanguages.first {
            $0.code == Locale.preferredLanguages.first.map { String($0.prefix(2)) }
        }?.label ?? Localization.supportedLanguages.first { $0.code == "fr" }!.label
        return L("language.system", ["lang": systemLanguage])
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLoginManager.isEnabled },
            set: { LaunchAtLoginManager.setEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Section(L("settings.section.general")) {
                Toggle(L("settings.launch_at_login"), isOn: launchAtLogin)
            }

            Section(L("menu.theme")) {
                Picker(L("menu.theme"), selection: activeFamilyID) {
                    ForEach(themeStore.themeFamilies) { family in
                        Text(family.displayName).tag(family.id)
                    }
                }
                .labelsHidden()
                Picker(L("settings.color_scheme"), selection: $themeStore.colorSchemeMode) {
                    Text(L("settings.color_scheme.light")).tag(ColorSchemeMode.light)
                    Text(L("settings.color_scheme.dark")).tag(ColorSchemeMode.dark)
                    Text(L("settings.color_scheme.system")).tag(ColorSchemeMode.system)
                }
                .pickerStyle(.segmented)
            }

            Section(L("settings.section.layout")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("menu.bar_size"))
                        Spacer()
                        Text("\(Int(panelHeight.wrappedValue)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: panelHeight, in: 22...160, step: 1)
                }
                Picker(L("settings.alignment"), selection: alignment) {
                    ForEach([Alignment.left, .center, .centerWithStart], id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker(L("menu.open_apps"), selection: taskDisplayStyle) {
                    Text(L("display.icon_and_label")).tag("iconAndLabel")
                    Text(L("display.icon_only")).tag("iconOnly")
                }
                .pickerStyle(.segmented)
                Toggle(L("menu.auto_hide"), isOn: $themeStore.autoHideEnabled)
            }

            Section(L("settings.section.start_menu")) {
                Picker(L("settings.start_menu_style"), selection: $themeStore.startMenuStyle) {
                    Text(L("settings.start_menu_style.kickoff")).tag(StartMenuStyle.kickoff)
                    Text(L("settings.start_menu_style.windows11")).tag(StartMenuStyle.windows11)
                    Text(L("settings.start_menu_style.spotlight")).tag(StartMenuStyle.realSpotlight)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Section(L("settings.section.clock")) {
                Toggle(L("settings.clock.show"), isOn: $themeStore.clockEnabled)
                Toggle(L("settings.clock.show_date"), isOn: $themeStore.clockShowDate)
                    .disabled(!themeStore.clockEnabled)
            }

            Section(L("settings.section.appearance")) {
                Toggle(L("menu.liquid_glass"), isOn: $themeStore.liquidGlassEnabled)
                if themeStore.liquidGlassEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("menu.liquid_glass_intensity"))
                        Slider(value: $themeStore.liquidGlassIntensity, in: 0...1)
                    }
                }
            }

            Section(L("menu.language")) {
                Picker(L("menu.language"), selection: languageSelection) {
                    Text(systemLanguageLabel).tag(Self.systemLanguageTag)
                    ForEach(Localization.supportedLanguages, id: \.code) { language in
                        Text(language.label).tag(language.code)
                    }
                }
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
    }
}

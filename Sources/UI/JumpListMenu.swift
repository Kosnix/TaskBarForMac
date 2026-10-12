import SwiftUI

/// The jump-list entries at the top of a taskbar icon's context menu.
struct JumpListMenu: View {
    let bundleIdentifier: String?
    let appURL: URL?
    let pid: pid_t?

    var body: some View {
        let store = JumpListStore.shared
        if let bundleIdentifier {
            let files = store.recentFiles(for: bundleIdentifier)
            if let pid, store.canOpenNewWindow[bundleIdentifier] == true {
                Button(L("jumplist.new_window")) { store.openNewWindow(pid: pid) }
            }
            if !files.isEmpty {
                Section(L("jumplist.recent")) {
                    ForEach(files, id: \.path) { file in
                        Button(file.lastPathComponent) { store.open(file, withAppAt: appURL) }
                    }
                }
            }
            if (pid != nil && store.canOpenNewWindow[bundleIdentifier] == true) || !files.isEmpty {
                Divider()
            }
        }
    }
}

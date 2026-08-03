import SwiftUI

struct SettingsView: View {
    let coordinator: AppCoordinator
    @ObservedObject private var syncManager: SyncManager
    @ObservedObject private var launchAtLoginManager: LaunchAtLoginManager

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _syncManager = ObservedObject(wrappedValue: coordinator.syncManager)
        _launchAtLoginManager = ObservedObject(wrappedValue: coordinator.launchAtLoginManager)
    }

    var body: some View {
        Form {
            Section("App") {
                Toggle(
                    "Open MD Sticky Notes when this Mac starts",
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                .disabled(!launchAtLoginManager.isSupported)

                Text("Starts the app automatically when you sign in to this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !launchAtLoginManager.isSupported {
                    Text("Launch at login requires macOS 13 or newer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = launchAtLoginManager.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Backend") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Production API")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(SyncSessionState.productionBackendBaseURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                Toggle(
                    "Use Custom Backend URL (Development)",
                    isOn: Binding(
                        get: { syncManager.usingCustomBackendBaseURL() },
                        set: { syncManager.setUseCustomBackendBaseURL($0) }
                    )
                )

                if syncManager.usingCustomBackendBaseURL() {
                    TextField(
                        "Custom Backend URL",
                        text: Binding(
                            get: { syncManager.customBackendBaseURL() },
                            set: { syncManager.updateCustomBackendBaseURL($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Reset To Production API") {
                        syncManager.resetBackendBaseURLOverride()
                    }
                }
            }

            Section("Account") {
                HStack {
                    if syncManager.isAuthenticated {
                        Button("Sign Out") {
                            syncManager.signOut()
                        }
                    } else {
                        Button("Sign In With Google") {
                            syncManager.beginSignIn()
                        }
                    }

                    Button("Sync Now") {
                        coordinator.syncNow()
                    }
                    .disabled(!syncManager.isAuthenticated || syncManager.syncSessionState.isManualSyncInFlight)

                    Button("Refresh Lists") {
                        syncManager.refreshTaskLists()
                    }
                    .disabled(!syncManager.isAuthenticated)
                }

                Text("Last Result: \(syncManager.syncSessionState.lastSyncResult ?? "No sync yet")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let error = syncManager.syncErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Task Lists") {
                if syncManager.taskLists.isEmpty {
                    Text("No task lists loaded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(syncManager.taskLists) { taskList in
                        HStack {
                            Toggle(
                                taskList.title,
                                isOn: Binding(
                                    get: { taskList.isSelected },
                                    set: { syncManager.setTaskListSelection(taskListId: taskList.id, isSelected: $0) }
                                )
                            )

                            Spacer()

                            Button(taskList.isDefault ? "Default" : "Make Default") {
                                syncManager.setDefaultTaskList(taskListId: taskList.id)
                            }
                            .disabled(!taskList.isSelected)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 470)
        .onAppear {
            launchAtLoginManager.refresh()
        }
    }
}

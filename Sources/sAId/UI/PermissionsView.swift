import SwiftUI

struct PermissionsView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Allow sAId to dictate").font(.title2)
                Text("All three permissions are required. Grant access to this signed sAId app, then return here.").foregroundStyle(.secondary)
                ForEach(PermissionKind.allCases) { permission in
                    HStack {
                        Image(systemName: permission.granted(in: model.permissions) ? "checkmark.circle.fill" : "circle").foregroundStyle(permission.granted(in: model.permissions) ? .green : .secondary)
                        Text(permission.rawValue)
                        Spacer()
                        if !permission.granted(in: model.permissions) {
                            Button("Grant") { Task { await model.requestPermission(permission) } }
                        }
                        Button("System Settings") { SystemPermissions.openSettings(permission) }
                    }
                }
                if model.permissions.allGranted { Label("All permissions granted", systemImage: "checkmark.shield").foregroundStyle(.green) }
                if let error = model.tapError { Text(error).foregroundStyle(.orange) }
                HStack {
                    Text("Changes are checked while this window is open.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Recheck") { model.recheckPermissions(force: true) }
                }
                Text("If macOS requires a restart after a grant, quit and reopen sAId.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
    }
}

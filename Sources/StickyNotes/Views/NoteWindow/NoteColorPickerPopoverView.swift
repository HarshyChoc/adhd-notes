import SwiftUI
import AppKit

struct NoteColorPickerPopoverView: View {
    let selectedColorValue: String
    let onSelectColorValue: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var selectedNSColor: NSColor {
        NoteColor.color(from: selectedColorValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(nsColor: selectedNSColor))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Note Color")
                        .font(.system(size: 12, weight: .semibold))
                    Text(NoteColor.displayName(for: selectedColorValue))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Text("Custom")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ColorPicker(
                    "",
                    selection: Binding(
                        get: { Color(nsColor: selectedNSColor) },
                        set: { newValue in
                            onSelectColorValue(NoteColor.storageValue(for: NSColor(newValue)))
                        }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pastels")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(NoteColor.allCases, id: \.self) { color in
                        Button {
                            onSelectColorValue(color.rawValue)
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(Color(nsColor: color.color))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                Color.black.opacity(selectedColorValue == color.rawValue ? 0.35 : 0.12),
                                                lineWidth: selectedColorValue == color.rawValue ? 2 : 1
                                            )
                                    )

                                Text(color.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 220)
    }
}

//
//  HomeItemsPanelView.swift
//  HomeDesign
//

import SwiftUI

struct HomeItem: Identifiable {
    let id: String
    let displayName: String
    let thumbnailURL: URL?
    let modelName: String

    static func discover() -> [HomeItem] {
        guard let thumbnailDir = Bundle.main.url(
            forResource: "Thumbnails",
            withExtension: nil,
            subdirectory: "GameData"
        ) else { return [] }

        let pngFiles = (try? FileManager.default.contentsOfDirectory(
            at: thumbnailDir,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "png" }
          .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        return pngFiles.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return HomeItem(
                id: name,
                displayName: formatDisplayName(name),
                thumbnailURL: url,
                modelName: name
            )
        }
    }

    static func formatDisplayName(_ id: String) -> String {
        let parts = id.split(separator: "_")
        guard let category = parts.first else { return id }
        if let variantStr = parts.last, let variantNum = Int(variantStr) {
            return "\(category.capitalized) \(variantNum)"
        }
        return category.capitalized
    }
}

struct HomeItemsPanelView: View {
    private let items = HomeItem.discover()
    @ObservedObject private var selectionStore = SelectionStore.shared

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Furniture")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("\(items.count) items available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

            // Surface selector: choose where the next item will be placed
            Picker("Place on", selection: Binding(
                get: { selectionStore.placementSurface },
                set: { newVal in
                    selectionStore.placementSurface = newVal
                    HomeDesignStore.shared.placementSurface = newVal
                }
            )) {
                Label("Floor", systemImage: "square.fill").tag(PlacementSurface.floor)
                Label("Wall", systemImage: "rectangle.portrait.fill").tag(PlacementSurface.wall)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            if items.isEmpty {
                ContentUnavailableView(
                    "No Items Found",
                    systemImage: "square.3.layers.3d",
                    description: Text("No furniture items were found in the bundle.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            HomeItemCard(item: item)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, selectionStore.hasSelection ? 12 : 28)
                }
            }

            // Selection controls — only visible when a placed item is selected
            if selectionStore.hasSelection {
                Divider()
                    .padding(.horizontal, 28)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    Button {
                        HomeDesignStore.shared.requestAction(.rotateLeft)
                    } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        HomeDesignStore.shared.requestAction(.rotateRight)
                    } label: {
                        Label("Rotate Right", systemImage: "rotate.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        HomeDesignStore.shared.requestAction(.duplicate)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 28)
                .padding(.top, 12)

                Button(role: .destructive) {
                    HomeDesignStore.shared.requestAction(.remove)
                } label: {
                    Label("Remove Selected", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Floor plan scale + snap toggle — always visible
            Divider()
                .padding(.horizontal, 28)
                .padding(.top, 4)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Floor Plan Scale")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f×", selectionStore.floorPlanScale))
                        .font(.headline)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    HomeDesignStore.shared.requestAction(.resetFloorPlanScale)
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(abs(selectionStore.floorPlanScale - 1.0) < 0.01)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Toggle("Snap to Grid", isOn: Binding(
                get: { selectionStore.snapEnabled },
                set: { newVal in
                    selectionStore.snapEnabled = newVal
                    HomeDesignStore.shared.snapEnabled = newVal
                }
            ))
            .padding(.horizontal, 28)
            .padding(.bottom, 12)

            // Undo — always visible, disabled when nothing to undo
            Divider()
                .padding(.horizontal, 28)

            Button {
                HomeDesignStore.shared.requestAction(.undo)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!selectionStore.canUndo)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .animation(.spring(response: 0.3), value: selectionStore.hasSelection)
        .animation(.spring(response: 0.3), value: selectionStore.canUndo)
    }
}

struct HomeItemCard: View {
    let item: HomeItem
    @State private var isHovered = false

    var body: some View {
        Button {
            FurnitureLoadQueue.shared.enqueue(item.modelName)
        } label: {
            VStack(alignment: .center, spacing: 10) {
                ThumbnailImageView(url: item.thumbnailURL)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(item.displayName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
            .onHover { isHovered = $0 }
        }
        .buttonStyle(.plain)
    }
}

struct ThumbnailImageView: View {
    let url: URL?

    var body: some View {
        if let url,
           let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
                .overlay {
                    Image(systemName: "bed.double.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

//
//  AppDelegate.swift
//  CoolZombie
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)
    import AppKit
    import CoolZombieKit
    import SwiftUI
    import UntoldEngine

    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        private enum Constants {
            static let windowSize = NSSize(width: 1280, height: 720)
            static let minimumWindowSize = NSSize(width: 800, height: 600)
        }

        private var window: NSWindow!
        private var renderer: UntoldRenderer!
        private var zombieScene: ZombieScene!

        func applicationDidFinishLaunching(_: Notification) {
            setupWindow()
            setupRendererAndScene()
            presentSceneView()
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            true
        }

        private func setupWindow() {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Constants.windowSize),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "CoolZombie — Motion Matching Demo"
            window.minSize = Constants.minimumWindowSize
            window.center()
        }

        private func setupRendererAndScene() {
            guard let renderer = UntoldRenderer.create() else {
                print("Failed to initialize UntoldRenderer.")
                NSApp.terminate(nil)
                return
            }

            self.renderer = renderer
            zombieScene = ZombieScene()

            renderer.setupCallbacks(
                gameUpdate: { [weak self] deltaTime in
                    self?.zombieScene.update(deltaTime: deltaTime)
                },
                handleInput: { [weak self] in
                    self?.zombieScene.handleInput()
                }
            )
        }

        private func presentSceneView() {
            guard let renderer else { return }

            let hostingView = NSHostingView(rootView: CoolZombieView(renderer: renderer, scene: zombieScene))
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private struct CoolZombieView: View {
        let renderer: UntoldRenderer
        let scene: ZombieScene
        @State private var isPlaying = ProcessInfo.processInfo.arguments.contains("-play")
        private let clipSets = ZombieResources.availableClipSets

        var body: some View {
            ZStack {
                SceneView(renderer: renderer)

                // The option groups live in one row of dropdowns along the
                // top; the transport (reset, play/pause) stays bottom right.
                VStack {
                    HStack {
                        optionsBar
                        Spacer()
                    }
                    .padding(12)
                    Spacer()
                    HStack(spacing: 12) {
                        Spacer()
                        throwButton
                        resetButton
                        playPauseButton(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .padding(16)
                }

                if !isPlaying {
                    VStack(spacing: 12) {
                        Text("CoolZombie")
                            .font(.title.bold())
                        Text("Motion matching: the character picks clips by itself — no state machine.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Pick the layout, cube, height and clips above; Space plays.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
            }
        }

        /// One dropdown per option group. The labels are drawn here, white
        /// on the dark bar, rather than by the system pop-up button, whose
        /// colours follow the window appearance; the bar is dark-scheme so
        /// the opened menus match. It reads the scene every quarter second
        /// so a key press (J/K/L) shows up in it too.
        private var optionsBar: some View {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                HStack(spacing: 14) {
                    optionGroup("Layout", options: scene.availableLayouts.map { ($0.title, $0) },
                                current: scene.layout) { scene.setLayout($0) }
                    optionGroup("Cube", options: ZombieScene.TargetMode.allCases.map { ($0.title, $0) },
                                current: scene.targetMode) { scene.setTargetMode($0) }
                    optionGroup("Height", options: ZombieScene.TargetHeight.allCases.map { ($0.title, $0) },
                                current: scene.targetHeight) { scene.setTargetHeight($0) }
                    if clipSets.count > 1 {
                        optionGroup("Clips", options: clipSets.map { ($0.title, $0) },
                                    current: scene.clipSet) { scene.setClipSet($0) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .environment(\.colorScheme, .dark)
            }
        }

        /// A caption and a dropdown for one option group: the current value
        /// in white on a translucent pill, the choices in a menu with the
        /// current one ticked.
        private func optionGroup<Value: Hashable>(
            _ title: String,
            options: [(String, Value)],
            current: Value,
            set: @escaping (Value) -> Void
        ) -> some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Menu {
                    ForEach(options, id: \.1) { option in
                        Button {
                            set(option.1)
                        } label: {
                            if option.1 == current {
                                Label(option.0, systemImage: "checkmark")
                            } else {
                                Text(option.0)
                            }
                        }
                    }
                } label: {
                    Text(options.first { $0.1 == current }?.0 ?? "—")
                        .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 96)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.16)))
            }
        }

        private var throwButton: some View {
            Button {
                scene.throwBall()
            } label: {
                Image(systemName: "basketball")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Toss a ball at the zombie (H); Shift+H throws hard")
        }

        private var resetButton: some View {
            Button {
                scene.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Reset the zombie to its spawn point")
        }

        private func playPauseButton(systemName: String) -> some View {
            Button {
                isPlaying.toggle()
                gameMode = isPlaying
            } label: {
                Image(systemName: systemName)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
        }
    }
#endif

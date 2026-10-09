import SwiftUI
import AppKit

@main struct CropperApp: App {
    @StateObject private var model = CropModel()
    var body: some Scene {
        Window("Cropper", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                    if model.files.isEmpty, let argument = CommandLine.arguments.dropFirst().first, !argument.hasPrefix("-") {
                        model.open(URL(fileURLWithPath: argument, isDirectory: true))
                    }
                }
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…", action: model.openFolder).keyboardShortcut("o") .disabled(model.saving)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Crop", action: model.save).keyboardShortcut("s").disabled(model.current == nil || model.loading || model.saving)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Crop", action: model.undo).keyboardShortcut("z").disabled(!model.canUndo || model.saving)
                Button("Reset Crop", action: model.reset).keyboardShortcut("r").disabled(model.preview == nil || model.saving)
            }
            CommandMenu("Crop") {
                ForEach(Array(Ratio.allCases.enumerated()), id: \.element.id) { index, ratio in
                    Button(ratio.rawValue) { model.setRatio(ratio) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                        .disabled(model.saving)
                }
                Divider()
                Button("Save Crop", action: model.save).keyboardShortcut(.return, modifiers: [])
                    .disabled(model.preview == nil || model.loading || model.saving)
                Button("Preview / Edit Crop") { model.reviewing.toggle() }.keyboardShortcut("p")
                    .disabled(model.preview == nil || model.saving)
                Button("Increase Retained Area") { model.adjustCrop(1) }.keyboardShortcut("+", modifiers: [])
                    .disabled(model.preview == nil || model.saving)
                Button("Decrease Retained Area") { model.adjustCrop(-1) }.keyboardShortcut("-", modifiers: [])
                    .disabled(model.preview == nil || model.saving)
                Button("Previous Photo") { model.navigate(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Photo") { model.navigate(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
        Settings { Preferences(model: model).frame(width: 440).padding(24) }
    }
}

struct ContentView: View {
    @ObservedObject var model: CropModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: model.openFolder) { Label("Open Folder", systemImage: "folder") }.disabled(model.saving)
                Divider().frame(height: 22)
                Picker("Ratio", selection: Binding(get: { model.ratio }, set: model.setRatio)) {
                    ForEach(Ratio.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 180).disabled(model.preview == nil || model.saving)
                if model.ratio == .custom {
                    TextField("Width", value: $model.customWidth, format: .number).frame(width: 45)
                    Text(":")
                    TextField("Height", value: $model.customHeight, format: .number).frame(width: 45)
                    Button("Apply") {
                        model.customWidth = max(0.01, min(1000, model.customWidth))
                        model.customHeight = max(0.01, min(1000, model.customHeight))
                        model.fitRatio()
                    }
                }
                Button("Reset", action: model.reset).disabled(model.preview == nil || model.saving)
                Spacer()
                Button(action: model.save) { Label(model.saving ? "Saving…" : "Save Crop", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).disabled(model.preview == nil || model.loading || model.saving)
            }.padding(12)
            HStack {
                Button(model.reviewing ? "Edit Crop" : "Preview Crop") { model.reviewing.toggle() }
                    .keyboardShortcut("p")
                    .disabled(model.preview == nil || model.saving)
                if model.reviewing {
                    Picker("Preview", selection: $model.previewMode) {
                        ForEach(CropPreviewMode.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 230)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if let megapixels = model.croppedMegapixels { Text(megapixels).font(.headline) }
                    if let dimensions = model.cropDimensions { Text(dimensions).font(.caption) }
                    if let summary = model.cropSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                }.monospacedDigit()
            }.padding(.horizontal, 12).padding(.bottom, 10)
            ZStack {
                CropCanvas(model: model)
                if model.files.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "crop").font(.system(size: 48, weight: .light))
                        Text("Cropper").font(.largeTitle)
                        Text(model.status).foregroundStyle(.secondary)
                        Button("Open JPEG Folder…", action: model.openFolder).buttonStyle(.borderedProminent)
                        Text("← / → Navigate     Enter / ⌘S Save     ⌘1–8 Ratio     ⌘Z Undo").font(.callout).foregroundStyle(.secondary)
                    }.foregroundStyle(.white)
                }
                if model.loading || model.saving {
                    ProgressView(model.saving ? "Saving full-resolution JPEG…" : "Loading…").padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack {
                Button { model.navigate(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.index == 0 || model.saving)
                Button { model.navigate(1) } label: { Image(systemName: "chevron.right") }.disabled(model.index >= model.files.count - 1 || model.saving)
                Text(model.current?.lastPathComponent ?? "No photo").lineLimit(1)
                if !model.files.isEmpty { Text("\(model.index + 1) / \(model.files.count)").foregroundStyle(.secondary) }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                SettingsLink { Image(systemName: "gearshape") }
            }.padding(12)
        }
        .navigationTitle("Cropper")
        .alert("Cropper", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct Preferences: View {
    @ObservedObject var model: CropModel
    var body: some View {
        Form {
            Toggle("Overwrite original JPEGs", isOn: $model.overwrite)
            Text(model.overwrite ? "Saving replaces the original file. Saved changes cannot be undone." : "Originals are preserved. New files get unique names.")
                .font(.caption).foregroundStyle(model.overwrite ? .orange : .secondary)
            HStack {
                Text("Output folder")
                Spacer()
                Button("Choose…", action: model.chooseOutput)
                Button("Default") { model.outputFolder = nil }
            }.disabled(model.overwrite)
            Text(model.outputFolder?.path ?? "Cropped subfolder beside the originals").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Picker("Crop preview layout", selection: $model.previewMode) {
                ForEach(CropPreviewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Preview automatically after dragging", isOn: $model.automaticPreview)
            Stepper("Crop shortcut step: \(Int(model.cropStep)) percentage points", value: $model.cropStep, in: 1...25, step: 1)
            Text("+ increases retained image area; − decreases it. The center and aspect ratio stay fixed. Enter saves the crop; in a text field it confirms your input. ⌘P switches between preview and editing; Escape returns to editing.").font(.caption).foregroundStyle(.secondary)
            Toggle("Advance to next photo after saving", isOn: $model.advance)
            HStack { Text("JPEG quality"); Slider(value: $model.quality, in: 0.5...1); Text("\(Int(model.quality * 100))%").monospacedDigit().frame(width: 40) }
            Toggle("Try lossless JPEG cropping", isOn: $model.lossless)
            Text("Uses an installed jpegtran for exact 16-pixel-aligned crops of unrotated images. Otherwise saves using the JPEG quality above. No additional software is required.").font(.caption).foregroundStyle(.secondary)
            Text("Drag anywhere on the photo toward the center to crop. Hold Shift and drag inside the crop to reposition. ⌘R resets. Ratio shortcuts: ⌘1 Original, ⌘2 Freeform, ⌘3 Square, ⌘4 3:2, ⌘5 4:3, ⌘6 5:4, ⌘7 16:9, ⌘8 Custom.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).disabled(model.saving)
    }
}

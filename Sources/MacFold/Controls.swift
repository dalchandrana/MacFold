import SwiftUI
import MetalKit
import FoldCore

struct MetalPreview: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = model.device else { return view }
        do {
            let renderer = try FoldRenderer(device:device)
            renderer.fallback = try renderer.makePreviewTexture()
            renderer.parameters = { [weak model] in model?.uniforms(preview:true) ?? FoldUniforms() }
            renderer.animatedState = { [weak model] in model?.animatedState(preview:true) }
            renderer.blendsWithDesktop = true
            renderer.pausesWhenSettled = true
            renderer.keepsAnimating = { [weak model] in
                guard let model else { return false }
                return model.previewPlaying || (model.followLid && model.demoRunning)
            }
            renderer.onFailure = { [weak model] message in model?.status = message }
            renderer.configure(view)
            context.coordinator.renderer = renderer
            model.previewRenderer = renderer
            model.previewView = view
        } catch { model.status = error.localizedDescription }
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = min(60,model.fps)
        context.coordinator.renderer?.wake(view)
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { view.isPaused = true;view.delegate = nil }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: FoldRenderer? }
}

struct Controls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red:1.0,green:0.56,blue:0.18) : Color(red:0.76,green:0.30,blue:0.04)
    }
    private var background: Color {
        colorScheme == .dark ? Color(red:0.075,green:0.085,blue:0.095) : Color(red:0.97,green:0.965,blue:0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            // All controls stay in one view. Only unusually small display work
            // areas scale the complete layout down; there is no internal scroll.
            let scale = min(1,geometry.size.width/900,geometry.size.height/508)
            let width = geometry.size.width/max(scale,0.1)
            let height = geometry.size.height/max(scale,0.1)
            let previewWidth = max(240,min(480,width-424,(height-205)*1.54+14))
            let panelHeight = (previewWidth-14)/1.54+21
            VStack(alignment:.leading,spacing:14) {
                header
                HStack(alignment:.top,spacing:24) {
                    preview(width:previewWidth).frame(maxWidth:.infinity)
                    settings.frame(width:350,height:panelHeight)
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                footer
            }
            .padding(20)
            .frame(width:width,height:height,alignment:.top)
            .scaleEffect(scale,anchor:.topLeading)
        }
        .background(background)
        .tint(accent)
    }

    private var header: some View {
        HStack(alignment:.top) {
            Image(nsImage:AppBrand.mark).resizable().scaledToFit().frame(width:40,height:40)
                .clipShape(RoundedRectangle(cornerRadius:9,style:.continuous))
                .shadow(color:.black.opacity(0.15),radius:2,x:0,y:1)
                .accessibilityHidden(true)
            VStack(alignment:.leading,spacing:5) {
                Text("Mac Fold").font(.system(size:27,weight:.semibold,design:.rounded))
                Text("Let your desktop follow the fold.").font(.system(size:12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { updater.checkForUpdates() } label: {
                Image(systemName:"arrow.triangle.2.circlepath")
                    .font(.system(size:16,weight:.semibold)).foregroundStyle(accent)
                    .frame(width:28,height:28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(updater.isBusy)
            .accessibilityLabel(updater.buttonTitle).help(updater.buttonTitle)
            HStack(spacing:6) {
                Circle().fill(model.sensorAvailable ? accent : .orange).frame(width:6,height:6)
                Text(model.lidAngle.map { String(format:"Lid %.0f°",$0) } ?? "Looking for sensor")
                    .font(.system(size:12,weight:.medium,design:.monospaced))
            }.padding(.horizontal,12).padding(.vertical,8).background(.primary.opacity(0.055),in:Capsule())
            Menu {
                Picker("Appearance",selection:$model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title,systemImage:appearance.symbol).tag(appearance)
                    }
                }
            } label: {
                Image(systemName:model.appearance.symbol).font(.system(size:16)).frame(width:28,height:28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Appearance").help("Appearance: \(model.appearance.title)")
        }
    }

    private func preview(width: CGFloat) -> some View {
        let screenWidth = width - 16
        let screenHeight = screenWidth / 1.54
        let notchWidth = min(screenWidth * 0.18, 92.0)
        let notchHeight: CGFloat = 11

        return VStack(spacing: 0) {
            // Display Lid Assembly
            ZStack(alignment: .top) {
                // Outer Anodized Aluminum Lid Edge & Bezel
                UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 18)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(white: 0.24), location: 0.0),
                                .init(color: Color(white: 0.13), location: 0.08),
                                .init(color: Color(white: 0.08), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 18)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(white: 0.40), Color(white: 0.18)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )

                // Active Metal Display
                MetalPreview(model: model)
                    .frame(width: screenWidth, height: screenHeight)
                    .overlay(alignment: .top) {
                        // MacBook Pro Notch with Camera & Sensors
                        ZStack {
                            UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                                .fill(Color(white: 0.05))
                                .frame(width: notchWidth, height: notchHeight)
                                .overlay(
                                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                                        .stroke(Color(white: 0.15), lineWidth: 0.5)
                                )

                            HStack(spacing: 5) {
                                // Camera Lens with optical flare
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [Color(red: 0.12, green: 0.25, blue: 0.42), Color(white: 0.03)],
                                            center: .center,
                                            startRadius: 0,
                                            endRadius: 3
                                        )
                                    )
                                    .frame(width: 5, height: 5)

                                // Green Camera Indicator LED with gentle glow
                                Circle()
                                    .fill(Color(red: 0.2, green: 0.9, blue: 0.4))
                                    .frame(width: 2.2, height: 2.2)
                                    .shadow(color: Color(red: 0.2, green: 0.9, blue: 0.4).opacity(0.8), radius: 2)
                            }
                            .offset(y: 1)
                        }
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 12))
                    .padding(8)
            }
            .frame(width: width)

            // Lower Chassis Deck (Unibody Base)
            ZStack(alignment: .top) {
                // Bottom aluminum unibody enclosure
                UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 5, bottomTrailingRadius: 5, topTrailingRadius: 1)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(white: 0.38), location: 0.0),
                                .init(color: Color(white: 0.26), location: 0.35),
                                .init(color: Color(white: 0.16), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: width + 8, height: 8)
                    .overlay(
                        // Specular edge highlight along bottom lip
                        UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 5, bottomTrailingRadius: 5, topTrailingRadius: 1)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(white: 0.55), Color(white: 0.20)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )

                // Precision CNC Thumb Opening Groove
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.12), Color(white: 0.22)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: width * 0.15, height: 3.5)
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                            .stroke(Color(white: 0.08), lineWidth: 0.5)
                    )
            }
            .padding(.top, 0)
            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 4)
        }
        .frame(width: width)
    }

    /// Sits in the row the "Controls" heading used to occupy. The reduced stack
    /// spacing keeps the panel exactly as tall as before, so nothing scrolls and
    /// the MacBook and the panel still align at top and bottom.
    private var effectPicker: some View {
        Picker("Effect",selection:$model.effect) {
            ForEach(FoldEffect.allCases) { effect in Text(effect.title).tag(effect) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .font(.system(size:11,weight:.medium))
        .frame(height:19)
        .accessibilityLabel("Effect")
        .help("Effect: \(model.effect.title) — \(model.effect.summary)")
    }

    private var settings: some View {
        VStack(alignment:.leading,spacing:10) {
            effectPicker
            Toggle("Follow my lid",isOn:$model.followLid)
                .toggleStyle(.switch).controlSize(.small).font(.system(size:11.5,weight:.medium))
            slider("Preview angle",value:Binding(get:{model.followLid ? model.lidAngle ?? model.clearAngle : model.previewAngle},
                                               set:{model.previewAngle = $0}),range:5...140,
                   text:model.followLid ? model.lidAngle.map { String(format:"%.0f°",$0) } ?? "—"
                                        : String(format:"%.0f°",model.previewAngle))
                .disabled(model.followLid || model.previewPlaying)
            Divider()
            slider("Clears at",value:$model.clearAngle,range:60...140,text:String(format:"%.0f°",model.clearAngle))
            VStack(alignment:.leading,spacing:6) {
                Toggle("Clear when the lid is still",isOn:$model.clearWhenStill)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size:11.5,weight:.medium))
                slider("Clear after",value:$model.stillnessDelay,range:1...5,text:String(format:"%.0f s",model.stillnessDelay),step:1)
                    .disabled(!model.clearWhenStill)
                Text("Move the lid to bring back the effect.")
                    .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Divider()
            slider("Perspective",value:$model.perspective,range:0...1,text:percent(model.perspective))
            slider("Softness",value:$model.blur,range:0...1,text:percent(model.blur))
            slider("Shadow",value:$model.shadow,range:0...1,text:percent(model.shadow))
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .padding(16).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:16))
    }

    private var footer: some View {
        VStack(alignment:.leading,spacing:8) {
            Divider()
            HStack(spacing:8) {
                Button(model.checkingPermission ? "Checking…" : (model.enabled ? "Pause Mac Fold" : "Enable Mac Fold")) {
                    if model.enabled { model.pause() } else { model.enable() }
                }.disabled(model.checkingPermission).buttonStyle(.borderedProminent).tint(accent)
                Button(model.demoRunning ? "Testing…" : "Test desktop · 8 sec") { model.testDesktop() }
                    .disabled(model.demoRunning || model.checkingPermission)
                Button { model.playPreview() } label: { Image(systemName:"play.fill");Text("Replay") }
                    .disabled(model.previewPlaying)
                Text(model.status).font(.system(size:11)).foregroundStyle(.secondary)
                    .lineLimit(2).help(model.status).frame(maxWidth:.infinity,alignment:.trailing)
                if !model.hasPermission {
                    Button { model.openPrivacy() } label:{Image(systemName:"gearshape")}.help("Open Screen Recording settings")
                }
            }
            HStack(spacing:5) {
                Text(model.previewPlaying ? "Replaying" : (model.followLid ? "Live preview" : "Manual preview"))
                Text("·")
                Image(systemName:"escape");Text("to pause");Text("·");Text("⌃⌥⌘F anywhere")
                Spacer()
                if model.reducedMotion { Text("Reduce Motion on");Text("·") }
                Text("On your Mac only").foregroundStyle(accent.opacity(0.85))
            }.font(.system(size:10)).foregroundStyle(.secondary)
        }
    }

    private func percent(_ x: Double) -> String { String(format:"%.0f%%",x*100) }
    private func slider(_ name:String,value:Binding<Double>,range:ClosedRange<Double>,text:String,step:Double? = nil) -> some View {
        HStack(spacing:10) {
            Text(name).font(.system(size:11.5,weight:.medium)).frame(width:84,alignment:.leading)
            Group {
                if let step { Slider(value:value,in:range,step:step) }
                else { Slider(value:value,in:range) }
            }.accessibilityLabel(name)
            Text(text).font(.system(size:11.5,design:.monospaced)).foregroundStyle(.secondary).frame(width:36,alignment:.trailing)
        }
    }
}

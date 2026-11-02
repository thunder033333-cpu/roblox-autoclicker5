// ContentView.swift
// Companion UI for the AutoClicker dylib running inside Roblox.
//
// Best experience: open both this app and Roblox (via LiveContainer)
// in iPadOS Split View — both stay foreground, no background limits.
//
// Workflow:
//   1. Launch Roblox inside LiveContainer (with AutoClicker.dylib)
//   2. Tap where you want auto-clicks to land in Roblox
//      (the dylib records the coordinate automatically)
//   3. Switch to this app (or use Split View)
//   4. Hold the FIRE button — releases = stops

import SwiftUI

struct ContentView: View {

    // ── State ─────────────────────────────────────────────────
    @State private var isFiring    = false
    @State private var intervalMs  = 50          // milliseconds
    @State private var tapCount    = 0
    @State private var ticker: Timer? = nil      // just for UI counter

    // ── Computed ──────────────────────────────────────────────
    private var tapsPerSec: Int { max(1, 1000 / intervalMs) }

    // ── Body ──────────────────────────────────────────────────
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header ────────────────────────────────────
                Text("AutoClicker")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .padding(.top, 40)

                Text("Roblox companion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 32)

                // ── Status badge ──────────────────────────────
                StatusBadge(firing: isFiring, count: tapCount)
                    .padding(.bottom, 32)

                // ── FIRE button ───────────────────────────────
                FireButton(isFiring: isFiring)
                    // DragGesture with minimumDistance:0 gives us
                    // finger-down / finger-up events reliably,
                    // unlike LongPressGestureRecognizer which has
                    // a minimum hold time.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isFiring else { return }
                                isFiring   = true
                                tapCount   = 0
                                DarwinBridge.start()
                                startCounter()
                            }
                            .onEnded { _ in
                                guard isFiring else { return }
                                isFiring = false
                                DarwinBridge.stop()
                                stopCounter()
                            }
                    )
                    .padding(.bottom, 40)

                // ── Interval control ──────────────────────────
                IntervalControl(ms: $intervalMs, tps: tapsPerSec)
                    .onChange(of: intervalMs) { newVal in
                        DarwinBridge.setInterval(newVal)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)

                Spacer()

                // ── Instructions ──────────────────────────────
                InstructionsFooter()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
        }
    }

    // ── Counter (UI only — not from dylib) ───────────────────
    private func startCounter() {
        ticker = Timer.scheduledTimer(withTimeInterval: Double(intervalMs) / 1000.0,
                                      repeats: true) { _ in
            tapCount += 1
        }
    }
    private func stopCounter() {
        ticker?.invalidate()
        ticker = nil
    }
}

// ─────────────────────────────────────────────────────────────
// SUB-VIEWS
// ─────────────────────────────────────────────────────────────

struct StatusBadge: View {
    let firing: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(firing ? Color.red : Color.green)
                .frame(width: 12, height: 12)
                .overlay {
                    if firing {
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 6)
                            .scaleEffect(1.6)
                    }
                }

            Text(firing
                 ? "FIRING  ·  \(count) taps"
                 : "STANDBY")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(firing ? .red : .green)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.quaternary, in: Capsule())
        .animation(.easeInOut(duration: 0.15), value: firing)
    }
}

struct FireButton: View {
    let isFiring: Bool

    var body: some View {
        ZStack {
            // Outer ring pulses while firing
            Circle()
                .stroke(isFiring ? Color.red : Color.blue,
                        lineWidth: isFiring ? 3 : 2)
                .frame(width: 160, height: 160)
                .scaleEffect(isFiring ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.2).repeatForever(autoreverses: true),
                            value: isFiring)

            // Main button face
            Circle()
                .fill(isFiring
                      ? LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                      : LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 140, height: 140)
                .shadow(color: isFiring ? .red.opacity(0.5) : .blue.opacity(0.3),
                        radius: isFiring ? 20 : 8)

            VStack(spacing: 4) {
                Image(systemName: isFiring ? "stop.fill" : "hand.point.up.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text(isFiring ? "RELEASE" : "HOLD")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .contentShape(Circle())    // hit area = circle only
        .animation(.spring(duration: 0.2), value: isFiring)
    }
}

struct IntervalControl: View {
    @Binding var ms: Int
    let tps: Int

    // Slider works on a Double internally
    @State private var sliderVal: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Interval")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(ms) ms  ·  \(tps) tap/s")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $sliderVal, in: 10...500, step: 5) {
                Text("Interval")
            } minimumValueLabel: {
                Text("10ms").font(.caption2)
            } maximumValueLabel: {
                Text("500ms").font(.caption2)
            }
            .onChange(of: sliderVal) { v in ms = Int(v) }
            .onAppear { sliderVal = Double(ms) }
            .tint(.blue)
        }
    }
}

struct InstructionsFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Launch Roblox in LiveContainer (with dylib)", systemImage: "1.circle.fill")
            Label("Tap your target in Roblox once (position auto-saved)", systemImage: "2.circle.fill")
            Label("Use Split View or switch here, then hold FIRE", systemImage: "3.circle.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}

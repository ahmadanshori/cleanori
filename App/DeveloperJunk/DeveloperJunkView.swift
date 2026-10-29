import CleanoriCore
import SwiftUI

/// The Developer Junk screen (spec §6.2): the start page, the scan in progress, then the results table with its
/// bottom bar. Cleaning always goes through the confirmation sheet and `DeveloperJunkModel.clean()`.
struct DeveloperJunkView: View {
    @Environment(AppModel.self) private var app
    @State private var isConfirming = false

    private var model: DeveloperJunkModel { app.junk }

    var body: some View {
        content
            .sheet(isPresented: $isConfirming) {
                ConfirmCleanSheet(
                    preview: model.cleanPreview,
                    onCancel: { isConfirming = false },
                    onConfirm: {
                        isConfirming = false
                        Task { await model.clean() }
                    }
                )
            }
            .alert(model.cleanProblem?.title ?? "", isPresented: problemShown) {
                Button("OK") {}
            } message: {
                Text(model.cleanProblem?.message ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            StartPage(
                module: .developerJunk,
                message: "Finds Xcode DerivedData, node_modules, package and Gradle caches, project builds, simulators and old SDKs. Everything listed can be regenerated, and you choose what to clean."
            ) { Task { await model.scan() } }
        case .scanning(let progress):
            ScanningPage(module: .developerJunk, progress: progress) { model.cancelScan() }
        case .results, .cleaning, .report:
            ResultsPage(model: model) { isConfirming = true }
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(
            get: { model.cleanProblem != nil },
            set: { if !$0 { model.cleanProblem = nil } }
        )
    }
}

// MARK: - Results

private struct ResultsPage: View {
    let model: DeveloperJunkModel
    let confirm: () -> Void
    /// Goes up each time a clean ends with a report, to play the sparkle burst once.
    @State private var burst = 0

    /// The banner counts what can be cleaned now; what a running app holds back is named in the subtitle (ruling R25).
    private var subtitle: String {
        let base = "Caches & builds that can be regenerated"
        guard let locked = model.result?.locked, locked.bytes > 0 else { return base }
        return "\(base) · \(locked.sizeText) locked"
    }

    var body: some View {
        VStack(spacing: 10) {
            ModuleBanner(
                module: .developerJunk,
                title: "\(model.result?.cleanable.sizeText ?? Int64(0).sizeText(approximate: false)) found",
                subtitle: subtitle
            ) {
                Button("Rescan") { Task { await model.scan() } }
                    .buttonStyle(BannerButtonStyle())
                    .disabled(model.isCleaning)
            }

            if case .report(let report) = model.phase {
                CleanReportBanner(report: report, context: model.reportContext) { model.dismissReport() }
            }

            if case .cleaning(let done, let total) = model.phase {
                CleaningPage(
                    module: .developerJunk,
                    sizes: model.cleaningSizes,
                    done: done,
                    total: total,
                    status: done < total ? "Cleaning \(done) of \(total)…" : "Updating the list…",
                    detail: "\(model.cleaningSizes.reduce(0, +).sizeText(approximate: model.cleaningSizesAreApproximate)) selected"
                )
            } else {
                JunkTableView(model: model)
                    .overlay {
                        if burst > 0 { SparkleBurst(color: Theme.accent).id(burst) }
                    }
            }

            SelectionBar(model: model, confirm: confirm)
        }
        .onChange(of: model.isCleaning) { wasCleaning, isCleaning in
            if wasCleaning, !isCleaning, case .report = model.phase { burst += 1 }
        }
        // The window has no title bar, so the screen already starts 38 pt down, below the traffic lights.
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

/// "Selected 97.9 GB · all deleted permanently" and the Clean button.
private struct SelectionBar: View {
    let model: DeveloperJunkModel
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            status
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.hasUserChoices, !model.isCleaning {
                Button("Reset to defaults") { model.resetToDefaults() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                    .fixedSize()
                    .help("Forget your own ticks and go back to what the scan suggests")
            }
            Spacer(minLength: 10)
            Button("Clean", action: confirm)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canClean)
        }
        .frame(height: 46)
    }

    @ViewBuilder private var status: some View {
        if case .cleaning = model.phase {
            // The cleaning page above shows the progress.
            EmptyView()
        } else {
            let preview = model.cleanPreview
            let totals = preview.totals
            let size = Text(verbatim: totals.totalBytes.sizeText(approximate: preview.isApproximate))
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(.primary)
            if let how = Self.how(preview) {
                Text("Selected \(size) · \(how)")
            } else {
                Text("Selected \(size)")
            }
        }
    }

    /// How the selection leaves the disk: "all deleted permanently" when it is one way, else each way's share. A way
    /// counts as soon as one ticked item goes that way, whatever its size, so a ticked 0-byte delete is never hidden
    /// behind "all moved to Trash".
    private static func how(_ preview: DeveloperJunkModel.CleanPreview) -> String? {
        let totals = preview.totals
        let ways: [(method: CleanMethod, all: String, share: String)] = [
            (.delete, "all deleted permanently", "deleted permanently"),
            (.trash, "all moved to Trash", "to Trash"),
            (.simctl, "all removed via simctl", "via simctl"),
        ].filter { totals.count(of: $0.method) > 0 }
        switch ways.count {
        case 0: return nil
        case 1: return ways[0].all
        default:
            return ways.map { way in
                "\(totals.bytes(of: way.method).sizeText(approximate: preview.isApproximate(way.method))) \(way.share)"
            }.joined(separator: " · ")
        }
    }
}

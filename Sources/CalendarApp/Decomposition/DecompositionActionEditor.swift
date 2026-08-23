import SwiftUI

struct DecompositionActionEditor: View {
    @Bindable var model: DecompositionWorkbenchModel
    @State private var activeCandidateID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DecompositionWorkbenchCopy.actions)
                .font(DecompositionTypography.sectionTitle)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.draft.candidates) { candidate in
                        actionRow(candidate)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowChrome(for: candidate))
                        Divider()
                    }
                }
            }
            DecompositionIdentifiedButton(
                title: DecompositionWorkbenchCopy.addAction,
                identifier: "decomposition-add-candidate",
                accessibilityName: DecompositionWorkbenchCopy.addAction,
                helpText: "手工添加一个行动",
                enabled: !model.isCommitting
            ) {
                model.addManualCandidate()
                activeCandidateID = model.draft.candidates.last?.id
            }
            .frame(width: 88, height: 22)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onChange(of: model.draft.candidates.map(\.id)) { _, ids in
            if let activeCandidateID, ids.contains(activeCandidateID) { return }
            activeCandidateID = ids.first
        }
        .onAppear {
            if activeCandidateID == nil {
                activeCandidateID = model.draft.candidates.first?.id
            }
        }
        .allowsHitTesting(!model.isCommitting)
    }

    private var expandedID: UUID? {
        activeCandidateID ?? model.draft.candidates.first?.id
    }

    @ViewBuilder
    private func actionRow(_ candidate: CandidateAction) -> some View {
        let expanded = candidate.id == expandedID
        HStack(alignment: .top, spacing: 10) {
            dragHandle(for: candidate)
            DecompositionIdentifiedCheckbox(
                isOn: creationBinding(candidate),
                identifier: "",
                accessibilityName: keepActionAccessibilityLabel(for: candidate),
                visualTitle: DecompositionWorkbenchCopy.createAction,
                enabled: !model.isCommitting
            )
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        DecompositionIdentifiedTextField(
                            text: titleBinding(candidate),
                            identifier: "decomposition-title-\(candidate.id.uuidString)",
                            accessibilityName: "行动标题",
                            placeholder: "行动标题",
                            requestsInitialFocus: isManual && isFirst(candidate.id)
                        )
                        .frame(height: 22)
                        .disabled(model.isCommitting)
                        DecompositionIdentifiedMultilineTextField(
                            text: completionBinding(candidate),
                            identifier: "decomposition-completion-\(candidate.id.uuidString)",
                            accessibilityName: "完成说明",
                            placeholder: DecompositionWorkbenchCopy.completionPlaceholder
                        )
                        .frame(minHeight: 32, maxHeight: 96)
                        .disabled(model.isCommitting)
                    }
                    HStack(spacing: 8) {
                        Picker("时长", selection: durationBinding(candidate)) {
                            ForEach(CandidateDuration.allCases, id: \.self) { duration in
                                Text("\(duration.rawValue) 分钟").tag(duration)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 120)
                        .accessibilityLabel("预计时长")
                        .disabled(model.isCommitting)
                        Spacer()
                        DecompositionIdentifiedButton(
                            title: "上移",
                            identifier: "decomposition-move-up-\(candidate.id.uuidString)",
                            accessibilityName: DecompositionWorkbenchCopy.moveUp,
                            helpText: "把这项行动上移一位",
                            enabled: !model.isCommitting && !isFirst(candidate.id)
                        ) {
                            moveUp(candidate.id)
                        }
                        .frame(width: 36, height: 22)
                        DecompositionIdentifiedButton(
                            title: "下移",
                            identifier: "decomposition-move-down-\(candidate.id.uuidString)",
                            accessibilityName: DecompositionWorkbenchCopy.moveDown,
                            helpText: "把这项行动下移一位",
                            enabled: !model.isCommitting && !isLast(candidate.id)
                        ) {
                            moveDown(candidate.id)
                        }
                        .frame(width: 36, height: 22)
                        DecompositionIdentifiedMenuButton(
                            title: "更多",
                            identifier: "decomposition-more-\(candidate.id.uuidString)",
                            accessibilityName: DecompositionWorkbenchCopy.more,
                            helpText: "更多操作",
                            enabled: !model.isCommitting,
                            items: [
                                DecompositionMenuAction(title: "删除", isDestructive: true) {
                                    model.deleteCandidate(id: candidate.id)
                                }
                            ]
                        )
                        .frame(width: 36, height: 22)
                    }
                } else {
                    Button {
                        activeCandidateID = candidate.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title.isEmpty ? "未命名行动" : candidate.title)
                                .font(DecompositionTypography.body)
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DecompositionAccessibleLabel(
                                text: candidate.completionDescription.isEmpty ? "还没有完成说明" : candidate.completionDescription,
                                identifier: "decomposition-completion-\(candidate.id.uuidString)",
                                label: "完成说明"
                            )
                            Text("\(candidate.estimatedDuration.rawValue) 分钟")
                                .font(DecompositionTypography.auxiliary)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        DecompositionWorkbenchCopy.collapsedActionAccessibilityLabel(
                            title: candidate.title,
                            completion: candidate.completionDescription,
                            minutes: candidate.estimatedDuration.rawValue
                        )
                    )
                    .accessibilityHint("展开后可微调行动标题、完成说明和预计时长")
                    .accessibilityAddTraits(.isButton)
                }
                if !isManual {
                    DecompositionIdentifiedButton(
                        title: DecompositionWorkbenchCopy.continueSplit,
                        identifier: "decomposition-split-\(candidate.id.uuidString)",
                        accessibilityName: DecompositionWorkbenchCopy.continueSplit,
                        helpText: DecompositionWorkbenchCopy.continueSplitHelp,
                        enabled: !model.isCommitting,
                        subdued: true
                    ) {
                        Task { await model.split(candidate.id) }
                    }
                    .frame(width: 72, height: 22)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { activeCandidateID = candidate.id }
        .dropDestination(for: String.self) { payloads, _ in
            acceptDrop(payloads, onto: candidate.id)
        }
    }

    @ViewBuilder
    private func dragHandle(for candidate: CandidateAction) -> some View {
        let handle = DecompositionDragHandle(
            identifier: "decomposition-drag-handle-\(candidate.id.uuidString)",
            helpText: DecompositionWorkbenchCopy.dragHandleHelp,
            colorScheme: colorScheme
        )
        .frame(width: 12, height: 22)
        .accessibilityHidden(true)
        if model.isCommitting {
            handle
        } else {
            handle.draggable(candidate.id.uuidString)
        }
    }

    @ViewBuilder
    private func rowChrome(for candidate: CandidateAction) -> some View {
        let selected = candidate.id == expandedID
        RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius)
            .fill(selected ? theme.selectionFill.opacity(0.55) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius)
                    .stroke(
                        selected ? theme.selectionOutline : theme.subtleBorder,
                        lineWidth: selected ? 1 : 0.5
                    )
            }
    }

    private var isManual: Bool {
        if case .manual = model.draft.mode { return true }
        return false
    }

    private func isFirst(_ id: UUID) -> Bool {
        model.draft.candidates.first?.id == id
    }

    private func isLast(_ id: UUID) -> Bool {
        model.draft.candidates.last?.id == id
    }

    private func moveUp(_ id: UUID) {
        guard let index = model.draft.candidates.firstIndex(where: { $0.id == id }), index > 0 else { return }
        model.moveCandidate(id: id, toPositionOf: model.draft.candidates[index - 1].id)
    }

    private func moveDown(_ id: UUID) {
        guard let index = model.draft.candidates.firstIndex(where: { $0.id == id }),
              index + 1 < model.draft.candidates.count
        else { return }
        model.moveCandidate(id: id, toPositionOf: model.draft.candidates[index + 1].id)
    }

    private func acceptDrop(_ payloads: [String], onto targetID: UUID) -> Bool {
        guard !model.isCommitting,
              let raw = payloads.first,
              let draggedID = UUID(uuidString: raw)
        else { return false }
        let before = model.draft.candidates.map(\.id)
        model.moveCandidate(id: draggedID, toPositionOf: targetID)
        return model.draft.candidates.map(\.id) != before
    }

    private func displayTitle(for candidate: CandidateAction) -> String {
        candidate.title.isEmpty ? "未命名行动" : candidate.title
    }

    private func keepActionAccessibilityLabel(for candidate: CandidateAction) -> String {
        "\(DecompositionWorkbenchCopy.keepAction)：\(displayTitle(for: candidate))"
    }

    private func creationBinding(_ candidate: CandidateAction) -> Binding<Bool> {
        Binding(
            get: { candidate.selectedForCreation },
            set: { model.setSelectedForCreation(id: candidate.id, selected: $0) }
        )
    }

    private func titleBinding(_ candidate: CandidateAction) -> Binding<String> {
        Binding(
            get: { candidate.title },
            set: { model.updateTitle(id: candidate.id, value: $0) }
        )
    }

    private func completionBinding(_ candidate: CandidateAction) -> Binding<String> {
        Binding(
            get: { candidate.completionDescription },
            set: { model.updateCompletion(id: candidate.id, value: $0) }
        )
    }

    private func durationBinding(_ candidate: CandidateAction) -> Binding<CandidateDuration> {
        Binding(
            get: { candidate.estimatedDuration },
            set: { model.updateDuration(id: candidate.id, duration: $0) }
        )
    }
}

private struct DecompositionDragHandle: NSViewRepresentable {
    var identifier: String
    var helpText: String
    var colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        view.imageScaling = .scaleProportionallyDown
        apply(view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        apply(view)
    }

    private func apply(_ view: NSImageView) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.toolTip = helpText
        view.contentTintColor = NSColor(
            CalendarTheme.appearance(for: colorScheme).secondaryText
        ).withAlphaComponent(0.55)
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(nil)
        view.setAccessibilityRole(nil)
    }
}

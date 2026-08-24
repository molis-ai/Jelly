import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionSourceCaptureTests")
struct DecompositionSourceCaptureTests {
    private let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)
    private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
    private let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000300")!)

    @Test func sameBlockSelectionUsesOnlySelectedTextAndAnchorsAfterThatBlock() throws {
        var note = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        note.document = .init(blocks: [
            .init(id: blockID, kind: .paragraph, inlineContent: .plain("预约牙医"),
                  taskState: nil, indentLevel: 0)
        ])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: blockID, graphemeOffset: 2),
            focus: .init(blockID: blockID, graphemeOffset: 4),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let snapshot = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 7,
            selection: selection
        )
        #expect(snapshot.sourceBlockID == blockID)
        #expect(snapshot.selectedRange?.lowerGraphemeOffset == 2)
        #expect(snapshot.normalizedText == "牙医")
        #expect(snapshot.noteID == noteID)
        #expect(snapshot.noteRevision == note.revision)
        #expect(snapshot.workspaceRevision == 7)
        #expect(snapshot.selectedRange?.blockID == blockID)
        #expect(snapshot.selectedRange?.upperGraphemeOffset == 4)
    }

    @Test func reverseSameBlockSelectionNormalizesGraphemeRange() throws {
        let note = try makeNote(text: "预约牙医")
        let snapshot = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 1,
            selection: textSelection(lower: 4, upper: 2)
        )
        #expect(snapshot.selectedRange?.lowerGraphemeOffset == 2)
        #expect(snapshot.selectedRange?.upperGraphemeOffset == 4)
        #expect(snapshot.normalizedText == "牙医")
    }

    @Test func collapsedCaretFallsBackToWholeNoteAndEndAnchor() throws {
        let secondID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000311")!)
        let dividerID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000312")!)
        var note = try makeNote(text: "预约牙医")
        note.document.blocks.append(contentsOf: [
            .init(id: dividerID, kind: .divider, inlineContent: .plain(""), taskState: nil, indentLevel: 0),
            .init(id: secondID, kind: .paragraph, inlineContent: .plain("明天上午"), taskState: nil, indentLevel: 0)
        ])
        let snapshot = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 3,
            selection: textSelection(lower: 1, upper: 1)
        )
        #expect(snapshot.sourceBlockID == nil)
        #expect(snapshot.selectedRange == nil)
        #expect(snapshot.normalizedText == "预约牙医\n\n明天上午")
    }

    @Test func allWhitespaceNoteIsEmptySource() throws {
        let note = try makeNote(text: "  \n\t  ")
        #expect(throws: DecompositionSourceCaptureError.emptySource) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: textSelection(lower: 0, upper: 0)
            )
        }
    }

    @Test func allWhitespaceSelectionIsEmptySource() throws {
        let note = try makeNote(text: "预约  牙医")
        #expect(throws: DecompositionSourceCaptureError.emptySource) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: textSelection(lower: 2, upper: 4)
            )
        }
    }

    @Test func emptyNoteIsEmptySource() throws {
        let note = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        let emptyBlockID = try #require(note.document.blocks.first?.id)
        #expect(throws: DecompositionSourceCaptureError.emptySource) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: .text(
                    anchor: .init(blockID: emptyBlockID, graphemeOffset: 0),
                    focus: .init(blockID: emptyBlockID, graphemeOffset: 0),
                    preferredColumn: nil,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            )
        }
    }

    @Test func crossBlockTextSelectionIsRejected() throws {
        let secondID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000313")!)
        var note = try makeNote(text: "预约牙医")
        note.document.blocks.append(
            .init(id: secondID, kind: .paragraph, inlineContent: .plain("明天上午"), taskState: nil, indentLevel: 0)
        )
        #expect(throws: DecompositionSourceCaptureError.crossBlockSelection) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: .text(
                    anchor: .init(blockID: blockID, graphemeOffset: 1),
                    focus: .init(blockID: secondID, graphemeOffset: 2),
                    preferredColumn: nil,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            )
        }
    }

    @Test func blockSelectionIsUnsupported() throws {
        let note = try makeNote(text: "预约牙医")
        #expect(throws: DecompositionSourceCaptureError.blockSelectionUnsupported) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: .blocks(anchor: blockID, focus: blockID)
            )
        }
    }

    @Test func emojiGraphemeBoundaryDoesNotSplitCluster() throws {
        let note = try makeNote(text: "预约🦷牙医")
        let snapshot = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 2,
            selection: textSelection(lower: 2, upper: 3)
        )
        #expect(snapshot.normalizedText == "🦷")
        #expect(snapshot.selectedRange?.lowerGraphemeOffset == 2)
        #expect(snapshot.selectedRange?.upperGraphemeOffset == 3)
        #expect(snapshot.normalizedText.count == 1)
    }

    @Test func missingBlockAndOutOfRangeOffsetsAreInvalidSelection() throws {
        let note = try makeNote(text: "预约牙医")
        let missing = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000399")!)
        #expect(throws: DecompositionSourceCaptureError.invalidSelection) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: .text(
                    anchor: .init(blockID: missing, graphemeOffset: 0),
                    focus: .init(blockID: missing, graphemeOffset: 1),
                    preferredColumn: nil,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            )
        }
        #expect(throws: DecompositionSourceCaptureError.invalidSelection) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: textSelection(lower: 0, upper: 8)
            )
        }
        #expect(throws: DecompositionSourceCaptureError.invalidSelection) {
            try DecompositionSourceCapture.capture(
                note: note,
                workspaceRevision: 0,
                selection: textSelection(lower: -1, upper: 2)
            )
        }
    }

    @Test func noteAndSourceChecksumChangeWhenTheirInputsChange() throws {
        let note = try makeNote(text: "预约牙医")
        let selected = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 7,
            selection: textSelection(lower: 0, upper: 4)
        )
        let collapsed = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 7,
            selection: textSelection(lower: 0, upper: 0)
        )
        let recapture = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 9,
            selection: textSelection(lower: 0, upper: 4)
        )

        #expect(selected.noteChecksum == (try WorkspaceChecksum.noteSnapshotChecksum(note)))
        #expect(selected.sourceChecksum.count == 64)
        #expect(selected.noteID == recapture.noteID)
        #expect(selected.sourceBlockID == recapture.sourceBlockID)
        #expect(selected.selectedRange == recapture.selectedRange)
        #expect(selected.normalizedText == recapture.normalizedText)
        #expect(selected.noteChecksum == recapture.noteChecksum)
        #expect(selected.sourceChecksum == recapture.sourceChecksum)
        #expect(selected.workspaceRevision == 7)
        #expect(recapture.workspaceRevision == 9)
        #expect(selected.sourceChecksum != collapsed.sourceChecksum)
        #expect(selected.normalizedText == collapsed.normalizedText)

        var revised = note
        revised.document.blocks[0].inlineContent = .plain("改期看牙")
        let changed = try DecompositionSourceCapture.capture(
            note: revised,
            workspaceRevision: 7,
            selection: textSelection(lower: 0, upper: 4)
        )
        #expect(changed.noteChecksum != selected.noteChecksum)
        #expect(changed.noteChecksum == (try WorkspaceChecksum.noteSnapshotChecksum(revised)))
        #expect(changed.sourceChecksum != selected.sourceChecksum)

        let partial = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 7,
            selection: textSelection(lower: 2, upper: 4)
        )
        #expect(partial.normalizedText == "牙医")
        #expect(partial.sourceChecksum != selected.sourceChecksum)
        #expect(partial.noteChecksum == selected.noteChecksum)
    }

    @Test func wholeNoteTrimsOnlyOuterWhitespace() throws {
        let note = try makeNote(text: "  预约牙医  ")
        let snapshot = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 1,
            selection: textSelection(lower: 0, upper: 0)
        )
        #expect(snapshot.normalizedText == "预约牙医")
        #expect(snapshot.sourceBlockID == nil)
    }
}

extension DecompositionSourceCaptureTests {
    fileprivate func makeNote(text: String) throws -> Note {
        var note = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        note.document = .init(blocks: [
            .init(id: blockID, kind: .paragraph, inlineContent: .plain(text), taskState: nil, indentLevel: 0)
        ])
        return note
    }

    fileprivate func textSelection(lower: Int, upper: Int) -> BlockEditorSelection {
        .text(
            anchor: .init(blockID: blockID, graphemeOffset: lower),
            focus: .init(blockID: blockID, graphemeOffset: upper),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
    }
}

import Foundation
import Testing
import WorkspaceDomain

@Suite("BlockDocumentValidatorTests")
struct BlockDocumentValidatorTests {
    @Test func validatorRejectsEveryUnsupportedBlockShapeWithItsStableIdentifier() throws {
        let duplicate = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000201")!)
        let orphan = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)
        let missingTaskState = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000203")!)
        let unexpectedTaskState = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000204")!)
        let divider = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000205")!)
        let link = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000206")!)
        let nonList = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000210")!)

        #expect(throws: BlockDocumentValidationError.unsupportedSchema(2)) {
            try BlockDocumentValidator.validate(.init(schemaVersion: 2, blocks: []))
        }
        #expect(throws: BlockDocumentValidationError.duplicateBlockID(duplicate)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: duplicate, kind: .paragraph, inlineContent: .plain("一"), taskState: nil, indentLevel: 0),
                .init(id: duplicate, kind: .paragraph, inlineContent: .plain("二"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.invalidIndent(orphan, 4)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: orphan, kind: .bullet, inlineContent: .plain("太深"), taskState: nil, indentLevel: 4)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.orphanedIndent(orphan, 1)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: orphan, kind: .bullet, inlineContent: .plain("没有父级"), taskState: nil, indentLevel: 1)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.missingTaskState(missingTaskState)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: missingTaskState, kind: .task, inlineContent: .plain("缺少状态"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.unexpectedTaskState(unexpectedTaskState)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: unexpectedTaskState, kind: .paragraph, inlineContent: .plain("错误状态"), taskState: .init(completedAt: nil), indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.dividerHasContent(divider)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: divider, kind: .divider, inlineContent: .plain("不应有文字"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.invalidLink(link)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: link, kind: .link, inlineContent: .plain("没有 URL"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.invalidIndent(nonList, 1)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: nonList, kind: .quote, inlineContent: .plain("引用不能缩进"), taskState: nil, indentLevel: 1)
            ]))
        }
    }

    @Test func validatorAcceptsContinuousNestedListsAndTaskTimestamp() throws {
        let parent = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000207")!)
        let child = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000208")!)
        let task = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000209")!)
        let completedAt = Date(timeIntervalSince1970: 1_786_220_400)
        let document = BlockDocument(blocks: [
            .init(id: parent, kind: .bullet, inlineContent: .plain("父级"), taskState: nil, indentLevel: 0),
            .init(id: child, kind: .ordered, inlineContent: .plain("子级"), taskState: nil, indentLevel: 1),
            .init(id: task, kind: .task, inlineContent: .plain("待办"), taskState: .init(completedAt: completedAt), indentLevel: 2)
        ])

        try BlockDocumentValidator.validate(document)
        #expect(document.blocks[2].taskState?.completedAt == completedAt)
    }

    @Test func taskFactoryAllowsNestedIndentBeforeItsParentDocumentIsAssembled() throws {
        let parent = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000211")!)
        let child = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000212")!)
        let task = try DocumentBlock.task(
            id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000213")!),
            text: "嵌套待办",
            indentLevel: 2,
            completedAt: .distantPast
        )
        let document = BlockDocument(blocks: [
            .init(id: parent, kind: .bullet, inlineContent: .plain("父级"), taskState: nil, indentLevel: 0),
            .init(id: child, kind: .ordered, inlineContent: .plain("子级"), taskState: nil, indentLevel: 1),
            task
        ])

        try BlockDocumentValidator.validate(document)
        #expect(task.indentLevel == 2)
        #expect(task.taskState?.completedAt == .distantPast)
    }

    @Test func codeInfoStringKeepsLegacyDecodingAndRejectsInvalidShapes() throws {
        let code = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000214")!)
        let paragraph = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000215")!)
        let legacyJSON = """
        {
          "id": { "rawValue": "00000000-0000-0000-0000-000000000214" },
          "kind": "code",
          "inlineContent": { "spans": [{ "text": "print(1)", "marks": [] }] },
          "taskState": null,
          "indentLevel": 0
        }
        """
        let legacy = try JSONDecoder().decode(DocumentBlock.self, from: Data(legacyJSON.utf8))

        #expect(legacy.codeInfoString == nil)
        #expect(DocumentBlock(
            id: code,
            kind: .code,
            inlineContent: .plain("print(1)"),
            taskState: nil,
            indentLevel: 0,
            codeInfoString: " \tswift linenums=1\t "
        ).codeInfoString == "swift linenums=1")

        var invalidCode = DocumentBlock(
            id: code,
            kind: .code,
            inlineContent: .plain("print(1)"),
            taskState: nil,
            indentLevel: 0,
            codeInfoString: "swift"
        )
        invalidCode.codeInfoString = "swift\n"
        #expect(throws: BlockDocumentValidationError.invalidCodeInfo(code)) {
            try BlockDocumentValidator.validate(.init(blocks: [invalidCode]))
        }
        #expect(throws: BlockDocumentValidationError.unexpectedCodeInfo(paragraph)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(
                    id: paragraph,
                    kind: .paragraph,
                    inlineContent: .plain("正文"),
                    taskState: nil,
                    indentLevel: 0,
                    codeInfoString: "swift"
                )
            ]))
        }
    }

    @Test(arguments: ["swift\r", "swift\n", "swift\u{0000}"])
    func validatorRejectsControlCharactersInCodeInfoString(_ invalidInfoString: String) throws {
        let code = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000216")!)
        var block = DocumentBlock(
            id: code,
            kind: .code,
            inlineContent: .plain("print(1)"),
            taskState: nil,
            indentLevel: 0,
            codeInfoString: "swift"
        )
        block.codeInfoString = invalidInfoString

        #expect(throws: BlockDocumentValidationError.invalidCodeInfo(code)) {
            try BlockDocumentValidator.validate(.init(blocks: [block]))
        }
    }

    @Test func validatorRejectsEveryNonCanonicalCodeAndDividerSpanShape() throws {
        let code = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000217")!)
        let divider = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000218")!)
        let url = URL(string: "https://example.com/invalid")!
        let invalidCodeContents: [InlineContent] = [
            .init(spans: []),
            .init(spans: [.init(text: "one"), .init(text: "two")]),
            .init(spans: [.init(text: "marked", marks: [.bold])]),
            .init(spans: [.init(text: "linked", linkURL: url)])
        ]
        let invalidDividerContents: [InlineContent] = [
            .init(spans: []),
            .init(spans: [.init(text: "not empty")]),
            .init(spans: [.init(text: "", marks: [.italic])]),
            .init(spans: [.init(text: "", linkURL: url)]),
            .init(spans: [.init(text: ""), .init(text: "")])
        ]

        for inlineContent in invalidCodeContents {
            #expect(throws: (any Error).self) {
                try BlockDocumentValidator.validate(.init(blocks: [
                    .init(id: code, kind: .code, inlineContent: inlineContent, taskState: nil, indentLevel: 0)
                ]))
            }
        }
        for inlineContent in invalidDividerContents {
            #expect(throws: (any Error).self) {
                try BlockDocumentValidator.validate(.init(blocks: [
                    .init(id: divider, kind: .divider, inlineContent: inlineContent, taskState: nil, indentLevel: 0)
                ]))
            }
        }
    }

    @Test func taskCompletionDescriptionCanonicalizesAndOldJSONDefaultsToNil() throws {
        let task = try DocumentBlock.task(text: "联系物业", completionDescription: "  确认上门时间  \n")
        #expect(task.taskState?.completionDescription == "确认上门时间")

        let whitespaceOnly = try DocumentBlock.task(text: "手工任务", completionDescription: "  \n\t")
        #expect(whitespaceOnly.taskState?.completionDescription == nil)

        let old = #"{"completedAt":null}"#.data(using: .utf8)!
        #expect(try JSONDecoder.workspaceDeterministic.decode(TaskBlockState.self, from: old)
            == TaskBlockState(completedAt: nil, completionDescription: nil))

        let encoded = try JSONEncoder.workspaceDeterministic.encode(
            TaskBlockState(completedAt: nil, completionDescription: "  结果  ")
        )
        #expect(try JSONDecoder.workspaceDeterministic.decode(TaskBlockState.self, from: encoded)
            == TaskBlockState(completedAt: nil, completionDescription: "结果"))
    }

    @Test func validatorAllowsNilCompletionDescriptionAndRejectsNonCanonicalValues() throws {
        let ordinaryID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000219")!)
        let paddedID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000220")!)
        let ordinary = try DocumentBlock.task(id: ordinaryID, text: "普通待办")
        try BlockDocumentValidator.validate(.init(blocks: [ordinary]))
        #expect(ordinary.taskState?.completionDescription == nil)

        var padded = try DocumentBlock.task(id: paddedID, text: "普通待办", completionDescription: "结果")
        padded.taskState?.completionDescription = "  结果  "
        #expect(throws: BlockDocumentValidationError.invalidCompletionDescription(paddedID)) {
            try BlockDocumentValidator.validate(.init(blocks: [padded]))
        }
    }

    @Test func changingCompletionDescriptionChangesNoteSnapshotChecksum() throws {
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000221")!)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000223")!)
        func note(with description: String?) throws -> Note {
            Note(
                id: noteID,
                title: "校验和",
                document: .init(blocks: [
                    try .task(id: blockID, text: "打电话", completionDescription: description)
                ]),
                categoryID: categoryID,
                archivedAt: nil,
                revision: 1,
                createdAt: .distantPast,
                updatedAt: .distantPast
            )
        }

        let without = try note(with: nil)
        let withDescription = try note(with: "拿到确认")
        let withOther = try note(with: "另一种结果")
        #expect(
            try WorkspaceChecksum.noteSnapshotChecksum(without)
                != WorkspaceChecksum.noteSnapshotChecksum(withDescription)
        )
        #expect(
            try WorkspaceChecksum.noteSnapshotChecksum(withDescription)
                != WorkspaceChecksum.noteSnapshotChecksum(withOther)
        )
    }
}

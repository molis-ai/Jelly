import Foundation
import Testing
@testable import CalendarApp

@Suite("XiaohongshuPageParserTests")
struct XiaohongshuPageParserTests {
    @Test func parsesVideoNoteFromBalancedInitialState() throws {
        let html = """
        <script>
        window.__INITIAL_STATE__={
          "note":{"noteDetailMap":{"video-note-id":{"note":{
            "noteId":"video-note-id",
            "type":"video",
            "title":"页面标题",
            "desc":"公开视频正文 {不会截断}",
            "tagList":[{"name":"效率"},{"name":"学习"},{"name":"效率"}],
            "video":{"media":{"stream":{"h264":[
              {"masterUrl":"https://media.example/video.mp4","backupUrls":["https://backup.example/video.mp4"]}
            ]}}},
            "ignored":undefined
          }}}}}
        };
        </script>
        <script>window.after={"noise":"}"};</script>
        """

        let payload = try XiaohongshuPageParser.parse(
            html: html,
            expectedNoteID: "video-note-id"
        )

        #expect(payload.kind == .video)
        #expect(payload.title == "页面标题")
        #expect(payload.body == "公开视频正文 {不会截断}")
        #expect(payload.tags == ["效率", "学习"])
        #expect(payload.images.isEmpty)
        #expect(payload.videoCandidateURLs.map(\.absoluteString) == [
            "https://media.example/video.mp4",
            "https://backup.example/video.mp4"
        ])
    }

    @Test func parsesAllOrderedImageReferencesAndRejectsWrongNoteID() throws {
        let html = initialStateHTML(note: """
        {
          "noteId":"image-note-id",
          "type":"normal",
          "desc":"三张公开图片",
          "imageList":[
            {"urlDefault":"https://img.example/1.jpg"},
            {"urlPre":"https://img.example/2.jpg"},
            {"url":"https://img.example/3.jpg"},
            {"url":"https://img.example/1.jpg"}
          ]
        }
        """)

        let payload = try XiaohongshuPageParser.parse(
            html: html,
            expectedNoteID: "image-note-id"
        )
        #expect(payload.kind == .image)
        #expect(payload.images.map(\.url.absoluteString) == [
            "https://img.example/1.jpg",
            "https://img.example/2.jpg",
            "https://img.example/3.jpg"
        ])
        #expect(payload.images.map(\.index) == [1, 2, 3])
        #expect(throws: XiaohongshuPageParserError.noteMismatch) {
            _ = try XiaohongshuPageParser.parse(html: html, expectedNoteID: "other-note")
        }
    }

    @Test func rejectsMissingStateAndUnsafeResourceSchemes() throws {
        #expect(throws: XiaohongshuPageParserError.missingInitialState) {
            _ = try XiaohongshuPageParser.parse(
                html: "<html><title>只有标题</title></html>",
                expectedNoteID: "note-id"
            )
        }
        let html = initialStateHTML(note: """
        {
          "noteId":"note-id",
          "type":"video",
          "desc":"正文",
          "imageList":[
            {"url":"http://img.example/1.jpg"},
            {"url":"javascript:alert(1)"}
          ],
          "video":{"masterUrl":"http://media.example/video.mp4"}
        }
        """)
        let payload = try XiaohongshuPageParser.parse(html: html, expectedNoteID: "note-id")
        #expect(payload.images.isEmpty)
        #expect(payload.videoCandidateURLs.isEmpty)
    }

    @Test func rejectsPayloadWhoseMapKeyAndEmbeddedNoteIDDisagree() {
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"expected-id":{"note":{
          "noteId":"different-id","type":"normal","desc":"不应采信"
        }}}}};</script>
        """
        #expect(throws: XiaohongshuPageParserError.noteMismatch) {
            _ = try XiaohongshuPageParser.parse(html: html, expectedNoteID: "expected-id")
        }
    }

    private func initialStateHTML(note: String) -> String {
        """
        <script>
        window.__INITIAL_STATE__={"note":{"noteDetailMap":{"image-note-id":{"note":\(note)},"note-id":{"note":\(note)}}}};
        </script>
        """
    }
}

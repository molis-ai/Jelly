import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarItemRowPresentationTests")
@MainActor
struct CalendarItemRowPresentationTests {
    @Test func productionPlacementsInstallSwipeDeleteOnlyInDayDrawer() {
        let monthGrid = ItemRowActionChromePolicy(
            allowsSwipeToDelete: CalendarItemRowPlacement.monthGrid.allowsSwipeToDelete
        )
        let dayDrawer = ItemRowActionChromePolicy(
            allowsSwipeToDelete: CalendarItemRowPlacement.dayDrawer.allowsSwipeToDelete
        )

        #expect(monthGrid.installsSwipeGesture == false)
        #expect(monthGrid.showsDeleteAction == false)
        #expect(dayDrawer.installsSwipeGesture == true)
        #expect(dayDrawer.showsDeleteAction == true)
    }

    @Test func narrowTimedRowDropsTheClockWhileAWiderRowKeepsTheFullRange() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        #expect(compact.categoryName == nil)
        #expect(compact.timeText == nil)
        #expect(compact.accessibilityLabel == "工作, 09:00, 产品同步会")
        #expect(compact.title == "产品同步会")
        #expect(compact.layout.titleMinimumWidth == 20)
        #expect(compact.layout.timeLayoutPriority > compact.layout.titleLayoutPriority)
        #expect(compact.layout.textFontSize == 11)

        let regular = CalendarItemRowPresentation.make(
            availableContentWidth: 142,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        #expect(regular.categoryName == nil)
        #expect(regular.timeText == "09:00–10:00")
        #expect(regular.layout.textFontSize == 12)
    }

    /// The clock needs its own advance width plus the badge reserve plus a
    /// readable title remainder; one point below that the title takes it all.
    @Test func clockYieldsToTheTitleOnlyBelowItsReadableWidth() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let tooNarrow = CalendarItemRowPresentation.make(
            availableContentWidth: 134,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        let wideEnough = CalendarItemRowPresentation.make(
            availableContentWidth: 135,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(tooNarrow.timeText == nil)
        #expect(wideEnough.timeText == "09:00–10:00")
        #expect(tooNarrow.accessibilityLabel == wideEnough.accessibilityLabel)
    }

    @Test func categoryNameIsNeverShownEvenForLongCategoryLabels() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "重点客户项目",
            timeRange: range,
            title: "需要被合理省略的长标题"
        )

        #expect(compact.categoryName == nil)
        #expect(compact.timeText == "09:00–10:00")
        #expect(compact.title == "需要被合理省略的长标题")
    }

    @Test func minimumWindowContentBoundaryKeepsTheTitleAndHidesTheClock() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let boundary = CalendarItemRowPresentation.make(
            availableContentWidth: 120,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(boundary.categoryName == nil)
        #expect(boundary.timeText == nil)
        #expect(boundary.accessibilityLabel == "工作, 09:00, 产品同步会")
        #expect(boundary.title == "产品同步会")
        #expect(boundary.layout.titleMinimumWidth == 20)
        #expect(boundary.layout.timeLayoutPriority > boundary.layout.titleLayoutPriority)
    }

    @Test func minimumWindowGeometryWidthUsesCompactLayoutThrough140Points() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "重点客户项目",
            timeRange: range,
            title: "产品同步会"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "重点客户项目",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(compact.categoryName == nil)
        #expect(compact.layout.textFontSize == 11)
        #expect(standard.categoryName == nil)
        #expect(standard.layout.textFontSize == 12)
    }

    @Test func visualPresentationNeverSurfacesCategoryTokens() {
        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "工作",
            timeRange: nil,
            title: "事项"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "工作",
            timeRange: nil,
            title: "事项"
        )

        #expect(compact.categoryName == nil)
        #expect(standard.categoryName == nil)
        #expect(compact.timeText == nil)
        #expect(standard.timeText == nil)
    }

    @Test func compactTimedLayoutUsesReducedTypographyWhileStandardKeepsOriginalSize() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(compact.layout.textFontSize == 11)
        #expect(standard.layout.textFontSize == 12)
        #expect(compact.categoryName == nil)
        #expect(compact.timeText == "09:00–10:00")
        #expect(compact.title == "产品同步会")
    }

    @Test func rowBodyAccessibilityLabelKeepsFullCategoryInCompactAndStandardLayouts() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(compact.categoryName == nil)
        #expect(compact.accessibilityLabel == "工作, 09:00, 产品同步会")
        #expect(standard.accessibilityLabel == "工作, 09:00, 产品同步会")
        #expect(compact.timeText == "09:00–10:00")
    }

    @Test func rowBodyAccessibilityLabelOmitsTimeForUntimedItems() {
        let presentation = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "未分类",
            timeRange: nil,
            title: "收集灵感"
        )

        #expect(presentation.categoryName == nil)
        #expect(presentation.accessibilityLabel == "未分类, 收集灵感")
    }

    @Test func scheduleBackedRowKeepsItsStartTimeWhenAnOvernightSpanHasNoLegacyTimeRange() throws {
        let schedule = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 29)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 30)!,
            startTime: MinuteOfDay(hour: 23, minute: 0)!,
            endTime: MinuteOfDay(hour: 1, minute: 0)!
        )

        let presentation = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "工作",
            schedule: schedule,
            title: "夜间发布"
        )

        #expect(presentation.categoryName == nil)
        #expect(presentation.timeText == "23:00")
        #expect(presentation.accessibilityLabel == "工作, 23:00, 夜间发布")
    }

    @Test func monthStyleShowsOnlyStartTimeSoTheTitleCanUseTheChip() throws {
        let schedule = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 26)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 26)!,
            startTime: MinuteOfDay(hour: 15, minute: 30)!,
            endTime: MinuteOfDay(hour: 18, minute: 0)!
        )

        let month = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "Keep Fit",
            schedule: schedule,
            title: "超皮训练计划",
            timeTextStyle: .startOnly
        )
        let drawer = CalendarItemRowPresentation.make(
            availableContentWidth: 240,
            categoryName: "Keep Fit",
            schedule: schedule,
            title: "超皮训练计划",
            timeTextStyle: .range
        )

        #expect(month.timeText == "15:30")
        #expect(month.title == "超皮训练计划")
        #expect(month.accessibilityLabel == "Keep Fit, 15:30, 超皮训练计划")
        #expect(drawer.timeText == "15:30–18:00")
    }

    @Test func narrowUntimedRowKeepsTitleWithoutCategoryLabel() {
        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "重点客户项目",
            timeRange: nil,
            title: "需要被合理省略的长标题"
        )

        #expect(compact.categoryName == nil)
        #expect(compact.timeText == nil)
        #expect(compact.title == "需要被合理省略的长标题")
        #expect(compact.layout.titleMinimumWidth == 20)
    }

    @Test func completeItemAccessibilityIncludesAllScheduleStateAndStableSourceValue() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            kind: .task,
            title: "跨夜发布",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 29)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 30)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let accessibility = CalendarItemAccessibility.make(
            item: .item(item),
            categoryName: "工作"
        )

        #expect(accessibility.label.contains("事项"))
        #expect(accessibility.label.contains("工作"))
        #expect(accessibility.label.contains("跨夜发布"))
        #expect(accessibility.label.contains("8月29日 23:00至8月30日 01:00"))
        #expect(accessibility.label.contains("未完成"))
        #expect(accessibility.value == "来源事项 item:\(item.id.uuidString)")
        #expect(CalendarItemAccessibility.completionLabel(isCompleted: false) == "标记为已完成")
        #expect(CalendarItemAccessibility.completionLabel(isCompleted: true) == "标记为未完成")
    }
}

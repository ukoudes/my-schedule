import SwiftUI
import PDFKit
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers

struct Course: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var teacher: String = ""
    var room: String = ""
    var building: String? = ""
    var weekday: Int
    var start: Int
    var end: Int
    var color: String
    var titleSize: String? = "特大"
    var startWeek: Int? = 1
    var endWeek: Int? = 20
}

enum CourseItemKind: String, Codable, CaseIterable, Identifiable {
    case exam = "考试"
    case assignment = "作业"
    case other = "其他"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .exam: return "doc.text.magnifyingglass"
        case .assignment: return "checklist"
        case .other: return "calendar"
        }
    }
}

struct CourseItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var courseID: UUID
    var kind: CourseItemKind = .assignment
    var title: String = "新作业"
    var date: Date = Date()
    var location: String = ""
    var notes: String = ""
    var isCompleted: Bool = false
}

private enum CourseItemDeadlineStatus {
    case overdue
    case dueToday

    func text(for kind: CourseItemKind) -> String {
        switch (self, kind) {
        case (.overdue, .exam): return "考试已过"
        case (.overdue, .assignment): return "已逾期"
        case (.overdue, .other): return "事项已过"
        case (.dueToday, .exam): return "今天考试"
        case (.dueToday, .assignment): return "今天截止"
        case (.dueToday, .other): return "今天进行"
        }
    }

    var color: Color {
        switch self {
        case .overdue: return .red
        case .dueToday: return .orange
        }
    }
}

private func deadlineStatus(for item: CourseItem, now: Date = Date()) -> CourseItemDeadlineStatus? {
    guard !item.isCompleted else { return nil }
    let calendar = Calendar.current
    if calendar.isDateInToday(item.date) { return .dueToday }
    if item.date < calendar.startOfDay(for: now) { return .overdue }
    return nil
}

private func itemNoun(for kind: CourseItemKind) -> String {
    switch kind {
    case .exam: return "考试"
    case .assignment: return "作业"
    case .other: return "事项"
    }
}

@MainActor final class ScheduleStore: ObservableObject {
    @Published var courses: [Course] = [] { didSet { saveCourses() } }
    @Published var courseItems: [CourseItem] = [] { didSet { saveCourseItems() } }
    private let coursesFile: URL
    private let courseItemsFile: URL
    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("课程小部件", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        coursesFile = folder.appendingPathComponent("courses.json")
        courseItemsFile = folder.appendingPathComponent("course-items.json")
        if let data = try? Data(contentsOf: coursesFile), let saved = try? JSONDecoder().decode([Course].self, from: data) { courses = saved }
        if let data = try? Data(contentsOf: courseItemsFile), let saved = try? JSONDecoder().decode([CourseItem].self, from: data) {
            courseItems = saved.map { savedItem in
                var item = savedItem
                if item.title == "新作业" {
                    if item.kind == .exam { item.title = "新考试" }
                    if item.kind == .other { item.title = "新事项" }
                }
                return item
            }
            if courseItems != saved { saveCourseItems() }
        }
    }
    private func saveCourses() { if let data = try? JSONEncoder().encode(courses) { try? data.write(to: coursesFile, options: .atomic) } }
    private func saveCourseItems() { if let data = try? JSONEncoder().encode(courseItems) { try? data.write(to: courseItemsFile, options: .atomic) } }
}

@main struct ScheduleWidgetApp: App {
    @StateObject private var store = ScheduleStore()
    var body: some Scene {
        WindowGroup("我的课表") { ContentView().environmentObject(store).frame(minWidth: 760, minHeight: 780) }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 980, height: 820)
    }
}

private func localDate(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private let defaultSemesterStart = localDate(year: 2026, month: 8, day: 24)
private let defaultSemesterEnd = localDate(year: 2027, month: 1, day: 10)

private func semesterWeeks(from semesterStart: Date, through semesterEnd: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = calendar.startOfDay(for: semesterStart)
    let end = max(start, calendar.startOfDay(for: semesterEnd))
    let dayDifference = calendar.dateComponents([.day], from: start, to: end).day ?? 0
    return max(1, (dayDifference + 7) / 7)
}

private func semesterWeekDateRange(_ week: Int, semesterStart: Date, semesterEnd: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let weekStart = calendar.date(byAdding: .day, value: (week - 1) * 7, to: semesterStart)!
    let naturalWeekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)!
    let weekEnd = min(naturalWeekEnd, semesterEnd)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return "\(formatter.string(from: weekStart))—\(formatter.string(from: weekEnd))"
}

private func currentSemesterWeek(from semesterStart: Date, through semesterEnd: Date, on date: Date = Date()) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let day = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: semesterStart),
        to: calendar.startOfDay(for: date)
    ).day ?? 0
    return min(semesterWeeks(from: semesterStart, through: semesterEnd), max(1, day / 7 + 1))
}

private func semesterWeekContaining(_ date: Date, from semesterStart: Date, through semesterEnd: Date) -> Int? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let target = calendar.startOfDay(for: date)
    let start = calendar.startOfDay(for: semesterStart)
    let end = calendar.startOfDay(for: semesterEnd)
    guard target >= start, target <= end else { return nil }
    let day = calendar.dateComponents([.day], from: start, to: target).day ?? 0
    return day / 7 + 1
}

private func timetableProgress(at date: Date) -> CGFloat? {
    let starts = [480, 540, 610, 670, 840, 900, 970, 1030, 1110, 1170, 1230, 1290]
    let ends =   [530, 590, 660, 720, 890, 950, 1020, 1080, 1160, 1220, 1280, 1340]
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    guard minute >= starts[0], minute <= ends[11] else { return nil }
    for index in starts.indices {
        if minute >= starts[index], minute <= ends[index] {
            return CGFloat(index) + CGFloat(minute - starts[index]) / CGFloat(ends[index] - starts[index])
        }
        if index < starts.count - 1, minute > ends[index], minute < starts[index + 1] {
            return CGFloat(index + 1)
        }
    }
    return nil
}

struct ContentView: View {
    @EnvironmentObject var store: ScheduleStore
    @AppStorage("academicYearStart") private var academicYearStart = 2026
    @AppStorage("semesterNumber") private var semesterNumber = 1
    @AppStorage("semesterStartTimestamp") private var semesterStartTimestamp = defaultSemesterStart.timeIntervalSince1970
    @AppStorage("semesterEndTimestamp") private var semesterEndTimestamp = defaultSemesterEnd.timeIntervalSince1970
    @State private var editing: Course? = nil
    @State private var editingCourseItem: CourseItem? = nil
    @State private var showingCampusMap = false
    @State private var showingSettings = false
    @State private var selectedWeek = 1
    private let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private let classTimes = ["08:00–08:50", "09:00–09:50", "10:10–11:00", "11:10–12:00", "14:00–14:50", "15:00–15:50", "16:10–17:00", "17:10–18:00", "18:30–19:20", "19:30–20:20", "20:30–21:20", "21:30–22:20"]
    private var semesterStart: Date { Date(timeIntervalSince1970: semesterStartTimestamp) }
    private var semesterEnd: Date { Date(timeIntervalSince1970: semesterEndTimestamp) }
    private var semesterWeekCount: Int { semesterWeeks(from: semesterStart, through: semesterEnd) }
    private var currentWeekInSemester: Int? {
        semesterWeekContaining(Date(), from: semesterStart, through: semesterEnd)
    }
    private var upcomingCourseItems: [CourseItem] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return store.courseItems
            .filter { item in
                guard !item.isCompleted else { return false }
                let isPastAndUnfinished = item.date < now
                return isPastAndUnfinished || (item.date >= now && item.date <= end)
            }
            .sorted { lhs, rhs in
                let lhsOverdue = deadlineStatus(for: lhs, now: now) == .overdue
                let rhsOverdue = deadlineStatus(for: rhs, now: now) == .overdue
                if lhsOverdue != rhsOverdue { return lhsOverdue }
                if lhsOverdue, rhsOverdue, lhs.date != rhs.date { return lhs.date > rhs.date }
                return lhs.date == rhs.date ? lhs.title < rhs.title : lhs.date < rhs.date
            }
    }

    private func jumpToCurrentWeek() {
        selectedWeek = currentSemesterWeek(from: semesterStart, through: semesterEnd)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("我的课表").font(.title2.bold())
                    Text(verbatim: "\(academicYearStart)–\(academicYearStart + 1)学年 第\(semesterNumber)学期").font(.caption).fontWeight(.medium)
                    Text("点按课程即可编辑 · 课程会自动保存").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let currentWeekInSemester, selectedWeek != currentWeekInSemester {
                    Button { selectedWeek = currentWeekInSemester } label: {
                        Label("回到本周", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
                HStack(spacing: 5) {
                    Button { selectedWeek = max(1, selectedWeek - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(selectedWeek == 1)
                    Menu {
                        ForEach(1...semesterWeekCount, id: \.self) { week in
                            Button("第 \(week) 周 · \(semesterWeekDateRange(week, semesterStart: semesterStart, semesterEnd: semesterEnd))") {
                                selectedWeek = week
                            }
                        }
                    } label: {
                        Text("第 \(selectedWeek) 周")
                            .frame(width: 64)
                    }
                    .frame(width: 88)
                    Button { selectedWeek = min(semesterWeekCount, selectedWeek + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(selectedWeek == semesterWeekCount)
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                Button { showingSettings = true } label: { Label("设置", systemImage: "gearshape") }.buttonStyle(.bordered)
                Button { showingCampusMap = true } label: { Label("查看地图", systemImage: "map") }.buttonStyle(.bordered)
                Button { editing = Course(title: "新课程", weekday: 0, start: 1, end: 2, color: "蓝", endWeek: semesterWeekCount) } label: { Label("添加课程", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(18)
            Divider()
            if !upcomingCourseItems.isEmpty {
                UpcomingItemsBar(
                    items: upcomingCourseItems,
                    courses: store.courses,
                    edit: { editingCourseItem = $0 },
                    toggleCompleted: { item in
                        guard let index = store.courseItems.firstIndex(where: { $0.id == item.id }) else { return }
                        store.courseItems[index].isCompleted.toggle()
                    }
                )
                Divider()
            }
            if store.courses.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    timetable(at: context.date)
                }
            }
        }
        .background(.regularMaterial)
        .sheet(item: $editing) { course in CourseEditor(course: course, semesterWeekCount: semesterWeekCount, isNew: !store.courses.contains(where: { $0.id == course.id })) { result in
            if let i = store.courses.firstIndex(where: { $0.id == result.id }) { store.courses[i] = result } else { store.courses.append(result) }
            editing = nil
        } delete: {
            store.courseItems.removeAll { $0.courseID == course.id }
            store.courses.removeAll { $0.id == course.id }
            editing = nil
        } cancel: { editing = nil } }
        .sheet(item: $editingCourseItem) { item in
            CourseItemEditor(item: item, course: store.courses.first(where: { $0.id == item.courseID }), isNew: false) { result in
                if let index = store.courseItems.firstIndex(where: { $0.id == result.id }) {
                    store.courseItems[index] = result
                }
                editingCourseItem = nil
            } delete: {
                store.courseItems.removeAll { $0.id == item.id }
                editingCourseItem = nil
            } cancel: { editingCourseItem = nil }
        }
        .sheet(isPresented: $showingCampusMap) { CampusMapSheet(initialQuery: "") }
        .sheet(isPresented: $showingSettings) {
            AppSettingsView(
                academicYearStart: $academicYearStart,
                semesterNumber: $semesterNumber,
                semesterStartTimestamp: $semesterStartTimestamp,
                semesterEndTimestamp: $semesterEndTimestamp,
                courses: store.courses,
                courseItems: store.courseItems,
                selectedWeek: selectedWeek,
                hasCourses: !store.courses.isEmpty,
                deleteAllCourses: {
                    store.courseItems.removeAll()
                    store.courses.removeAll()
                }
            )
        }
        .onAppear { jumpToCurrentWeek() }
        .onChange(of: semesterStartTimestamp) { _, _ in jumpToCurrentWeek() }
        .onChange(of: semesterEndTimestamp) { _, _ in jumpToCurrentWeek() }
    }

    var emptyState: some View { VStack(spacing: 13) { Spacer(); Image(systemName: "calendar.badge.plus").font(.system(size: 42)).foregroundStyle(.blue); Text("从第一门课开始吧").font(.headline); Text("添加后可以随时点按编辑，或调整窗口大小。 ").foregroundStyle(.secondary); Button("添加课程") { editing = Course(title: "新课程", weekday: 0, start: 1, end: 2, color: "蓝", endWeek: semesterWeekCount) }.buttonStyle(.borderedProminent); Spacer() } }
    func timetable(at now: Date) -> some View {
        GeometryReader { proxy in
            let headerHeight: CGFloat = 28
            let left: CGFloat = 126; let col = (proxy.size.width-left)/7; let row = (proxy.size.height-headerHeight)/12
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let startDay = calendar.startOfDay(for: semesterStart)
            let endDay = calendar.startOfDay(for: semesterEnd)
            let dayOffset = calendar.dateComponents([.day], from: startDay, to: today).day ?? -1
            let todayWeek = dayOffset >= 0 ? dayOffset / 7 + 1 : 0
            let viewingCurrentWeek = today >= startDay && today <= endDay && selectedWeek == todayWeek
            let todayIndex = (calendar.component(.weekday, from: today) + 5) % 7
            ZStack(alignment: .topLeading) {
                if viewingCurrentWeek {
                    Color.accentColor.opacity(0.07)
                        .frame(width: col, height: proxy.size.height)
                        .position(x: left + col * (CGFloat(todayIndex) + 0.5), y: proxy.size.height / 2)
                }
                ForEach(0..<8, id: \.self) { i in
                    let isToday = viewingCurrentWeek && i > 0 && i - 1 == todayIndex
                    ZStack {
                        if isToday {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.accentColor.opacity(0.2))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                        Text(i == 0 ? "节次" : (isToday ? "\(days[i - 1]) · 今天" : days[i - 1]))
                            .font(.caption.bold())
                            .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                    }
                    .frame(width: i == 0 ? left : col, height: headerHeight)
                    .position(x: i == 0 ? left / 2 : left + col * (CGFloat(i) - 0.5), y: headerHeight / 2)
                }
                ForEach(1...12, id: \.self) { section in
                    Path { p in let y = headerHeight + CGFloat(section-1)*row; p.move(to: CGPoint(x: 0,y:y)); p.addLine(to: CGPoint(x: proxy.size.width,y:y)) }.stroke(.gray.opacity(0.15))
                    VStack(spacing: 3) {
                        Text("第 \(section) 节").font(.caption.bold())
                        Text(classTimes[section - 1]).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(width: left, height: row)
                    .position(x:left/2,y:headerHeight+CGFloat(section-1)*row+row/2)
                }
                Path { p in p.move(to: CGPoint(x: 0, y: proxy.size.height)); p.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height)) }
                    .stroke(.gray.opacity(0.24), lineWidth: 1)
                Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: proxy.size.height)) }
                    .stroke(.gray.opacity(0.24), lineWidth: 1)
                ForEach(0...7, id: \.self) { i in Path { p in let x = i == 0 ? left : left + CGFloat(i)*col; p.move(to: CGPoint(x:x,y:0)); p.addLine(to: CGPoint(x:x,y:proxy.size.height)) }.stroke(.gray.opacity(0.24), lineWidth: 1) }
                ForEach(store.courses.filter { course in
                    selectedWeek >= (course.startWeek ?? 1) && selectedWeek <= (course.endWeek ?? semesterWeekCount)
                }) { course in
                    Button { editing = course } label: { CourseCard(course: course) }.buttonStyle(.plain)
                        .frame(width: col-8, height: max(38, CGFloat(course.end-course.start+1)*row-6))
                        .position(x: left + col*(CGFloat(course.weekday)+0.5), y: headerHeight + CGFloat(course.start-1)*row + CGFloat(course.end-course.start+1)*row/2)
                }
                if viewingCurrentWeek, let progress = timetableProgress(at: now) {
                    let lineY = headerHeight + progress * row
                    let markerX = left + CGFloat(todayIndex + 1) * col
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .position(x: markerX, y: lineY)
                        .help("当前时间 \(now.formatted(.dateTime.hour().minute()))")
                }
            }.padding(.top, 0)
        }.padding(.horizontal, 10).padding(.bottom, 10)
    }
}

private func courseTint(from value: String) -> Color {
    let presets: [String: Color] = ["蓝": .blue, "紫": .purple, "绿": .green, "橙": .orange, "粉": .pink, "红": .red]
    if let preset = presets[value] { return preset }
    let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return .blue }
    return Color(
        red: Double((number >> 16) & 0xff) / 255,
        green: Double((number >> 8) & 0xff) / 255,
        blue: Double(number & 0xff) / 255
    )
}

private func colorHex(from color: Color) -> String {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#007AFF" }
    return String(
        format: "#%02X%02X%02X",
        Int(round(rgb.redComponent * 255)),
        Int(round(rgb.greenComponent * 255)),
        Int(round(rgb.blueComponent * 255))
    )
}

struct CourseCard: View {
    let course: Course
    var tint: Color { courseTint(from: course.color) }
    var titleFont: Font { switch course.titleSize ?? "特大" { case "标准": .caption.bold(); case "大": .subheadline.bold(); case "超大": .title3.bold(); default: .headline.bold() } }
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(course.title).font(titleFont).lineLimit(2); if !course.teacher.isEmpty { Text(course.teacher).font(.caption).lineLimit(1) }; if !course.room.isEmpty { Text(course.room).font(.caption2).lineLimit(1) } }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(8).foregroundStyle(tint).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9)) }
}

struct UpcomingItemsBar: View {
    let items: [CourseItem]
    let courses: [Course]
    let edit: (CourseItem) -> Void
    let toggleCompleted: (CourseItem) -> Void

    private func course(for item: CourseItem) -> Course? {
        courses.first { $0.id == item.courseID }
    }

    private func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M月d日 E HH:mm"
        }
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("未来 7 天").font(.caption.bold())
                Text("课程事项").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 74, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        let course = course(for: item)
                        let status = deadlineStatus(for: item)
                        HStack(spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: item.kind.icon)
                                    .foregroundStyle(course.map { courseTint(from: $0.color) } ?? Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.caption.bold()).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text("\(course?.title ?? item.kind.rawValue) · \(dateText(item.date))")
                                            .font(.system(size: 10))
                                            .foregroundStyle(status?.color ?? Color.secondary)
                                            .lineLimit(1)
                                        if let status {
                                            Text(status.text(for: item.kind))
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(status.color, in: Capsule())
                                        }
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { edit(item) }
                            Button { toggleCompleted(item) } label: {
                                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(item.isCompleted ? "标记为未完成" : "标记为已完成")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(height: 58)
    }
}

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var neutralFocus: Bool
    @State private var showingDeleteAllConfirmation = false
    @State private var showingCalendarSyncConfirmation = false
    @State private var exportStatus = ""
    @State private var isSyncingCalendar = false
    @Binding var academicYearStart: Int
    @Binding var semesterNumber: Int
    @Binding var semesterStartTimestamp: Double
    @Binding var semesterEndTimestamp: Double
    let courses: [Course]
    let courseItems: [CourseItem]
    let selectedWeek: Int
    let hasCourses: Bool
    let deleteAllCourses: () -> Void

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: semesterStartTimestamp) },
            set: { newDate in
                let normalized = Calendar.current.startOfDay(for: newDate)
                semesterStartTimestamp = normalized.timeIntervalSince1970
                if semesterEndTimestamp < semesterStartTimestamp {
                    semesterEndTimestamp = semesterStartTimestamp
                }
            }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: semesterEndTimestamp) },
            set: { newDate in
                let normalized = Calendar.current.startOfDay(for: newDate)
                semesterEndTimestamp = max(normalized.timeIntervalSince1970, semesterStartTimestamp)
            }
        )
    }

    private var weekCount: Int {
        semesterWeeks(from: startDateBinding.wrappedValue, through: endDateBinding.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("应用设置")
                    .font(.title2.bold())
                    .focusable()
                    .focused($neutralFocus)
                    .focusEffectDisabled()
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            Form {
                Section("学期设置") {
                    HStack(alignment: .center, spacing: 12) {
                        Text("学年").frame(width: 72, alignment: .leading)
                        Text(verbatim: "\(academicYearStart)–\(academicYearStart + 1)学年")
                            .monospacedDigit()
                        Spacer()
                        Stepper("", value: $academicYearStart, in: 2000...2100)
                            .labelsHidden()
                            .fixedSize()
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Text("学期").frame(width: 72, alignment: .leading)
                        Picker("", selection: $semesterNumber) {
                            Text("第1学期").tag(1)
                            Text("第2学期").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Text("起始日期").frame(width: 72, alignment: .leading)
                        DatePicker("", selection: startDateBinding, displayedComponents: .date)
                            .labelsHidden()
                        Spacer()
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Text("终止日期").frame(width: 72, alignment: .leading)
                        DatePicker("", selection: endDateBinding, in: startDateBinding.wrappedValue..., displayedComponents: .date)
                            .labelsHidden()
                        Spacer()
                    }
                    HStack {
                        Text("自动计算")
                        Spacer()
                        Text("共 \(weekCount) 周").fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                }
                Section("导出与日历") {
                    HStack(spacing: 10) {
                        Button { exportCurrentWeek(as: .png) } label: {
                            Label("导出图片", systemImage: "photo")
                        }
                        Button { exportCurrentWeek(as: .pdf) } label: {
                            Label("导出 PDF", systemImage: "doc.richtext")
                        }
                    }
                    HStack(spacing: 10) {
                        Button(action: exportICS) {
                            Label("导出日历文件", systemImage: "calendar.badge.plus")
                        }
                        Button { showingCalendarSyncConfirmation = true } label: {
                            if isSyncingCalendar {
                                ProgressView().controlSize(.small)
                                Text("正在同步…")
                            } else {
                                Label("同步到苹果日历", systemImage: "calendar")
                            }
                        }
                        .disabled(isSyncingCalendar)
                    }
                    if !exportStatus.isEmpty {
                        Text(exportStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("数据管理") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("清空课表").fontWeight(.medium)
                            Text("删除应用内保存的全部课程")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("删除所有课程", role: .destructive) {
                            showingDeleteAllConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(!hasCourses)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(width: 520, height: 620)
        .defaultFocus($neutralFocus, true)
        .alert("删除所有课程？", isPresented: $showingDeleteAllConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive, action: deleteAllCourses)
        } message: {
            Text("此操作会清空课表中的全部课程，且无法撤销。")
        }
        .confirmationDialog("同步到苹果日历？", isPresented: $showingCalendarSyncConfirmation) {
            Button("同步整学期课程") { syncToAppleCalendar() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用会创建或更新名为“我的课表”的日历；再次同步不会产生重复课程。")
        }
    }

    private enum ExportFormat { case png, pdf }

    private func exportCurrentWeek(as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "我的课表-第\(selectedWeek)周.\(format == .png ? "png" : "pdf")"
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let exportView = TimetableExportView(
            courses: courses,
            selectedWeek: selectedWeek,
            semesterStart: startDateBinding.wrappedValue,
            semesterEnd: endDateBinding.wrappedValue,
            academicYearStart: academicYearStart,
            semesterNumber: semesterNumber
        )
        let size = CGSize(width: 1400, height: 1000)

        do {
            switch format {
            case .png:
                let renderer = ImageRenderer(content: exportView.frame(width: size.width, height: size.height))
                renderer.proposedSize = ProposedViewSize(size)
                renderer.scale = 3
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else {
                    throw ExportError.renderFailed
                }
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw ExportError.renderFailed
                }
                try data.write(to: url, options: .atomic)
            case .pdf:
                let renderer = ImageRenderer(content: exportView.frame(width: size.width, height: size.height))
                renderer.proposedSize = ProposedViewSize(size)
                renderer.scale = 1
                var rendered = false
                renderer.render { renderedSize, draw in
                    var mediaBox = CGRect(origin: .zero, size: renderedSize)
                    guard let consumer = CGDataConsumer(url: url as CFURL),
                          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
                    context.beginPDFPage(nil)
                    draw(context)
                    context.endPDFPage()
                    context.closePDF()
                    rendered = true
                }
                if !rendered { throw ExportError.renderFailed }
            }
            exportStatus = "已导出：\(url.lastPathComponent)"
        } catch {
            exportStatus = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportICS() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let calendarType = UTType(filenameExtension: "ics") {
            panel.allowedContentTypes = [calendarType]
        }
        panel.nameFieldStringValue = "我的课表-\(academicYearStart)-\(academicYearStart + 1)-第\(semesterNumber)学期.ics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = CalendarExport.ics(
                courses: courses,
                courseItems: courseItems,
                semesterStart: startDateBinding.wrappedValue,
                semesterEnd: endDateBinding.wrappedValue
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "已导出：\(url.lastPathComponent)"
        } catch {
            exportStatus = "导出失败：\(error.localizedDescription)"
        }
    }

    private func syncToAppleCalendar() {
        isSyncingCalendar = true
        exportStatus = "正在请求日历权限…"
        CalendarExport.syncToAppleCalendar(
            courses: courses,
            courseItems: courseItems,
            semesterStart: startDateBinding.wrappedValue,
            semesterEnd: endDateBinding.wrappedValue
        ) { result in
            DispatchQueue.main.async {
                isSyncingCalendar = false
                switch result {
                case .success(let count): exportStatus = "已同步 \(count) 节课到苹果日历"
                case .failure(let error): exportStatus = "同步失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private enum ExportError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "无法生成课表画面" }
    }
}

private struct TimetableExportView: View {
    let courses: [Course]
    let selectedWeek: Int
    let semesterStart: Date
    let semesterEnd: Date
    let academicYearStart: Int
    let semesterNumber: Int

    private let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private let classTimes = ["08:00–08:50", "09:00–09:50", "10:10–11:00", "11:10–12:00", "14:00–14:50", "15:00–15:50", "16:10–17:00", "17:10–18:00", "18:30–19:20", "19:30–20:20", "20:30–21:20", "21:30–22:20"]

    private func dateLabel(for weekday: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: (selectedWeek - 1) * 7 + weekday, to: semesterStart) ?? semesterStart
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的课表").font(.system(size: 30, weight: .bold))
                    Text(verbatim: "\(academicYearStart)–\(academicYearStart + 1)学年 第\(semesterNumber)学期")
                        .font(.system(size: 16, weight: .medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("第 \(selectedWeek) 周").font(.system(size: 24, weight: .bold))
                    Text(semesterWeekDateRange(selectedWeek, semesterStart: semesterStart, semesterEnd: semesterEnd))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26)

            GeometryReader { proxy in
                let headerHeight: CGFloat = 56
                let left: CGFloat = 126
                let col = (proxy.size.width - left) / 7
                let row = (proxy.size.height - headerHeight) / 12
                ZStack(alignment: .topLeading) {
                    Color.white
                    ForEach(0..<8, id: \.self) { index in
                        Group {
                            if index == 0 {
                                Text("节次").font(.system(size: 14, weight: .bold))
                            } else {
                                VStack(spacing: 3) {
                                    Text(days[index - 1]).font(.system(size: 14, weight: .bold))
                                    Text(dateLabel(for: index - 1)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: index == 0 ? left : col, height: headerHeight)
                        .position(x: index == 0 ? left / 2 : left + col * (CGFloat(index) - 0.5), y: headerHeight / 2)
                    }
                    ForEach(1...12, id: \.self) { section in
                        VStack(spacing: 4) {
                            Text("第 \(section) 节").font(.system(size: 13, weight: .bold))
                            Text(classTimes[section - 1]).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(width: left, height: row)
                        .position(x: left / 2, y: headerHeight + CGFloat(section - 1) * row + row / 2)
                    }
                    ForEach(0...12, id: \.self) { index in
                        Path { path in
                            let y = headerHeight + CGFloat(index) * row
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }.stroke(Color.gray.opacity(0.28), lineWidth: 1)
                    }
                    ForEach(0...8, id: \.self) { index in
                        Path { path in
                            let x = index == 0 ? 0 : left + CGFloat(index - 1) * col
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }.stroke(Color.gray.opacity(0.28), lineWidth: 1)
                    }
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                    }.stroke(Color.gray.opacity(0.28), lineWidth: 1)

                    ForEach(courses.filter {
                        selectedWeek >= ($0.startWeek ?? 1) && selectedWeek <= ($0.endWeek ?? semesterWeeks(from: semesterStart, through: semesterEnd))
                    }) { course in
                        CourseCard(course: course)
                            .frame(width: col - 10, height: max(40, CGFloat(course.end - course.start + 1) * row - 8))
                            .position(
                                x: left + col * (CGFloat(course.weekday) + 0.5),
                                y: headerHeight + CGFloat(course.start - 1) * row + CGFloat(course.end - course.start + 1) * row / 2
                            )
                    }
                }
            }
        }
        .padding(24)
        .foregroundStyle(Color.black)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

private enum CalendarExport {
    private static let marker = "[我的课表同步]"
    private static let sectionTimes = [
        (8, 0, 8, 50), (9, 0, 9, 50), (10, 10, 11, 0), (11, 10, 12, 0),
        (14, 0, 14, 50), (15, 0, 15, 50), (16, 10, 17, 0), (17, 10, 18, 0),
        (18, 30, 19, 20), (19, 30, 20, 20), (20, 30, 21, 20), (21, 30, 22, 20)
    ]

    private struct Occurrence {
        let course: Course
        let week: Int
        let start: Date
        let end: Date
    }

    static func ics(courses: [Course], courseItems: [CourseItem], semesterStart: Date, semesterEnd: Date) -> String {
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = .current
        localFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        stampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = stampFormatter.string(from: Date())
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//My Schedule//CN",
            "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:我的课表",
            "X-WR-TIMEZONE:Asia/Shanghai"
        ]
        for item in occurrences(courses: courses, semesterStart: semesterStart, semesterEnd: semesterEnd) {
            let location = [item.course.building ?? "", item.course.room].filter { !$0.isEmpty }.joined(separator: " ")
            lines += [
                "BEGIN:VEVENT",
                "UID:\(item.course.id.uuidString)-\(item.week)@my-schedule.local",
                "DTSTAMP:\(stamp)",
                "DTSTART;TZID=Asia/Shanghai:\(localFormatter.string(from: item.start))",
                "DTEND;TZID=Asia/Shanghai:\(localFormatter.string(from: item.end))",
                "SUMMARY:\(escapeICS(item.course.title))",
                "LOCATION:\(escapeICS(location))",
                "DESCRIPTION:\(escapeICS(item.course.teacher))",
                "END:VEVENT"
            ]
        }
        for item in calendarItems(courseItems, courses: courses, semesterStart: semesterStart, semesterEnd: semesterEnd) {
            let end = Calendar.current.date(byAdding: .hour, value: 1, to: item.item.date) ?? item.item.date
            let courseTitle = item.course?.title ?? "课程事项"
            let summaryPrefix = item.item.kind == .assignment ? "作业截止" : item.item.kind.rawValue
            let completion = item.item.isCompleted ? "✓ " : ""
            lines += [
                "BEGIN:VEVENT",
                "UID:item-\(item.item.id.uuidString)@my-schedule.local",
                "DTSTAMP:\(stamp)",
                "DTSTART;TZID=Asia/Shanghai:\(localFormatter.string(from: item.item.date))",
                "DTEND;TZID=Asia/Shanghai:\(localFormatter.string(from: end))",
                "SUMMARY:\(escapeICS("\(completion)\(summaryPrefix)：\(item.item.title)"))",
                "LOCATION:\(escapeICS(item.item.location))",
                "DESCRIPTION:\(escapeICS([courseTitle, item.item.notes].filter { !$0.isEmpty }.joined(separator: "\n")))",
                "END:VEVENT"
            ]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func syncToAppleCalendar(
        courses: [Course], courseItems: [CourseItem], semesterStart: Date, semesterEnd: Date,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let eventStore = EKEventStore()
        requestAccess(to: eventStore) { granted, accessError in
            guard granted else {
                completion(.failure(accessError ?? CalendarError.permissionDenied))
                return
            }
            DispatchQueue.main.async {
                do {
                    let calendar = try writableCalendar(in: eventStore)
                    let calendarEnd = Calendar.current.date(byAdding: .day, value: 1, to: semesterEnd) ?? semesterEnd
                    let predicate = eventStore.predicateForEvents(withStart: semesterStart, end: calendarEnd, calendars: [calendar])
                    for event in eventStore.events(matching: predicate) where event.notes?.contains(marker) == true {
                        try eventStore.remove(event, span: .thisEvent, commit: false)
                    }
                    let occurrences = occurrences(courses: courses, semesterStart: semesterStart, semesterEnd: semesterEnd)
                    for item in occurrences {
                        let event = EKEvent(eventStore: eventStore)
                        event.calendar = calendar
                        event.title = item.course.title
                        event.startDate = item.start
                        event.endDate = item.end
                        event.location = [item.course.building ?? "", item.course.room].filter { !$0.isEmpty }.joined(separator: " ")
                        event.notes = [marker, item.course.teacher].filter { !$0.isEmpty }.joined(separator: "\n")
                        try eventStore.save(event, span: .thisEvent, commit: false)
                    }
                    let scheduledItems = calendarItems(courseItems, courses: courses, semesterStart: semesterStart, semesterEnd: semesterEnd)
                    for item in scheduledItems {
                        let event = EKEvent(eventStore: eventStore)
                        let summaryPrefix = item.item.kind == .assignment ? "作业截止" : item.item.kind.rawValue
                        let completion = item.item.isCompleted ? "✓ " : ""
                        event.calendar = calendar
                        event.title = "\(completion)\(summaryPrefix)：\(item.item.title)"
                        event.startDate = item.item.date
                        event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: item.item.date) ?? item.item.date
                        event.location = item.item.location
                        event.notes = [marker, item.course?.title ?? "", item.item.notes].filter { !$0.isEmpty }.joined(separator: "\n")
                        try eventStore.save(event, span: .thisEvent, commit: false)
                    }
                    try eventStore.commit()
                    completion(.success(occurrences.count + scheduledItems.count))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func requestAccess(to store: EKEventStore, completion: @escaping (Bool, Error?) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: completion)
        } else {
            store.requestAccess(to: .event, completion: completion)
        }
    }

    private static func writableCalendar(in store: EKEventStore) throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == "我的课表" && $0.allowsContentModifications }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }) ?? store.sources.first else {
            throw CalendarError.noWritableSource
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "我的课表"
        calendar.source = source
        calendar.cgColor = NSColor.systemBlue.cgColor
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private static func occurrences(courses: [Course], semesterStart: Date, semesterEnd: Date) -> [Occurrence] {
        let calendar = Calendar.current
        let maxWeek = semesterWeeks(from: semesterStart, through: semesterEnd)
        var result: [Occurrence] = []
        for course in courses {
            let firstWeek = min(max(1, course.startWeek ?? 1), maxWeek)
            let lastWeek = min(max(firstWeek, course.endWeek ?? maxWeek), maxWeek)
            let startIndex = min(max(course.start, 1), 12) - 1
            let endIndex = min(max(course.end, course.start), 12) - 1
            for week in firstWeek...lastWeek {
                guard let day = calendar.date(byAdding: .day, value: (week - 1) * 7 + course.weekday, to: semesterStart), day <= semesterEnd else { continue }
                let startTime = sectionTimes[startIndex]
                let endTime = sectionTimes[endIndex]
                let start = calendar.date(bySettingHour: startTime.0, minute: startTime.1, second: 0, of: day) ?? day
                let end = calendar.date(bySettingHour: endTime.2, minute: endTime.3, second: 0, of: day) ?? day
                result.append(Occurrence(course: course, week: week, start: start, end: end))
            }
        }
        return result
    }

    private static func calendarItems(_ items: [CourseItem], courses: [Course], semesterStart: Date, semesterEnd: Date) -> [(item: CourseItem, course: Course?)] {
        let start = Calendar.current.startOfDay(for: semesterStart)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: semesterEnd)) ?? semesterEnd
        return items
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.date < $1.date }
            .map { item in (item, courses.first { $0.id == item.courseID }) }
    }

    private static func escapeICS(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private enum CalendarError: LocalizedError {
        case permissionDenied, noWritableSource
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有日历访问权限，请在系统设置的隐私与安全性中允许访问"
            case .noWritableSource: return "没有找到可写入的苹果日历账户"
            }
        }
    }
}

struct CourseItemEditor: View {
    @State var item: CourseItem
    @State private var showingDeleteConfirmation = false
    let course: Course?
    let isNew: Bool
    let save: (CourseItem) -> Void
    let delete: () -> Void
    let cancel: () -> Void

    private var timeFieldTitle: String {
        switch item.kind {
        case .exam: return "考试时间"
        case .assignment: return "截止时间"
        case .other: return "事项时间"
        }
    }

    private func defaultTitle(for kind: CourseItemKind) -> String {
        switch kind {
        case .exam: return "新考试"
        case .assignment: return "新作业"
        case .other: return "新事项"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "添加事项" : "编辑事项").font(.title2.bold())
                if let course {
                    Text(course.title).font(.caption).foregroundStyle(courseTint(from: course.color))
                }
            }
            Form {
                Picker("类型", selection: $item.kind) {
                    ForEach(CourseItemKind.allCases) { kind in
                        Label(kind.rawValue, systemImage: kind.icon).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                TextField("名称", text: $item.title)
                DatePicker(timeFieldTitle, selection: $item.date, displayedComponents: [.date, .hourAndMinute])
                TextField("地点", text: $item.location)
                TextField("备注", text: $item.notes)
                Toggle("已完成", isOn: $item.isCompleted)
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("删除\(itemNoun(for: item.kind))", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
                Spacer()
                Button("取消", action: cancel)
                Button("保存") {
                    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(item)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470, height: 410)
        .onChange(of: item.kind) { _, kind in
            if ["新考试", "新作业", "新事项"].contains(item.title) {
                item.title = defaultTitle(for: kind)
            }
        }
        .alert("删除\(itemNoun(for: item.kind))？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除\(itemNoun(for: item.kind))", role: .destructive, action: delete)
        } message: {
            Text("“\(item.title)”将被永久删除。")
        }
    }
}

struct CourseEditor: View {
    @EnvironmentObject private var store: ScheduleStore
    @AppStorage("academicYearStart") private var academicYearStart = 2026
    @AppStorage("semesterNumber") private var semesterNumber = 1
    @State var course: Course
    @State private var showingMap = false
    @State private var showingNJUImport = false
    @State private var editingCourseItem: CourseItem?
    @State private var deletingCourseItem: CourseItem?
    let semesterWeekCount: Int
    let isNew: Bool
    let save: (Course) -> Void
    let delete: () -> Void
    let cancel: () -> Void

    let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    let titleSizes = ["标准", "大", "特大", "超大"]

    var titleSizeBinding: Binding<String> {
        Binding(get: { course.titleSize ?? "特大" }, set: { course.titleSize = $0 })
    }

    var buildingBinding: Binding<String> {
        Binding(get: { course.building ?? "" }, set: { course.building = $0 })
    }

    var courseColorBinding: Binding<Color> {
        Binding(
            get: { courseTint(from: course.color) },
            set: { course.color = colorHex(from: $0) }
        )
    }

    var startWeekBinding: Binding<Int> {
        Binding(get: { course.startWeek ?? 1 }, set: { course.startWeek = $0 })
    }

    var endWeekBinding: Binding<Int> {
        Binding(get: { course.endWeek ?? semesterWeekCount }, set: { course.endWeek = $0 })
    }

    var trimmedBuilding: String {
        (course.building ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "添加课程" : "编辑课程").font(.title2.bold())
            Form {
                if isNew {
                    Button { showingNJUImport = true } label: {
                        Label("从南京大学教务系统导入", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                TextField("课程名称", text: $course.title)
                Picker("课程名大小", selection: titleSizeBinding) {
                    ForEach(titleSizes, id: \.self) { Text($0).tag($0) }
                }
                TextField("教师", text: $course.teacher)
                TextField("教室", text: $course.room)
                TextField("教室所在楼栋", text: buildingBinding)
                Button { showingMap = true } label: {
                    Label("在地图上查找", systemImage: "map")
                }
                .disabled(trimmedBuilding.isEmpty)
                Picker("星期", selection: $course.weekday) {
                    ForEach(days.indices, id: \.self) { Text(days[$0]).tag($0) }
                }
                HStack(alignment: .center, spacing: 8) {
                    Text("开始节次")
                    Spacer()
                    TextField("", value: $course.start, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 62, height: 24)
                    Stepper("", value: $course.start, in: 1...12).labelsHidden().fixedSize()
                    Text("节")
                }
                HStack(alignment: .center, spacing: 8) {
                    Text("结束节次")
                    Spacer()
                    TextField("", value: $course.end, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 62, height: 24)
                    Stepper("", value: $course.end, in: 1...12).labelsHidden().fixedSize()
                    Text("节")
                }
                HStack(alignment: .center, spacing: 8) {
                    Text("开始周")
                    Spacer()
                    TextField("", value: startWeekBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 62, height: 24)
                    Stepper("", value: startWeekBinding, in: 1...semesterWeekCount).labelsHidden().fixedSize()
                    Text("周")
                }
                HStack(alignment: .center, spacing: 8) {
                    Text("结束周")
                    Spacer()
                    TextField("", value: endWeekBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 62, height: 24)
                    Stepper("", value: endWeekBinding, in: 1...semesterWeekCount).labelsHidden().fixedSize()
                    Text("周")
                }
                ColorPicker("颜色", selection: courseColorBinding, supportsOpacity: false)
                Section("课程事项") {
                    if isNew {
                        Text("保存课程后即可添加考试、作业和其他事项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                            let defaultDate = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                            editingCourseItem = CourseItem(courseID: course.id, date: defaultDate)
                        } label: {
                            Label("添加课程事项", systemImage: "plus.circle")
                        }
                        ForEach(store.courseItems.filter { $0.courseID == course.id }.sorted { $0.date < $1.date }) { item in
                            let status = deadlineStatus(for: item)
                            HStack(spacing: 9) {
                                Button { editingCourseItem = item } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: item.kind.icon)
                                            .foregroundStyle(courseTint(from: course.color))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .lineLimit(1)
                                                .strikethrough(item.isCompleted)
                                            HStack(spacing: 6) {
                                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.caption)
                                                    .foregroundStyle(status?.color ?? Color.secondary)
                                                if let status {
                                                    Text(status.text(for: item.kind))
                                                        .font(.caption2.bold())
                                                        .foregroundStyle(status.color)
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .opacity(item.isCompleted ? 0.65 : 1)
                                }
                                .buttonStyle(.plain)
                                HStack(alignment: .center, spacing: 4) {
                                    Button {
                                        guard let index = store.courseItems.firstIndex(where: { $0.id == item.id }) else { return }
                                        store.courseItems[index].isCompleted.toggle()
                                    } label: {
                                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(item.isCompleted ? Color.green : Color.secondary)
                                            .frame(width: 28, height: 28, alignment: .center)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(item.isCompleted ? "标记为未完成" : "标记为已完成")
                                    Button(role: .destructive) {
                                        deletingCourseItem = item
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14, weight: .semibold))
                                            .frame(width: 28, height: 28, alignment: .center)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.red)
                                    .help("删除\(itemNoun(for: item.kind))")
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew { Button("删除课程", role: .destructive, action: delete) }
                Spacer()
                Button("取消", action: cancel)
                Button("保存") {
                    course.startWeek = min(max(course.startWeek ?? 1, 1), semesterWeekCount)
                    course.endWeek = min(max(course.endWeek ?? semesterWeekCount, course.startWeek ?? 1), semesterWeekCount)
                    course.start = min(max(course.start, 1), 12)
                    course.end = min(max(course.end, course.start), 12)
                    save(course)
                }
                .buttonStyle(.borderedProminent)
                .disabled(course.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .sheet(isPresented: $showingMap) {
            CampusMapSheet(initialQuery: trimmedBuilding)
        }
        .sheet(isPresented: $showingNJUImport) {
            NJUImportSheet(
                academicYearStart: academicYearStart,
                semesterNumber: semesterNumber,
                semesterWeekCount: semesterWeekCount
            ) { imported in
                mergeImportedCourses(imported)
                cancel()
            }
        }
        .sheet(item: $editingCourseItem) { item in
            let isNewItem = !store.courseItems.contains(where: { $0.id == item.id })
            CourseItemEditor(item: item, course: course, isNew: isNewItem) { result in
                if let index = store.courseItems.firstIndex(where: { $0.id == result.id }) {
                    store.courseItems[index] = result
                } else {
                    store.courseItems.append(result)
                }
                editingCourseItem = nil
            } delete: {
                store.courseItems.removeAll { $0.id == item.id }
                editingCourseItem = nil
            } cancel: {
                editingCourseItem = nil
            }
        }
        .alert("删除\(deletingCourseItem.map { itemNoun(for: $0.kind) } ?? "事项")？", isPresented: Binding(
            get: { deletingCourseItem != nil },
            set: { if !$0 { deletingCourseItem = nil } }
        )) {
            Button("取消", role: .cancel) { deletingCourseItem = nil }
            Button("删除\(deletingCourseItem.map { itemNoun(for: $0.kind) } ?? "事项")", role: .destructive) {
                if let deletingCourseItem {
                    store.courseItems.removeAll { $0.id == deletingCourseItem.id }
                }
                deletingCourseItem = nil
            }
        } message: {
            Text(deletingCourseItem.map { "“\($0.title)”将从“\(course.title)”中永久删除。" } ?? "该事项将被永久删除。")
        }
    }

    private func mergeImportedCourses(_ imported: [Course]) {
        for importedCourse in imported where !store.courses.contains(where: { existing in
            existing.title == importedCourse.title &&
            existing.weekday == importedCourse.weekday &&
            existing.start == importedCourse.start &&
            existing.end == importedCourse.end &&
            (existing.startWeek ?? 1) == (importedCourse.startWeek ?? 1) &&
            (existing.endWeek ?? semesterWeekCount) == (importedCourse.endWeek ?? semesterWeekCount) &&
            existing.room == importedCourse.room
        }) {
            store.courses.append(importedCourse)
        }
    }
}

struct CampusMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var searchID = UUID()
    @State private var found: Bool?

    init(initialQuery: String) {
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("输入楼栋名称", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("定位", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("完成") { dismiss() }
            }
            if let found {
                Text(found ? "已在地图上高亮楼栋位置" : "地图中未找到该名称，请尝试输入完整楼栋名称")
                    .font(.caption)
                    .foregroundStyle(found ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LegacyCampusPDFView(query: query, searchID: searchID, found: $found)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.25)))
        }
        .padding(18)
        .frame(minWidth: 860, minHeight: 760)
        .onAppear { search() }
    }

    private func search() {
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchID = UUID()
    }
}

final class RasterMarkerOverlay: NSView {
    var markerRect: NSRect?
    var selectionRect: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let markerRect else { return }
        let markerPath = NSBezierPath(ovalIn: markerRect)
        NSColor.systemYellow.withAlphaComponent(0.40).setFill()
        markerPath.fill()
        NSColor.systemRed.setStroke()
        markerPath.lineWidth = 8
        markerPath.stroke()

        if let selectionRect {
            let selectionPath = NSBezierPath(roundedRect: selectionRect.insetBy(dx: -6, dy: -5), xRadius: 5, yRadius: 5)
            NSColor.systemYellow.withAlphaComponent(0.72).setFill()
            selectionPath.fill()
            NSColor.systemOrange.setStroke()
            selectionPath.lineWidth = 3
            selectionPath.stroke()
        }
    }
}

final class RasterMapCanvas: NSImageView {
    private let baseImage: NSImage
    private var dragStartPoint: NSPoint?
    private var dragStartOrigin: NSPoint?
    private weak var activeScrollView: NSScrollView?
    private let markerLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private var drawnMarkerRect: NSRect?
    private var drawnSelectionRect: NSRect?
    private let markerOverlay = RasterMarkerOverlay(frame: .zero)

    init(image: NSImage, pageSize: NSSize) {
        baseImage = image
        super.init(frame: NSRect(origin: .zero, size: pageSize))
        self.image = image
        imageScaling = .scaleAxesIndependently
        imageAlignment = .alignCenter
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        markerLayer.frame = bounds
        markerLayer.fillColor = NSColor.systemYellow.withAlphaComponent(0.42).cgColor
        markerLayer.strokeColor = NSColor.systemRed.cgColor
        markerLayer.lineWidth = 7
        markerLayer.isHidden = true
        layer?.addSublayer(markerLayer)

        selectionLayer.frame = bounds
        selectionLayer.fillColor = NSColor.systemYellow.withAlphaComponent(0.72).cgColor
        selectionLayer.strokeColor = NSColor.systemOrange.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true
        layer?.addSublayer(selectionLayer)

        markerOverlay.frame = bounds
        markerOverlay.autoresizingMask = [.width, .height]
        addSubview(markerOverlay)
    }

    required init?(coder: NSCoder) { nil }

    func showMarker(around markerRect: NSRect, selectionRect: NSRect) {
        drawnMarkerRect = markerRect
        drawnSelectionRect = selectionRect
        markerOverlay.markerRect = markerRect
        markerOverlay.selectionRect = selectionRect
        markerOverlay.needsDisplay = true
        let markedImage = NSImage(size: bounds.size)
        markedImage.lockFocus()
        baseImage.draw(in: bounds)
        let markerPath = NSBezierPath(ovalIn: markerRect)
        NSColor.systemYellow.withAlphaComponent(0.40).setFill()
        markerPath.fill()
        NSColor.systemRed.setStroke()
        markerPath.lineWidth = 8
        markerPath.stroke()
        let selectionPath = NSBezierPath(roundedRect: selectionRect.insetBy(dx: -6, dy: -5), xRadius: 5, yRadius: 5)
        NSColor.systemYellow.withAlphaComponent(0.72).setFill()
        selectionPath.fill()
        NSColor.systemOrange.setStroke()
        selectionPath.lineWidth = 3
        selectionPath.stroke()
        markedImage.unlockFocus()
        image = markedImage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markerLayer.isHidden = true
        selectionLayer.isHidden = true
        CATransaction.commit()
        needsDisplay = true
    }

    func clearMarker() {
        drawnMarkerRect = nil
        drawnSelectionRect = nil
        markerOverlay.markerRect = nil
        markerOverlay.selectionRect = nil
        markerOverlay.needsDisplay = true
        image = baseImage
        markerLayer.isHidden = true
        selectionLayer.isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let markerRect = drawnMarkerRect else { return }

        let markerPath = NSBezierPath(ovalIn: markerRect)
        NSColor.systemYellow.withAlphaComponent(0.38).setFill()
        markerPath.fill()
        NSColor.systemRed.setStroke()
        markerPath.lineWidth = 8
        markerPath.stroke()

        if let selectionRect = drawnSelectionRect {
            let selectionPath = NSBezierPath(roundedRect: selectionRect.insetBy(dx: -6, dy: -5), xRadius: 5, yRadius: 5)
            NSColor.systemYellow.withAlphaComponent(0.68).setFill()
            selectionPath.fill()
            NSColor.systemOrange.setStroke()
            selectionPath.lineWidth = 3
            selectionPath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else {
            super.mouseDown(with: event)
            return
        }
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragStartOrigin = scrollView.contentView.bounds.origin
        activeScrollView = scrollView
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = dragStartPoint,
              let startOrigin = dragStartOrigin,
              let scrollView = enclosingScrollView else {
            super.mouseDragged(with: event)
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let viewport = scrollView.contentView.bounds.size
        let maxX = max(0, bounds.width - viewport.width)
        let maxY = max(0, bounds.height - viewport.height)
        let target = NSPoint(
            x: min(max(0, startOrigin.x - (currentPoint.x - startPoint.x)), maxX),
            y: min(max(0, startOrigin.y - (currentPoint.y - startPoint.y)), maxY)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.contentView.setBoundsOrigin(target)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        if let scrollView = activeScrollView {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if dragStartPoint != nil { NSCursor.pop() }
        dragStartPoint = nil
        dragStartOrigin = nil
        activeScrollView = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if result.width > documentView.frame.width {
            result.origin.x = (documentView.frame.width - result.width) / 2
        }
        if result.height > documentView.frame.height {
            result.origin.y = (documentView.frame.height - result.height) / 2
        }
        return result
    }
}

final class RasterCampusMapView: NSScrollView {
    let pdfDocument: PDFDocument?
    let canvas: RasterMapCanvas
    private var didInitialFit = false

    init(image: NSImage, document: PDFDocument?, pageSize: NSSize) {
        pdfDocument = document
        canvas = RasterMapCanvas(image: image, pageSize: pageSize)
        super.init(frame: .zero)
        let centeredClipView = CenteringClipView()
        centeredClipView.drawsBackground = false
        contentView = centeredClipView
        documentView = canvas
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        contentView.wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if !didInitialFit, contentSize.width > 1, contentSize.height > 1 {
            didInitialFit = true
            fitMap()
        }
    }

    private var fitMagnification: CGFloat {
        min(contentSize.width / canvas.bounds.width, contentSize.height / canvas.bounds.height)
    }

    func fitMap() {
        layoutSubtreeIfNeeded()
        guard contentSize.width > 1, contentSize.height > 1 else {
            DispatchQueue.main.async { [weak self] in self?.fitMap() }
            return
        }
        let fit = max(0.01, fitMagnification)
        maxMagnification = max(8, fit * 8)
        minMagnification = min(fit, 1)
        setMagnification(fit, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        // At fit scale the portrait map is narrower than the viewport. AppKit may
        // reset the clip origin after changing magnification, so center it once
        // more using document coordinates.
        let visibleSize = contentView.bounds.size
        contentView.setBoundsOrigin(NSPoint(
            x: (canvas.bounds.width - visibleSize.width) / 2,
            y: (canvas.bounds.height - visibleSize.height) / 2
        ))
        reflectScrolledClipView(contentView)
    }

    func focus(on rect: NSRect) {
        layoutSubtreeIfNeeded()
        guard contentSize.width > 1, contentSize.height > 1 else {
            DispatchQueue.main.async { [weak self] in self?.focus(on: rect) }
            return
        }
        let fit = max(0.01, fitMagnification)
        maxMagnification = max(8, fit * 8)
        minMagnification = min(fit, 1)
        setMagnification(min(maxMagnification, fit * 4.2), centeredAt: NSPoint(x: rect.midX, y: rect.midY))
    }
}

struct CampusPDFView: NSViewRepresentable {
    let query: String
    let searchID: UUID
    @Binding var found: Bool?

    func makeNSView(context: Context) -> RasterCampusMapView {
        let pdfURL = Bundle.main.url(forResource: "鼓楼校区地图竖版2024", withExtension: "pdf")
        let document = pdfURL.flatMap(PDFDocument.init(url:))
        let pageSize = document?.page(at: 0)?.bounds(for: .mediaBox).size ?? NSSize(width: 1700, height: 2551)
        let imageURL = Bundle.main.url(forResource: "鼓楼校区地图高清", withExtension: "png")
        let image = imageURL.flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: pageSize)
        return RasterCampusMapView(image: image, document: document, pageSize: pageSize)
    }

    func updateNSView(_ view: RasterCampusMapView, context: Context) {
        guard context.coordinator.lastSearchID != searchID else { return }
        context.coordinator.lastSearchID = searchID
        view.canvas.clearMarker()
        guard let document = view.pdfDocument else {
            DispatchQueue.main.async { found = false }
            return
        }

        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            view.fitMap()
            view.alphaValue = 1
            DispatchQueue.main.async { found = nil }
            return
        }

        view.alphaValue = 0
        DispatchQueue.main.async { found = nil }

        var matches = document.findString(clean, withOptions: [.caseInsensitive])
        if matches.isEmpty {
            let spaced = clean.map(String.init).joined(separator: " ")
            matches = document.findString(spaced, withOptions: [.caseInsensitive])
        }

        guard let match = matches.first, let page = match.pages.first else {
            view.fitMap()
            view.alphaValue = 1
            DispatchQueue.main.async { found = false }
            return
        }

        let selectionBounds = match.bounds(for: page)
        let markerWidth = max(150, selectionBounds.width + 80)
        let markerHeight = max(90, selectionBounds.height + 60)
        let markerBounds = NSRect(
            x: selectionBounds.midX - markerWidth / 2,
            y: selectionBounds.midY - markerHeight / 2,
            width: markerWidth,
            height: markerHeight
        )
        view.canvas.showMarker(around: markerBounds, selectionRect: selectionBounds)
        view.focus(on: markerBounds)
        DispatchQueue.main.async {
            view.alphaValue = 1
            found = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSearchID: UUID?
    }
}

// Restored PDFKit-backed map used by the version before the raster-map
// experiment. The original vector PDF remains sharp at every zoom level.
struct LegacyCampusPDFView: NSViewRepresentable {
    let query: String
    let searchID: UUID
    @Binding var found: Bool?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = false
        view.autoScales = true
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 12
        view.backgroundColor = .windowBackgroundColor
        if let url = Bundle.main.url(forResource: "鼓楼校区地图竖版2024", withExtension: "pdf") {
            view.document = PDFDocument(url: url)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.lastSearchID != searchID else { return }
        context.coordinator.lastSearchID = searchID
        removeAnnotations(context.coordinator.annotations)
        context.coordinator.annotations.removeAll()

        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            view.currentSelection = nil
            view.autoScales = true
            DispatchQueue.main.async { found = nil }
            return
        }
        guard let document = view.document else {
            DispatchQueue.main.async { found = false }
            return
        }

        var matches = document.findString(clean, withOptions: [.caseInsensitive])
        if matches.isEmpty {
            matches = document.findString(clean.map(String.init).joined(separator: " "), withOptions: [.caseInsensitive])
        }
        guard let match = matches.first, let page = match.pages.first else {
            view.autoScales = true
            DispatchQueue.main.async { found = false }
            return
        }

        let selectionBounds = match.bounds(for: page)
        let markerBounds = NSRect(
            x: selectionBounds.midX - max(150, selectionBounds.width + 80) / 2,
            y: selectionBounds.midY - max(90, selectionBounds.height + 60) / 2,
            width: max(150, selectionBounds.width + 80),
            height: max(90, selectionBounds.height + 60)
        )
        let marker = PDFAnnotation(bounds: markerBounds, forType: .circle, withProperties: nil)
        marker.color = .systemRed
        marker.interiorColor = .systemYellow.withAlphaComponent(0.34)
        let border = PDFBorder()
        border.lineWidth = 5
        marker.border = border
        page.addAnnotation(marker)

        let highlight = PDFAnnotation(bounds: selectionBounds.insetBy(dx: -5, dy: -4), forType: .highlight, withProperties: nil)
        highlight.color = .systemYellow.withAlphaComponent(0.78)
        page.addAnnotation(highlight)
        context.coordinator.annotations = [marker, highlight]

        view.autoScales = false
        let targetScale = min(view.maxScaleFactor, max(view.minScaleFactor, view.scaleFactorForSizeToFit * 4.2))
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0
            view.scaleFactor = targetScale
            view.go(to: match)
        }
        view.setCurrentSelection(nil, animate: false)
        DispatchQueue.main.async { found = true }
    }

    private func removeAnnotations(_ annotations: [PDFAnnotation]) {
        for annotation in annotations { annotation.page?.removeAnnotation(annotation) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSearchID: UUID?
        var annotations: [PDFAnnotation] = []
    }
}

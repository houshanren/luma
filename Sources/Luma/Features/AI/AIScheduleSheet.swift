import SwiftUI

/// 定时任务：按天 / 按周自动跑一轮助手任务，结果留在对话里。
/// 后台只执行只读步骤，涉及写入会停下等人确认。
struct AIScheduleSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var prompt = ""
    @State private var cadence: AIScheduleCadence = .daily
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = 1

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editor
                    list
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 600)
        .background(.regularMaterial)
        .tint(settings.accentColor)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("定时任务")
                    .font(.system(size: 14, weight: .semibold))
                Text("到点自动跑一轮；后台只读，写操作留给你确认")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("新建")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("名称，例如「每周一图库体检」", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("任务内容，例如「给当前图库做一次体检，列出可清理项」", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack(spacing: 10) {
                Picker("", selection: $cadence) {
                    ForEach(AIScheduleCadence.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)

                if cadence == .weekly {
                    Picker("", selection: $weekday) {
                        ForEach(1...7, id: \.self) { value in
                            Text(AIScheduledTask(title: "", prompt: "", weekday: value).weekdayText)
                                .tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }

                Picker("", selection: $hour) {
                    ForEach(0...23, id: \.self) { value in
                        Text(String(format: "%02d", value)).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
                Text(":")
                    .foregroundStyle(.secondary)
                Picker("", selection: $minute) {
                    ForEach(Array(stride(from: 0, through: 55, by: 5)), id: \.self) { value in
                        Text(String(format: "%02d", value)).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 60)

                Spacer(minLength: 8)
                Button("添加") {
                    add()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已设置")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(store.aiSchedules.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if store.aiSchedules.isEmpty {
                Text("还没有定时任务。可以先从「每周一图库体检」开始。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.aiSchedules) { task in
                    taskRow(task)
                }
            }
        }
    }

    private func taskRow(_ task: AIScheduledTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { _ in store.toggleAISchedule(task.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(task.cadenceText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(task.prompt)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let next = task.nextRunAt, task.isEnabled {
                        Text("下次 \(Self.timeFormatter.string(from: next))")
                    } else if !task.isEnabled {
                        Text("已暂停")
                    }
                    if !task.lastStatus.isEmpty {
                        Text("· \(task.lastStatus)")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Menu {
                Button("立即运行") {
                    store.runAIScheduleNow(task.id)
                }
                .disabled(store.aiIsResponding)
                Button("删除", role: .destructive) {
                    store.removeAISchedule(task.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(task.isEnabled ? 1 : 0.62)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("到点时若助手正忙，会顺延到下一次检查；后台任务不会自动执行写操作。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func add() {
        let created = store.addAISchedule(title: title,
                                          prompt: prompt,
                                          cadence: cadence,
                                          hour: hour,
                                          minute: minute,
                                          weekday: weekday)
        guard created != nil else { return }
        title = ""
        prompt = ""
        store.showToast("已添加定时任务")
    }
}

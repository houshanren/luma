import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runFootprintChecks() {

    let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

    func sample(_ seconds: Double, _ latitude: Double, _ longitude: Double,
                _ key: String = "a", _ name: String = "杭州") -> FootprintSample {
        FootprintSample(time: baseTime.addingTimeInterval(seconds),
                        point: FootprintPoint(latitude: latitude, longitude: longitude),
                        placeKey: key,
                        placeName: name)
    }

    let merged = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300),
        sample(60, 30.2600, 120.1300),
        sample(120, 30.2601, 120.1301)
    ])
    expectEqual(merged.stops.count, 1, "同一位置的连拍合并成一站")
    expectEqual(merged.stops.first?.photoCount, 3, "合并后保留照片数")

    let nearby = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300),
        sample(600, 30.2610, 120.1300)
    ])
    expectEqual(nearby.stops.count, 2, "相隔约 110 米的照片仍是两站")
    expectEqual(nearby.legs.count, 1, "两站之间有一段行程")
    if let leg = nearby.legs.first {
        expect(leg.distance > 90 && leg.distance < 130, "近距离行程按实际米数计算")
        expect(leg.cameraDistance < 500, "近距离行程把镜头压到街区尺度")
        expect(leg.pitch >= 45, "街区行程使用大俯仰角")
        expect(leg.caption.contains("米"), "近距离行程给出米级文案")
        expect(leg.duration >= 1.5 && leg.duration <= 2.0, "近距离行程保留可辨认的移动过程")
        expectClose(CGFloat(leg.distance / leg.cameraDistance / leg.duration), 0.24,
                    accuracy: 0.001, "近距离行程使用统一视觉速度")
    }

    let flight = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300),
        sample(3600, 39.9042, 116.4074, "b", "北京")
    ])
    if let leg = flight.legs.first {
        expect(leg.distance > 1_000_000, "跨城距离为千米级")
        expect(leg.cameraDistance > leg.distance, "长距离航段镜头升到更高处")
        expect(leg.pitch <= 35, "长距离航段压低俯仰角")
        expect(leg.heading > 300 || leg.heading < 20, "北京在杭州北方，朝向接近正北")
        expect(leg.duration <= 2.5, "长距离航段有最长时长上限")
        expectClose(CGFloat(leg.distance / leg.cameraDistance / leg.duration), 0.24,
                    accuracy: 0.001, "跨城与街区保持一致的画面速度")
    }

    let samePlaceLongStay = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300),
        sample(3_000, 30.2604, 120.1300),
        sample(6_000, 30.2604, 120.1301)
    ])
    expectEqual(samePlaceLongStay.stops.count, 1, "同地点数十米内合并为一站，避免原地抖动")

    let placeChange = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300, "a", "杭州"),
        sample(600, 30.2700, 120.1300, "west", "西湖")
    ])
    expectEqual(placeChange.stops.count, 2, "地点键变化时另起一站")
    expectEqual(placeChange.places, ["杭州", "西湖"], "地点名按出现顺序去重")

    let monotonic = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300),
        sample(600, 30.2700, 120.1300),
        sample(1200, 30.2800, 120.1300)
    ])
    expectEqual(monotonic.distanceToStop.count, monotonic.stops.count, "累计里程与站点数一致")
    expect(monotonic.distanceToStop == monotonic.distanceToStop.sorted(), "累计里程单调递增")
    expectClose(CGFloat(monotonic.totalDistance), CGFloat(monotonic.distanceToStop.last ?? 0),
                accuracy: 0.001, "总里程取最后一站的累计值")

    let far = FootprintPlanner.distance(from: FootprintPoint(latitude: 0, longitude: 0),
                                        to: FootprintPoint(latitude: 1, longitude: 0))
    expectClose(CGFloat(far), 111_195, accuracy: 500, "一度纬度约 111 公里")

    let midpoint = FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                                to: FootprintPoint(latitude: 30, longitude: 40),
                                                fraction: 0.5)
    expectClose(CGFloat(midpoint.latitude), 20.28, accuracy: 0.2, "大圆插值中点纬度")
    expectClose(CGFloat(midpoint.longitude), 29.35, accuracy: 0.3, "大圆插值中点经度")
    expect(FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                        to: FootprintPoint(latitude: 30, longitude: 40),
                                        fraction: -1) == FootprintPoint(latitude: 10, longitude: 20),
           "插值比例夹到 0")
    expect(FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                        to: FootprintPoint(latitude: 30, longitude: 40),
                                        fraction: 2) == FootprintPoint(latitude: 30, longitude: 40),
           "插值比例夹到 1")

    var manySamples: [FootprintSample] = []
    for index in 0..<400 {
        let offset = Double(index) * 0.002
        manySamples.append(sample(Double(index) * 60, 30.0 + offset, 120.0 + offset))
    }
    let capped = FootprintPlanner.plan(samples: manySamples)
    expect(capped.stops.count <= FootprintPlanner.maxStops, "站点数收敛到上限")
    expectEqual(capped.stops.first?.point, manySamples.first?.point, "抽样保留首站")
    expect(capped.stops.last?.point.latitude ?? 0 > 30.7, "抽样保留尾站")

    let oneDegree = FootprintPlanner.overviewDistance(of: [
        FootprintPoint(latitude: 30, longitude: 120),
        FootprintPoint(latitude: 31, longitude: 121)
    ])
    expect(oneDegree > 150_000, "全览镜头覆盖整段范围")

    expect(FootprintPlanner.plan(samples: []).isEmpty, "没有样本时返回空计划")



    let veryShort = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300, "a", "起点"),
        sample(2_000, 30.26036, 120.1300, "b", "附近")
    ])
    expectEqual(veryShort.stops.count, 2, "约四十米且时间断开的照片保留为两站")
    expect(veryShort.legs.first?.duration ?? 0 >= 0.85, "极短行程也有最短可辨认时长")

    let cruisePlan = FootprintPlanner.plan(samples: [
        sample(0, 30.2600, 120.1300, "a", "第一站"),
        sample(600, 30.2620, 120.1300, "b", "第二站"),
        sample(660, 30.2620, 120.1300, "b", "第二站"),
        sample(1_500, 30.2640, 120.1300, "c", "第三站"),
        sample(1_560, 30.2640, 120.1300, "c", "第三站")
    ])
    let cruise = FootprintCruiseTimeline(plan: cruisePlan)
    let expectedDuration = cruisePlan.legs.reduce(0) { $0 + $1.duration + $1.dwell }
    expectClose(CGFloat(cruise.totalDuration), CGFloat(expectedDuration),
                accuracy: 0.0001, "总时长包含所有行进与旅拍停留")

    if let firstLeg = cruisePlan.legs.first {
        let middle = cruise.frame(at: firstLeg.duration * 0.5)
        expectClose(CGFloat(middle.legFraction), 0.5, accuracy: 0.0001,
                    "行进段中点使用未经缓动的线性比例")
        expectEqual(middle.head,
                    FootprintPlanner.interpolate(from: cruisePlan.stops[0].point,
                                                 to: cruisePlan.stops[1].point,
                                                 fraction: 0.5),
                    "光点与线性行程比例同步")

        let arrival = cruise.frame(at: firstLeg.duration)
        let dwelling = cruise.frame(at: firstLeg.duration + firstLeg.dwell * 0.5)
        expect(arrival.isDwelling, "抵达照片较多的站点后进入旅拍停留")
        expectEqual(dwelling.head, cruisePlan.stops[1].point, "停留期间光点保持不动")
        expectClose(CGFloat(dwelling.dwellFraction), 0.5, accuracy: 0.0001,
                    "停留进度也在统一时间轴中")

        let departure = cruise.frame(at: cruise.time(atStop: 1))
        expectEqual(arrival.cameraCenter, departure.cameraCenter, "跨段时镜头中心不跳变")
        expectClose(CGFloat(arrival.cameraDistance), CGFloat(departure.cameraDistance),
                    accuracy: 0.0001, "跨段时镜头高度连续")
        expectClose(CGFloat(arrival.pitch), CGFloat(departure.pitch),
                    accuracy: 0.0001, "跨段时俯仰角连续")
        expectClose(CGFloat(arrival.heading), CGFloat(departure.heading),
                    accuracy: 0.0001, "跨段时航向连续")
        expectEqual(arrival.head, departure.head, "跨段时光点位置连续")
        expect(!departure.isDwelling, "停留结束后直接进入下一段行进")
    }

    expectClose(CGFloat(cruise.time(atStop: 0)), 0, accuracy: 0.0001,
                "首站映射到时间轴起点")
    if let lastLeg = cruisePlan.legs.last {
        expectClose(CGFloat(cruise.time(atStop: cruisePlan.stops.count - 1)),
                    CGFloat(cruise.totalDuration - lastLeg.dwell),
                    accuracy: 0.0001, "末站映射到抵达时刻而非整个时间轴末尾")
        let finalDwell = cruise.frame(at: cruise.totalDuration - lastLeg.dwell * 0.5)
        expect(finalDwell.isDwelling, "末尾旅拍停留不会提前结束旅程")
    }
    let completed = cruise.frame(at: cruise.totalDuration)
    expect(completed.isComplete, "时间轴末尾返回完成状态")
    expectEqual(completed.head, cruisePlan.stops.last?.point, "完成时光点停在最后一站")

    let wrapPlan = FootprintPlanner.plan(samples: [
        sample(0, 30.0, 120.0, "a", "起点"),
        sample(600, 30.01, 119.999, "b", "西北"),
        sample(1_200, 30.02, 120.0, "c", "东北")
    ])
    let wrapCruise = FootprintCruiseTimeline(plan: wrapPlan)
    if wrapPlan.legs.count == 2 {
        let middle = wrapCruise.frame(at: wrapCruise.time(atStop: 1) + wrapPlan.legs[1].duration * 0.5)
        expect(middle.heading > 350 || middle.heading < 10, "跨段航向走最短圆弧，不从三百五十度反转半圈")
    }

    let emptyCruise = FootprintCruiseTimeline(plan: FootprintPlanner.plan(samples: []))
    expectEqual(emptyCruise.totalDuration, 0, "空计划时间轴为零时长")
    expect(emptyCruise.frame(at: 0).isComplete, "空计划直接完成")
    let singleCruise = FootprintCruiseTimeline(plan: merged)
    expectEqual(singleCruise.totalDuration, 0, "单站计划没有行进时长")
    expect(singleCruise.frame(at: 0).isComplete, "单站计划直接完成")
    expectEqual(singleCruise.frame(at: 0).head, merged.stops.first?.point, "单站光点固定在唯一站点")

}

//
//  AMapView.swift
//  高德地图 iOS SDK 封装（UIViewRepresentable）
//
//  用 MAMapTypeStandardNight（SDK 内置夜间视图）实现参考图那种深色 3D 底图，
//  不需要额外申请「自定义地图样式」。
//
//  只有设置里填了「iOS 平台 Key」才会用这个；没填就退回 Apple 地图。
//

import SwiftUI
import UIKit
import CoreLocation
import MAMapKit
import AMapFoundationKit

/// 高德地图视图
struct AMapView: UIViewRepresentable {

    /// 地图中心（车的位置）
    let center: CLLocationCoordinate2D?
    /// 相机朝向（度）
    let heading: Double
    /// 缩放级别（越大越近，参考图约 17）
    var zoomLevel: CGFloat = 17.2
    /// 3D 俯角（度，0 = 正俯视，45 = 斜视）
    var cameraDegree: CGFloat = 45
    /// 路线点
    var route: [CLLocationCoordinate2D] = []
    /// 目的地
    var destination: CLLocationCoordinate2D? = nil

    func makeCoordinator() -> Coord {
        Coord()
    }

    func makeUIView(context: Context) -> MAMapView {
        // apiKey 必须在创建 MAMapView 之前设好
        AMapView.configureIfNeeded()

        let map = MAMapView(frame: .zero)
        map.delegate = context.coordinator
        // 内置夜间视图：深色底图 + 3D 建筑
        map.mapType = .standardNight
        map.showsUserLocation = false     // 用我们自己的环形标记
        map.showsCompass = false
        map.showsScale = false
        map.isRotateEnabled = true
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        // 3D 视角
        map.cameraDegree = cameraDegree
        map.zoomLevel = zoomLevel
        if let c = center {
            map.setCenter(c, animated: false)
        }
        map.setRotationDegree(CGFloat(heading), animated: false, duration: 0)
        return map
    }

    func updateUIView(_ map: MAMapView, context: Context) {
        // 中心跟随
        if let c = center {
            map.centerCoordinate = c
            context.coordinator.updateCarMarker(on: map, at: c, heading: heading)
        }
        // 朝向跟随
        if abs(map.rotationDegree - CGFloat(heading)) > 2 {
            map.setRotationDegree(CGFloat(heading), animated: true, duration: 0.25)
        }
        // 俯角
        if abs(map.cameraDegree - cameraDegree) > 1 {
            map.cameraDegree = cameraDegree
        }
        // 路线
        context.coordinator.syncRoute(on: map, coords: route)
        // 目的地
        context.coordinator.syncDestination(on: map, coord: destination)
    }

    /// 设置 apiKey / 开启 HTTPS（幂等，可以重复调）
    static func configureIfNeeded() {
        let key = AmapKey.iosKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        AMapServices.shared().apiKey = key
        AMapServices.shared().enableHTTPS = true
    }

    // MARK: - Coordinator

    final class Coord: NSObject, MAMapViewDelegate {

        /// 车的位置标记
        private var carAnnotation: MAPointAnnotation?
        /// 已画的路线
        private var routePolyline: MAPolyline?
        /// 目的地标记
        private var destAnnotation: MAPointAnnotation?

        /// 更新车辆标记（白色环 + 蓝点）
        func updateCarMarker(on map: MAMapView,
                             at coord: CLLocationCoordinate2D,
                             heading: Double) {
            if let a = carAnnotation {
                a.coordinate = coord
                // 触发刷新
                map.removeAnnotation(a)
                map.addAnnotation(a)
            } else {
                let a = MAPointAnnotation()
                a.coordinate = coord
                a.title = "car"
                carAnnotation = a
                map.addAnnotation(a)
            }
        }

        /// 同步路线
        func syncRoute(on map: MAMapView, coords: [CLLocationCoordinate2D]) {
            // 先清掉旧的
            if let old = routePolyline {
                map.remove(old)
                routePolyline = nil
            }
            guard coords.count >= 2 else { return }
            var c = coords
            if let line = MAPolyline(coordinates: &c, count: UInt(c.count)) {
                routePolyline = line
                map.add(line)
            }
        }

        /// 同步目的地
        func syncDestination(on map: MAMapView, coord: CLLocationCoordinate2D?) {
            if let old = destAnnotation {
                map.removeAnnotation(old)
                destAnnotation = nil
            }
            guard let c = coord else { return }
            let a = MAPointAnnotation()
            a.coordinate = c
            a.title = "dest"
            destAnnotation = a
            map.addAnnotation(a)
        }

        // MARK: MAMapViewDelegate

        /// 自定义标注视图
        func mapView(_ mapView: MAMapView!, viewFor annotation: MAAnnotation!) -> MAAnnotationView! {
            guard let point = annotation as? MAPointAnnotation else { return nil }

            if point.title == "car" {
                let id = "car"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                if v == nil {
                    v = MAAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                v?.annotation = annotation
                v?.frame = CGRect(x: 0, y: 0, width: 46, height: 46)
                v?.centerOffset = CGPoint(x: 0, y: 0)
                v?.subviews.forEach { $0.removeFromSuperview() }
                if let v = v {
                    v.addSubview(AMapCarMarker())
                }
                return v
            }

            if point.title == "dest" {
                let id = "dest"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                if v == nil {
                    v = MAAnnotationView(annotation: annotation, reuseIdentifier: id)
                    v?.image = UIImage(systemName: "flag.checkered")
                    v?.canShowCallout = false
                }
                v?.annotation = annotation
                return v
            }
            return nil
        }

        /// 路线渲染
        func mapView(_ mapView: MAMapView!, rendererFor overlay: MAOverlay!) -> MAOverlayRenderer! {
            if let line = overlay as? MAPolyline {
                let r = MAPolylineRenderer(polyline: line)
                r?.lineWidth = 7
                r?.strokeColor = UIColor(red: 0.20, green: 0.90, blue: 0.35, alpha: 1.0)
                r?.lineCapType = kMALineCapRound
                r?.lineJoinType = kMALineJoinRound
                return r
            }
            return nil
        }
    }
}

/// 车辆标记：白色外环 + 蓝色实心点（参考图那种）
private final class AMapCarMarker: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: rect.midX, y: rect.midY)

        // 白色外环
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))

        // 内圈浅色光晕
        ctx.setFillColor(UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 0.22).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))

        // 蓝色实心点
        ctx.setFillColor(UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))

        // 蓝点白描边
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))
    }
}

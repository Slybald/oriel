import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Oriel

/// Diagnostic : empreinte mémoire et CPU de la vue de la notch (repliée, dépliée, après des cycles).
/// Ne fait rien sans `ORIEL_FOOTPRINT=1`. Chiffres imprimés, pas d'assertion : ils dépendent de la machine.
final class FootprintTests: XCTestCase {
    func testFootprint() throws {
        guard ProcessInfo.processInfo.environment["ORIEL_FOOTPRINT"] == "1" else {
            throw XCTSkip("ORIEL_FOOTPRINT non défini")
        }
        let notch = NotchHarness(self, store: .working(3))
        let model = notch.model
        let root = notch.root
        let start = Self.sample()
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: NotchController.panelSize)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let collapsed = Self.sample()

        model.isExpanded = true
        notch.registry.setPanelOpen(true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let expanded = Self.sample()

        // Ouvertures et fermetures, en passant par chaque onglet.
        let tabs = notch.registry.enabled.map { $0.id }
        for index in 0..<20 {
            model.isExpanded = false
            notch.registry.setPanelOpen(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            model.selectedTab = tabs[index % tabs.count]
            model.isExpanded = true
            notch.registry.setPanelOpen(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        model.isExpanded = false
        notch.registry.setPanelOpen(false)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let cycled = Self.sample()

        // CPU replié, oreilles animées (spinner) : 5 s.
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        let idle = Self.sample()
        window.close()

        func mb(_ bytes: UInt64) -> String { String(format: "%.1f Mo", Double(bytes) / 1_048_576) }
        print("FOOTPRINT départ        footprint \(mb(start.footprint)) rss \(mb(start.resident))")
        print("FOOTPRINT replié        footprint \(mb(collapsed.footprint)) rss \(mb(collapsed.resident))")
        print("FOOTPRINT déplié        footprint \(mb(expanded.footprint)) rss \(mb(expanded.resident))")
        print("FOOTPRINT 20 cycles     footprint \(mb(cycled.footprint)) rss \(mb(cycled.resident))")
        print(String(format: "FOOTPRINT CPU replié 5 s : %.1f %%", (idle.cpu - cycled.cpu) / 5 * 100))
    }

    struct Sample {
        var footprint: UInt64
        var resident: UInt64
        var cpu: Double
    }

    static func sample() -> Sample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return Sample(footprint: info.phys_footprint, resident: info.resident_size, cpu: cpu)
    }
}

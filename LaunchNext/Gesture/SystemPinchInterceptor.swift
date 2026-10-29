import ApplicationServices
import Foundation

// Intercepts the system "Apps" pinch (thumb + three fingers) before the Dock
// sees it and turns it into LaunchNext open/close actions.
// The Dock gesture arrives as an undocumented CGEvent (type 30) whose private
// fields describe a DockSwipe. Field numbers were observed on macOS 27 and may
// change in future releases; when they do, the tap simply stops matching.
final class SystemPinchInterceptor {
    struct Configuration: Equatable {
        var isEnabled: Bool = false
        var closeOnPinchOutEnabled: Bool = false
        // |progress| a pinch must reach before it fires. Dock pinches end around 0.4–1.0.
        var triggerProgress: Double = 0.2
    }

    private static let dockGestureEventType: UInt32 = 30
    private static let gestureTypeField = CGEventField(rawValue: 110)!
    private static let motionField = CGEventField(rawValue: 123)!
    private static let progressField = CGEventField(rawValue: 124)!
    private static let phaseField = CGEventField(rawValue: 132)!
    private static let dockSwipeGestureType: Int64 = 23
    private static let pinchMotion: Int64 = 3
    private static let beganPhase: Int64 = 1

    private let onTrigger: (GestureTriggerAction) -> Void
    private let isLaunchNextVisible: () -> Bool
    private var configuration = Configuration()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryWorkItem: DispatchWorkItem?
    private var didPromptForAccessibility = false
    private var hasFiredForCurrentPinch = false
    private var isPassingThroughCurrentPinch = false

    init(isLaunchNextVisible: @escaping () -> Bool, onTrigger: @escaping (GestureTriggerAction) -> Void) {
        self.isLaunchNextVisible = isLaunchNextVisible
        self.onTrigger = onTrigger
    }

    deinit {
        stop()
    }

    func update(configuration: Configuration) {
        self.configuration = configuration
        if configuration.isEnabled {
            start()
        } else {
            stop()
        }
    }

    func restart() {
        stop()
        start()
    }

    private func start() {
        guard configuration.isEnabled, eventTap == nil else { return }

        let mask = CGEventMask(1) << CGEventMask(Self.dockGestureEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SystemPinchInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Swallowing events needs Accessibility; ask once, then keep retrying
            // until the user grants it or turns the feature off.
            if !didPromptForAccessibility {
                didPromptForAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            scheduleRetry()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        hasFiredForCurrentPinch = false
        isPassingThroughCurrentPinch = false
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.retryWorkItem = nil
            self?.start()
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.dockGestureEventType,
              event.getIntegerValueField(Self.gestureTypeField) == Self.dockSwipeGestureType,
              event.getIntegerValueField(Self.motionField) == Self.pinchMotion else {
            return Unmanaged.passUnretained(event)
        }

        // Positive progress is pinch-in (open), negative is spread (close).
        let progress = event.getDoubleValueField(Self.progressField)

        if event.getIntegerValueField(Self.phaseField) == Self.beganPhase {
            hasFiredForCurrentPinch = false
            // A spread is only ours when it can close a visible LaunchNext;
            // otherwise the whole gesture goes to the Dock (e.g. Show Desktop).
            isPassingThroughCurrentPinch = progress < 0
                && !(configuration.closeOnPinchOutEnabled && isLaunchNextVisible())
        }
        if isPassingThroughCurrentPinch {
            return Unmanaged.passUnretained(event)
        }

        if !hasFiredForCurrentPinch {
            if progress >= configuration.triggerProgress {
                hasFiredForCurrentPinch = true
                onTrigger(.open)
            } else if progress <= -configuration.triggerProgress, configuration.closeOnPinchOutEnabled {
                hasFiredForCurrentPinch = true
                onTrigger(.close)
            }
        }

        // Drop every phase so the Dock never starts its own Apps transition.
        return nil
    }
}

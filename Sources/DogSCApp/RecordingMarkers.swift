import AppKit
import Carbon
import Combine
import CoreMedia
import RecorderCore

extension AppModel {
    var canAddRecordingMarker: Bool {
        phase == .recording && !isRecordingPaused && !isPauseTransitioning
            && recordingMarkerSourceTime() != nil
    }

    private func recordingMarkerSourceTime() -> TimeInterval? {
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if project.capture.source == .device {
            return deviceRecorder.recordedSourceTime(atHostTime: hostTime)
        }
        return recorder.recordedSourceTime(atHostTime: hostTime)
    }

    func addRecordingMarker() {
        guard phase == .recording, !isRecordingPaused, !isPauseTransitioning,
              let sourceTime = recordingMarkerSourceTime(), sourceTime.isFinite else { return }
        // Ignore key repeats/double clicks; this is a cue, not a frame sampler.
        if let previous = project.recordingMarkers.last, sourceTime - previous.sourceTime < 0.3 { return }
        let number = (project.recordingMarkers.map(\.number).max() ?? 0) + 1
        project.recordingMarkers.append(RecordingMarker(sourceTime: sourceTime, number: number))
    }
}

/// A registered shortcut works in other applications without an event tap or
/// extra privacy permission. Its lifetime is limited to an active recording.
@MainActor
final class RecordingMarkerHotKey {
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private static let signature: OSType = 0x44474D4B // DGMK

    init(model: AppModel) {
        self.model = model
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x44474D4B, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<RecordingMarkerHotKey>.fromOpaque(context).takeUnretainedValue().model?.addRecordingMarker()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }
        observation = model.$phase.removeDuplicates().sink { [weak self] phase in
            self?.setRegistered(phase == .recording)
        }
    }

    private func setRegistered(_ registered: Bool) {
        if !registered {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            model?.recordingMarkerShortcutAvailable = false
        } else if hotKey == nil {
            let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey),
                EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
            model?.recordingMarkerShortcutAvailable = status == noErr
        }
    }

    func invalidate() {
        observation = nil
        setRegistered(false)
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

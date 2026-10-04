import Foundation

/// Scalar transport evidence carried with the same compressed access unit.
/// All timestamps use CLOCK_UPTIME_RAW; zero means unavailable. The decisive
/// packet timestamp is userspace receive processing, not kernel or wire arrival.
public struct TransportFrameTiming: Sendable {
    public let lastRequiredPacketNanoseconds: UInt64
    public let fecReadyNanoseconds: UInt64
    public let queueOfferNanoseconds: UInt64
    public let handoffNanoseconds: UInt64
    public let payloadBytes: UInt64
    public let partialFrame: Bool

    public init(lastRequiredPacketNanoseconds: UInt64, fecReadyNanoseconds: UInt64,
                queueOfferNanoseconds: UInt64, handoffNanoseconds: UInt64,
                payloadBytes: UInt64, partialFrame: Bool) {
        self.lastRequiredPacketNanoseconds = lastRequiredPacketNanoseconds
        self.fecReadyNanoseconds = fecReadyNanoseconds
        self.queueOfferNanoseconds = queueOfferNanoseconds
        self.handoffNanoseconds = handoffNanoseconds
        self.payloadBytes = payloadBytes; self.partialFrame = partialFrame
    }
}

/// Additive diagnostics only. No buffers or packet contents survive admission.
public struct TransportStageTiming: Codable, Sendable {
    public let payloadBytes: UInt64?
    public let partialFrame: Bool
    public let firstPacketNanoseconds: UInt64?
    public let lastRequiredPacketNanoseconds: UInt64?
    public let fecReadyNanoseconds: UInt64?
    public let enqueueNanoseconds: UInt64?
    public let queueOfferNanoseconds: UInt64?
    public let handoffNanoseconds: UInt64?
    public let admissionNanoseconds: UInt64?
    public let firstPacketToLastRequiredPacketMilliseconds: Double?
    public let lastRequiredPacketToFECReadyMilliseconds: Double?
    public let fecReadyToEnqueueMilliseconds: Double?
    public let enqueueToQueueOfferMilliseconds: Double?
    public let queueOfferToHandoffMilliseconds: Double?
    public let handoffToAdmissionMilliseconds: Double?
    public let firstPacketToAdmissionMilliseconds: Double?

    init(_ timing: TransportFrameTiming, firstPacket: UInt64, enqueue: UInt64, admission: UInt64) {
        payloadBytes = timing.payloadBytes > 0 ? timing.payloadBytes : nil
        partialFrame = timing.partialFrame
        // Reject clocks outside this access unit's known transport/admission span.
        let validSpan = firstPacket > 0 && admission >= firstPacket
        func bounded(_ value: UInt64) -> UInt64? {
            validSpan && value >= firstPacket && value <= admission ? value : nil
        }
        firstPacketNanoseconds = validSpan ? firstPacket : nil
        admissionNanoseconds = validSpan ? admission : nil
        lastRequiredPacketNanoseconds = timing.partialFrame ? nil : bounded(timing.lastRequiredPacketNanoseconds)
        fecReadyNanoseconds = bounded(timing.fecReadyNanoseconds)
        enqueueNanoseconds = bounded(enqueue)
        queueOfferNanoseconds = bounded(timing.queueOfferNanoseconds)
        handoffNanoseconds = bounded(timing.handoffNanoseconds)
        func interval(_ start: UInt64?, _ end: UInt64?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return Double(end - start) / 1_000_000
        }
        firstPacketToLastRequiredPacketMilliseconds = interval(firstPacketNanoseconds, lastRequiredPacketNanoseconds)
        lastRequiredPacketToFECReadyMilliseconds = interval(lastRequiredPacketNanoseconds, fecReadyNanoseconds)
        fecReadyToEnqueueMilliseconds = interval(fecReadyNanoseconds, enqueueNanoseconds)
        enqueueToQueueOfferMilliseconds = interval(enqueueNanoseconds, queueOfferNanoseconds)
        queueOfferToHandoffMilliseconds = interval(queueOfferNanoseconds, handoffNanoseconds)
        handoffToAdmissionMilliseconds = interval(handoffNanoseconds, admissionNanoseconds)
        firstPacketToAdmissionMilliseconds = interval(firstPacketNanoseconds, admissionNanoseconds)
    }
}

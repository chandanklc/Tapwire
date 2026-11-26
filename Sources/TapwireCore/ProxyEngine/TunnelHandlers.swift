import Foundation
import NIOCore

/// Forwards raw bytes between two channels on the same event loop (tunnels, WebSockets).
final class GlueHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private(set) var bytesRead = 0
    var onClose: ((Int) -> Void)?
    /// Sees every buffer read from this side before it is forwarded (WebSocket message capture).
    var onRead: ((ByteBuffer) -> Void)?

    static func pair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler()
        let b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerClose() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        bytesRead += buf.readableBytes
        onRead?(buf)
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose?(bytesRead)
        onClose = nil
        partner?.partnerClose()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelShouldQuiesceEvent {
            context.close(promise: nil)
            return
        }
        if let e = event as? ChannelEvent, e == .inputClosed {
            partner?.partnerClose()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Looks at the first byte after a CONNECT to tell TLS from plain HTTP, then installs the
/// right handlers and replays the bytes.
final class ProtocolSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let install: (Bool, ChannelHandlerContext) throws -> Void
    private var done = false

    init(install: @escaping (_ isTLS: Bool, ChannelHandlerContext) throws -> Void) {
        self.install = install
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        guard !done else { context.fireChannelRead(data); return }
        guard let first = buf.getInteger(at: buf.readerIndex, as: UInt8.self) else { return }
        done = true
        do {
            try install(first == 0x16, context)
            context.fireChannelRead(data)
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelShouldQuiesceEvent { context.close(promise: nil); return }
        context.fireUserInboundEventTriggered(event)
    }
}

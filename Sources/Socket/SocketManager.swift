//
//  SocketManager.swift
//  
//
//  Created by Alsey Coleman Miller on 4/1/22.
//

import Foundation
import SystemPackage

/// Socket Manager
internal actor SocketManager {
    
    static let shared = SocketManager()
    
    private var sockets = [SocketDescriptor: SocketState]()
    
    private var pollDescriptors = [SocketDescriptor.Poll]()
    
    private var isMonitoring = false
        
    private init() { }
    
    private func startMonitoring() {
        guard isMonitoring == false else { return }
        log("Will start monitoring")
        isMonitoring = true
        // Add to runloop of background thread from concurrency thread pool
        Task(priority: Socket.configuration.monitorPriority) { [weak self] in
            while let self = self, isMonitoring {
                do {
                    try await Task.sleep(nanoseconds: Socket.configuration.monitorInterval)
                    try await self.poll()
                    // stop monitoring if no sockets
                    if pollDescriptors.isEmpty {
                        isMonitoring = false
                    }
                }
                catch {
                    log("Socket monitoring failed. \(error.localizedDescription)")
                    assertionFailure("Socket monitoring failed. \(error.localizedDescription)")
                    isMonitoring = false
                }
            }
        }
    }
    
    func contains(_ fileDescriptor: SocketDescriptor) -> Bool {
        return sockets.keys.contains(fileDescriptor)
    }
    
    func add(
        _ fileDescriptor: SocketDescriptor
    ) -> Socket.Event.Stream {
        guard sockets.keys.contains(fileDescriptor) == false else {
            fatalError("Another socket for file descriptor \(fileDescriptor) already exists.")
        }
        log("Add socket \(fileDescriptor).")
        
        // make sure its non blocking
        do {
            var status = try fileDescriptor.getStatus()
            if status.contains(.nonBlocking) == false {
                status.insert(.nonBlocking)
                try fileDescriptor.setStatus(status)
            }
        }
        catch {
            log("Unable to set non blocking. \(error)")
            assertionFailure("Unable to set non blocking. \(error)")
        }
        
        // append socket
        let event = Socket.Event.Stream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.sockets[fileDescriptor] = SocketState(
                fileDescriptor: fileDescriptor,
                event: continuation
            )
        }
        // start monitoring
        updatePollDescriptors()
        startMonitoring()
        return event
    }
    
    func remove(_ fileDescriptor: SocketDescriptor, error: Error? = nil) async {
        guard let socket = sockets[fileDescriptor] else {
            return // could have been removed by `poll()`
        }
        log("Remove socket \(fileDescriptor) \(error?.localizedDescription ?? "")")
        // update sockets to monitor
        sockets[fileDescriptor] = nil
        updatePollDescriptors()
        // close underlying socket
        try? fileDescriptor.close()
        // cancel all pending actions
        await socket.dequeueAll(error ?? Errno.connectionAbort)
        // notify
        socket.event.yield(.close(error))
        socket.event.finish()
    }
    
    @discardableResult
    internal nonisolated func write(_ data: Data, for fileDescriptor: SocketDescriptor) async throws -> Int {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to write unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        try await wait(for: .write, fileDescriptor: fileDescriptor)
        return try await socket.write(data)
    }
    
    @discardableResult
    internal nonisolated func sendMessage(_ data: Data, for fileDescriptor: SocketDescriptor) async throws -> Int {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to send message to unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        try await wait(for: .write, fileDescriptor: fileDescriptor)
        return try await socket.sendMessage(data)
    }
    
    @discardableResult
    internal nonisolated func sendMessage<Address: SocketAddress>(_ data: Data, to address: Address,  for fileDescriptor: SocketDescriptor) async throws -> Int {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to send message to unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        try await wait(for: .write, fileDescriptor: fileDescriptor)
        return try await socket.sendMessage(data, to: address)
    }
    
    internal nonisolated func read(_ length: Int, for fileDescriptor: SocketDescriptor) async throws -> Data {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to read unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        try await wait(for: .read, fileDescriptor: fileDescriptor)
        return try await socket.read(length)
    }
    
    internal nonisolated func receiveMessage(_ length: Int, for fileDescriptor: SocketDescriptor) async throws -> Data {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to receive message from unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        try await wait(for: .read, fileDescriptor: fileDescriptor)
        return try await socket.receiveMessage(length)
    }
    
    internal nonisolated func receiveMessage<Address: SocketAddress>(_ length: Int, fromAddressOf addressType: Address.Type = Address.self, for fileDescriptor: SocketDescriptor) async throws -> (Data, Address) {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to receive message from unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // attempt to execute immediately
        try await wait(for: .read, fileDescriptor: fileDescriptor)
        return try await socket.receiveMessage(length, fromAddressOf: addressType)
    }
    
    private func events(for fileDescriptor: SocketDescriptor) throws -> FileEvents {
        guard let poll = pollDescriptors.first(where: { $0.socket == fileDescriptor }) else {
            throw Errno.connectionAbort
        }
        return poll.returnedEvents
    }
    
    private nonisolated func wait(for event: FileEvents, fileDescriptor: SocketDescriptor) async throws {
        guard let socket = await sockets[fileDescriptor] else {
            log("Unable to wait for unknown socket \(fileDescriptor).")
            throw Errno.invalidArgument
        }
        // poll immediately and try to read / write
        try await poll()
        // wait until event is polled (with continuation)
        while try await events(for: fileDescriptor).contains(event) == false {
            try Task.checkCancellation()
            guard await contains(fileDescriptor) else {
                throw Errno.connectionAbort
            }
            try await withThrowingContinuation(for: fileDescriptor) { (continuation: SocketContinuation<(), Error>) in
                Task { [weak socket] in
                    guard let socket = socket else {
                        continuation.resume(throwing: Errno.connectionAbort)
                        return
                    }
                    await socket.queue(event: event, continuation)
                }
            }
            try await poll()
        }
    }
    
    private func updatePollDescriptors() {
        pollDescriptors = sockets.keys
            .lazy
            .sorted(by: { $0.rawValue < $1.rawValue })
            .map { SocketDescriptor.Poll(socket: $0, events: .socketManager) }
    }
    
    private func poll() async throws {
        pollDescriptors.reset()
        do {
            try pollDescriptors.poll()
        }
        catch {
            log("Unable to poll for events. \(error.localizedDescription)")
            throw error
        }
        
        // wait for concurrent handling
        for poll in pollDescriptors {
            if poll.returnedEvents.contains(.write) {
                await self.canWrite(poll.socket)
            }
            if poll.returnedEvents.contains(.read) {
                await self.shouldRead(poll.socket)
            }
            if poll.returnedEvents.contains(.invalidRequest) {
                assertionFailure("Polled for invalid socket \(poll.socket)")
                await self.error(.badFileDescriptor, for: poll.socket)
            }
            if poll.returnedEvents.contains(.hangup) {
                await self.error(.connectionReset, for: poll.socket)
            }
            if poll.returnedEvents.contains(.error) {
                await self.error(.connectionAbort, for: poll.socket)
            }
        }
    }
    
    private func error(_ error: Errno, for fileDescriptor: SocketDescriptor) async {
        await self.remove(fileDescriptor, error: error)
    }
    
    private func shouldRead(_ fileDescriptor: SocketDescriptor) async {
        guard let socket = self.sockets[fileDescriptor] else {
            log("Pending read for unknown socket \(fileDescriptor).")
            return
        }
        // stop waiting
        await socket.dequeue(event: .read)?.resume()
        // notify
        socket.event.yield(.pendingRead)
    }
    
    private func canWrite(_ fileDescriptor: SocketDescriptor) async {
        guard let socket = self.sockets[fileDescriptor] else {
            log("Can write for unknown socket \(fileDescriptor).")
            return
        }
        // stop waiting
        await socket.dequeue(event: .write)?.resume()
    }
}

// MARK: - Supporting Types

extension SocketManager {
    
    actor SocketState {
        
        let fileDescriptor: SocketDescriptor
        
        let event: Socket.Event.Stream.Continuation
        
        private var pendingEvent = [FileEvents: [SocketContinuation<(), Error>]]()
        
        init(fileDescriptor: SocketDescriptor,
             event: Socket.Event.Stream.Continuation
        ) {
            self.fileDescriptor = fileDescriptor
            self.event = event
        }
        
        func dequeueAll(_ error: Error) {
            // cancel all continuations
            for event in pendingEvent.keys {
                dequeue(event: event)?.resume(throwing: error)
            }
        }
        
        func queue(event: FileEvents, _ continuation: SocketContinuation<(), Error>) {
            pendingEvent[event, default: []].append(continuation)
        }
        
        func dequeue(event: FileEvents) -> SocketContinuation<(), Error>? {
            guard pendingEvent[event, default: []].isEmpty == false else {
                return nil
            }
            return pendingEvent[event, default: []].removeFirst()
        }
    }
}

extension SocketManager.SocketState {
    
    func write(_ data: Data) throws -> Int {
        log("Will write \(data.count) bytes to \(fileDescriptor)")
        let byteCount = try data.withUnsafeBytes {
            try fileDescriptor.write($0)
        }
        // notify
        event.yield(.write(byteCount))
        return byteCount
    }
    
    func sendMessage(_ data: Data) throws -> Int {
        log("Will send message with \(data.count) bytes to \(fileDescriptor)")
        let byteCount = try data.withUnsafeBytes {
            try fileDescriptor.send($0)
        }
        // notify
        event.yield(.write(byteCount))
        return byteCount
    }
    
    func sendMessage<Address: SocketAddress>(_ data: Data, to address: Address) throws -> Int {
        log("Will send message with \(data.count) bytes to \(fileDescriptor)")
        let byteCount = try data.withUnsafeBytes {
            try fileDescriptor.send($0, to: address)
        }
        // notify
        event.yield(.write(byteCount))
        return byteCount
    }
    
    func read(_ length: Int) throws -> Data {
        log("Will read \(length) bytes from \(fileDescriptor)")
        var data = Data(count: length)
        let bytesRead = try data.withUnsafeMutableBytes {
            try fileDescriptor.read(into: $0)
        }
        if bytesRead < length {
            data = data.prefix(bytesRead)
        }
        // notify
        event.yield(.read(bytesRead))
        return data
    }
    
    func receiveMessage(_ length: Int) throws -> Data {
        log("Will receive message with \(length) bytes from \(fileDescriptor)")
        var data = Data(count: length)
        let bytesRead = try data.withUnsafeMutableBytes {
            try fileDescriptor.receive(into: $0)
        }
        if bytesRead < length {
            data = data.prefix(bytesRead)
        }
        // notify
        event.yield(.read(bytesRead))
        return data
    }
    
    func receiveMessage<Address: SocketAddress>(_ length: Int, fromAddressOf addressType: Address.Type = Address.self) throws -> (Data, Address) {
        log("Will receive message with \(length) bytes from \(fileDescriptor)")
        var data = Data(count: length)
        let (bytesRead, address) = try data.withUnsafeMutableBytes {
            try fileDescriptor.receive(into: $0, fromAddressOf: addressType)
        }
        if bytesRead < length {
            data = data.prefix(bytesRead)
        }
        // notify
        event.yield(.read(bytesRead))
        return (data, address)
    }
}

private extension FileEvents {
    
    static var socketManager: FileEvents {
        [
            .read,
            .write,
            .error,
            .hangup,
            .invalidRequest
        ]
    }
}

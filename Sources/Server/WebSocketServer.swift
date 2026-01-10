//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WebSocketServer.swift
//  Starscream
//
//  Created by Dalton Cherry on 4/5/19.
//  Copyright © 2019 Vluxe. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

#if canImport(Network)
import Foundation
import Network
import CryptoKit

/// WebSocketServer is a Network.framework implementation of a WebSocket server
@available(watchOS, unavailable)
@available(macOS 10.14, iOS 13.0, watchOS 5.0, tvOS 12.0, *)
public class WebSocketServer: Server, ConnectionDelegate {
    public var onEvent: ((ServerEvent) -> Void)?
    private var connections = [String: ServerConnection]()
    private var listener: NWListener?
    public var indexData: Data?
    public var notFoundData: Data?
    private let queue = DispatchQueue(label: "com.vluxe.starscream.server.networkstream", attributes: [])
    
    public init() {
        
    }
    
    public func start(address: String, port: UInt16) -> Error? {
        //TODO: support TLS cert adding/binding
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let p = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host.name(address, nil), port: p)
        
        guard let listener = try? NWListener(using: parameters, on: p) else {
            return WSError(type: .serverError, message: "unable to start the listener at: \(address):\(port)", code: 0)
        }
        listener.newConnectionHandler = {[weak self] conn in
            let transport = TCPTransport(connection: conn)
            let c = ServerConnection(transport: transport)
            c.delegate = self
            guard let self = self else { return }
            self.queue.async {
                self.connections[c.uuid] = c
            }
        }
//        listener.stateUpdateHandler = { state in
//            switch state {
//            case .ready:
//                print("ready to get sockets!")
//            case .setup:
//                print("setup to get sockets!")
//            case .cancelled:
//                print("server cancelled!")
//            case .waiting(let error):
//                print("waiting error: \(error)")
//            case .failed(let error):
//                print("server failed: \(error)")
//            @unknown default:
//                print("wat?")
//            }
//        }
        self.listener = listener
        listener.start(queue: queue)
        return nil
    }
    
    public func didReceive(event: ServerEvent) {
        onEvent?(event)
        switch event {
        case .disconnected(let conn, _, _):
            guard let conn = conn as? ServerConnection else {
                return
            }
            queue.async {
                self.connections.removeValue(forKey: conn.uuid)
            }
        default:
            break
        }
    }
    
    public func connection(_ connection: any Connection, didReceive request: URLRequest) {
        onEvent?(.http(connection, request))
    }
}

@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public class ServerConnection: Connection, HTTPServerDelegate, FramerEventClient, FrameCollectorDelegate, TransportEventClient {
    let transport: TCPTransport
    private let httpHandler = FoundationHTTPServerHandler()
    private let framer = WSFramer(isServer: true)
    private let frameHandler = FrameCollector()
    private var didUpgrade = false
    public var onEvent: ((ConnectionEvent) -> Void)?
    public weak var delegate: ConnectionDelegate?
    private let id: String
    var uuid: String {
        return id
    }
    
    init(transport: TCPTransport) {
        self.id = UUID().uuidString
        self.transport = transport
        transport.register(delegate: self)
        httpHandler.register(delegate: self)
        framer.register(delegate: self)
        frameHandler.delegate = self
    }
    
    public func write(data: Data, opcode: FrameOpCode) {
        let wsData = framer.createWriteFrame(opcode: opcode, payload: data, isCompressed: false)
        transport.write(data: wsData, completion: {_ in })
    }
    
    public func write(data: Data, completion: @escaping ((Error?) -> Void)) {
        transport.write(data: data, completion: completion)
    }
    
    // MARK: - TransportEventClient
    
    public func connectionChanged(state: ConnectionState) {
        switch state {
        case .connected:
            break
        case .waiting:
            break
        case .failed(let error):
            print("server connection error: \(error ?? WSError(type: .protocolError, message: "default error, no extra data", code: 0))") //handleError(error)
        case .viability(_):
            break
        case .shouldReconnect(_):
            break
        case .receive(let data):
            if didUpgrade {
                framer.add(data: data)
            } else {
                httpHandler.parse(data: data)
            }
        case .cancelled:
            print("server connection cancelled!")
            //broadcast(event: .cancelled)
        case .peerClosed:
            delegate?.didReceive(event: .disconnected(self, "Connection closed by peer", UInt16(FrameOpCode.connectionClose.rawValue)))
        }
    }
    
    /// MARK: - HTTPServerDelegate
    
    public func didReceive(event: HTTPEvent) {
        switch event {
        case .success(let request):
            let headers = request.allHTTPHeaderFields ?? [:]
            if let upgrade = headers["Upgrade"], upgrade.lowercased() == "websocket",
               let key = headers["Sec-WebSocket-Key"] {
                didUpgrade = true
                let accept = calculateWebSocketAcceptKey(from: key)
                var responseHeader: [String:String] = [
                    "Upgrade":"websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Accept": accept,
                    "Sec-WebSocket-Version": "13",
                    "Date": getCurrentGMTTimeString(),
                ]
                
                if let proto = headers["Sec-WebSocket-Protocol"] {
                    responseHeader["Sec-WebSocket-Protocol"] = proto
                }
                
                let response = httpHandler.createResponse(headers: responseHeader)
                transport.write(data: response, completion: {_ in })
                delegate?.didReceive(event: .connected(self, headers))
            } else {
                didUpgrade = false
                delegate?.connection(self, didReceive: request)
            }
            
            onEvent?(.connected(headers))
        case .failure(let error):
            onEvent?(.error(error))
        }
    }
    
    /// 从 Sec-WebSocket-Key 计算 Sec-WebSocket-Accept
    /// - Parameter webSocketKey: 客户端传入的 Sec-WebSocket-Key 字符串
    /// - Returns: 计算后的 Sec-WebSocket-Accept 字符串（失败返回 nil）
    func calculateWebSocketAcceptKey(from webSocketKey: String) -> String {
        // 1. 定义固定魔术字符串
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        
        // 2. 拼接 Sec-WebSocket-Key 和魔术字符串
        let combinedString = webSocketKey + magicString
        
        // 3. 转换为 UTF-8 编码的 Data（转换失败则返回 nil）
        guard let combinedData = combinedString.data(using: .utf8) else {
            print("错误：字符串无法转换为 UTF-8 编码 Data")
            return ""
        }
        
        // 4. 计算 SHA-1 哈希（CryptoKit 实现，得到 20 字节二进制摘要）
        let sha1Digest = Insecure.SHA1.hash(data: combinedData)
        
        // 5. 将 SHA-1 摘要转换为 Data（CryptoKit 哈希结果需手动封装为 Data）
        let sha1Data = Data(sha1Digest)
        
        // 6. 对 SHA-1 Data 进行 Base64 编码，得到最终结果
        let acceptKey = sha1Data.base64EncodedString()
        
        return acceptKey
    }
    
    func getCurrentGMTTimeString() -> String {
        // 1. 获取当前系统时间（UTC 时间，与 GMT 本质一致，无时区偏差）
        let currentDate = Date()
        
        // 2. 配置日期格式化器，确保符合 RFC 1123 标准
        let gmtDateFormatter = DateFormatter()
        
        // 关键配置1：固定区域为 en_US_POSIX，避免本地化（如中文、其他语言）导致格式错乱
        gmtDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // 关键配置2：强制设置时区为 GMT，不使用系统默认时区
        gmtDateFormatter.timeZone = TimeZone(identifier: "GMT")
        
        // 关键配置3：严格匹配 RFC 1123 格式（HTTP Date 头标准格式）
        // EEE=星期3字母 | dd=日期2位 | MMM=月份3字母 | yyyy=4位年份 | HH:mm:ss=24小时制时分秒 | GMT=固定后缀
        gmtDateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss GMT"
        
        // 3. 格式化并返回字符串
        return gmtDateFormatter.string(from: currentDate)
    }
    
    /// MARK: - FrameCollectorDelegate
    
    public func frameProcessed(event: FrameEvent) {
        switch event {
        case .frame(let frame):
            frameHandler.add(frame: frame)
        case .error(let error):
            onEvent?(.error(error))
        }
    }
    
    public func didForm(event: FrameCollector.Event) {
        switch event {
        case .text(let string):
            delegate?.didReceive(event: .text(self, string))
            onEvent?(.text(string))
        case .binary(let data):
            delegate?.didReceive(event: .binary(self, data))
            onEvent?(.binary(data))
        case .pong(let data):
            delegate?.didReceive(event: .pong(self, data))
            onEvent?(.pong(data))
        case .ping(let data):
            delegate?.didReceive(event: .ping(self, data))
            onEvent?(.ping(data))
        case .closed(let reason, let code):
            delegate?.didReceive(event: .disconnected(self, reason, code))
            onEvent?(.disconnected(reason, code))
        case .error(let error):
            onEvent?(.error(error))
        }
    }
    
    public func decompress(data: Data, isFinal: Bool) -> Data? {
        return nil
    }
}
#endif

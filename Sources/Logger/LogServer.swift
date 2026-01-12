//
//  LogServer.swift
//  log
//
//  日志服务器：提供 HTTP 服务和 WebSocket 服务
//

import Foundation
import Network
import Darwin

import CocoaLumberjack

@available(iOS 12.0, *)
class LogServer: NSObject {
    private var webSocketServer: WebSocketServer?
    private let wsPort: UInt16 = 8080
    private let logger = WebSocketLogger()
    
    var serverIP: String {
        return getLocalIPAddress() ?? "localhost"
    }
    
    override init() {
        super.init()
        start()
        DDLog.add(logger, with: .all)
    }
    
    func start() {
        startWebSocketServer()
        print("Log server started")
        print("http://\(serverIP):\(wsPort)")
    }
    
    func stop() {
        webSocketServer = nil
    }
    
    private func startWebSocketServer() {
        webSocketServer = WebSocketServer()
        webSocketServer?.indexData = htmlResponseData()
        webSocketServer?.notFoundData = notFoundReponseData()
        webSocketServer?.onEvent = { [weak self] event in
            self?.handleWebSocketEvent(event)
        }
        
        if let error = webSocketServer?.start(address: "localhost", port: wsPort) {
            print("Failed to start WebSocket server: \(error)")
        }
    }
    
    private func handleWebSocketEvent(_ event: ServerEvent) {
        switch event {
        case .connected(let conn, _):
            logger.addConnection(conn)
        case .disconnected(let conn, _, _):
            logger.removeConnection(conn)
        case .text(_, _): break
        case .binary(_, _): break
        case .pong(_, _): break
        case .ping(_, _): break
        case .http(let conn, let request):
            if request.url?.absoluteString == "/" {
                conn.write(data: htmlResponseData(), completion: { _ in })
            } else {
                conn.write(data: notFoundReponseData(), completion: { _ in })
            }
        }
    }
    
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if address != "127.0.0.1" {
                        break
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address ?? "127.0.0.1"
    }
    
    private func htmlResponseData() -> Data {
        guard let htmlPath = currentBundle().path(forResource: "LogViewer", ofType: "html"),
              var htmlContent = try? String(contentsOfFile: htmlPath) else {
            return notFoundReponseData()
        }
        
        // 替换 WebSocket URL 占位符
        htmlContent = htmlContent.replacingOccurrences(of: "{{WS_URL}}", with: "ws://\(serverIP):\(wsPort)")
        
        let httpResponse = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(htmlContent.utf8.count)\r
        Connection: close\r
        \r
        \(htmlContent)
        """
        
        return httpResponse.data(using: .utf8)!
    }
    
    private func notFoundReponseData() -> Data {
        let httpResponse = """
        HTTP/1.1 404 Not Found\r
        Content-Type: text/plain\r
        Content-Length: 13\r
        Connection: close\r
        \r
        404 Not Found
        """
        
        return httpResponse.data(using: .utf8)!
    }
    
    private func currentBundle() -> Bundle {
        let bundle = Bundle(for: self.classForCoder)
        
        guard let path = bundle.path(forResource: "StarscreamLogger_Privacy", ofType: "bundle"), let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        
        return bundle
    }
}

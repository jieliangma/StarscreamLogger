//
//  WebSocketLogger.swift
//  log
//
//  自定义 DDLogger：将日志发送到 WebSocket 客户端
//

import Foundation
import CocoaLumberjack

#if canImport(Network)

@available(iOS 12.0, *)
class WebSocketLogger: DDAbstractLogger {    
    private var webSocketConnections: [Connection] = []
    private let queue = DispatchQueue(label: "com.log.websocketlogger")
    
    override init() {
        super.init()
    }
    
    override func log(message logMessage: DDLogMessage) {
        // 在 logger queue 中处理日志
        queue.async { [weak self] in
            self?.processLogMessage(logMessage)
        }
    }
    
    private func processLogMessage(_ logMessage: DDLogMessage) {
        var tag = logMessage.tag as? String ?? ""
        let tagHasWraped = tag.hasPrefix("[") && tag.hasSuffix("]") || tag.hasPrefix("【") && tag.hasSuffix("】")
        if !tag.isEmpty && !tagHasWraped {
            tag = "[" + tag + "]"
        }
        
        // 格式化日志消息
        let logDict: [String: Any] = [
            "level": logMessage.flag.rawValue,
            "levelName": levelName(for: logMessage.flag),
            "message": tag + " " + logMessage.message,
            "timestamp": logMessage.timestamp.timeIntervalSince1970,
            "timeString": formatTimestamp(logMessage.timestamp),
            "file": (logMessage.file as NSString).lastPathComponent,
            "function": logMessage.function ?? "",
            "line": logMessage.line
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: logDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        // 广播到所有连接的客户端
        broadcast(jsonString)
    }
    
    func addConnection(_ connection: Connection) {
        queue.async { [weak self] in
            self?.webSocketConnections.append(connection)
        }
    }
    
    func removeConnection(_ connection: Connection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // 通过对象标识符比较来移除连接
            // 由于 ServerConnection 是类，我们可以使用对象比较
            self.webSocketConnections.removeAll { conn in
                (conn as AnyObject) === (connection as AnyObject)
            }
        }
    }
    
    func broadcast(_ message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let messageData = message.data(using: .utf8) ?? Data()
            
            // 发送消息到所有连接
            for connection in self.webSocketConnections {
                connection.write(data: messageData, opcode: .textFrame)
            }
        }
    }
    
    private func levelName(for flag: DDLogFlag) -> String {
        switch flag {
        case DDLogFlag.error: return "error"
        case DDLogFlag.warning: return "warn"
        case DDLogFlag.info: return "info"
        case DDLogFlag.debug: return "debug"
        case DDLogFlag.verbose: return "verbose"
        default: return "unknown"
        }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    
    override var loggerName: DDLoggerName {
        get { return .file }
    }
}

#endif

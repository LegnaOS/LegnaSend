import Cocoa
import FlutterMacOS

public class OpenFilePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "open_file", binaryMessenger: registrar.messenger)
        let instance = OpenFilePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "open_file":
            let arguments = call.arguments as? [String: Any]
            let filePath = arguments!["file_path"] as? String
            if filePath == nil {
                self.result(result: result, message: "the file path cannot be null", type: -4)
                return
            }
            let fileExist = FileManager.default.fileExists(atPath: filePath!)
            if fileExist {
                let documentURL = URL(fileURLWithPath: filePath!)
                let fileType = documentURL.pathExtension
                if !self.canOpen(filePath: filePath!) {
                    self.openSelectPanel(filePath: filePath!, fileType: fileType, result: result)
                } else {
                    self.open(documentURL: documentURL, result: result)
                }
            } else {
                self.result(result: result, message: "the file does not exist", type: -2)
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func canOpen(filePath: String) ->Bool {
        return FileManager.default.isReadableFile(atPath: filePath)
    }
    
    private func convertDictionaryToString(dict: [String: Any])->String {
        var result = ""
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: JSONSerialization.WritingOptions(rawValue: 0))
            
            if let JSONString = String(data: jsonData, encoding: String.Encoding.utf8) {
                result = JSONString
            }
            
        } catch {
            result = ""
        }
        return result
    }
    
    private func openSelectPanel(filePath: String, fileType: String, result: @escaping FlutterResult) {
        let fileUrl = URL(fileURLWithPath: filePath)
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.allowedFileTypes = [fileType]
        openPanel.directoryURL = fileUrl
        openPanel.showsHiddenFiles = true
        openPanel.allowsOtherFileTypes = false
        let currentLanguage = Locale.current.languageCode
        openPanel.prompt = (currentLanguage == "zh") ?"允许" : "Accept"
        openPanel.beginSheetModal(for: NSApplication.shared.mainWindow!) { openResult in
            if openResult.rawValue == NSApplication.ModalResponse.OK.rawValue {
                let selectedURL = openPanel.url!
                var isReadable = false
                if FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: nil) && FileManager.default.isReadableFile(atPath: selectedURL.path) {
                    isReadable = true
                }
                if isReadable {
                    self.open(documentURL: fileUrl, result: result)
                } else {
                    self.result(result: result, message: "Operation not permitted", type: -3)
                }
            } else {
                self.result(result: result, message: "Operation not permitted", type: -3)
            }
        }
    }
    
    private func open(documentURL: URL, result: @escaping FlutterResult) {
        if #available(macOS 10.15, *) {
            NSWorkspace.shared.open(documentURL, configuration: NSWorkspace.OpenConfiguration()) { application, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.result(result: result, message: error.localizedDescription, type: -4)
                    } else if application == nil {
                        self.result(result: result, message: "No application could open this file", type: -1)
                    } else {
                        self.result(result: result, message: "done", type: 0)
                    }
                }
            }
        } else {
            let opened = NSWorkspace.shared.open(documentURL)
            self.result(result: result, message: opened ? "done" : "No application could open this file", type: opened ? 0 : -1)
        }
    }

    private func result(result: FlutterResult, message: String, type: Int) {
        let map = ["message": message, "type": type] as [String: Any]
        result(self.convertDictionaryToString(dict: map))
    }
    
}

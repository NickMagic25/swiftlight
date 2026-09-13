import Foundation

struct HostXML {
    let fields: [String: String]
    let applications: [[String: String]]
    init(data: Data) throws {
        // Limits bound work and explicitly exclude external/internal entity declarations.
        guard data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw HostError.invalidResponse }
        let delegate = Parser(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot, delegate.depth == 0, let code = delegate.status else { throw HostError.invalidResponse }
        if code == 401 || code == 403 { throw HostError.permissionDenied }
        guard code == 200 else { throw HostError.hostStatus(code) }
        self.fields = delegate.fields; self.applications = delegate.applications
    }
    func required(_ key: String) throws -> String {
        guard let value = fields[key], !value.isEmpty else { throw HostError.invalidResponse }; return value
    }
    func requirePaired() throws { guard fields["paired"] == "1" else { throw HostError.pairingFailed } }
    func serverInfo(defaultHTTPSPort: Int, authenticated: Bool) throws -> HostInfo {
        let id = try required("uniqueid"), name = try required("hostname"), version = try required("appversion")
        let httpsPort = Int(fields["HttpsPort"] ?? "") ?? defaultHTTPSPort
        guard (1...65535).contains(httpsPort) else { throw HostError.invalidResponse }
        return HostInfo(id: id, name: name, appVersion: version, gfeVersion: fields["GfeVersion"] ?? "",
                        httpsPort: httpsPort, isPaired: authenticated && fields["PairStatus"] == "1", currentAppID: Int(fields["currentgame"] ?? "") ?? 0,
                        codecSupport: UInt32(fields["ServerCodecModeSupport"] ?? "") ?? 0,
                        permissions: fields["Permission"].flatMap(UInt32.init), rawFields: fields)
    }
    func apps() throws -> [RemoteApp] {
        try applications.map { fields in
            guard let raw = fields["ID"], let id = Int(raw), id > 0, let name = fields["AppTitle"] else { throw HostError.invalidResponse }
            if id == 114514 && name == "Permission Denied" { throw HostError.permissionDenied }
            return RemoteApp(id: id, name: name, supportsHDR: fields["IsHdrSupported"] == "1", uuid: fields["UUID"])
        }
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var fields: [String: String] = [:], applications: [[String: String]] = []
        var app: [String: String]?, text = "", depth = 0, status: Int?, sawRoot = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            depth += 1; text = ""
            if depth == 1 { sawRoot = elementName == "root"; status = attributes["status_code"].flatMap(Int.init) }
            if elementName == "App", depth == 2 { app = [:] }
            if depth > 16 { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if depth == 3, app != nil { app?[elementName] = value }
            else if depth == 2, elementName == "App", let app { applications.append(app); self.app = nil }
            else if depth == 2 { fields[elementName] = value }
            depth -= 1; text = ""
        }
    }
}

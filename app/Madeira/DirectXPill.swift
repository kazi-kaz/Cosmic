import Foundation

// (dx-pill) The DirectX pill on a game's card: the Direct3D and DirectDraw DLLs Wine actually
// loaded during the game's last run, read from that run's log once the game ends. Nothing is
// read from the program before it runs (the old graphics API pill did that and was often wrong,
// #543). Before a game's first run there is no pill.
//
// The signal is FEX's line for every module it maps, in every run (FEX ImageTracker.cpp,
// LogMan::Msg::DFmt("Load module {} ({}): {:X}", ...); FEX's MSG_LEVEL is the constant INFO,
// which keeps D lines, and MADEIRA_QUIET does not remove them), e.g.
//   D 130 Load module d3d9.dll (d3d9.dll-23c8601a8ec1e345): 7276FD0000
// Only the API DLLs below count: dxgi.dll loads for DX9 games too, and d3d10core, d3d11on12,
// d3dcompiler, d3dx9_*, d3d9-emulated and opengl32 name no API version. Every API found is
// shown, lowest first ("DX11 + DX12"); none is picked over another.
// Foundation only, so tests/host/check-dx-pill.py can compile and run it.
enum DirectXPill {
    /// Module name (lowercase, without ".dll") to its rank and label.
    static let modules: [String: (rank: Int, label: String)] = [
        "ddraw": (7, "DDraw"), "d3d8": (8, "DX8"), "d3d9": (9, "DX9"),
        "d3d10": (10, "DX10"), "d3d10_1": (10, "DX10"), "d3d11": (11, "DX11"), "d3d12": (12, "DX12"),
    ]

    /// The ranks of the API DLLs named by "Load module <name>.dll" lines in `text` (any case).
    static func ranks(in text: String) -> Set<Int> {
        var found = Set<Int>()
        var from = text.startIndex
        while let hit = text.range(of: "load module ", options: .caseInsensitive, range: from..<text.endIndex) {
            from = hit.upperBound
            let name = text[hit.upperBound...].prefix { $0 != " " && $0 != "\n" && $0 != "\r" && $0 != "\t" }.lowercased()
            guard name.hasSuffix(".dll"), let m = modules[String(name.dropLast(4))] else { continue }
            found.insert(m.rank)
        }
        return found
    }

    /// The pill's text for a set of ranks ("DDraw + DX9"), nil when empty.
    static func text(_ ranks: Set<Int>) -> String? {
        let labels = ranks.sorted().compactMap { r in modules.values.first { $0.rank == r }?.label }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    /// The pill's text for the part of the log at `url` from byte `offset` on (this run), read in
    /// 1 MB pieces cut at line ends; nil when no API DLL loaded or the file cannot be read. A log
    /// that is shorter than `offset` (rotated) is read from its start. It stops at the size the file had
    /// when the scan began, so a game started meanwhile is not counted for this run.
    static func scan(_ url: URL, from offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let first = offset <= size ? offset : 0
        guard (try? handle.seek(toOffset: first)) != nil else { return nil }
        var left = size - first
        var found = Set<Int>()
        var carry = Data()
        while true {
            let chunk = left == 0 ? nil : (try? handle.read(upToCount: Int(min(left, 1 << 20))))
            left -= UInt64(chunk?.count ?? 0)
            let end = chunk?.isEmpty ?? true
            var data = carry
            if let chunk { data.append(chunk) }
            var cut = data.endIndex
            if !end {
                if let nl = data.lastIndex(of: 0x0A) { cut = data.index(after: nl) }
                else if data.count < (4 << 20) { carry = data; continue }   // no line end yet
            }
            found.formUnion(ranks(in: String(decoding: data[data.startIndex..<cut], as: UTF8.self)))
            carry = Data(data[cut...])
            if end { break }
        }
        return text(found)
    }
}

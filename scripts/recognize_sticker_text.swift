#!/usr/bin/env swift
import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 4 else {
    fatalError("usage: recognize_sticker_text.swift REPO selection.json output.json")
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let selectionURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let selectionData = try Data(contentsOf: selectionURL)
let selection = try JSONSerialization.jsonObject(with: selectionData) as! [String: Any]
let categories = selection["categories"] as! [String: [String]]
let names = categories.values.flatMap { $0 }
var result: [String: [String]] = [:]

for (packIndex, name) in names.enumerated() {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "gif" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in files {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            guard (try? handler.perform([request])) != nil else { return }
            let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !texts.isEmpty { result[file.deletingPathExtension().lastPathComponent] = texts }
        }
    }
    fputs("\rOCR \(packIndex + 1)/\(names.count) \(name)        ", stderr)
}

let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try data.write(to: outputURL, options: .atomic)
fputs("\nrecognized text in \(result.count) stickers\n", stderr)

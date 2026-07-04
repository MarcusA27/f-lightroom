import Foundation
import AppKit

// The "describe your vision" feature: send the photo + the user's words to Claude
// and get back a full slider recipe. Swift has no official Anthropic SDK, so this
// talks to POST /v1/messages directly, with structured outputs forcing the model
// to return exactly our Adjustments schema.

enum VisionError: Error {
    case missingKey
    case http(String)
    case noContent
    case decode
}

// API key from the environment, or a plain-text ~/.anthropic_key file (one line).
private func anthropicKey() -> String? {
    if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
       !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return k.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let path = ("~/.anthropic_key" as NSString).expandingTildeInPath
    if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
        let t = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    return nil
}

private func jpegBase64(_ image: NSImage, maxDim: CGFloat = 1024) -> String? {
    let small = downscaled(image, maxDim: maxDim)
    guard let tiff = small.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    else { return nil }
    return data.base64EncodedString()
}

// Claude's structured reply: the full slider set plus a one-line summary.
private struct VisionResult: Decodable {
    let temperature, tint, exposure, contrast, highlights, shadows: Double
    let whites, blacks, clarity, vibrance, saturation: Double
    let summary: String
}

private let visionSystem = """
You are the editing brain of Lumen, a photo editor. Given a photo and a described \
vision, choose slider values that realize that vision tastefully. Every control is \
an integer from -100 to 100 where 0 means no change:
- temperature: negative cooler/bluer, positive warmer/oranger
- tint: negative greener, positive more magenta
- exposure: overall brightness
- contrast: overall contrast
- highlights: brightness of the bright midtones (negative recovers/darkens bright areas)
- shadows: negative deepens the dark areas, positive lifts them
- whites: the white point (negative recovers blown whites, positive brightens)
- blacks: the black point (negative deepens/crushes blacks, positive lifts/fades)
- clarity: local midtone contrast and texture. NEGATIVE clarity is the primary \
"soft, dreamy, hazy, glowing" look — reach for it whenever the vision is soft or ethereal.
- vibrance: gentle saturation that protects skin tones
- saturation: intensity of all colors

How to think about moods:
- "dreamy / soft / ethereal / hazy": the glow comes from NEGATIVE clarity (e.g. -40 to -70), \
a gentle black lift (blacks +10 to +25) for an airy fade, and slightly softened highlights. \
KEEP THE COLOR ALIVE — hold vibrance at 0 or push it slightly positive, and add a touch of \
warmth. Do not desaturate.
- "moody / cinematic / dramatic": deepen blacks (negative), add contrast, cool it slightly, \
maybe recover highlights.
- "warm / golden / cozy": positive temperature, gentle contrast, a little vibrance.
- "punchy / crisp / vivid": positive clarity, contrast, and vibrance.

CRITICAL: never wash the image out. Lifting blacks + dropping contrast + cutting saturation \
all at once produces a flat, lifeless gray — that is the most common failure. Every edit \
should keep either rich tone or lively color; usually both. A "dreamy" photo is soft and \
luminous, NOT gray and drained.

Return the full set of target values. Move only what serves the vision and leave the rest \
near 0. Prefer restrained, natural edits unless the vision explicitly asks for something \
bold. Also return one short sentence summarizing what you did.
"""

func requestVisionEdit(image: NSImage, prompt: String, current: Adjustments) async throws -> (Adjustments, String) {
    guard let key = anthropicKey() else { throw VisionError.missingKey }
    guard let b64 = jpegBase64(image) else { throw VisionError.noContent }

    func f(_ v: Double) -> String { String(Int(v.rounded())) }
    let currentText = """
    My vision: \(prompt)

    Current slider values (-100 to 100, 0 = unchanged): \
    temperature \(f(current.temperature)), tint \(f(current.tint)), \
    exposure \(f(current.exposure)), contrast \(f(current.contrast)), \
    highlights \(f(current.highlights)), shadows \(f(current.shadows)), \
    whites \(f(current.whites)), blacks \(f(current.blacks)), \
    clarity \(f(current.clarity)), vibrance \(f(current.vibrance)), \
    saturation \(f(current.saturation)).

    Return the target values for all sliders to achieve the vision.
    """

    let numberKeys = ["temperature", "tint", "exposure", "contrast", "highlights",
                      "shadows", "whites", "blacks", "clarity", "vibrance", "saturation"]
    var properties: [String: Any] = [:]
    for k in numberKeys {
        properties[k] = ["type": "number", "description": "\(k), integer -100 to 100"]
    }
    properties["summary"] = ["type": "string", "description": "one short sentence describing the edit"]
    let schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "required": numberKeys + ["summary"],
        "additionalProperties": false
    ]

    let body: [String: Any] = [
        "model": "claude-opus-4-8",
        "max_tokens": 1024,
        "system": visionSystem,
        "messages": [[
            "role": "user",
            "content": [
                ["type": "image",
                 "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                ["type": "text", "text": currentText]
            ]
        ]],
        "output_config": ["format": ["type": "json_schema", "schema": schema]]
    ]

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(key, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: req)
    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
        throw VisionError.http(msg)
    }
    // With output_config.format the first content block is text holding the JSON.
    guard let content = obj?["content"] as? [[String: Any]],
          let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
          let jsonData = text.data(using: .utf8) else {
        throw VisionError.noContent
    }
    guard let r = try? JSONDecoder().decode(VisionResult.self, from: jsonData) else {
        throw VisionError.decode
    }

    func clamp(_ v: Double) -> Double { max(-100, min(100, v.rounded())) }
    let adj = Adjustments(
        temperature: clamp(r.temperature), tint: clamp(r.tint), exposure: clamp(r.exposure),
        contrast: clamp(r.contrast), highlights: clamp(r.highlights), shadows: clamp(r.shadows),
        whites: clamp(r.whites), blacks: clamp(r.blacks), clarity: clamp(r.clarity),
        vibrance: clamp(r.vibrance), saturation: clamp(r.saturation))
    return (adj, r.summary)
}

func visionErrorMessage(_ error: Error) -> String {
    switch error {
    case VisionError.missingKey:
        return "Set ANTHROPIC_API_KEY (or ~/.anthropic_key) to use vision"
    case VisionError.http(let m):
        return "Vision failed: \(m)"
    case VisionError.noContent, VisionError.decode:
        return "Vision returned an unexpected response"
    default:
        return "Vision failed: \(error.localizedDescription)"
    }
}

//
//  GuidanceModels.swift
//  leanring-buddy
//
//  Everything for step-by-step spoken guidance and on-screen drawing:
//    1. GuidanceParser   splits the AI's reply into steps (speech + point + drawings)
//    2. ScreenAnnotation a shape ready to draw on one screen
//    3. AnnotationLayerView draws the shapes on the overlay, with a "pen stroke" animation
//
//  Reply format the AI uses (see the system prompt in CompanionManager):
//    [POINT:x,y:label:screenN]
//    [DRAW:circle:x,y,radius:label:screenN]
//    [DRAW:box:x,y,width,height:label:screenN]
//    [DRAW:arrow:x1,y1,x2,y2:label:screenN]
//    [DRAW:line:x1,y1,x2,y2:label:screenN]
//    [DIAGRAM:description of a diagram to draw in a floating window]
//  A tag belongs to the sentence(s) right before it. Old-style replies with a
//  single [POINT] at the very end still work: they become one step.
//

import SwiftUI

// MARK: - Parsed actions

struct GuidancePointAction {
    let coordinate: CGPoint
    let label: String?
    let screenNumber: Int?
}

enum AnnotationKind: String {
    case circle
    case box
    case arrow
    case line
}

struct GuidanceDrawAction {
    let kind: AnnotationKind
    /// circle: x, y, radius   box: x, y, width, height   arrow/line: x1, y1, x2, y2
    /// All on the 0-1000 grid over the screenshot, top-left origin.
    let values: [CGFloat]
    let label: String?
    let screenNumber: Int?
}

/// One beat of a guided reply: something to say, plus what to show while saying it.
struct GuidanceStep {
    var spokenText: String
    var point: GuidancePointAction?
    var drawings: [GuidanceDrawAction]
    /// A request for the diagram window (drawn by a separate Gemini request).
    var diagram: String? = nil

    var hasVisualAction: Bool {
        point != nil || !drawings.isEmpty || diagram != nil
    }
}

/// A shape that is ready to draw: values are already converted into the
/// screen's own point space (top-left origin), and it knows which screen it is on.
struct ScreenAnnotation: Identifiable, Equatable {
    let id = UUID()
    let kind: AnnotationKind
    let values: [CGFloat]
    let label: String?
    let displayFrame: CGRect
}

// MARK: - Parser

enum GuidanceParser {

    private static let maxSteps = 8
    private static let maxDrawingsPerStep = 4

    /// Matches [POINT:...] and [DRAW:...] anywhere in the reply.
    private static let tagPattern = #"\[(POINT|DRAW|DIAGRAM):([^\]]*)\]"#

    /// Splits a reply into steps. Text that comes after a tag starts a new step.
    static func parse(_ response: String) -> [GuidanceStep] {
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else {
            return StepBuilder.singleSpokenStep(response)
        }

        let nsResponse = response as NSString
        let fullRange = NSRange(location: 0, length: nsResponse.length)
        var builder = StepBuilder(maxDrawingsPerStep: maxDrawingsPerStep)
        var cursor = 0

        for match in regex.matches(in: response, options: [], range: fullRange) {
            let textBefore = nsResponse.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            builder.appendText(textBefore)
            cursor = match.range.location + match.range.length

            let tagName = nsResponse.substring(with: match.range(at: 1)).uppercased()
            let tagBody = nsResponse.substring(with: match.range(at: 2))

            if tagName == "POINT" {
                if let point = parsePoint(body: tagBody) {
                    builder.setPoint(point)
                }
                // [POINT:none] is simply ignored.
            } else if tagName == "DRAW" {
                if let drawing = parseDrawing(body: tagBody) {
                    builder.addDrawing(drawing)
                }
            } else if tagName == "DIAGRAM" {
                builder.setDiagram(tagBody)
            }
        }

        builder.appendText(nsResponse.substring(from: cursor))
        return Array(builder.finish().prefix(maxSteps))
    }

    // MARK: Tag parsing

    private static func splitBody(_ body: String) -> [String] {
        body.split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func parsePoint(body: String) -> GuidancePointAction? {
        let parts = splitBody(body)
        guard let first = parts.first, first.lowercased() != "none" else { return nil }

        let numbers = first.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 2, numbers.allSatisfy({ $0.isFinite }) else { return nil }

        let (label, screenNumber) = labelAndScreen(from: Array(parts.dropFirst()))
        return GuidancePointAction(
            coordinate: CGPoint(x: numbers[0], y: numbers[1]),
            label: label,
            screenNumber: screenNumber
        )
    }

    private static func parseDrawing(body: String) -> GuidanceDrawAction? {
        let parts = splitBody(body)
        guard parts.count >= 2,
              let kind = AnnotationKind(rawValue: parts[0].lowercased()) else { return nil }

        let numbers = parts[1].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }.map { CGFloat($0) }

        let requiredCount = (kind == .circle) ? 3 : 4
        guard numbers.count == requiredCount, numbers.allSatisfy({ $0.isFinite }) else { return nil }

        // Reject shapes that would be invisible or nonsense.
        switch kind {
        case .circle:
            guard numbers[2] >= 4 else { return nil }
        case .box:
            guard numbers[2] >= 4, numbers[3] >= 4 else { return nil }
        case .arrow, .line:
            let length = hypot(numbers[2] - numbers[0], numbers[3] - numbers[1])
            guard length >= 6 else { return nil }
        }

        let (label, screenNumber) = labelAndScreen(from: Array(parts.dropFirst(2)))
        return GuidanceDrawAction(kind: kind, values: numbers, label: label, screenNumber: screenNumber)
    }

    private static func labelAndScreen(from parts: [String]) -> (label: String?, screenNumber: Int?) {
        var label: String?
        var screenNumber: Int?
        for part in parts {
            let lowercased = part.lowercased()
            if lowercased.hasPrefix("screen"), let number = Int(lowercased.dropFirst(6)) {
                screenNumber = number
            } else if label == nil, !part.isEmpty, lowercased != "none" {
                label = part
            }
        }
        return (label, screenNumber)
    }

    // MARK: Step builder

    private struct StepBuilder {
        let maxDrawingsPerStep: Int
        var steps: [GuidanceStep] = []
        var current = GuidanceStep(spokenText: "", point: nil, drawings: [])
        /// Only one diagram window request is honored per reply.
        var hasDiagram = false

        init(maxDrawingsPerStep: Int) {
            self.maxDrawingsPerStep = maxDrawingsPerStep
        }

        static func singleSpokenStep(_ text: String) -> [GuidanceStep] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [GuidanceStep(spokenText: trimmed, point: nil, drawings: [])]
        }

        mutating func appendText(_ rawText: String) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Text after a tag means a new beat of the walkthrough begins.
            if current.hasVisualAction {
                steps.append(current)
                current = GuidanceStep(spokenText: "", point: nil, drawings: [])
            }
            current.spokenText += (current.spokenText.isEmpty ? "" : " ") + trimmed
        }

        mutating func setPoint(_ point: GuidancePointAction) {
            // A second point with no words in between becomes its own step.
            if current.point != nil {
                steps.append(current)
                current = GuidanceStep(spokenText: "", point: nil, drawings: [])
            }
            current.point = point
        }

        mutating func setDiagram(_ description: String) {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hasDiagram, trimmed.count >= 8 else { return }
            hasDiagram = true
            current.diagram = trimmed
        }

        mutating func addDrawing(_ drawing: GuidanceDrawAction) {
            guard current.drawings.count < maxDrawingsPerStep else { return }
            current.drawings.append(drawing)
        }

        mutating func finish() -> [GuidanceStep] {
            if !current.spokenText.isEmpty || current.hasVisualAction {
                steps.append(current)
                current = GuidanceStep(spokenText: "", point: nil, drawings: [])
            }
            return steps
        }
    }
}

// MARK: - Converting a drawing into screen coordinates

extension ScreenAnnotation {
    /// Converts values on the 0-1000 grid into the target display's point space
    /// (the same scaling the cursor-pointing code uses).
    static func make(from drawing: GuidanceDrawAction, capture: CompanionScreenCapture) -> ScreenAnnotation? {
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        guard displayWidth > 0, displayHeight > 0 else { return nil }

        let scaleX = displayWidth / 1000
        let scaleY = displayHeight / 1000
        let v = drawing.values

        let converted: [CGFloat]
        switch drawing.kind {
        case .circle:
            converted = [v[0] * scaleX, v[1] * scaleY, v[2] * (scaleX + scaleY) / 2]
        case .box:
            converted = [v[0] * scaleX, v[1] * scaleY, v[2] * scaleX, v[3] * scaleY]
        case .arrow, .line:
            converted = [v[0] * scaleX, v[1] * scaleY, v[2] * scaleX, v[3] * scaleY]
        }

        return ScreenAnnotation(
            kind: drawing.kind,
            values: converted,
            label: drawing.label,
            displayFrame: capture.displayFrame
        )
    }
}

// MARK: - Drawing views

/// Draws every annotation that belongs to this screen. Lives inside the
/// click-through overlay window, so it never blocks the mouse.
struct AnnotationLayerView: View {
    let annotations: [ScreenAnnotation]
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            ForEach(annotationsOnThisScreen) { annotation in
                AnnotationShapeView(annotation: annotation)
                    .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    private var annotationsOnThisScreen: [ScreenAnnotation] {
        annotations.filter { annotation in
            screenFrame.contains(CGPoint(x: annotation.displayFrame.midX, y: annotation.displayFrame.midY))
        }
    }
}

/// One shape, drawn like a pen stroke (trim animation), with an optional label.
struct AnnotationShapeView: View {
    let annotation: ScreenAnnotation

    @State private var drawProgress: CGFloat = 0
    @State private var labelOpacity: Double = 0

    var body: some View {
        ZStack {
            AnnotationPathShape(kind: annotation.kind, values: annotation.values)
                .trim(from: 0, to: drawProgress)
                .stroke(
                    DS.Colors.overlayCursorBlue,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.8), radius: 6, x: 0, y: 0)

            if let label = annotation.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .position(labelPosition)
                    .opacity(labelOpacity)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55)) {
                drawProgress = 1
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.45)) {
                labelOpacity = 1
            }
        }
    }

    /// Where the label sits relative to the shape.
    private var labelPosition: CGPoint {
        let v = annotation.values
        switch annotation.kind {
        case .circle:
            return CGPoint(x: v[0], y: v[1] + v[2] + 16)
        case .box:
            return CGPoint(x: v[0] + 30, y: max(14, v[1] - 14))
        case .arrow:
            return CGPoint(x: v[0], y: max(14, v[1] - 16))
        case .line:
            return CGPoint(x: (v[0] + v[2]) / 2, y: (v[1] + v[3]) / 2 + 16)
        }
    }
}

/// The outline for each annotation kind, in the screen's own point space.
struct AnnotationPathShape: Shape {
    let kind: AnnotationKind
    let values: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .circle:
            let centerX = values[0]
            let centerY = values[1]
            let radius = values[2]
            path.addEllipse(in: CGRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            ))

        case .box:
            path.addRoundedRect(
                in: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
                cornerSize: CGSize(width: 6, height: 6)
            )

        case .line:
            path.move(to: CGPoint(x: values[0], y: values[1]))
            path.addLine(to: CGPoint(x: values[2], y: values[3]))

        case .arrow:
            let start = CGPoint(x: values[0], y: values[1])
            let end = CGPoint(x: values[2], y: values[3])
            path.move(to: start)
            path.addLine(to: end)

            // Arrowhead: two short strokes angled back from the tip.
            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLength: CGFloat = 18
            let spread: CGFloat = .pi / 7
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - headLength * cos(angle - spread),
                y: end.y - headLength * sin(angle - spread)
            ))
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - headLength * cos(angle + spread),
                y: end.y - headLength * sin(angle + spread)
            ))
        }
        return path
    }
}

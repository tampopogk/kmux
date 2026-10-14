import AppKit
import Testing
@testable import KmuxDiagram

@Suite struct DiagramTests {
    @Test func flowchartHasEveryLabelAndColour() throws {
        let layout = try Diagram.layout(source: """
        flowchart LR
            A[Start here] -->|go| B{Decide}
            B --> C[(Store)]
            classDef hot fill:#f96
            class C hot
        """)
        #expect(layout.type.hasPrefix("flowchart"))
        let scene = try #require(layout.scene)
        #expect(Set(scene.texts).isSuperset(of: ["Start here", "go", "Decide", "Store"]))
        #expect(scene.size.width > scene.size.height) // left to right
        let orange = scene.items.contains { item in
            guard case .shape(let shape) = item, case .color(let color)? = shape.fill else { return false }
            return abs((color.components?[0] ?? 0) - 1) < 0.01 && abs((color.components?[1] ?? 0) - 0.6) < 0.01
        }
        #expect(orange, "classDef fill should colour the node")
    }

    @Test func sequenceAndStateDiagramsLayOut() throws {
        let sequence = try #require(try Diagram.layout(source: "sequenceDiagram\n    Alice->>Bob: Hello\n    Bob-->>Alice: Hi").scene)
        #expect(Set(sequence.texts).isSuperset(of: ["Alice", "Bob", "Hello", "Hi"]))
        let state = try #require(try Diagram.layout(source: "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Busy: work\n    Busy --> [*]").scene)
        #expect(Set(state.texts).isSuperset(of: ["Idle", "Busy", "work"]))
    }

    @Test func classDiagramDrawsCompartmentsAndRelations() throws {
        let layout = try Diagram.layout(source: """
        classDiagram
            class Shape {
                <<abstract>>
                +String name
                -int id$
                #List~Point~ points
                +area()* double
            }
            Shape <|-- Circle : inherits
            Canvas "1" *-- "many" Shape
            Canvas o-- Layer
            Circle ..> Point
            note for Circle "Round"
        """)
        #expect(layout.type == "classDiagram")
        let scene = try #require(layout.scene)
        #expect(Set(scene.texts).isSuperset(of: ["«abstract»", "Shape", "+String name", "-int id", "#List&lt;Point&gt; points", "+area() : double",
                                                 "inherits", "1", "many", "Round", "Circle", "Canvas", "Layer", "Point"]))
        let labels = scene.items.compactMap { if case .text(let label) = $0 { label } else { nil } }
        #expect(labels.first { $0.text == "Shape" }?.bold == true)
        #expect(labels.first { $0.text == "+area() : double" }?.italic == true, "abstract methods are italic")
        #expect(labels.first { $0.text == "+String name" }?.alignment == .left)
        let shapes = scene.items.compactMap { if case .shape(let shape) = $0 { shape } else { nil } }
        #expect(shapes.contains { if case .role(.classFill(0))? = $0.fill { true } else { false } }, "the first class gets Mermaid's first colour")
        #expect(shapes.contains { $0.dash == [2, 2] }, "a dependency drawn .. is dotted")
    }

    @Test func otherTypesAreUnsupportedNotErrors() throws {
        let layout = try Diagram.layout(source: "pie title Pets\n    \"Dogs\" : 3\n    \"Cats\" : 2")
        #expect(layout.scene == nil)
        #expect(layout.type.lowercased().contains("pie"))
    }

    @Test func invalidSourceThrows() {
        #expect(throws: DiagramError.self) { try Diagram.layout(source: "flowchart LR\n    A -->") }
    }

    /// Labels are measured with Core Text, so drawing never has to shrink one
    /// to fit its box, in light or dark, and the scene contains everything drawn.
    @Test(arguments: ["""
        flowchart TD
            A[A fairly long label that has to wrap onto more than one line] --> B([Stadium])
            B --> C{{Hexagon label}}
        """, """
        classDiagram
            class Animal["An animal"] {
                <<interface>>
                +isMammal() bool
            }
            Animal <|-- Duck
            Duck "1" --> "*" Egg : lays
            A --() Iface
        """])
    func labelsFitTheirBoxes(source: String) throws {
        let scene = try #require(try Diagram.layout(source: source).scene)
        let context = try #require(CGContext(data: nil, width: Int(scene.size.width), height: Int(scene.size.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(scene.draw(in: context, dark: false) == 0)
        #expect(scene.png(scale: 2, dark: true) != nil)
        for item in scene.items {
            if case .text(let label) = item {
                #expect(CGRect(origin: .zero, size: scene.size).contains(label.drawnBounds.integral.insetBy(dx: 1, dy: 1)))
            }
        }
    }
}

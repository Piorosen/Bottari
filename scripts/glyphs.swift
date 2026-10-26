// Writes Bottari's line icons into the asset catalog as template SVGs:
// a 20-point grid, 1.5-point strokes with round ends, drawn in black so
// the app can tint them.
//
//   swift scripts/glyphs.swift Bottari/Assets.xcassets/Glyphs
import Foundation

let glyphs: [String: String] = [
    // The bundle the app is named after: cloth tied at the top. The knot and
    // the two tied corners are solid so they still read at sidebar size.
    "bt.bundle": """
        <path d="M7.6 10.2C5.4 10.9 3.5 12.2 3.5 14V15.5C3.5 16.6 4.4 17.5 5.5 17.5H14.5C15.6 17.5 16.5 16.6 16.5 15.5V14C16.5 12.2 14.6 10.9 12.4 10.2"/>
        <path d="M3.7 14.2C7.4 15.5 12.6 15.5 16.3 14.2"/>
        <g fill="#000" stroke-width="1">
        <ellipse cx="10" cy="9.6" rx="2.3" ry="1.6"/>
        <path d="M8.9 8.5C8 6.6 6.4 5.1 4.2 4.5C4.5 6.8 6.1 8.6 8.3 9.5Z"/>
        <path d="M11.1 8.5C12 6.8 13.5 5.6 15.6 5.1C15.3 7.2 13.9 8.8 11.7 9.5Z"/>
        </g>
        """,
    "bt.server": """
        <rect x="3.5" y="3.5" width="13" height="5.5" rx="1.6"/>
        <rect x="3.5" y="11" width="13" height="5.5" rx="1.6"/>
        <path d="M9.5 6.25H13.5M9.5 13.75H13.5"/>
        <circle cx="6.6" cy="6.25" r="0.9" fill="#000" stroke="none"/>
        <circle cx="6.6" cy="13.75" r="0.9" fill="#000" stroke="none"/>
        """,
    "bt.cloud": """
        <path d="M5.3 15.5H14.4C16.1 15.5 17.5 14.1 17.5 12.4C17.5 10.8 16.2 9.5 14.6 9.4C14.1 7.1 12.2 5.5 9.9 5.5C7.5 5.5 5.6 7.3 5.3 9.6C3.7 9.9 2.5 11.2 2.5 12.8C2.5 14.3 3.8 15.5 5.3 15.5Z"/>
        """,
    "bt.bucket": """
        <ellipse cx="10" cy="5.5" rx="5.5" ry="2"/>
        <path d="M4.5 5.5V14.5C4.5 15.6 7 16.5 10 16.5C13 16.5 15.5 15.6 15.5 14.5V5.5"/>
        <path d="M4.5 10C4.5 11.1 7 12 10 12C13 12 15.5 11.1 15.5 10"/>
        """,
    "bt.mac": """
        <rect x="4" y="4.5" width="12" height="8.5" rx="1.3"/>
        <path d="M2.5 15.5H17.5"/>
        """,
    "bt.desktop": """
        <rect x="2.5" y="3.5" width="15" height="10" rx="1.6"/>
        <path d="M10 13.5V16.5M7 16.5H13"/>
        """,
    "bt.document": """
        <path d="M6.8 3.5H11.2L14.5 6.8V15.7C14.5 16.1 14.1 16.5 13.7 16.5H6.8C6.4 16.5 6 16.1 6 15.7V4.3C6 3.9 6.4 3.5 6.8 3.5Z"/>
        <path d="M11 3.7V7H14.3"/>
        <path d="M8.3 10.5H12.2M8.3 13.2H12.2"/>
        """,
    "bt.download": """
        <circle cx="10" cy="10" r="7"/>
        <path d="M10 6.5V13M7.4 10.5L10 13.1L12.6 10.5"/>
        """,
    "bt.apps": """
        <rect x="3.5" y="3.5" width="5.3" height="5.3" rx="1.4"/>
        <rect x="11.2" y="3.5" width="5.3" height="5.3" rx="1.4"/>
        <rect x="3.5" y="11.2" width="5.3" height="5.3" rx="1.4"/>
        <rect x="11.2" y="11.2" width="5.3" height="5.3" rx="1.4"/>
        """,
    "bt.star": """
        <path d="M10 3.3L12 7.6L16.6 8.1L13.2 11.2L14.1 15.8L10 13.5L5.9 15.8L6.8 11.2L3.4 8.1L8 7.6Z"/>
        """,
    "bt.plus": """
        <path d="M10 4.5V15.5M4.5 10H15.5"/>
        """,
    "bt.terminal": """
        <rect x="2.5" y="3.5" width="15" height="13" rx="2"/>
        <path d="M6 8L8.5 10L6 12M10.5 12.5H14"/>
        """,
    "bt.transfer": """
        <path d="M7 15.5V4.5M4.3 7.2L7 4.5L9.7 7.2M13 4.5V15.5M10.3 12.8L13 15.5L15.7 12.8"/>
        """,
    "bt.inspector": """
        <rect x="2.5" y="3.5" width="15" height="13" rx="2"/>
        <path d="M12.5 3.5V16.5"/>
        """,
    "bt.settings": """
        <path d="M3.5 6.5H10M14 6.5H16.5M3.5 13.5H5.5M9.5 13.5H16.5"/>
        <circle cx="12" cy="6.5" r="2"/>
        <circle cx="7.5" cy="13.5" r="2"/>
        """,
    "bt.tunnel": """
        <path d="M3.5 16.5V10C3.5 6.4 6.4 3.5 10 3.5C13.6 3.5 16.5 6.4 16.5 10V16.5"/>
        <path d="M7.5 16.5V10.5C7.5 9.1 8.6 8 10 8C11.4 8 12.5 9.1 12.5 10.5V16.5"/>
        <path d="M2.5 16.5H17.5"/>
        """,
    "bt.search": """
        <circle cx="8.8" cy="8.8" r="5.3"/>
        <path d="M12.7 12.7L16.5 16.5"/>
        """,
    "bt.screen": """
        <rect x="2.5" y="3.5" width="15" height="10" rx="1.6"/>
        <path d="M10 13.5V16.5M7 16.5H13M8.5 7L11.5 8.5L8.5 10"/>
        """,
]

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Bottari/Assets.xcassets/Glyphs"
let fm = FileManager.default
try? fm.removeItem(atPath: folder)
try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(toFile: "\(folder)/Contents.json", atomically: true, encoding: .utf8)
for (name, body) in glyphs {
    let set = "\(folder)/\(name).imageset"
    try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
    let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
        \(body)
        </svg>

        """
    try svg.write(toFile: "\(set)/\(name).svg", atomically: true, encoding: .utf8)
    let contents = """
        {
          "images" : [ { "filename" : "\(name).svg", "idiom" : "universal" } ],
          "info" : { "author" : "xcode", "version" : 1 },
          "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" }
        }

        """
    try contents.write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
}
print("\(glyphs.count) glyphs in \(folder)")

//
//  MessageView.swift
//  Apple Intelligence Chat
//
//  Created by Pallav Agarwal on 6/9/25.
//

import SwiftUI

/// Represents the role of a chat participant
enum ChatRole {
    case user
    case assistant
}

/// Represents a single message in the chat conversation
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: ChatRole
    var text: String
}


/// View for displaying a single chat message
struct MessageView: View {
    let message: ChatMessage
    let isResponding: Bool
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
                Text(message.text)
                    .padding(12)
                    .foregroundColor(.white)
                    .background(.blue)
                    .clipShape(.rect(cornerRadius: 18))
                    .glassEffect(in: .rect(cornerRadius: 18))
                
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if message.text.isEmpty && isResponding {
                        PulsingDotView()
                            .frame(width: 60, height: 25)
                    } else {
                        MarkdownText(message.text)
                    }
                }
                .padding(.vertical, 8)
                Spacer()
            }
        }
        .padding(.vertical, 6)
    }
}

/// View that renders text with markdown formatting
struct MarkdownText: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseMarkdownBlocks(text), id: \.id) { block in
                switch block.type {
                case .code:
                    CodeBlockView(code: block.content, language: block.language)
                case .text:
                    renderTextBlock(block.content)
                }
            }
        }
    }
    
    /// Renders a text block by splitting it into paragraphs so that
    /// headings, list items, and line breaks are preserved.
    @ViewBuilder
    private func renderTextBlock(_ content: String) -> some View {
        let paragraphs = splitIntoParagraphs(content)
        ForEach(paragraphs, id: \.id) { paragraph in
            if let attributedString = try? AttributedString(
                markdown: paragraph.content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            ) {
                // Apply heading styling based on prefix
                if paragraph.headingLevel > 0 {
                    Text(attributedString)
                        .font(fontForHeadingLevel(paragraph.headingLevel))
                        .fontWeight(.bold)
                        .textSelection(.enabled)
                } else {
                    Text(attributedString)
                        .textSelection(.enabled)
                }
            } else {
                Text(paragraph.content)
                    .textSelection(.enabled)
            }
        }
    }
    
    /// Splits a text block into separate paragraphs, preserving blank-line
    /// separation and keeping headings, list items, etc. on their own lines.
    private func splitIntoParagraphs(_ text: String) -> [TextParagraph] {
        let lines = text.components(separatedBy: "\n")
        var paragraphs: [TextParagraph] = []
        var currentLines: [String] = []
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#")
            let isListItem = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                || trimmed.first.map({ $0.isNumber && trimmed.contains(". ") }) == true
            let isEmpty = trimmed.isEmpty
            
            // Check if the next line is a heading or list item
            let nextLine = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            let nextIsHeading = nextLine.hasPrefix("#")
            let nextIsListItem = nextLine.hasPrefix("- ") || nextLine.hasPrefix("* ")
                || nextLine.first.map({ $0.isNumber && nextLine.contains(". ") }) == true
            
            if isHeading {
                // Flush any accumulated text before the heading
                if !currentLines.isEmpty {
                    let joined = currentLines.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        paragraphs.append(TextParagraph(content: joined, headingLevel: 0))
                    }
                    currentLines = []
                }
                // Parse heading level and content
                let (level, headingContent) = parseHeading(trimmed)
                paragraphs.append(TextParagraph(content: headingContent, headingLevel: level))
            } else if isEmpty {
                // Blank line: flush accumulated text as a paragraph
                if !currentLines.isEmpty {
                    let joined = currentLines.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        paragraphs.append(TextParagraph(content: joined, headingLevel: 0))
                    }
                    currentLines = []
                }
            } else if isListItem && !currentLines.isEmpty && !isListLine(currentLines.last ?? "") {
                // Starting a list after non-list text: flush first
                let joined = currentLines.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    paragraphs.append(TextParagraph(content: joined, headingLevel: 0))
                }
                currentLines = [line]
            } else {
                currentLines.append(line)
                // If next line is a heading or we're at end, flush
                if nextIsHeading {
                    let joined = currentLines.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        paragraphs.append(TextParagraph(content: joined, headingLevel: 0))
                    }
                    currentLines = []
                }
            }
        }
        
        // Flush remaining lines
        if !currentLines.isEmpty {
            let joined = currentLines.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paragraphs.append(TextParagraph(content: joined, headingLevel: 0))
            }
        }
        
        return paragraphs
    }
    
    /// Parses a heading line like "## Hello" into (level: 2, content: "Hello")
    private func parseHeading(_ line: String) -> (Int, String) {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex && line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        let content = String(line[index...]).trimmingCharacters(in: .whitespaces)
        return (min(level, 6), content)
    }
    
    /// Returns the appropriate font for a heading level (1–6)
    private func fontForHeadingLevel(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        case 5: return .subheadline
        default: return .subheadline
        }
    }
    
    /// Returns true if a line looks like a list item (-, *, or numbered)
    private func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
        if let first = trimmed.first, first.isNumber, trimmed.contains(". ") { return true }
        return false
    }
    
    // Parse markdown into code blocks and text blocks
    private func parseMarkdownBlocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        
        // Pattern for complete code blocks
        let completePattern = "```(\\w*)\\n([\\s\\S]*?)```"
        
        guard let regex = try? NSRegularExpression(pattern: completePattern, options: []) else {
            return [MarkdownBlock(type: .text, content: markdown)]
        }
        
        let nsString = markdown as NSString
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
        
        var lastIndex = 0
        
        for match in matches {
            // Add text before code block
            if match.range.location > lastIndex {
                let textRange = NSRange(location: lastIndex, length: match.range.location - lastIndex)
                let textContent = nsString.substring(with: textRange)
                if !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(MarkdownBlock(type: .text, content: textContent))
                }
            }
            
            // Add complete code block
            let languageRange = match.range(at: 1)
            let codeRange = match.range(at: 2)
            
            let language = languageRange.location != NSNotFound ? nsString.substring(with: languageRange) : ""
            let code = nsString.substring(with: codeRange)
            
            blocks.append(MarkdownBlock(type: .code, content: code, language: language.isEmpty ? nil : language))
            
            lastIndex = match.range.location + match.range.length
        }
        
        // Check for unclosed code block in remaining text
        if lastIndex < nsString.length {
            let remainingText = nsString.substring(from: lastIndex)
            
            // Pattern for opening code fence
            let openPattern = "```(\\w*)\\n([\\s\\S]*)"
            if let openRegex = try? NSRegularExpression(pattern: openPattern, options: []),
               let openMatch = openRegex.firstMatch(in: remainingText, options: [], range: NSRange(location: 0, length: remainingText.count)) {
                
                let remainingNSString = remainingText as NSString
                
                // Add any text before the opening fence
                if openMatch.range.location > 0 {
                    let textBefore = remainingNSString.substring(with: NSRange(location: 0, length: openMatch.range.location))
                    if !textBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(MarkdownBlock(type: .text, content: textBefore))
                    }
                }
                
                // Add unclosed code block
                let languageRange = openMatch.range(at: 1)
                let codeRange = openMatch.range(at: 2)
                
                let language = languageRange.location != NSNotFound ? remainingNSString.substring(with: languageRange) : ""
                let code = remainingNSString.substring(with: codeRange)
                
                blocks.append(MarkdownBlock(type: .code, content: code, language: language.isEmpty ? nil : language))
            } else {
                // No unclosed code block, just regular text
                if !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(MarkdownBlock(type: .text, content: remainingText))
                }
            }
        }
        
        // If no matches, return original text
        if blocks.isEmpty {
            blocks.append(MarkdownBlock(type: .text, content: markdown))
        }
        
        return blocks
    }
}

/// Represents a block of markdown content
struct MarkdownBlock: Identifiable {
    let id = UUID()
    let type: BlockType
    let content: String
    let language: String?
    
    enum BlockType {
        case text
        case code
    }
    
    init(type: BlockType, content: String, language: String? = nil) {
        self.type = type
        self.content = content
        self.language = language
    }
}

/// Represents a paragraph of text with optional heading level
struct TextParagraph: Identifiable {
    let id = UUID()
    let content: String
    let headingLevel: Int
}

/// View for displaying a code block with styling
struct CodeBlockView: View {
    let code: String
    let language: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language = language, !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(language != nil ? [.horizontal, .bottom] : .all, 12)
            }
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

/// Animated loading indicator shown while AI is generating a response
struct PulsingDotView: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundStyle(.primary.opacity(0.5))
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}

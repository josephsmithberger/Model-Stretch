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
                    if let attributedString = try? AttributedString(markdown: block.content, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributedString)
                            .textSelection(.enabled)
                    } else {
                        Text(block.content)
                            .textSelection(.enabled)
                    }
                }
            }
        }
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

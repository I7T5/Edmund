import AppKit

// MARK: - Active Block Syntax Highlighting & Inactive Block Rendering

extension EditorTextView {

    /// Color for dimmed syntax delimiters (*, **, `, #, etc.)
    var syntaxDimColor: NSColor { .tertiaryLabelColor }

    /// Color for inline code spans.
    var codeColor: NSColor { NSColor(calibratedRed: 0.541, green: 0.141, blue: 0.145, alpha: 1.0) }

    /// Indentation amount for list items (active and inactive).
    var listIndent: CGFloat { 16 }

    /// Paragraph style with indentation for list items.
    private func listParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing
        ps.firstLineHeadIndent = listIndent
        ps.headIndent = listIndent
        return ps
    }

    /// Paragraph style with a left border for blockquotes.
    private func blockquoteParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing

        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        let leftEdge = NSRectEdge(rawValue: 0)!
        block.setWidth(2, type: .absoluteValueType, for: .border, edge: leftEdge)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: leftEdge)
        block.setBorderColor(.tertiaryLabelColor, for: leftEdge)
        ps.textBlocks = [block]

        return ps
    }

    // MARK: - Active Block Syntax Highlighting

    /// Builds an NSAttributedString of the raw markdown with syntax highlighting.
    func highlightSyntax(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: markdown, attributes: baseAttributes)
        let spans = SyntaxHighlighter.parse(markdown)

        for span in spans {
            // Dim delimiter characters
            for dr in span.delimiterRanges {
                guard dr.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
            }

            switch span.kind {
            case .bold:
                guard span.contentRange.upperBound <= result.length else { continue }
                let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: bold, range: span.contentRange)

            case .italic:
                guard span.contentRange.upperBound <= result.length else { continue }
                let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italic, range: span.contentRange)

            case .boldItalic:
                guard span.contentRange.upperBound <= result.length else { continue }
                let bi = NSFontManager.shared.convert(bodyFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                result.addAttribute(.font, value: bi, range: span.contentRange)

            case .code:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: codeColor, range: span.contentRange)

            case .strikethrough:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)

            case .highlight:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: span.contentRange)

            case .heading(let level):
                guard span.fullRange.upperBound <= result.length else { continue }
                let scale: CGFloat = level == 1 ? 1.5 : level == 2 ? 1.3 : level == 3 ? 1.15 : 1.0
                let sized = NSFont(descriptor: bodyFont.fontDescriptor,
                                   size: bodyFont.pointSize * scale) ?? bodyFont
                let heading = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: heading, range: span.fullRange)
                for dr in span.delimiterRanges {
                    guard dr.upperBound <= result.length else { continue }
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                }

            case .link:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: accentColor, range: span.contentRange)

            case .blockquote:
                break  // Just dim the "> " prefix (handled by generic delimiter loop)

            case .listItem:
                guard span.fullRange.upperBound <= result.length else { continue }
                result.addAttribute(.paragraphStyle, value: listParagraphStyle(), range: span.fullRange)

            case .thematicBreak:
                guard span.fullRange.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.fullRange)
            }
        }

        return result
    }

    /// Re-applies syntax highlighting to the active block in the text storage.
    /// Called after each keystroke to keep formatting in sync with content.
    func applySyntaxHighlighting() {
        guard let ts = textStorage,
              let activeIdx = activeBlockIndex,
              activeIdx < displayRanges.count,
              activeIdx < blocks.count else { return }

        let displayRange = displayRanges[activeIdx]
        guard displayRange.upperBound <= ts.length else { return }

        let content = blocks[activeIdx].content
        let highlighted = highlightSyntax(content)
        let offset = displayRange.location

        isUpdating = true
        ts.beginEditing()

        highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length), options: []) { attrs, range, _ in
            let displayR = NSRange(location: range.location + offset, length: range.length)
            ts.setAttributes(attrs, range: displayR)
        }

        ts.endEditing()
        isUpdating = false

        typingAttributes = baseAttributes
    }

    // MARK: - Inactive Block Rendering

    /// Computes the exact delimiter ranges to strip for a rendered (inactive) block.
    private func renderDelimiters(for span: SyntaxHighlighter.Span) -> [NSRange] {
        switch span.kind {
        case .italic:
            return [
                NSRange(location: span.contentRange.location - 1, length: 1),
                NSRange(location: span.contentRange.upperBound, length: 1),
            ]
        case .bold:
            return [
                NSRange(location: span.contentRange.location - 2, length: 2),
                NSRange(location: span.contentRange.upperBound, length: 2),
            ]
        case .boldItalic:
            return [
                NSRange(location: span.contentRange.location - 3, length: 3),
                NSRange(location: span.contentRange.upperBound, length: 3),
            ]
        case .strikethrough, .highlight:
            return [
                NSRange(location: span.contentRange.location - 2, length: 2),
                NSRange(location: span.contentRange.upperBound, length: 2),
            ]
        case .code, .heading, .link, .blockquote:
            return span.delimiterRanges
        case .listItem(let ordered, _):
            return ordered ? [] : span.delimiterRanges
        case .thematicBreak:
            return span.delimiterRanges
        }
    }

    func renderMarkdown(_ markdown: String) -> NSAttributedString {
        let spans = SyntaxHighlighter.parse(markdown)

        // Compute exact delimiter ranges for each span, sorted descending for back-to-front removal
        var allDelimRanges: [NSRange] = []
        for span in spans {
            allDelimRanges.append(contentsOf: renderDelimiters(for: span))
        }
        allDelimRanges.sort { $0.location > $1.location }

        // Build stripped text by removing delimiters
        var stripped = markdown
        var removals: [(location: Int, length: Int)] = []
        for dr in allDelimRanges {
            guard dr.location >= 0, dr.upperBound <= (stripped as NSString).length else { continue }
            let startUTF16 = stripped.utf16.index(stripped.utf16.startIndex, offsetBy: dr.location)
            let endUTF16 = stripped.utf16.index(startUTF16, offsetBy: dr.length)
            stripped.removeSubrange(startUTF16..<endUTF16)
            removals.append((location: dr.location, length: dr.length))
        }
        removals.reverse()

        // For thematic breaks, insert a visual divider line.
        let thematicBreakSpans = spans.filter { $0.kind == .thematicBreak }
        for span in thematicBreakSpans.reversed() {
            let insertPos = mappedOffset(span.fullRange.location, removals: removals)
            let idx = stripped.utf16.index(stripped.utf16.startIndex, offsetBy: insertPos)
            let divider = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"  // 20× ─
            stripped.insert(contentsOf: divider, at: idx)
            removals.append((location: span.fullRange.location, length: -(divider as NSString).length))
        }

        // For unordered list items, insert bullet/checkbox replacement at the start.
        let unorderedListSpans = spans.filter {
            if case .listItem(ordered: false, _) = $0.kind { return true }
            return false
        }
        for span in unorderedListSpans.reversed() {
            let insertPos = mappedOffset(span.contentRange.location, removals: removals)
            let idx = stripped.utf16.index(stripped.utf16.startIndex, offsetBy: insertPos)
            let bullet: String
            if case .listItem(_, let checkbox) = span.kind {
                switch checkbox {
                case .unchecked: bullet = "\u{25CB} "  // ○
                case .checked:   bullet = "\u{25CF} "  // ●
                case .none:      bullet = "\u{2022} "  // •
                }
            } else {
                bullet = "\u{2022} "
            }
            stripped.insert(contentsOf: bullet, at: idx)
            removals.append((location: span.contentRange.location - 1, length: -2))
        }

        removals.sort { $0.location < $1.location }

        let result = NSMutableAttributedString(string: stripped, attributes: baseAttributes)

        for span in spans {
            let start = mappedOffset(span.contentRange.location, removals: removals)
            let end = mappedOffset(span.contentRange.upperBound, removals: removals)
            let mappedRange = NSRange(location: start, length: max(0, end - start))
            guard mappedRange.upperBound <= result.length else { continue }

            switch span.kind {
            case .bold:
                let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: bold, range: mappedRange)
            case .italic:
                let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italic, range: mappedRange)
            case .boldItalic:
                let bi = NSFontManager.shared.convert(bodyFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                result.addAttribute(.font, value: bi, range: mappedRange)
            case .code:
                result.addAttribute(.foregroundColor, value: codeColor, range: mappedRange)
            case .strikethrough:
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: mappedRange)
            case .highlight:
                result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: mappedRange)
            case .heading(let level):
                let fullStart = mappedOffset(span.fullRange.location, removals: removals)
                let fullEnd = mappedOffset(span.fullRange.upperBound, removals: removals)
                let mappedFull = NSRange(location: fullStart, length: max(0, fullEnd - fullStart))
                guard mappedFull.upperBound <= result.length else { continue }
                let scale: CGFloat = level == 1 ? 1.5 : level == 2 ? 1.3 : level == 3 ? 1.15 : 1.0
                let sized = NSFont(descriptor: bodyFont.fontDescriptor,
                                   size: bodyFont.pointSize * scale) ?? bodyFont
                let heading = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: heading, range: mappedFull)
            case .link:
                result.addAttribute(.foregroundColor, value: accentColor, range: mappedRange)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: mappedRange)
            case .blockquote:
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: mappedRange)
                result.addAttribute(.paragraphStyle, value: blockquoteParagraphStyle(), range: mappedRange)
            case .listItem(let ordered, let checkbox):
                // Apply indentation to the full line
                let lineStart: Int
                if !ordered {
                    lineStart = mappedRange.location - 2  // "• " or checkbox was inserted
                } else {
                    lineStart = mappedOffset(span.fullRange.location, removals: removals)
                }
                let lineEnd = mappedRange.upperBound
                if lineStart >= 0 && lineEnd <= result.length {
                    let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                    result.addAttribute(.paragraphStyle, value: listParagraphStyle(), range: lineRange)
                }
                if !ordered {
                    // Dim the bullet/checkbox
                    let bulletRange = NSRange(location: mappedRange.location - 2, length: 2)
                    if bulletRange.location >= 0 && bulletRange.upperBound <= result.length {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: bulletRange)
                    }
                    // Strikethrough checked items
                    if checkbox == .checked {
                        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: mappedRange)
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: mappedRange)
                    }
                } else {
                    // Dim the number/marker
                    for dr in span.delimiterRanges {
                        let drStart = mappedOffset(dr.location, removals: removals)
                        let drEnd = mappedOffset(dr.upperBound, removals: removals)
                        let mappedDR = NSRange(location: drStart, length: max(0, drEnd - drStart))
                        if mappedDR.location >= 0 && mappedDR.upperBound <= result.length {
                            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: mappedDR)
                        }
                    }
                }
            case .thematicBreak:
                // The divider text was inserted earlier; apply dim color to it.
                let fullStart = mappedOffset(span.fullRange.location, removals: removals)
                let fullEnd = mappedOffset(span.fullRange.upperBound, removals: removals)
                let mappedFull = NSRange(location: fullStart, length: max(0, fullEnd - fullStart))
                if mappedFull.upperBound <= result.length {
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: mappedFull)
                }
            }
        }

        return result
    }

    /// Maps an offset in the original text to the stripped/modified text.
    private func mappedOffset(_ original: Int, removals: [(location: Int, length: Int)]) -> Int {
        var shift = 0
        for r in removals {
            if original > r.location {
                shift += r.length
            }
        }
        return original - shift
    }
}

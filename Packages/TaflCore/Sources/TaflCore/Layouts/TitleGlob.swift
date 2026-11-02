import Foundation

public enum TitleGlob {
    private enum Token {
        case star
        case anyCharacter
        case literal(Character)
    }

    public static func matches(_ pattern: String, _ title: String) -> Bool {
        let tokens = tokenize(fold(pattern))
        let text = Array(fold(title))
        var tokenIndex = 0
        var textIndex = 0
        var starToken: Int?
        var starText = 0
        while textIndex < text.count {
            if tokenIndex < tokens.count {
                switch tokens[tokenIndex] {
                case .star:
                    starToken = tokenIndex
                    starText = textIndex
                    tokenIndex += 1
                    continue
                case .anyCharacter:
                    tokenIndex += 1
                    textIndex += 1
                    continue
                case .literal(let character) where character == text[textIndex]:
                    tokenIndex += 1
                    textIndex += 1
                    continue
                case .literal:
                    break
                }
            }
            guard let star = starToken else { return false }
            starText += 1
            textIndex = starText
            tokenIndex = star + 1
        }
        return tokens[tokenIndex...].allSatisfy { if case .star = $0 { true } else { false } }
    }

    public static func escape(_ title: String) -> String {
        var escaped = ""
        for character in title {
            if character == "\\" || character == "*" || character == "?" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil)
    }

    private static func tokenize(_ pattern: String) -> [Token] {
        var tokens: [Token] = []
        var characters = pattern.makeIterator()
        while let character = characters.next() {
            switch character {
            case "*": tokens.append(.star)
            case "?": tokens.append(.anyCharacter)
            case "\\": tokens.append(.literal(characters.next() ?? "\\"))
            default: tokens.append(.literal(character))
            }
        }
        return tokens
    }
}

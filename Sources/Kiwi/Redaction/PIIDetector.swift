import Foundation

/// Kinds of sensitive text Kiwi can find and cover.
enum PIICategory: String, CaseIterable, Identifiable {
    case email
    case phone
    case card
    case nationalID
    case secret
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .email: return "Email addresses"
        case .phone: return "Phone numbers"
        case .card: return "Payment card numbers"
        case .nationalID: return "National IDs (CPF, RG, SSN)"
        case .secret: return "Passwords, API keys and tokens"
        case .network: return "IP and MAC addresses"
        }
    }
}

struct PIIMatch {
    let range: Range<String.Index>
    let category: PIICategory
}

/// Finds sensitive substrings in a line of text with patterns and checksums.
/// Everything runs locally; nothing is logged or stored.
enum PIIDetector {
    private struct Rule {
        let category: PIICategory
        let regex: NSRegularExpression
        /// Capture group holding the sensitive part (0 = whole match).
        let group: Int
        let validate: ((String) -> Bool)?
    }

    private static func rule(
        _ category: PIICategory,
        _ pattern: String,
        group: Int = 0,
        validate: ((String) -> Bool)? = nil
    ) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            assertionFailure("Invalid PII pattern: \(pattern)")
            return nil
        }
        return Rule(category: category, regex: regex, group: group, validate: validate)
    }

    private static let rules: [Rule] = [
        // Email
        rule(.email, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),

        // Payment cards: 13 to 19 digits, optionally grouped, passing the Luhn check.
        rule(.card, #"(?<![\d.])(?:\d[ \-]?){12,18}\d(?![\d.])"#, validate: { PIIChecks.luhn($0) }),

        // US Social Security number.
        rule(.nationalID, #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#),
        // Brazilian CPF, formatted or bare, passing its check digits.
        rule(.nationalID, #"(?<![\d.])\d{3}\.?\d{3}\.?\d{3}-?\d{2}(?![\d.])"#, validate: { PIIChecks.cpf($0) }),
        // Brazilian RG. It has no national format or checksum, so it is recognised three ways:
        // the classic dotted shape with a check digit, a number announced by a label,
        // and a number followed by its issuing body (SSP, SDS, DETRAN...).
        rule(.nationalID, #"(?<![\d.])\d{1,2}\.\d{3}\.\d{3}-[\dXx](?![\dA-Za-z])"#),
        rule(
            .nationalID,
            #"(?i)(?<![A-Za-z])(?:RG|R\.G\.?|identidade|registro\s+geral)(?![A-Za-z])\D{0,15}?(\d[\d.]{4,11}(?:-[\dXx])?)"#,
            group: 1
        ),
        rule(
            .nationalID,
            #"(?<![\d.])(\d{1,2}\.?\d{3}\.?\d{3}(?:-?[\dXx])?)\s*(?:SSP|SDS|SESP|SEJUSP|SESDS|DETRAN|IGP|IFP)(?![A-Za-z])"#,
            group: 1
        ),

        // Phone numbers: international prefix, Brazilian and North American shapes.
        rule(.phone, #"(?<![\w+])\+\d{1,3}[ \-.]?(?:\(?\d{1,4}\)?[ \-.]?){2,4}\d{2,4}(?!\d)"#),
        rule(.phone, #"(?<![\w(])\(\d{2}\)[ \-]?9?\d{4}[ \-]?\d{4}(?!\d)"#),
        rule(.phone, #"(?<![\d.\-])\d{2} 9\d{4}-\d{4}(?!\d)"#),
        rule(.phone, #"(?<![\w(])\(\d{3}\)[ \-.]?\d{3}[ \-.]\d{4}(?!\d)"#),
        rule(.phone, #"(?<![\d.\-])\d{3}[\-.]\d{3}[\-.]\d{4}(?![\d.\-])"#),

        // Well-known credential formats.
        rule(.secret, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),                                   // AWS access key ID
        rule(.secret, #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),                                     // GitHub token
        rule(.secret, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#),                                   // GitHub fine-grained token
        rule(.secret, #"\bglpat-[A-Za-z0-9_\-]{18,}"#),                                      // GitLab token
        rule(.secret, #"\bxox[abeoprs]-[A-Za-z0-9\-]{10,}"#),                                // Slack token
        rule(.secret, #"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#),                           // Stripe key
        rule(.secret, #"\bAIza[0-9A-Za-z_\-]{30,}"#),                                        // Google API key
        rule(.secret, #"\bsk-[A-Za-z0-9_\-]{20,}"#),                                         // OpenAI / Anthropic style key
        rule(.secret, #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#), // JSON Web Token
        rule(.secret, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),                               // private key header
        rule(.secret, #"\b[Bb]earer\s+([A-Za-z0-9._~+/\-]{20,}=*)"#, group: 1),              // bearer token
        // key = value, password: value, and friends. Only the value is covered.
        rule(
            .secret,
            #"(?i)\b(?:password|passwd|pwd|secret|token|api[_\-]?key|access[_\-]?key|client[_\-]?secret|senha|chave)\b["']?\s*[:=]\s*["']?([^\s"',;]{6,})"#,
            group: 1
        ),
        // Long hex strings (hashes, raw keys) and long mixed-case random strings.
        rule(.secret, #"(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])"#, validate: { PIIChecks.hasDigitAndLetter($0) }),
        rule(.secret, #"(?<![A-Za-z0-9+_\-])[A-Za-z0-9+_\-]{40,}={0,2}"#, validate: { PIIChecks.looksRandom($0) }),

        // Network identifiers.
        rule(.network, #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d|\.\d)"#),
        rule(.network, #"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:])"#),
        rule(.network, #"(?<![0-9A-Fa-f:\-])(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:\-])"#),
    ].compactMap { $0 }

    // On ID cards and forms the caption and the number often sit on separate
    // lines, so the scanner also asks about a line and the one after it.
    private static let idLabelPattern = #"(?i)^\W*(?:RG|R\.G\.?|registro\s+geral|(?:carteira\s+de\s+)?identidade|doc(?:umento)?\.?\s+(?:de\s+)?identidade|n[ºo°.]{0,2}\s*(?:do\s+)?(?:RG|registro)|CPF|CNH|SSN|social\s+security(?:\s+number)?)\W*$"#
    private static let idNumberPattern = #"^\W*\d[\d.\-/ ]{3,18}[\dXx]\W*$"#
    private static let idLabel = try? NSRegularExpression(pattern: idLabelPattern, options: [])
    private static let idNumber = try? NSRegularExpression(pattern: idNumberPattern, options: [])

    private static func matchesWhole(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: whole) != nil
    }

    /// True when a line is only the caption of an ID field ("RG", "Registro Geral", "CPF"...).
    static func isIDLabel(_ text: String) -> Bool {
        matchesWhole(idLabel, text)
    }

    /// True when a line is nothing but an ID-shaped number.
    static func looksLikeIDNumber(_ text: String) -> Bool {
        guard matchesWhole(idNumber, text) else { return false }
        return text.filter(\.isNumber).count >= 5
    }

    private static let phoneDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )

    /// All sensitive ranges in `text` for the enabled categories, merged where they overlap.
    static func matches(in text: String, categories: Set<PIICategory>) -> [PIIMatch] {
        guard !text.isEmpty, !categories.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [PIIMatch] = []

        for rule in rules where categories.contains(rule.category) {
            for result in rule.regex.matches(in: text, options: [], range: whole) {
                let nsRange = result.range(at: rule.group)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { continue }
                if let validate = rule.validate, !validate(String(text[range])) { continue }
                found.append(PIIMatch(range: range, category: rule.category))
            }
        }

        if categories.contains(.phone), let phoneDetector {
            for result in phoneDetector.matches(in: text, options: [], range: whole) {
                guard let range = Range(result.range, in: text) else { continue }
                // Data detectors are generous; require a believable number of digits.
                let digits = text[range].filter(\.isNumber).count
                if digits >= 8, digits <= 15 {
                    found.append(PIIMatch(range: range, category: .phone))
                }
            }
        }

        return merge(found)
    }

    private static func merge(_ matches: [PIIMatch]) -> [PIIMatch] {
        let sorted = matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [PIIMatch] = []
        for match in sorted {
            if let last = merged.last, match.range.lowerBound <= last.range.upperBound {
                let upper = max(last.range.upperBound, match.range.upperBound)
                merged[merged.count - 1] = PIIMatch(range: last.range.lowerBound..<upper, category: last.category)
            } else {
                merged.append(match)
            }
        }
        return merged
    }
}

enum PIIChecks {
    private static func digits(_ text: String) -> [Int] {
        text.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
    }

    /// Luhn checksum over the digits in `text` (13 to 19 digits).
    static func luhn(_ text: String) -> Bool {
        let numbers = digits(text)
        guard numbers.count >= 13, numbers.count <= 19 else { return false }
        guard Set(numbers).count > 1 else { return false }
        var sum = 0
        for (offset, digit) in numbers.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Brazilian CPF check digits.
    static func cpf(_ text: String) -> Bool {
        let numbers = digits(text)
        guard numbers.count == 11, Set(numbers).count > 1 else { return false }

        func checkDigit(_ count: Int) -> Int {
            var sum = 0
            for index in 0..<count {
                sum += numbers[index] * (count + 1 - index)
            }
            let remainder = (sum * 10) % 11
            return remainder == 10 ? 0 : remainder
        }
        return checkDigit(9) == numbers[9] && checkDigit(10) == numbers[10]
    }

    static func hasDigitAndLetter(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
    }

    /// True for long strings that mix cases and digits the way generated keys do.
    static func looksRandom(_ text: String) -> Bool {
        let hasDigit = text.contains(where: \.isNumber)
        let hasUpper = text.contains(where: \.isUppercase)
        let hasLower = text.contains(where: \.isLowercase)
        return hasDigit && hasUpper && hasLower
    }
}

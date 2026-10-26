#!/usr/bin/env python3
"""Log-privacy guard for Swift sources, stdlib only.

Every interpolation in a PortsLog call states its privacy, identifying values are never public, and nothing logs
around PortsLog. The name check is a heuristic: a reviewer marks a false positive with '// log-privacy: reviewed'
on the reported line. Usage: check-log-privacy.py <Sources> | --self-test
"""
import bisect
import pathlib
import re
import sys

LOG_CALL = re.compile(r"\bPortsLog\s*\.\s*\w+\s*\.\s*(?:trace|debug|info|notice|warning|error|critical|fault|log)\s*\(")
DIRECT_OUTPUT = re.compile(r"(?<![\w.])(print|NSLog|os_log)\(")
LOGGER = re.compile(r"(?<![\w.])Logger\(")
STRING_START = re.compile(r'(#*)("""|")')
PRIVACY = re.compile(r"privacy\s*:\s*(.*)", re.S)
SENSITIVE = re.compile(
    r"path|directory|command|argument|argv|executable|url|origin|project|name|message|environment"
    r"|localizedDescription",
    re.I,
)
REVIEWED = "// log-privacy: reviewed"


def lex(text):
    """Blanks comments and literal text (keeping newlines) and returns (masked, interpolation spans).

    Code inside an interpolation stays visible, so parentheses balance over code only and a literal like
    "sad :(" cannot swallow the rest of the file.
    """
    masked = list(text)
    interpolations = []

    def blank(start, end):
        for k in range(start, end):
            if masked[k] != "\n":
                masked[k] = " "

    def block_comment(i):
        depth, j = 0, i
        while j < len(text):
            if text.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif text.startswith("*/", j):
                depth, j = depth - 1, j + 2
                if depth == 0:
                    break
            else:
                j += 1
        blank(i, j)
        return j

    def literal(i, match):
        hashes, quotes = match.groups()
        escape, closing, start, j = "\\" + hashes, quotes + hashes, i, match.end()
        while j < len(text):
            if text.startswith(escape, j):
                k = j + len(escape)
                if text.startswith("(", k):
                    blank(start, k + 1)
                    end = code(k + 1, nested=True)
                    interpolations.append((k + 1, end))
                    start, j = end, end + 1
                else:
                    j = k + 1
            elif text.startswith(closing, j):
                j += len(closing)
                break
            elif quotes == '"' and text[j] == "\n":
                break
            else:
                j += 1
        blank(start, j)
        return j

    def code(i, nested):
        depth = 0
        while i < len(text):
            character = text[i]
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = len(text) if end < 0 else end
                blank(i, end)
                i = end
            elif text.startswith("/*", i):
                i = block_comment(i)
            elif character in '#"' and (match := STRING_START.match(text, i)):
                i = literal(i, match)
            elif character == "(":
                depth, i = depth + 1, i + 1
            elif character == ")":
                if nested and depth == 0:
                    return i
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return i

    code(0, nested=False)
    return "".join(masked), interpolations


def strip_trailing_group(expression):
    depth = 0
    for k in range(len(expression) - 1, -1, -1):
        if expression[k] in ")]}":
            depth += 1
        elif expression[k] in "([{":
            depth -= 1
            if depth == 0:
                return expression[:k]
    return ""


def last_identifier(expression):
    """`url.path(percentEncoded: false)` -> `path`; `services.count` -> `count`; `String(describing: x)` -> `String`."""
    while True:
        expression = expression.rstrip(" \t\n?!")
        if not expression or expression[-1] not in ")]}":
            break
        expression = strip_trailing_group(expression)
    match = re.search(r"\w+$", expression)
    return match.group() if match else ""


def arguments(masked):
    spans, depth, start = [], 0, 0
    for k, character in enumerate(masked):
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == "," and depth == 0:
            spans.append((start, k))
            start = k + 1
    return spans + [(start, len(masked))]


def closing_paren(masked, i):
    depth = 0
    for j in range(i, len(masked)):
        if masked[j] == "(":
            depth += 1
        elif masked[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    return len(masked)


def check(relative, text):
    """Returns sorted (line, reason) findings for one file; `relative` is its path below the Sources root."""
    masked, interpolations = lex(text)
    line_starts = [0] + [m.end() for m in re.finditer("\n", text)]
    lines = text.split("\n")
    findings = []

    def report(position, reason):
        line = bisect.bisect_right(line_starts, position)
        if REVIEWED not in lines[line - 1]:
            findings.append((line, reason))

    parts = pathlib.PurePath(relative).parts
    if "PortsDiagnostics" not in parts[:-1] and parts[-2:] != ("PortsCore", "PortsLog.swift"):
        for match in DIRECT_OUTPUT.finditer(masked):
            report(match.start(), f"{match.group(1)}( outside PortsDiagnostics; log through PortsLog")
        for match in LOGGER.finditer(masked):
            report(match.start(), "Logger( outside PortsLog.swift; use a PortsLog category")
    for call in LOG_CALL.finditer(masked):
        start, end = call.end() - 1, closing_paren(masked, call.end() - 1)
        for first, last in interpolations:
            if not start < first < end:
                continue
            spans = arguments(masked[first:last])
            source = text[first:last].strip()
            labels = [PRIVACY.match(masked[first + a : first + b].strip()) for a, b in spans[1:]]
            privacy = next((label.group(1).strip() for label in labels if label), None)
            if privacy is None:
                report(first, f"interpolation without explicit privacy: \\({source})")
            elif re.match(r"\.public\b", privacy):
                a, b = spans[0]
                if SENSITIVE.search(last_identifier(masked[first + a : first + b])):
                    report(first, f"identifying value marked public: \\({source})")
    return sorted(findings)


SELF_TEST = [
    (
        "PortsCore/ShellEnvironment.swift",
        r'''let key = fingerprint()
let other = environment.fingerprint()
// print("comments are not code")
/* NSLog("nor are /* nested */ block comments") */
let text = "print(\(value)) and Logger( inside a literal"
let raw = #"os_log("x") \#(value)"#
PortsLog.ui.error("Presented error \(context.logKey, privacy: .public): \(message, privacy: .private)")
PortsLog.scan.debug(
    "Scan :( \(services.count, privacy: .public) in \(elapsed, format: .fixed(precision: 1), privacy: .public) ms"
)
PortsLog.launch.notice("Phase \(String(describing: phase), privacy: .public) in \(directory, privacy: .private)")
''',
        [],
    ),
    (
        "PortsApp/MonitorModel.swift",
        r'''PortsLog.scan.error("x \(path)")
PortsLog.launch.notice("Started in \(job.directory, privacy: .public)")
PortsLog.ui.error("Presented error \(context.logName, privacy: .public)")
PortsLog.tunnel.error(
    "Share failed: \(error.localizedDescription, privacy: .public)"
)
PortsLog.scan.error("x \(path)") // log-privacy: reviewed
print("x")
NSLog("x")
os_log("x")
let log = Logger(subsystem: "x", category: "y")
PortsLog.update.info("Sad :( \(version, privacy: .public)")
PortsLog.update.error("Failed \(url.path(percentEncoded: false), privacy: .public)")
''',
        [1, 2, 3, 5, 8, 9, 10, 11, 13],
    ),
    ("PortsDiagnostics/PortsDiagnostics.swift", 'print("ok")\nlet log = Logger(subsystem: "a", category: "b")\n', []),
    ("PortsCore/PortsLog.swift", 'public static let scan = Logger(subsystem: subsystem, category: "scan")\n', []),
]


def self_test():
    failed = False
    for relative, text, expected in SELF_TEST:
        found = check(relative, text)
        if [line for line, _ in found] != expected:
            print(f"self-test {relative}: expected lines {expected}, found {found}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    root = pathlib.Path(argv[0])
    findings = [
        f"{path}:{line}: {reason}"
        for path in sorted(root.rglob("*.swift"))
        for line, reason in check(path.relative_to(root), path.read_text(encoding="utf-8"))
    ]
    for finding in findings:
        print(finding, file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

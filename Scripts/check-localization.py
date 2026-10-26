#!/usr/bin/env python3
"""Localization check for Byte Ports: Python stdlib plus /usr/bin/plutil.

Compares the keys swiftc extracted (-emit-localized-strings) and the literals passed to String sinks with the tables
in Resources/Localization. Legacy text listed in the baseline (one key per line, newline written as \\n and backslash
as \\\\) is tolerated until a step converts it; the baseline may only shrink. docs/LOCALIZATION.md explains each rule.

Usage: check-localization.py --stringsdata DIR --sources DIR [DIR ...] --localizations DIR --info-plist FILE
           --baseline FILE [--write-baseline] [--report] [--strict]
       check-localization.py --self-test
"""
import argparse
import bisect
import collections
import difflib
import json
import os
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ElementTree

# U+201C opens English quotations, so only the German opening quote „ counts.
GERMAN = re.compile("[äöüÄÖÜß„]")
SPECIFIER = re.compile(
    r"%(?:(\d+)\$)?(?:#@(\w+)@|[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?"
    r"([@dDiuUxXoOfFeEgGaAcCsSp%]))"
)
KINDS = {
    **dict.fromkeys("dDiuUxXoO", "integer"),
    **dict.fromkeys("fFeEgGaA", "float"),
    **dict.fromkeys("cC", "character"),
    **dict.fromkeys("sS", "C string"),
    "@": "object",
    "p": "pointer",
}
PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}
TABLE = "Localizable"
# Literals passed straight to these String-typed sinks are invisible to the extractor (E11).
SINKS = re.compile(
    r"(?:\b(?:errorMessage|messageText|informativeText)|\.(?:message|title|prompt|toolTip|placeholderString))\s*=(?!=)"
    r"|\baddButton\(\s*withTitle:|\.(?:scanFailed|launchFailed|failed)\(|\brequestStop\(\s*message:"
    r"|\breport\(|\baccessibilityDescription:"
)
ERROR_TEXT = re.compile(r"\bvar\s+(?:errorDescription|failureReason)\s*:[^{=]*\{")
LOCALIZED_STRING = re.compile(r"\bString\s*\(\s*localized\s*:")
ERROR_TEXT_MODULES = {"PortsCore", "PortsFeatures"}
SWIFT_STRING = re.compile(r'(#*)("""|")')
SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
STRINGS_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|/\*.*?\*/|//[^\n]*|([=;])|\s+|([^\s"=;]+)', re.S)
STRINGS_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}

Literal = collections.namedtuple("Literal", "offset line columns text")
Finding = collections.namedtuple("Finding", "path line rule message")


def specifiers(text):
    """Yields (position, kind, variable) per consumed argument; %% consumes none."""
    sequence = 0
    for match in SPECIFIER.finditer(text):
        position, variable, conversion = match.groups()
        if conversion == "%":
            continue
        if position:
            index = int(position)
        else:
            sequence += 1
            index = sequence
        yield index, KINDS.get(conversion), variable


def signature(text, variables=None):
    """Argument kinds by position, so '%2$lld von %1$@' equals '%@ of %lld' and %d equals %lld."""
    kinds = {}
    for index, kind, variable in specifiers(text):
        if variable is not None:
            kind = (variables or {}).get(variable, "undefined variable")
        if kinds.setdefault(index, kind) != kind:
            kinds[index] = "conflicting"
    return tuple(kinds.get(index, "unused") for index in range(1, max(kinds, default=0) + 1))


def has_letters(text):
    return re.search(r"[^\W\d_]", SPECIFIER.sub("", text)) is not None


def line_starts(text):
    return [0] + [match.end() for match in re.finditer("\n", text)]


def line_of(starts, offset):
    return bisect.bisect_right(starts, offset)


def lex_swift(source):
    """Returns (code, literals): comments and literal text blanked (newlines kept), interpolated code still visible,
    and every string literal in key form, with interpolations written as %@."""
    masked = list(source)
    literals = []
    starts = line_starts(source)

    def blank(start, end):
        for k in range(start, end):
            if masked[k] != "\n":
                masked[k] = " "

    def block_comment(i):
        depth, j = 0, i
        while j < len(source):
            if source.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif source.startswith("*/", j):
                depth, j = depth - 1, j + 2
                if depth == 0:
                    break
            else:
                j += 1
        blank(i, j)
        return j

    def literal(i, match):
        hashes, quotes = match.groups()
        escape, closing = "\\" + hashes, quotes + hashes
        pieces, start, j = [], i, match.end()
        while j < len(source):
            if source.startswith(escape, j):
                k = j + len(escape)
                following = source[k : k + 1]
                if following == "(":
                    blank(start, k + 1)
                    end = code(k + 1, nested=True)
                    pieces.append("%@")
                    # Both interpolation delimiters are blanked, so parentheses balance over code only.
                    start, j = end, end + 1
                elif following == "u" and source.startswith("{", k + 1):
                    close = source.find("}", k)
                    pieces.append(chr(int(source[k + 2 : close], 16)))
                    j = close + 1
                elif following == "\n":
                    j = k + 1
                else:
                    pieces.append(SWIFT_ESCAPES.get(following, following))
                    j = k + 1
            elif source.startswith(closing, j):
                j += len(closing)
                break
            elif quotes == '"' and source[j] == "\n":
                break
            else:
                pieces.append(source[j])
                j += 1
        blank(start, j)
        text = "".join(pieces)
        if quotes == '"""':
            # Drop the opening line break and the closing line's indentation from every line.
            lines = text.split("\n")[1:]
            indentation = lines.pop() if lines and not lines[-1].strip() else ""
            text = "\n".join(line[len(indentation) :] if line.startswith(indentation) else line for line in lines)
        line = line_of(starts, i)
        prefix = source[starts[line - 1] : i]
        literals.append(Literal(i, line, {len(prefix) + 1, len(prefix.encode()) + 1}, text))
        return j

    def code(i, nested):
        depth = 0
        while i < len(source):
            character = source[i]
            if source.startswith("//", i):
                end = source.find("\n", i)
                end = len(source) if end < 0 else end
                blank(i, end)
                i = end
            elif source.startswith("/*", i):
                i = block_comment(i)
            elif character in '#"' and (match := SWIFT_STRING.match(source, i)):
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
    return "".join(masked), literals


def closing(code, i, opening, closer):
    depth = 0
    for j in range(i, len(code)):
        if code[j] == opening:
            depth += 1
        elif code[j] == closer:
            depth -= 1
            if depth == 0:
                return j
    return len(code)


def scan_swift(relative, source, extracted):
    """Returns (sink, error_text, german) literal lists for one file; `extracted` holds the (line, column) pairs the
    compiler extracted, which are localizable even at a sink."""
    code, literals = lex_swift(source)
    by_offset = {literal.offset: literal for literal in literals}
    sink = []
    for match in SINKS.finditer(code):
        offset = match.end()
        while offset < len(source) and source[offset].isspace():
            offset += 1
        literal = by_offset.get(offset)
        if literal and has_letters(literal.text) and not any((literal.line, c) in extracted for c in literal.columns):
            sink.append(literal)
    error_text = []
    if ERROR_TEXT_MODULES.intersection(pathlib.PurePath(relative).parts[:-1]):
        for match in ERROR_TEXT.finditer(code):
            body = (match.end() - 1, closing(code, match.end() - 1, "{", "}"))
            localized = [
                (call.start(), closing(code, code.index("(", call.start()), "(", ")"))
                for call in LOCALIZED_STRING.finditer(code, *body)
            ]
            error_text += [
                literal
                for literal in literals
                if body[0] < literal.offset < body[1]
                and has_letters(literal.text)
                and not any(start < literal.offset < end for start, end in localized)
            ]
    german = [literal for literal in literals if GERMAN.search(literal.text)]
    return sink, error_text, german


def unescape_strings(text):
    def replace(match):
        value = match.group(1)
        if value[0] == "U" and len(value) == 5:
            return chr(int(value[1:], 16))
        if value[0] in "01234567":
            return chr(int(value, 8))
        return STRINGS_ESCAPES.get(value, value)

    return re.sub(r"\\(U[0-9a-fA-F]{4}|[0-7]{1,3}|.)", replace, text, flags=re.S)


def strings_entries(text):
    """Returns ([(key, value, line)], first malformed line or None) for a .strings file. Duplicates are included:
    plutil silently keeps the last one, and its own syntax errors often name the wrong line."""
    starts, tokens = line_starts(text), []
    for match in STRINGS_TOKEN.finditer(text):
        quoted, operator, bare = match.groups()
        if quoted is not None:
            tokens.append(("word", unescape_strings(quoted), match.start()))
        elif bare is not None:
            tokens.append(("word", bare, match.start()))
        elif operator:
            tokens.append((operator, operator, match.start()))
    entries, malformed, i = [], None, 0
    while i < len(tokens):
        kinds = [kind for kind, _, _ in tokens[i : i + 4]]
        if kinds == ["word", "=", "word", ";"]:
            entries.append((tokens[i][1], tokens[i + 2][1], line_of(starts, tokens[i][2])))
            i += 4
        elif kinds[:2] == ["word", ";"]:
            entries.append((tokens[i][1], tokens[i][1], line_of(starts, tokens[i][2])))
            i += 2
        else:
            malformed = malformed or line_of(starts, tokens[i][2])
            i += 1
    return entries, malformed


def plist_duplicates(data):
    """Keys repeated inside one <dict> of an XML plist."""
    duplicates = []
    for element in ElementTree.fromstring(data).iter("dict"):
        seen = set()
        for child in element:
            if child.tag == "key":
                if child.text in seen:
                    duplicates.append(child.text)
                seen.add(child.text)
    return duplicates


def plutil_json(path):
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise ValueError((result.stderr or result.stdout).strip() or "plutil failed")
    return json.loads(result.stdout)


def encode_baseline(key):
    return key.replace("\\", "\\\\").replace("\n", "\\n")


def decode_baseline(line):
    return re.sub(r"\\(.)", lambda match: "\n" if match.group(1) == "n" else match.group(1), line)


def markdown_cell(text):
    return text.replace("|", "\\|").replace("\n", "<br>") if text else ""


class Check:
    def __init__(self, options):
        self.options = options
        self.findings = []
        paths = [*options.sources, options.localizations]
        self.root = pathlib.Path(os.path.commonpath([str(path.resolve()) for path in paths]))

    def flag(self, path, line, rule, message):
        self.findings.append(Finding(self.display(path), line, rule, message))

    def display(self, path):
        path = pathlib.Path(path).resolve()
        return str(path.relative_to(self.root)) if self.root in path.parents else str(path)

    def load_table(self, path, required=True):
        """Parses a table with plutil (E10), reports duplicate keys (E9) and remembers each key's line."""
        if not path.exists():
            if required:
                self.flag(path, 0, "E10", "table is missing")
            return {}
        data = path.read_bytes()
        text = data.decode("utf-8", errors="replace")
        entries, malformed = strings_entries(text) if path.suffix == ".strings" else ([], None)
        try:
            table = plutil_json(path)
        except ValueError as error:
            problem = 'expected "key" = "value";' if malformed else str(error)
            self.flag(path, malformed or 0, "E10", f"plutil cannot read the table: {problem}")
            return {}
        if path.suffix == ".strings":
            seen = {}
            for key, _, line in entries:
                if key in seen:
                    self.flag(path, line, "E9", f"duplicate key {key!r}, first on line {seen[key]}")
                seen.setdefault(key, line)
            self.lines[path] = seen
        elif data.lstrip().startswith(b"<"):
            for key in plist_duplicates(data):
                self.flag(path, 0, "E9", f"duplicate key {key!r}")
            starts = line_starts(text)
            self.lines[path] = {
                ElementTree.fromstring(f"<k>{match.group(1)}</k>").text: line_of(starts, match.start())
                for match in re.finditer(r"^\t?<key>(.*?)</key>", text, re.M)
            }
        return table

    def line(self, path, key):
        return self.lines.get(path, {}).get(key, 0)

    def run(self):
        options, self.lines = self.options, {}
        localizations = pathlib.Path(options.localizations)
        baseline_path = pathlib.Path(options.baseline)
        if options.strict and baseline_path.exists():
            self.flag(baseline_path, 0, "E12", "strict mode allows no baseline: convert the entries and delete it")

        # Extracted keys (E1, E2).
        entries, extracted_at = collections.defaultdict(list), collections.defaultdict(set)
        sources = {}
        for path in sorted(pathlib.Path(options.stringsdata).glob("*.stringsdata")):
            data = json.loads(path.read_text(encoding="utf-8"))
            source = pathlib.Path(data["source"]).resolve()
            sources[source] = path
            for table, items in data.get("tables", {}).items():
                for item in items:
                    line = item.get("location", {}).get("startingLine", 0)
                    if table != TABLE:
                        self.flag(source, line, "E2", f"table {table!r} is not used; drop the table: argument")
                        continue
                    entries[item["key"]].append((source, line, item.get("value")))
                    extracted_at[source].add((line, item.get("location", {}).get("startingColumn", 0)))
        swift_files = sorted(path.resolve() for directory in options.sources for path in directory.rglob("*.swift"))
        for path in swift_files:
            if path not in sources:
                self.flag(path, 0, "E1", "no .stringsdata: the scan is stale or two modules share this file name")

        # Tables (E6, E9, E10).
        de_strings_path = localizations / "de.lproj" / "Localizable.strings"
        de_plurals_path = localizations / "de.lproj" / "Localizable.stringsdict"
        en_plurals_path = localizations / "en.lproj" / "Localizable.stringsdict"
        de_strings = self.load_table(de_strings_path)
        de_plurals = self.load_table(de_plurals_path)
        en_plurals = self.load_table(en_plurals_path)
        english_strings = localizations / "en.lproj" / "Localizable.strings"
        if english_strings.exists():
            self.flag(english_strings, 0, "E6", "English is the source text in code; delete this table")
        for path in sorted(localizations.glob("*.lproj/*")):
            # Hidden files such as Finder's .DS_Store are not packaged; see package-app.sh.
            if path.name.startswith("."):
                continue
            if path.stem not in (TABLE, "InfoPlist") or path.suffix not in (".strings", ".stringsdict"):
                self.flag(path, 0, "E2", "only Localizable tables and InfoPlist.strings are used")
        for key in sorted(set(de_strings) & set(de_plurals)):
            self.flag(de_strings_path, self.line(de_strings_path, key), "E9", f"{key!r} is also in the stringsdict")
        translated = set(de_strings) | set(de_plurals)

        def english(key):
            return next((value for _, _, value in entries[key] if value), key)

        # Literals that bypass the extractor (E11, E16) and German literals (E14).
        sink_literals, error_literals, german_literals = [], [], []
        for path in swift_files:
            sink, error_text, german = scan_swift(
                path.relative_to(self.root) if self.root in path.parents else path,
                path.read_text(encoding="utf-8"),
                extracted_at.get(path, set()),
            )
            sink_literals += [(path, literal) for literal in sink]
            error_literals += [(path, literal) for literal in error_text]
            german_literals += [(path, literal) for literal in german]

        untranslated = {key for key in entries if has_letters(english(key)) and key not in translated}
        legacy = untranslated | {literal.text for _, literal in sink_literals + error_literals}
        baseline, baseline_lines = set(), {}
        if options.write_baseline:
            if baseline_path.exists():
                print(f"{baseline_path} exists; its entries may only be removed", file=sys.stderr)
                return 2
            baseline_path.write_text("".join(encode_baseline(key) + "\n" for key in sorted(legacy)), encoding="utf-8")
            print(f"Wrote {len(legacy)} baseline entries to {baseline_path}", file=sys.stderr)
        if baseline_path.exists() and not options.strict:
            previous = None
            for number, raw in enumerate(baseline_path.read_text(encoding="utf-8").split("\n"), 1):
                if not raw:
                    continue
                key = decode_baseline(raw)
                if key in baseline:
                    self.flag(baseline_path, number, "E12", f"duplicate entry {key!r}")
                elif previous is not None and raw < previous:
                    self.flag(baseline_path, number, "E12", "keep the baseline sorted")
                baseline.add(key)
                baseline_lines.setdefault(key, number)
                previous = raw

        # E3, E4: new keys need German and must be English.
        unused = sorted((set(de_strings) | set(de_plurals) | set(en_plurals)) - set(entries))
        for key in sorted(entries, key=lambda key: (str(entries[key][0][0]), entries[key][0][1])):
            if key in baseline:
                continue
            text = english(key)
            if GERMAN.search(key) or GERMAN.search(text):
                for source, line, _ in entries[key]:
                    self.flag(source, line, "E4", f"key {key!r} is German; write the English source text")
            elif key in untranslated:
                hint = difflib.get_close_matches(key, unused, n=1)
                rename = f" (renamed from {hint[0]!r}?)" if hint else ""
                for source, line, _ in entries[key]:
                    self.flag(source, line, "E3", f"no German entry for {key!r}{rename}")

        # E5: unused entries.
        for path, table in (
            (de_strings_path, de_strings),
            (de_plurals_path, de_plurals),
            (en_plurals_path, en_plurals),
        ):
            for key in sorted(set(table) - set(entries)):
                self.flag(path, self.line(path, key), "E5", f"{key!r} is not used in code; delete or rename it")

        # E7, E8: plural rules and argument types.
        for key in sorted(set(de_strings) & set(entries)):
            value = de_strings[key]
            if signature(value) != signature(english(key)):
                self.flag(
                    de_strings_path,
                    self.line(de_strings_path, key),
                    "E8",
                    f"{key!r} takes {signature(english(key))} but the German text uses {signature(value)}",
                )
        for path, table, other in (
            (de_plurals_path, de_plurals, en_plurals),
            (en_plurals_path, en_plurals, de_plurals),
        ):
            for key in sorted(set(table) - set(other)):
                self.flag(path, self.line(path, key), "E7", f"{key!r} needs plural rules in both languages")
            for key, rule in sorted(table.items()):
                self.check_plural(path, key, rule, english(key) if key in entries else None)

        # E11, E12, E14, E16.
        for path, literal in sink_literals:
            if literal.text not in baseline:
                self.flag(
                    path, literal.line, "E11", f"literal {literal.text!r} reaches a String sink; use String(localized:)"
                )
        for path, literal in error_literals:
            if literal.text not in baseline:
                self.flag(path, literal.line, "E16", f"error text {literal.text!r} must be String(localized:comment:)")
        for key in sorted(baseline):
            if key in translated:
                self.flag(baseline_path, baseline_lines[key], "E12", f"{key!r} is translated; remove it")
            elif key not in legacy:
                self.flag(baseline_path, baseline_lines[key], "E12", f"{key!r} is no longer used; remove it")
        if options.strict:
            for path, literal in german_literals:
                self.flag(path, literal.line, "E14", f"German text in a Swift literal: {literal.text!r}")

        # E13: usage descriptions shown by macOS need both languages.
        info = self.load_table(pathlib.Path(options.info_plist))
        descriptions = sorted(key for key in info if key.endswith("UsageDescription"))
        for language in ("de", "en"):
            path = localizations / f"{language}.lproj" / "InfoPlist.strings"
            table = self.load_table(path, required=False)
            for key in descriptions:
                if key not in table:
                    self.flag(path, 0, "E13", f"{key} needs an entry in this table")

        if options.report:
            self.print_report(entries, de_strings, de_plurals, baseline, sink_literals + error_literals)
        for finding in sorted(self.findings):
            print(f"{finding.path}:{finding.line}: {finding.rule}: {finding.message}", file=sys.stderr)
        if self.findings:
            print(f"Localization check failed with {len(self.findings)} findings.", file=sys.stderr)
            return 1
        print(
            f"Localization check passed: {len(entries)} keys, {len(translated)} German entries, "
            f"{len(baseline)} baseline entries.",
            file=sys.stderr,
        )
        return 0

    def check_plural(self, path, key, rule, text):
        line = self.line(path, key)
        if not isinstance(rule, dict) or not isinstance(rule.get("NSStringLocalizedFormatKey"), str):
            self.flag(path, line, "E7", f"{key!r} needs an NSStringLocalizedFormatKey")
            return
        format_key, bound, kinds = rule["NSStringLocalizedFormatKey"], {}, {}
        for index, _, variable in specifiers(format_key):
            if variable is None:
                continue
            if variable in bound or index in bound.values():
                self.flag(path, line, "E7", f"{key!r} needs one plural variable per argument")
            bound[variable] = index
        for variable in bound:
            spec = rule.get(variable)
            if not isinstance(spec, dict):
                self.flag(path, line, "E7", f"{key!r} does not define the variable {variable!r}")
                continue
            value_type = spec.get("NSStringFormatValueTypeKey")
            match = SPECIFIER.fullmatch(f"%{value_type}") if isinstance(value_type, str) else None
            if spec.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType" or not match:
                self.flag(path, line, "E7", f"{variable!r} in {key!r} needs NSStringPluralRuleType and a value type")
                continue
            if "other" not in spec:
                self.flag(path, line, "E7", f"{variable!r} in {key!r} needs an 'other' form")
            kinds[variable] = KINDS.get(match.group(3))
            arguments = dict(enumerate(signature(text), 1)) if text is not None else {}
            for form, variant in spec.items():
                if form not in PLURAL_FORMS:
                    continue
                # A plain specifier prints this variable; a positional one may print any argument of the key.
                for position, nested, conversion in (found.groups() for found in SPECIFIER.finditer(variant)):
                    if nested or conversion == "%":
                        continue
                    expected = arguments.get(int(position)) if position else kinds[variable]
                    if KINDS.get(conversion) != expected:
                        self.flag(
                            path,
                            line,
                            "E8",
                            f"the {form!r} form of {key!r} uses {KINDS.get(conversion)}, not {expected}",
                        )
        unused = set(rule) - {"NSStringLocalizedFormatKey"} - set(bound)
        if unused:
            self.flag(path, line, "E7", f"{key!r} defines unused variables {sorted(unused)}")
        if text is not None and signature(format_key, kinds) != signature(text):
            self.flag(
                path,
                line,
                "E8",
                f"{key!r} takes {signature(text)} but the rule uses {signature(format_key, kinds)}",
            )

    def print_report(self, entries, de_strings, de_plurals, baseline, literals):
        print("| Key | English | German | Location | Note |\n| --- | --- | --- | --- | --- |")
        rows = []
        for key, places in entries.items():
            text = next((value for _, _, value in places if value), key)
            if not has_letters(text):
                continue
            if key in de_plurals:
                german = " · ".join(
                    f"{form}: {variant}"
                    for spec in de_plurals[key].values()
                    if isinstance(spec, dict)
                    for form, variant in spec.items()
                    if form in PLURAL_FORMS
                )
            else:
                german = de_strings.get(key, "")
            if key in baseline:
                note = "baseline"
            elif not german:
                note = "missing"
            else:
                note = "identical" if german == text else ""
            source, line, _ = places[0]
            more = f" (+{len(places) - 1})" if len(places) > 1 else ""
            rows.append((self.display(source), line, key, text if text != key else "", german, note + more))
        for path, literal in literals:
            if literal.text in baseline:
                rows.append((self.display(path), literal.line, literal.text, "", "", "baseline (not extracted)"))
        for path, line, key, text, german, note in sorted(rows):
            cells = (key, text, german, f"{path}:{line}", note)
            print("| " + " | ".join(markdown_cell(cell) for cell in cells) + " |")


SELF_TEST_SWIFT = r'''alert.messageText = "Es läuft noch ein Dienst."
alert.informativeText =
    "Second line"
// errorMessage = "commented out"
model.errorMessage = String(localized: "Could not save.")
panel.title = ""
model.report("Copied", as: .copy)
let text = "errorMessage = \(value)"
throw MonitorError.scanFailed("Die Liste \(name) fehlt.")
if title == "Stop" {}
public var errorDescription: String? {
    switch self {
    case .one: "Plain text"
    case .two(let code): String(localized: "Failed (\(code)).", comment: "x")
    case .three(let code): "\(code)"
    case .four: #"Raw \#(value) text"#
    }
}
let multi = """
    Erster „Absatz“
      eingerückt
    """
'''


def self_test():
    failures = []

    def expect(name, actual, expected):
        if actual != expected:
            failures.append(f"{name}: expected {expected!r}, found {actual!r}")

    expect("English quotes", bool(GERMAN.search("“%@” is already running.")), False)
    expect("German quotes", bool(GERMAN.search("„%@“ läuft")), True)
    expect("positional", signature("%2$lld von %1$@"), ("object", "integer"))
    expect("sequential", signature("%@ of %lld"), ("object", "integer"))
    expect("integer widths", signature("%d %i %ld %lld"), ("integer",) * 4)
    expect("dropped argument", signature("Läuft") == signature("%@ läuft"), False)
    expect("percent", signature("100 %% fertig"), ())
    expect("variable", signature("%#@seconds@", {"seconds": "integer"}), ("integer",))
    expect("letters", [has_letters(t) for t in ("%lld", "%@ · %1$@", "", "Stop %@")], [False, False, False, True])
    expect("baseline", decode_baseline(encode_baseline("A\\n\nB")), "A\\n\nB")
    strings = '/* "Fake" = "Kommentar"; */\n"Copy" = "Kopieren";\n'
    strings += '"Say \\"hi\\"\\n" = "Sag „hi“";\n"Copy" = "Kopie";\n'
    expect(
        "strings entries",
        [(key, line) for key, _, line in strings_entries(strings)[0]],
        [("Copy", 2), ('Say "hi"\n', 3), ("Copy", 4)],
    )
    expect("missing semicolon", strings_entries('"A" = "B";\n"C" = "D"\n"E" = "F";\n')[1], 2)
    plist = b"<plist><dict><key>a</key><dict><key>x</key><string/><key>x</key><string/></dict></dict></plist>"
    expect("plist duplicates", plist_duplicates(plist), ["x"])
    extracted = {(7, 14)}
    sink, error_text, german = scan_swift("PortsCore/Errors.swift", SELF_TEST_SWIFT, extracted)
    expect(
        "sink",
        [(literal.line, literal.text) for literal in sink],
        [(1, "Es läuft noch ein Dienst."), (3, "Second line"), (9, "Die Liste %@ fehlt.")],
    )
    expect(
        "error text",
        [(literal.line, literal.text) for literal in error_text],
        [(13, "Plain text"), (16, "Raw %@ text")],
    )
    german_texts = ["Es läuft noch ein Dienst.", "Erster „Absatz“\n  eingerückt"]
    expect("German", [literal.text for literal in german], german_texts)
    expect("error text outside Core", scan_swift("PortsApp/Errors.swift", SELF_TEST_SWIFT, extracted)[1], [])
    for failure in failures:
        print(f"self-test {failure}", file=sys.stderr)
    return 1 if failures else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stringsdata", required=True, type=pathlib.Path)
    parser.add_argument("--sources", required=True, nargs="+", type=pathlib.Path)
    parser.add_argument("--localizations", required=True, type=pathlib.Path)
    parser.add_argument("--info-plist", required=True, type=pathlib.Path)
    parser.add_argument("--baseline", required=True, type=pathlib.Path)
    parser.add_argument("--write-baseline", action="store_true", help="create the baseline once")
    parser.add_argument("--report", action="store_true", help="print a Markdown review table to stdout")
    parser.add_argument("--strict", action="store_true", help="no baseline and no German text in Swift literals")
    return Check(parser.parse_args(argv)).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

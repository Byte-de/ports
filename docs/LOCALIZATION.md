# Localization

Byte Ports ships in English and German and follows the macOS language, including the per-app language in
System Settings › General › Language & Region › Applications. English is the development language: the text written in
code is both the English copy and the lookup key. German comes from `Resources/Localization/de.lproj`. Every other
language falls back to English.

## How it works

- The tables are classic `Localizable.strings` and `Localizable.stringsdict` files. String Catalogs need
  `xcstringstool`, which the Command Line Tools do not ship.
- `Resources/Localization/de.lproj/Localizable.strings` holds the German text.
  `de.lproj/Localizable.stringsdict` and `en.lproj/Localizable.stringsdict` hold the plural rules.
  `en.lproj/Localizable.strings` must not exist, because the English text is the key.
- `Scripts/package-app.sh` copies the `*.strings` and `*.stringsdict` tables of each `.lproj` folder into `Contents/Resources` and converts them to binary plists.
  Never place resource bundles at the `.app` root: codesign rejects them there.
- Every lookup goes through `Bundle.main`: SwiftUI's default, `LocalizedStringResource` and `String(localized:)`.
  Never use `Bundle.module` or a `bundle:` argument, and do not declare resources in `Package.swift`.
- Without the packaged app (`swift run`, `swift test`, `ports-diagnostics`) there are no tables, so text is English.
  Tests therefore expect the English source text.

## Rules for copy

1. Write every new or changed user-facing string as an English literal in a localizable API: SwiftUI `Text`,
   `Button`, `Label`, `Toggle`, `Picker`, `Link`, `.help`, `.accessibilityLabel`, a `LocalizedStringResource`
   parameter, or `String(localized: "…", comment: "…")` where a `String` is required.
2. Add the German translation to `de.lproj/Localizable.strings` in the same commit, in the section of the file that
   uses the key (see [Table layout](#table-layout)).
3. Plurals use one interpolated literal per count, such as `Text("\(count) seconds")` (key `%lld seconds`), with
   rules in both stringsdicts. Never write `count == 1 ? … : …`.
4. Never build sentences from fragments. Interpolate whole values into one sentence instead.
5. These forms are silently shown verbatim and never translated:
   - `Text(condition ? "literal" : stringVariable)`
   - `Text(optional ?? "literal")`
   - `LocalizedStringKey(expression)`
6. Text that is not copy uses `Text(verbatim:)` or a format style, such as `Text(count, format: .number)`. Pass ports
   and PIDs as `String(value)` and the brand as `AppInfo.name`.
7. Everything typed as `String` needs `String(localized:comment:)`. Examples are `NSAlert` `messageText`,
   `informativeText` and `addButton(withTitle:)`, window and panel titles, tool tips, prompts, placeholder strings,
   `accessibilityDescription:`, and `LocalizedError.errorDescription` and `failureReason`. Error alerts go through
   `report(_:as:)`, which takes an `Error` or a `LocalizedStringResource` literal and an `ErrorContext` for the title.
8. Never localize `PortsLog` messages, `ports-diagnostics` output, TunnelRunner stderr, cloudflared output, product
   and framework names, commands, paths, ports, PIDs or URLs.
9. Context-dependent short labels use an explicit key with an English default value, because one key has exactly one
   translation and comments never tell two uses apart. This applies to **Stop, Open, Quit, Running, Paused and
   Close**:

   ```swift
   Button(LocalizedStringResource("job.stop", defaultValue: "Stop", comment: "Stops a launched action")) { stop() }
   String(localized: "share.stop", defaultValue: "Stop", comment: "Ends a public share")
   ```

   The German entry uses the explicit key: `"job.stop" = "Stoppen";`. Explicit keys are dotted lower camel case
   paths, such as `job.stop` or `quitPanel.forceQuit`. The check reads the English text from the default value.

German uses the informal „du“, „…“ quotes and the … ellipsis. English uses “…” quotes and ends commands that open a
dialog with ….

## Table layout

Each table has one section per source file that owns keys, in alphabetical order, plus a `Shared` section first for
keys used by several files. Entries are sorted within their section. A change edits only the sections of the files it
touches, so parallel branches merge cleanly. A new source file adds its section at its alphabetical position.

```
/* MARK: Shared */

/* MARK: Sources/PortsApp/PreferencesView.swift */
"Automatic detection" = "Automatische Erkennung";
```

The stringsdicts use the same sections as XML comments (`<!-- MARK: Sources/PortsApp/PreferencesView.swift -->`).

## Plural rules

Add the same key to both stringsdicts. One count:

```xml
<key>%lld seconds</key>
<dict>
	<key>NSStringLocalizedFormatKey</key>
	<string>%#@seconds@</string>
	<key>seconds</key>
	<dict>
		<key>NSStringFormatSpecTypeKey</key>
		<string>NSStringPluralRuleType</string>
		<key>NSStringFormatValueTypeKey</key>
		<string>lld</string>
		<key>one</key>
		<string>%lld Sekunde</string>
		<key>other</key>
		<string>%lld Sekunden</string>
	</dict>
</dict>
```

Two counts, from `Text("\(agents) agents · \(servers) servers")`, use one plural variable per argument with
positions:

```xml
<key>%lld agents · %lld servers</key>
<dict>
	<key>NSStringLocalizedFormatKey</key>
	<string>%1$#@agents@ · %2$#@servers@</string>
	<key>agents</key>
	<dict>
		<key>NSStringFormatSpecTypeKey</key>
		<string>NSStringPluralRuleType</string>
		<key>NSStringFormatValueTypeKey</key>
		<string>lld</string>
		<key>one</key>
		<string>%lld Agent</string>
		<key>other</key>
		<string>%lld Agenten</string>
	</dict>
	<key>servers</key>
	<dict>
		<key>NSStringFormatSpecTypeKey</key>
		<string>NSStringPluralRuleType</string>
		<key>NSStringFormatValueTypeKey</key>
		<string>lld</string>
		<key>one</key>
		<string>%lld Server</string>
		<key>other</key>
		<string>%lld Server</string>
	</dict>
</dict>
```

## Missing-translation check

`Scripts/check.sh` runs the checker's self-test and then `Scripts/check-localization.sh`, so CI and `release.sh`
enforce it. The script builds `BytePorts` from scratch in `$PORTS_BUILD_DIR/localization` with
`-emit-localized-strings`, because the compiler emits keys only for files it recompiles. It then runs
`Scripts/check-localization.py`, which compares the extracted keys with the tables. Extra arguments are passed on:

- `--report` prints a Markdown table of every key with its German text, location and status, for copy review.
- `--strict` forbids the baseline and German text in Swift literals. Strict mode is switched on once the legacy text
  is converted.
- `--write-baseline` creates the baseline. It refuses to overwrite an existing one.

| Rule | Fails when |
| --- | --- |
| E1 | A Swift file in `Sources/PortsApp`, `PortsCore` or `PortsFeatures` has no `.stringsdata`: the scan is stale, or two modules share a file name. |
| E2 | Code uses a table other than `Localizable`, or a `.lproj` folder holds another non-hidden file. |
| E3 | An extracted key with letters, outside the baseline, has no German entry. The message suggests a renamed entry. |
| E4 | A key outside the baseline contains German (`ä ö ü Ä Ö Ü ß „`). The English “ is allowed. |
| E5 | A German or plural entry is not used in code. |
| E6 | `en.lproj/Localizable.strings` exists. |
| E7 | The stringsdicts differ in keys, or a rule lacks `NSStringPluralRuleType`, a value type, an `other` form or one variable per argument. |
| E8 | A translation or plural rule uses other argument types than its key. `%d`, `%i`, `%ld` and `%lld` all count as integers, and positions are normalized. |
| E9 | A key appears twice in a table. plutil silently keeps the last one. |
| E10 | plutil cannot read a table, for example because a semicolon is missing. |
| E11 | A literal with letters goes straight into a `String` sink that the compiler cannot see: `errorMessage =`, `messageText =`, `informativeText =`, `addButton(withTitle:`, `.scanFailed(`, `.launchFailed(`, `.failed(`, `requestStop(message:`, `.message =`, `.title =`, `.prompt =`, `.toolTip =`, `.placeholderString =`, `report(` or `accessibilityDescription:`. Extracted literals pass. |
| E12 | A baseline entry is stale, already translated, duplicated or out of order. In strict mode, the baseline exists at all. |
| E13 | An `*UsageDescription` key in `Info.plist` lacks an entry in `de.lproj` or `en.lproj/InfoPlist.strings`. |
| E14 | Strict mode only: a Swift string literal contains German. |
| E16 | In PortsCore or PortsFeatures, `errorDescription` or `failureReason` returns a literal with letters that is not wrapped in `String(localized:)`. |

## Baseline

`Scripts/localization-baseline.txt` lists the legacy German text that existed when the check was introduced. It has
one key per line, sorted, with a line break written as `\n` and a backslash as `\\`. Entries may only be removed:
when you convert a text, delete its line in the same commit. The check reports entries that are stale or already
translated. Never add entries. Rebase onto changes to the baseline rather than merging them.

## Testing

- `Scripts/check.sh`, or `Scripts/check-localization.sh` alone, which takes about 35 seconds.
- `LocalizationTableTests` loads the tables from `Resources/Localization` with `Bundle(url:)` and checks plural
  rules through `LocalizationTable.format`. Each step keeps its plural tests in its own test file.
- In the packaged app:

  ```sh
  Scripts/build-app.sh /tmp/BytePorts.app
  /tmp/BytePorts.app/Contents/MacOS/BytePorts -AppleLanguages '(de)'
  ```

  `(de)`, `(de-AT)`, `(de-CH)` and `(fr, de)` show German. `(en)` and `(fr)` show English.

## Glossary

| English | German | Note |
| --- | --- | --- |
| Service | Dienst | |
| Server | Server | |
| Agent | Agent | |
| TCP listener | TCP-Listener | |
| Project | Projekt | |
| No project | Ohne Projekt | |
| Action | Aktion | |
| New Action | Neue Aktion | |
| Started | Gestartet | |
| Detection | Erkennung | |
| Pause detection / Resume detection | Erkennung pausieren / Erkennung fortsetzen | |
| Paused | Pausiert | explicit key |
| Stop | Stoppen | explicit key |
| Force Stop | Sofort beenden | rows |
| Force Quit | Sofort beenden | quit panel |
| Quit %@ | %@ beenden | |
| Exited | Beendet | |
| Pause | Pausieren | |
| Resume | Fortsetzen | |
| Restart | Neu starten | |
| Share publicly | Öffentlich teilen | |
| Stop sharing | Freigabe beenden | |
| Share link | Freigabelink | never “Tunnel” in the UI |
| Details | Details | |
| Output | Ausgabe | |
| Activity | Aktivität | |
| Settings | Einstellungen | |
| Introduction | Einführung | |
| Favorite | Favorit | |
| Project folder | Projektordner | |
| Launch command | Startbefehl | |

Do not use: Übersicht, AI-Agenten, Dev-Server (as a tab name), Startaktion, Scan pausieren, Projekt anheften.

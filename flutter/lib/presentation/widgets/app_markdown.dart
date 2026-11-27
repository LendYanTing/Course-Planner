import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A dependency-free Markdown renderer for agent replies.
///
/// It understands the subset the built-in assistant emits: ATX headings,
/// paragraphs, emphasis, inline code, bullet/ordered lists, block quotes,
/// dividers, fenced code blocks with a copy button, and GFM tables. Colours are
/// read from the ambient [ColorScheme] so light, dark and Monet themes all
/// look right without per-theme constants.
class AppMarkdownContent extends StatelessWidget {
  const AppMarkdownContent({
    super.key,
    required this.data,
    this.textColor,
    this.selectable = true,
  });

  /// Raw Markdown source.
  final String data;

  /// Overrides the base colour used by headings, body text and list labels.
  final Color? textColor;

  /// Wraps the result in a [SelectionArea] so replies can be copied.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = textColor ?? scheme.onSurface;
    final source = data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = _MarkdownParser(
      scheme: scheme,
      textColor: base,
    ).parse(source);
    if (blocks.isEmpty) return const SizedBox.shrink();
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
    return selectable ? SelectionArea(child: content) : content;
  }
}

/// One parsed list item: indentation in two-space steps, an optional ordered
/// number and the raw content that still needs inline parsing.
class _ListItem {
  const _ListItem({
    required this.indent,
    required this.number,
    required this.text,
  });

  final int indent;
  final int? number;
  final String text;
}

/// Converts Markdown source into a flat list of widgets.
///
/// A fresh parser is created per build, so the block counters used for widget
/// keys always start at zero and stay deterministic.
class _MarkdownParser {
  _MarkdownParser({required this.scheme, required this.textColor});

  final ColorScheme scheme;
  final Color textColor;

  static final RegExp _fencePattern = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
  static final RegExp _headingPattern = RegExp(r'^ {0,3}(#{1,6})\s+(.*)$');
  static final RegExp _quotePattern = RegExp(r'^ {0,3}> ?(.*)$');
  static final RegExp _orderedPattern = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
  static final RegExp _bulletPattern = RegExp(r'^(\s*)([-*+•])\s+(.*)$');
  static final RegExp _delimiterCell = RegExp(r'^:?-+:?$');
  static final RegExp _trailingHashes = RegExp(r'\s+#+\s*$');
  static const String _escapable = r'\`*_{}[]()#+-.!~|>';

  static const TextStyle _boldStyle = TextStyle(fontWeight: FontWeight.w700);
  static const TextStyle _italicStyle = TextStyle(fontStyle: FontStyle.italic);
  static const TextStyle _boldItalicStyle = TextStyle(
    fontWeight: FontWeight.w700,
    fontStyle: FontStyle.italic,
  );
  static const TextStyle _strikeStyle = TextStyle(
    decoration: TextDecoration.lineThrough,
  );

  int _codeBlocks = 0;
  int _tables = 0;

  TextStyle get _bodyStyle =>
      TextStyle(fontSize: 14, height: 1.48, color: textColor);

  TextStyle get _inlineCodeStyle => TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    color: scheme.primary,
    backgroundColor: scheme.surfaceContainerHighest,
  );

  List<Widget> parse(String source) {
    final lines = source.split('\n');
    final widgets = <Widget>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        index++;
        continue;
      }

      final fence = _fencePattern.firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        final language = fence.group(2)!.trim().split(RegExp(r'\s+')).first;
        final body = <String>[];
        var cursor = index + 1;
        var closed = false;
        while (cursor < lines.length) {
          final closing = _fencePattern.firstMatch(lines[cursor]);
          if (closing != null &&
              closing.group(1)![0] == marker[0] &&
              closing.group(2)!.trim().isEmpty) {
            closed = true;
            break;
          }
          body.add(lines[cursor]);
          cursor++;
        }
        // An unclosed fence simply runs to the end of the text.
        widgets.add(_codeBlock(body.join('\n'), language));
        index = closed ? cursor + 1 : lines.length;
        continue;
      }

      if (_startsTable(lines, index)) {
        final table = _tableAt(lines, index);
        widgets.add(table.widget);
        index = table.next;
        continue;
      }

      final heading = _headingPattern.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final text = heading.group(2)!.replaceFirst(_trailingHashes, '').trim();
        widgets.add(_heading(text, level));
        index++;
        continue;
      }

      if (_isDivider(trimmed)) {
        widgets.add(_divider());
        index++;
        continue;
      }

      if (_quotePattern.hasMatch(line)) {
        final parts = <String>[];
        var cursor = index;
        while (cursor < lines.length) {
          final quote = _quotePattern.firstMatch(lines[cursor]);
          if (quote == null) break;
          parts.add(quote.group(1)!);
          cursor++;
        }
        widgets.add(_quote(parts.join('\n')));
        index = cursor;
        continue;
      }

      final listItem = _parseListItem(line);
      if (listItem != null) {
        final items = <_ListItem>[];
        var cursor = index;
        while (cursor < lines.length) {
          final item = _parseListItem(lines[cursor]);
          if (item == null) break;
          items.add(item);
          cursor++;
        }
        widgets.add(_list(items));
        index = cursor;
        continue;
      }

      final paragraph = <String>[line.trimRight()];
      var cursor = index + 1;
      while (cursor < lines.length) {
        if (_startsBlock(lines, cursor)) break;
        paragraph.add(lines[cursor].trimRight());
        cursor++;
      }
      widgets.add(_paragraph(paragraph.join('\n')));
      index = cursor;
    }
    return widgets;
  }

  bool _startsBlock(List<String> lines, int index) {
    final line = lines[index];
    final trimmed = line.trim();
    if (trimmed.isEmpty) return true;
    if (_fencePattern.hasMatch(line)) return true;
    if (_headingPattern.hasMatch(line)) return true;
    if (_isDivider(trimmed)) return true;
    if (_quotePattern.hasMatch(line)) return true;
    if (_parseListItem(line) != null) return true;
    if (_startsTable(lines, index)) return true;
    return false;
  }

  /// A divider is a line of three or more identical `-`, `*` or `_` markers,
  /// optionally separated by spaces.
  bool _isDivider(String trimmed) {
    if (trimmed.length < 3) return false;
    final marker = trimmed[0];
    if (marker != '-' && marker != '*' && marker != '_') return false;
    var count = 0;
    for (var i = 0; i < trimmed.length; i++) {
      final char = trimmed[i];
      if (char == marker) {
        count++;
      } else if (char != ' ' && char != '\t') {
        return false;
      }
    }
    return count >= 3;
  }

  /// GFM tables normally start with a pipe; the outer pipes may be omitted
  /// when the delimiter row follows immediately.
  bool _startsTable(List<String> lines, int index) {
    final trimmed = lines[index].trim();
    if (!trimmed.contains('|')) return false;
    if (trimmed.startsWith('|')) return true;
    return index + 1 < lines.length && _isDelimiterRow(lines[index + 1]);
  }

  bool _isDelimiterRow(String line) {
    final trimmed = line.trim();
    if (!trimmed.contains('|') || !trimmed.contains('-')) return false;
    final cells = _splitRow(trimmed);
    return cells.isNotEmpty && cells.every(_delimiterCell.hasMatch);
  }

  List<String> _splitRow(String line) {
    var trimmed = line.trim();
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('|')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed.split('|').map((cell) => cell.trim()).toList();
  }

  TextAlign? _alignment(String cell) {
    final trimmed = cell.trim();
    final left = trimmed.startsWith(':');
    final right = trimmed.endsWith(':');
    if (left && right) return TextAlign.center;
    if (right) return TextAlign.end;
    return null;
  }

  ({Widget widget, int next}) _tableAt(List<String> lines, int index) {
    final rows = <String>[];
    final leadingPipes = lines[index].trim().startsWith('|');
    final firstCount = _splitRow(lines[index].trim()).length;
    var cursor = index;
    while (cursor < lines.length) {
      final trimmed = lines[cursor].trim();
      if (trimmed.isEmpty || !trimmed.contains('|')) break;
      if (!trimmed.startsWith('|')) {
        final count = _splitRow(trimmed).length;
        if (leadingPipes || count != firstCount) break;
      }
      rows.add(trimmed);
      cursor++;
    }

    final hasDelimiter = rows.length >= 2 && _isDelimiterRow(rows[1]);
    final headerCells = hasDelimiter ? _splitRow(rows[0]) : null;
    final bodyRows = [
      for (var i = hasDelimiter ? 2 : 0; i < rows.length; i++)
        _splitRow(rows[i]),
    ];
    var columns = headerCells?.length ?? 1;
    for (final row in bodyRows) {
      if (row.length > columns) columns = row.length;
    }
    final alignments = <TextAlign?>[
      if (hasDelimiter)
        for (final cell in _splitRow(rows[1])) _alignment(cell),
    ];
    while (alignments.length < columns) {
      alignments.add(null);
    }

    return (
      widget: _table(
        header: headerCells,
        body: bodyRows,
        alignments: alignments,
        columns: columns,
      ),
      next: cursor,
    );
  }

  _ListItem? _parseListItem(String line) {
    final ordered = _orderedPattern.firstMatch(line);
    if (ordered != null) {
      return _ListItem(
        indent: _indentOf(ordered.group(1)!),
        number: int.tryParse(ordered.group(2)!),
        text: ordered.group(3)!,
      );
    }
    final bullet = _bulletPattern.firstMatch(line);
    if (bullet != null) {
      return _ListItem(
        indent: _indentOf(bullet.group(1)!),
        number: null,
        text: bullet.group(3)!,
      );
    }
    return null;
  }

  /// Two leading spaces add one nesting level (14dp each).
  int _indentOf(String leading) {
    final spaces = leading.replaceAll('\t', '  ').length;
    return (spaces ~/ 2).clamp(0, 8);
  }

  Widget _paragraph(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(children: _inline(text)),
        style: _bodyStyle,
      ),
    );
  }

  Widget _heading(String text, int level) {
    final size = switch (level) {
      1 => 19.0,
      2 => 17.0,
      3 => 15.5,
      _ => 14.5,
    };
    final style = TextStyle(
      fontSize: size,
      fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
      height: 1.32,
      color: textColor,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text.rich(TextSpan(children: _inline(text)), style: style),
    );
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
    );
  }

  Widget _list(List<_ListItem> items) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            Padding(
              padding: EdgeInsets.only(left: item.indent * 14, bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.number != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '${item.number}.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.48,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: 14,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Container(
                            width: 4.5,
                            height: 4.5,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: _inline(item.text)),
                      style: _bodyStyle,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _quote(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3.5,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Container(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  padding: const EdgeInsets.all(10),
                  child: Text.rich(
                    TextSpan(children: _inline(text)),
                    style: _bodyStyle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _codeBlock(String code, String language) {
    final background = scheme.brightness == Brightness.dark
        ? scheme.surfaceContainerLowest
        : scheme.surfaceContainerHighest;
    final label = language.isEmpty ? '代码' : language;
    return Container(
      key: ValueKey('app-markdown-code-${_codeBlocks++}'),
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 3, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _CodeCopyButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              code,
              softWrap: false,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.45,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table({
    required List<String>? header,
    required List<List<String>> body,
    required List<TextAlign?> alignments,
    required int columns,
  }) {
    final rows = [
      if (header != null)
        _tableRow(header, columns, alignments, header: true),
      for (final row in body)
        _tableRow(row, columns, alignments, header: false),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Container(
        key: ValueKey('app-markdown-table-${_tables++}'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(
              horizontalInside: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            children: rows,
          ),
        ),
      ),
    );
  }

  TableRow _tableRow(
    List<String> cells,
    int columns,
    List<TextAlign?> alignments, {
    required bool header,
  }) {
    return TableRow(
      decoration: header
          ? BoxDecoration(
              color: scheme.secondaryContainer.withValues(alpha: 0.45),
            )
          : null,
      children: [
        for (var column = 0; column < columns; column++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text.rich(
              TextSpan(
                children: _inline(column < cells.length ? cells[column] : ''),
              ),
              textAlign: alignments[column] ?? TextAlign.start,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: textColor,
                fontWeight: header ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
      ],
    );
  }

  /// Parses inline Markdown into spans. Unclosed markers are emitted as plain
  /// text so no characters are swallowed.
  List<InlineSpan> _inline(String text) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    var index = 0;

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
    }

    while (index < text.length) {
      final char = text[index];

      if (char == r'\' &&
          index + 1 < text.length &&
          _escapable.contains(text[index + 1])) {
        buffer.write(text[index + 1]);
        index += 2;
        continue;
      }

      if (char == '`') {
        final close = text.indexOf('`', index + 1);
        if (close > index + 1) {
          flush();
          spans.add(
            TextSpan(
              text: text.substring(index + 1, close),
              style: _inlineCodeStyle,
            ),
          );
          index = close + 1;
          continue;
        }
        buffer.write(char);
        index++;
        continue;
      }

      if (char == '*') {
        var next = _consumeEmphasis(
          text,
          index,
          '***',
          _boldItalicStyle,
          spans,
          flush,
        );
        if (next < 0) {
          next = _consumeEmphasis(
            text,
            index,
            '**',
            _boldStyle,
            spans,
            flush,
          );
        }
        if (next < 0) {
          next = _consumeEmphasis(
            text,
            index,
            '*',
            _italicStyle,
            spans,
            flush,
          );
        }
        if (next >= 0) {
          index = next;
          continue;
        }
        buffer.write(char);
        index++;
        continue;
      }

      if (char == '_') {
        final intraword =
            index > 0 &&
            index + 1 < text.length &&
            _isWordChar(text[index - 1]) &&
            _isWordChar(text[index + 1]);
        if (!intraword) {
          var next = _consumeEmphasis(
            text,
            index,
            '___',
            _boldItalicStyle,
            spans,
            flush,
          );
          if (next < 0) {
            next = _consumeEmphasis(
              text,
              index,
              '__',
              _boldStyle,
              spans,
              flush,
            );
          }
          if (next < 0) {
            next = _consumeEmphasis(
              text,
              index,
              '_',
              _italicStyle,
              spans,
              flush,
            );
          }
          if (next >= 0) {
            index = next;
            continue;
          }
        }
        buffer.write(char);
        index++;
        continue;
      }

      if (char == '~' && index + 1 < text.length && text[index + 1] == '~') {
        final next = _consumeEmphasis(
          text,
          index,
          '~~',
          _strikeStyle,
          spans,
          flush,
        );
        if (next >= 0) {
          index = next;
          continue;
        }
      }

      buffer.write(char);
      index++;
    }
    flush();
    return spans;
  }

  int _consumeEmphasis(
    String text,
    int start,
    String marker,
    TextStyle style,
    List<InlineSpan> spans,
    void Function() flush,
  ) {
    // A single `*` must not be treated as the opening of `**`: the marker has
    // to be present in full at the current position.
    if (!text.startsWith(marker, start)) return -1;
    final openEnd = start + marker.length;
    if (openEnd >= text.length) return -1;
    final close = text.indexOf(marker, openEnd);
    if (close <= openEnd) return -1;
    final inner = text.substring(openEnd, close);
    flush();
    spans.addAll(_applyStyle(_inline(inner), style));
    return close + marker.length;
  }

  /// Pushes an emphasis style onto every leaf span so the resulting spans each
  /// carry their resolved weight / decoration.
  List<InlineSpan> _applyStyle(List<InlineSpan> spans, TextStyle style) {
    final result = <InlineSpan>[];
    for (final span in spans) {
      if (span is TextSpan) {
        result.add(
          TextSpan(
            text: span.text,
            style: style.merge(span.style),
            children: span.children == null
                ? null
                : _applyStyle(span.children!, style),
          ),
        );
      } else {
        result.add(span);
      }
    }
    return result;
  }

  bool _isWordChar(String char) {
    final code = char.codeUnitAt(0);
    final digit = code >= 0x30 && code <= 0x39;
    final upper = code >= 0x41 && code <= 0x5A;
    final lower = code >= 0x61 && code <= 0x7A;
    return digit || upper || lower || code > 0x7F;
  }
}

/// The compact "copy" action in a fenced code block's header.
class _CodeCopyButton extends StatefulWidget {
  const _CodeCopyButton({required this.code});

  final String code;

  @override
  State<_CodeCopyButton> createState() => _CodeCopyButtonState();
}

class _CodeCopyButtonState extends State<_CodeCopyButton> {
  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('已复制代码')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: _copy,
      icon: Icon(Icons.copy_rounded, size: 13, color: scheme.primary),
      label: Text(
        '复制代码',
        style: TextStyle(fontSize: 12, color: scheme.primary),
      ),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

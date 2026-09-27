import Foundation

enum MarkdownHTMLRenderer {
    static func document(
        blocks: [MarkdownBlock],
        activeIndex: Int?,
        backgroundHex: String,
        noteDirectory: URL? = nil,
        fontSize: Double = 11,
        columnCount: Int = 1
    ) -> String {
        let columns = NoteWindowState.clampedColumnCount(columnCount)
        var body = ""
        for (index, block) in blocks.enumerated() {
            let isBlank = block.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if index == activeIndex {
                let escaped = escapeHTML(block.source)
                let kind = activeSourceKind(block.source)
                body += """
                <div class="block active\(isBlank ? " blank" : "")" data-index="\(index)">
                  <textarea class="source \(kind)" rows="1">\(escaped)</textarea>
                </div>
                """
            } else if isBlank {
                body += """
                <div class="block blank" data-index="\(index)"><p class="blank-line"><br></p></div>
                """
            } else {
                body += """
                <div class="block" data-index="\(index)">\(renderBlock(block.source, noteDirectory: noteDirectory))</div>
                """
            }
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = """
            <div class="block active" data-index="0">
              <textarea class="source para" rows="1"></textarea>
            </div>
            """
        }

        let multiColumn = columns > 1
        let contentColumnCSS = multiColumn ? """
          /* Tall equal columns; page scrolls vertically (same as 1-column notes). */
          html, body {
            height: auto !important;
            min-height: 100%;
            overflow-x: hidden;
            overflow-y: auto;
          }
          body {
            height: auto !important;
          }
          .content {
            flex: 0 0 auto;
            width: 100%;
            column-count: \(columns);
            column-gap: 24px;
            column-fill: balance;
            column-rule: 1px solid rgba(0,0,0,0.12);
          }
          .tail {
            flex: 0 0 auto;
            min-height: 56px;
            cursor: text;
          }
          /* Column box is the %-width containing block — browser does the 2/3-way math. */
          .block {
            width: 100%;
            max-width: 100%;
            overflow: hidden;
          }
          img {
            width: 100%;
            max-width: 100%;
            height: auto;
            display: block;
            box-sizing: border-box;
          }
        """ : """
          .content { flex: 0 0 auto; }
          .tail {
            flex: 1 1 auto;
            min-height: 56px;
            cursor: text;
          }
        """

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body {
            margin: 0; padding: 0;
            height: 100%;
            background: \(backgroundHex) !important;
            color: #1a1a1a !important;
            font: \(String(format: "%.1f", fontSize))px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            word-wrap: break-word;
            overflow-wrap: anywhere;
          }
          body {
            display: flex;
            flex-direction: column;
            box-sizing: border-box;
            padding: 8px 12px 0;
            min-height: 100%;
            position: relative;
          }
          \(contentColumnCSS)
          /* Spacing: blank-line blocks carry empty lines; other blocks stay tight. */
          .block {
            margin: 0;
            padding: 0;
            border: none;
            border-radius: 0;
            cursor: text;
            box-sizing: border-box;
            break-inside: avoid;
            -webkit-column-break-inside: avoid;
            page-break-inside: avoid;
          }
          .block:hover { background: rgba(0,0,0,0.03); }
          .block.blank {
            margin: 0;
            min-height: 1.45em;
            height: auto;
          }
          .block.active {
            /* Slightly lighter than the sticky — easy to see what's being edited. */
            background: rgba(255,255,255,0.22);
            margin: 0;
            padding: 0;
            height: auto;
            overflow: visible;
          }
          .block.active:hover { background: rgba(255,255,255,0.22); }
          .block.blank:hover { background: transparent; }
          .blank-line {
            margin: 0;
            padding: 0;
            line-height: 1.45;
            min-height: 1.45em;
          }
          .block > :first-child { margin-top: 0 !important; }
          .block > :last-child { margin-bottom: 0 !important; }
          .source {
            display: block;
            width: 100%;
            border: none;
            outline: none;
            resize: none;
            overflow: hidden;
            background: transparent;
            color: #1a1a1a;
            font: inherit;
            font-family: inherit;
            font-size: inherit;
            font-weight: inherit;
            line-height: inherit;
            letter-spacing: inherit;
            padding: 0;
            margin: 0;
            box-sizing: border-box;
            white-space: pre-wrap;
            vertical-align: top;
            /* Avoid the browser's default ~2-row textarea floor. */
            min-height: 0;
            height: 1.45em;
            field-sizing: content;
          }
          /* Match rendered typography while editing the same block type. */
          .source.para { font-size: 1em; font-weight: normal; line-height: 1.45; }
          .source.blank {
            font-size: 1em;
            font-weight: normal;
            line-height: 1.45;
            min-height: 1.45em;
            height: auto;
          }
          .source.h1 { font-size: 1.45em; font-weight: bold; line-height: 1.25; height: 1.25em; }
          .source.h2 { font-size: 1.25em; font-weight: bold; line-height: 1.25; height: 1.25em; }
          .source.h3 { font-size: 1.1em; font-weight: bold; line-height: 1.25; height: 1.25em; }
          .source.h4, .source.h5, .source.h6 { font-size: 1em; font-weight: bold; line-height: 1.25; height: 1.25em; }
          .source.list { font-size: 1em; font-weight: normal; line-height: 1.45; }
          .source.quote {
            font-size: 1em; font-weight: normal; line-height: 1.45;
            color: rgba(0,0,0,0.75);
            padding-left: 0.7em;
            border-left: 3px solid rgba(0,0,0,0.25);
          }
          .source.code {
            font: 0.92em/1.4 ui-monospace, Menlo, monospace;
            padding: 8px 10px;
            background: rgba(0,0,0,0.08);
            border-radius: 6px;
          }
          h1,h2,h3,h4,h5,h6 {
            margin: 0;
            line-height: 1.25;
            font-weight: bold;
          }
          h1 { font-size: 1.45em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
          h4,h5,h6 { font-size: 1em; }
          p { margin: 0; line-height: 1.45; }
          ul, ol {
            margin: 0;
            padding-left: 1.35em;
            line-height: 1.45;
          }
          li { margin: 0.28em 0 0; line-height: 1.45; }
          li:first-child { margin-top: 0; }
          li.list-gap {
            list-style: none;
            margin: 0;
            padding: 0;
            height: 1.45em;
            min-height: 1.45em;
            line-height: 1.45;
            border: none;
          }
          li.list-gap::marker { content: ""; }
          blockquote {
            margin: 0;
            padding-left: 0.7em;
            border-left: 3px solid rgba(0,0,0,0.25);
            color: rgba(0,0,0,0.75);
            line-height: 1.45;
          }
          code {
            font: 0.92em/1.4 ui-monospace, Menlo, monospace;
            background: rgba(0,0,0,0.08);
            padding: 0.05em 0.3em;
            border-radius: 3px;
          }
          pre {
            margin: 0;
            padding: 8px 10px;
            background: rgba(0,0,0,0.08);
            border-radius: 6px;
            overflow-x: auto;
            line-height: 1.4;
          }
          pre code { background: none; padding: 0; }
          hr { border: none; border-top: 1px solid rgba(0,0,0,0.25); margin: 0.3em 0; }
          a { color: #0b57d0; }
          img { max-width: 100%; height: auto; border-radius: 4px; display: block; margin: 0.2em 0; }
          /* Insertion caret while dragging an image onto the note. */
          #ms-drop-caret {
            position: absolute;
            left: 8px;
            right: 8px;
            height: 3px;
            margin-top: -1px;
            background: #0b57d0;
            border-radius: 2px;
            pointer-events: none;
            z-index: 10000;
            display: none;
            box-shadow: 0 0 0 1px rgba(255,255,255,0.85);
          }
          table {
            border-collapse: collapse;
            width: 100%;
            margin: 0;
            font-size: 0.92em;
          }
          th, td {
            border: 1px solid rgba(0,0,0,0.2);
            padding: 4px 8px;
            text-align: left;
          }
          th { background: rgba(0,0,0,0.06); }
        </style>
        </head>
        <body data-columns="\(columns)">
        <div class="content">
        \(body)
        </div>
        <div class="tail" data-tail="1"></div>
        <script>
          (function() {
            function post(name, payload) {
              try { webkit.messageHandlers[name].postMessage(payload); } catch (e) {}
            }
            function autoGrow(ta) {
              // Collapse first so scrollHeight is content height, not the default
              // 2-row textarea floor (which made one-line edits taller than view mode).
              ta.style.height = '0px';
              var next = ta.scrollHeight;
              if (next < 1) {
                var cs = window.getComputedStyle(ta);
                var lh = parseFloat(cs.lineHeight);
                if (!lh || isNaN(lh)) lh = (parseFloat(cs.fontSize) || 12) * 1.45;
                next = lh;
              }
              ta.style.height = next + 'px';
            }
            function clickLineColumn(blockEl, ev) {
              var range = null;
              if (document.caretRangeFromPoint) {
                range = document.caretRangeFromPoint(ev.clientX, ev.clientY);
              } else if (document.caretPositionFromPoint) {
                var pos = document.caretPositionFromPoint(ev.clientX, ev.clientY);
                if (pos) {
                  range = document.createRange();
                  range.setStart(pos.offsetNode, pos.offset);
                  range.collapse(true);
                }
              }
              if (range && blockEl.contains(range.startContainer)) {
                try {
                  var pre = document.createRange();
                  pre.selectNodeContents(blockEl);
                  pre.setEnd(range.startContainer, range.startOffset);
                  var text = pre.toString();
                  var line = 0, col = 0;
                  for (var i = 0; i < text.length; i++) {
                    if (text.charAt(i) === '\\n') { line++; col = 0; }
                    else col++;
                  }
                  return { line: line, column: col };
                } catch (e) {}
              }
              // Geometric fallback when caretRangeFromPoint misses (e.g. padding).
              var rect = blockEl.getBoundingClientRect();
              var style = window.getComputedStyle(blockEl);
              var lh = parseFloat(style.lineHeight);
              if (!lh || isNaN(lh)) lh = (parseFloat(style.fontSize) || 12) * 1.45;
              var line = Math.max(0, Math.floor((ev.clientY - rect.top) / lh));
              var fs = parseFloat(style.fontSize) || 12;
              var col = Math.max(0, Math.round((ev.clientX - rect.left) / (fs * 0.55)));
              return { line: line, column: col };
            }
            document.querySelectorAll('.block:not(.active)').forEach(function(el) {
              el.addEventListener('click', function(ev) {
                if (ev.target.closest('a')) return;
                var lc = clickLineColumn(el, ev);
                post('activate', {
                  index: parseInt(el.dataset.index, 10),
                  line: lc.line,
                  column: lc.column
                });
              });
            });
            var ta = document.querySelector('textarea.source');
            if (ta) {
              syncSourceClass(ta);
              autoGrow(ta);
              ta.focus({ preventScroll: true });
              function notifyEdit() {
                syncSourceClass(ta);
                autoGrow(ta);
                post('edit', {
                  index: parseInt(ta.closest('.block').dataset.index, 10),
                  text: ta.value,
                  caret: ta.selectionStart
                });
              }
              ta.addEventListener('input', notifyEdit);
              ta.addEventListener('keydown', function(ev) {
                if (ev.key === 'Escape') {
                  ev.preventDefault();
                  post('commit', null);
                  return;
                }
                var meta = ev.metaKey || ev.ctrlKey;
                // Cmd/Ctrl+Z handled in AppKit undo stack — block WebKit's native undo.
                if (meta && (ev.key === 'z' || ev.key === 'Z')) {
                  ev.preventDefault();
                  return;
                }
                // Enter → split block at caret (new block below). Shift+Enter → soft newline.
                if (ev.key === 'Enter' && !ev.shiftKey && !meta && !ev.altKey) {
                  if (ta.selectionStart === ta.selectionEnd) {
                    ev.preventDefault();
                    var idxEnter = parseInt(ta.closest('.block').dataset.index, 10);
                    post('splitBlock', {
                      index: idxEnter,
                      text: ta.value,
                      caret: ta.selectionStart
                    });
                    return;
                  }
                }
                if (ev.key === 'Enter' && ev.shiftKey) {
                  requestAnimationFrame(function() { autoGrow(ta); });
                }
                if (ev.key === 'Backspace' || ev.key === 'Delete') {
                  requestAnimationFrame(function() { autoGrow(ta); });
                }
                if (meta && (ev.key === 'b' || ev.key === 'B')) {
                  ev.preventDefault();
                  wrapInline(ta, '**');
                  notifyEdit();
                  return;
                }
                if (meta && (ev.key === 'i' || ev.key === 'I')) {
                  ev.preventDefault();
                  wrapInline(ta, '*');
                  notifyEdit();
                  return;
                }
                if (ev.key === 'Tab') {
                  ev.preventDefault();
                  adjustListIndent(ta, !ev.shiftKey);
                  notifyEdit();
                  return;
                }
                if (ev.altKey && (ev.key === 'ArrowUp' || ev.key === 'ArrowDown')) {
                  ev.preventDefault();
                  if (moveLine(ta, ev.key === 'ArrowUp' ? -1 : 1) === 'local') {
                    notifyEdit();
                  }
                  return;
                }
                // Empty blank-line blocks: only remove when fully empty (""), never content.
                if (!ev.altKey && !meta && !ev.shiftKey && (ev.key === 'Backspace' || ev.key === 'Delete')) {
                  if (ta.selectionStart !== ta.selectionEnd) return;
                  var val = ta.value;
                  var pos = ta.selectionStart;
                  var idx = parseInt(ta.closest('.block').dataset.index, 10);
                  var block = ta.closest('.block');
                  function siblingTrulyEmpty(el, dir) {
                    if (!el) return false;
                    var sib = dir < 0 ? el.previousElementSibling : el.nextElementSibling;
                    if (!sib || !sib.classList.contains('block')) return false;
                    var other = sib.querySelector('textarea.source');
                    if (other) return other.value.length === 0;
                    // Rendered blank spacer (no textarea) counts as empty.
                    return sib.classList.contains('blank');
                  }
                  if (val.length === 0) {
                    ev.preventDefault();
                    post('deleteEmptyBlock', { target: 'self', index: idx, text: val });
                    return;
                  }
                  if (ev.key === 'Backspace' && pos === 0 && siblingTrulyEmpty(block, -1)) {
                    ev.preventDefault();
                    post('deleteEmptyBlock', { target: 'above', index: idx, text: val });
                    return;
                  }
                  if (ev.key === 'Delete' && pos === val.length && siblingTrulyEmpty(block, 1)) {
                    ev.preventDefault();
                    post('deleteEmptyBlock', { target: 'below', index: idx, text: val });
                    return;
                  }
                }
                // Plain arrows at block edge → neighboring block (hide the block model).
                if (!ev.altKey && !meta && !ev.shiftKey && (ev.key === 'ArrowUp' || ev.key === 'ArrowDown')) {
                  var pos2 = ev.key === 'ArrowUp' ? ta.selectionStart : ta.selectionEnd;
                  if (ta.selectionStart !== ta.selectionEnd) return;
                  var val2 = ta.value;
                  if (ev.key === 'ArrowUp') {
                    if (val2.lastIndexOf('\\n', pos2 - 1) < 0) {
                      ev.preventDefault();
                      post('navigate', { direction: -1, column: pos2 });
                      return;
                    }
                  } else {
                    if (val2.indexOf('\\n', pos2) < 0) {
                      ev.preventDefault();
                      var lineStart = val2.lastIndexOf('\\n', pos2 - 1) + 1;
                      post('navigate', { direction: 1, column: pos2 - lineStart });
                      return;
                    }
                  }
                }
              });
            }
            function syncSourceClass(ta) {
              var raw = ta.value || '';
              var t = raw.replace(/^\\s+/, '');
              var cls = 'para';
              if (raw.trim().length === 0) cls = 'blank';
              else if (t.indexOf('```') === 0) cls = 'code';
              else if (/^#{6}\\s/.test(t)) cls = 'h6';
              else if (/^#{5}\\s/.test(t)) cls = 'h5';
              else if (/^#{4}\\s/.test(t)) cls = 'h4';
              else if (/^#{3}\\s/.test(t)) cls = 'h3';
              else if (/^#{2}\\s/.test(t)) cls = 'h2';
              else if (/^#\\s/.test(t)) cls = 'h1';
              else if (/^>/.test(t)) cls = 'quote';
              else if (/^([-*+]|\\d+\\.)\\s+/.test(t) || /^[ \\t]+([-*+]|\\d+\\.)\\s+/.test(raw)) cls = 'list';
              ta.className = 'source ' + cls;
              var block = ta.closest('.block');
              if (block) {
                if (cls === 'blank') block.classList.add('blank');
                else block.classList.remove('blank');
              }
            }
            function wrapInline(ta, marker) {
              var start = ta.selectionStart, end = ta.selectionEnd;
              var val = ta.value;
              var selected = val.slice(start, end);
              var open = marker, close = marker;
              // Unwrap if already wrapped
              if (selected.length >= open.length + close.length
                  && selected.slice(0, open.length) === open
                  && selected.slice(-close.length) === close) {
                var inner = selected.slice(open.length, selected.length - close.length);
                ta.value = val.slice(0, start) + inner + val.slice(end);
                ta.selectionStart = start;
                ta.selectionEnd = start + inner.length;
                return;
              }
              // Unwrap markers just outside selection
              if (start >= open.length && end + close.length <= val.length
                  && val.slice(start - open.length, start) === open
                  && val.slice(end, end + close.length) === close) {
                ta.value = val.slice(0, start - open.length) + selected + val.slice(end + close.length);
                ta.selectionStart = start - open.length;
                ta.selectionEnd = end - open.length;
                return;
              }
              if (start === end) {
                var placeholder = marker === '**' ? 'bold' : 'italic';
                ta.value = val.slice(0, start) + open + placeholder + close + val.slice(end);
                ta.selectionStart = start + open.length;
                ta.selectionEnd = start + open.length + placeholder.length;
              } else {
                ta.value = val.slice(0, start) + open + selected + close + val.slice(end);
                ta.selectionStart = start + open.length;
                ta.selectionEnd = end + open.length;
              }
            }
            function lineBounds(val, pos) {
              var a = val.lastIndexOf('\\n', pos - 1) + 1;
              var b = val.indexOf('\\n', pos);
              if (b < 0) b = val.length;
              return { start: a, end: b };
            }
            function isListLineText(line) {
              return /^[ \\t]*([-*+]|\\d+\\.)\\s+/.test(line);
            }
            function adjustListIndent(ta, increase) {
              var val = ta.value;
              var start = ta.selectionStart, end = ta.selectionEnd;
              var from = lineBounds(val, start).start;
              var to = lineBounds(val, Math.max(start, end - (end > start ? 1 : 0))).end;
              // Expand to full lines in selection
              var block = val.slice(from, to);
              var lines = block.split('\\n');
              var changed = lines.map(function(line) {
                if (!line.length && lines.length === 1) {
                  return increase ? '- ' : line;
                }
                if (!isListLineText(line) && line.trim().length === 0) return line;
                if (!isListLineText(line)) {
                  return increase ? ('  - ' + line.replace(/^\\s+/, '')) : line;
                }
                if (increase) return '  ' + line;
                if (line.indexOf('  ') === 0) return line.slice(2);
                if (line.indexOf('\\t') === 0) return line.slice(1);
                return line;
              });
              var next = changed.join('\\n');
              ta.value = val.slice(0, from) + next + val.slice(to);
              ta.selectionStart = from;
              ta.selectionEnd = from + next.length;
            }
            function moveLine(ta, dir) {
              var val = ta.value;
              var pos = ta.selectionStart;
              var cur = lineBounds(val, pos);
              var lines = val.split('\\n');
              // Find line index
              var idx = 0, acc = 0;
              for (var i = 0; i < lines.length; i++) {
                var len = lines[i].length;
                if (pos <= acc + len) { idx = i; break; }
                acc += len + 1;
                if (i === lines.length - 1) idx = i;
              }
              var j = idx + dir;
              if (j < 0 || j >= lines.length) {
                post('moveLineAcross', {
                  direction: dir,
                  lineIndex: idx,
                  column: pos - cur.start
                });
                return 'across';
              }
              var tmp = lines[idx];
              lines[idx] = lines[j];
              lines[j] = tmp;
              ta.value = lines.join('\\n');
              // Place caret on moved line
              var newPos = 0;
              for (var k = 0; k < j; k++) newPos += lines[k].length + 1;
              var offset = pos - cur.start;
              ta.selectionStart = ta.selectionEnd = newPos + Math.min(offset, lines[j].length);
              return 'local';
            }
            window.__msEditorAction = function(action) {
              var t = document.querySelector('textarea.source');
              if (!t) return false;
              if (action === 'bold') { wrapInline(t, '**'); }
              else if (action === 'italic') { wrapInline(t, '*'); }
              else if (action === 'indent') { adjustListIndent(t, true); }
              else if (action === 'outdent') { adjustListIndent(t, false); }
              else if (action === 'lineUp' || action === 'lineDown') {
                if (moveLine(t, action === 'lineUp' ? -1 : 1) === 'across') return true;
              }
              else return false;
              autoGrow(t);
              post('edit', { index: parseInt(t.closest('.block').dataset.index, 10), text: t.value });
              return true;
            };
            // Drop target: viewport x/y → block index + insert side (for image drops).
            window.__msDropTargetAt = function(x, y) {
              var el = document.elementFromPoint(x, y);
              if (!el || el.closest && el.closest('.tail')) {
                return { append: true };
              }
              var block = el.closest ? el.closest('.block') : null;
              if (!block) {
                var blocks = document.querySelectorAll('.block');
                if (!blocks.length) return { append: true };
                var last = blocks[blocks.length - 1];
                var lr = last.getBoundingClientRect();
                if (y >= lr.bottom) return { append: true };
                block = last;
              }
              var index = parseInt(block.dataset.index, 10);
              var ta = block.querySelector('textarea.source');
              if (ta) {
                return { index: index, caret: ta.selectionStart, editing: true };
              }
              var rect = block.getBoundingClientRect();
              var after = y > rect.top + rect.height * 0.5;
              return { index: index, after: after };
            };
            function ensureDropCaret() {
              var el = document.getElementById('ms-drop-caret');
              if (!el) {
                el = document.createElement('div');
                el.id = 'ms-drop-caret';
                document.body.appendChild(el);
              }
              return el;
            }
            window.__msShowDropCaret = function(x, y) {
              var t = window.__msDropTargetAt(x, y);
              var caret = ensureDropCaret();
              var bodyRect = document.body.getBoundingClientRect();
              var top = 8;
              if (t.append) {
                var blocks = document.querySelectorAll('.block');
                if (blocks.length) {
                  var last = blocks[blocks.length - 1].getBoundingClientRect();
                  top = last.bottom - bodyRect.top;
                } else {
                  top = y - bodyRect.top;
                }
              } else if (typeof t.index === 'number') {
                var block = document.querySelector('.block[data-index=\"' + t.index + '\"]');
                if (block) {
                  var rect = block.getBoundingClientRect();
                  top = (t.after ? rect.bottom : rect.top) - bodyRect.top;
                } else {
                  top = y - bodyRect.top;
                }
              } else {
                top = y - bodyRect.top;
              }
              caret.style.top = Math.max(0, top) + 'px';
              caret.style.display = 'block';
              return t;
            };
            window.__msHideDropCaret = function() {
              var el = document.getElementById('ms-drop-caret');
              if (el) el.style.display = 'none';
            };
            // HTML5 drop path — reliable inside WKWebView (AppKit alone often fails to insert).
            document.addEventListener('dragenter', function(ev) {
              if (!ev.dataTransfer) return;
              ev.preventDefault();
            });
            document.addEventListener('dragover', function(ev) {
              if (!ev.dataTransfer) return;
              ev.preventDefault();
              ev.dataTransfer.dropEffect = 'copy';
              // Caret line is drawn in AppKit (correct coords for Finder drags).
            });
            document.addEventListener('dragleave', function(ev) {
              if (ev.relatedTarget && document.documentElement.contains(ev.relatedTarget)) return;
            });
            document.addEventListener('drop', function(ev) {
              ev.preventDefault();
              ev.stopPropagation();
              window.__msHideDropCaret();
              var target = window.__msDropTargetAt(ev.clientX, ev.clientY);
              var files = ev.dataTransfer && ev.dataTransfer.files;
              if (!files || !files.length) {
                post('imageDrop', { target: target, missingFiles: true });
                return;
              }
              var file = files[0];
              var type = file.type || '';
              if (type && type.indexOf('image/') !== 0) return;
              var reader = new FileReader();
              reader.onload = function() {
                post('imageDrop', {
                  dataUrl: reader.result,
                  name: file.name || 'image.png',
                  target: target
                });
              };
              reader.readAsDataURL(file);
            });
            function handleTailClick(ev) {
              if (ev.target.closest('a')) return;
              if (ev.target.closest('.block')) return;
              post('append', null);
            }
            document.querySelector('.tail').addEventListener('click', handleTailClick);
            document.body.addEventListener('click', function(ev) {
              if (ev.target === document.body) post('append', null);
            });
            document.querySelectorAll('a[href]').forEach(function(a) {
              a.addEventListener('click', function(ev) {
                ev.preventDefault();
                post('openURL', a.href);
              });
            });
          })();
        </script>
        </body>
        </html>
        """
    }

    /// CSS class for the active textarea so edit mode matches rendered metrics.
    private static func activeSourceKind(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "blank" }
        if trimmed.hasPrefix("```") || isIndentedCode(source) { return "code" }
        if let level = headingLevel(trimmed) { return "h\(level)" }
        if trimmed.hasPrefix(">") { return "quote" }
        if isList(source) { return "list" }
        return "para"
    }

    static func renderBlock(_ source: String, noteDirectory: URL? = nil) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "<p><br></p>" }

        if trimmed.hasPrefix("```") {
            return renderFence(source)
        }
        if isIndentedCode(source) {
            return renderIndentedCode(source)
        }
        if looksLikeTable(source) {
            return renderTable(source, noteDirectory: noteDirectory)
        }
        if trimmed.hasPrefix(">") {
            return renderQuote(source, noteDirectory: noteDirectory)
        }
        if isList(source) {
            return renderList(source, noteDirectory: noteDirectory)
        }
        if let level = headingLevel(trimmed) {
            let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
            return "<h\(level)>\(renderInline(String(text), noteDirectory: noteDirectory))</h\(level)>"
        }
        if isRule(trimmed) {
            return "<hr>"
        }
        let html = source
            .components(separatedBy: "\n")
            .map { renderInline($0, noteDirectory: noteDirectory) }
            .joined(separator: "<br>")
        return "<p>\(html)</p>"
    }

    // MARK: - Block renderers

    private static func renderFence(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "<pre><code></code></pre>" }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return "<pre><code>\(escapeHTML(lines.joined(separator: "\n")))</code></pre>"
    }

    private static func renderIndentedCode(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            return line
        }
        return "<pre><code>\(escapeHTML(lines.joined(separator: "\n")))</code></pre>"
    }

    private static func renderQuote(_ source: String, noteDirectory: URL?) -> String {
        let inner = source.components(separatedBy: "\n").map { line -> String in
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") {
                t = String(t.dropFirst())
                if t.hasPrefix(" ") { t = String(t.dropFirst()) }
            }
            return renderInline(t, noteDirectory: noteDirectory)
        }.joined(separator: "<br>")
        return "<blockquote>\(inner)</blockquote>"
    }

    private static func renderList(_ source: String, noteDirectory: URL?) -> String {
        struct Item {
            var level: Int
            var ordered: Bool
            var html: String?
            /// Empty line between list items — keep visible height.
            var isGap: Bool
        }

        func indentLevel(_ line: String) -> Int {
            var n = 0
            for ch in line {
                if ch == " " { n += 1 }
                else if ch == "\t" { n += 2 }
                else { break }
            }
            return n / 2
        }

        var items: [Item] = []
        for line in source.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                items.append(Item(level: items.last?.level ?? 0, ordered: items.last?.ordered ?? false, html: nil, isGap: true))
                continue
            }
            let level = indentLevel(line)
            let ordered: Bool
            let content: String
            if t.count >= 2, let first = t.first, "-*+".contains(first) {
                ordered = false
                content = String(t.dropFirst(2))
            } else if let dot = t.firstIndex(of: "."),
                      !t[t.startIndex..<dot].isEmpty,
                      t[t.startIndex..<dot].allSatisfy(\.isNumber) {
                ordered = true
                content = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }
            items.append(Item(
                level: level,
                ordered: ordered,
                html: renderInline(content, noteDirectory: noteDirectory),
                isGap: false
            ))
        }

        let realItems = items.filter { !$0.isGap }
        guard !realItems.isEmpty else {
            return "<p>\(renderInline(source, noteDirectory: noteDirectory))</p>"
        }

        var out = ""
        var stack: [(level: Int, ordered: Bool)] = []

        for item in items {
            if item.isGap {
                // Need an open list to hang the spacer on.
                if stack.isEmpty {
                    let seed = realItems[0]
                    out += seed.ordered ? "<ol>" : "<ul>"
                    stack.append((seed.level, seed.ordered))
                }
                out += #"<li class="list-gap" aria-hidden="true"><br></li>"#
                continue
            }

            while let top = stack.last, top.level > item.level {
                out += top.ordered ? "</ol>" : "</ul>"
                stack.removeLast()
            }
            if stack.isEmpty || item.level > stack.last!.level {
                out += item.ordered ? "<ol>" : "<ul>"
                stack.append((item.level, item.ordered))
            } else if stack.last!.ordered != item.ordered {
                out += stack.last!.ordered ? "</ol>" : "</ul>"
                stack.removeLast()
                out += item.ordered ? "<ol>" : "<ul>"
                stack.append((item.level, item.ordered))
            }
            out += "<li>\(item.html ?? "")</li>"
        }
        while let top = stack.popLast() {
            out += top.ordered ? "</ol>" : "</ul>"
        }
        return out
    }

    private static func renderTable(_ source: String, noteDirectory: URL?) -> String {
        let rows = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard rows.count >= 2 else { return "<p>\(renderInline(source, noteDirectory: noteDirectory))</p>" }

        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            return s.split(separator: "|", omittingEmptySubsequences: false).map {
                renderInline($0.trimmingCharacters(in: .whitespaces), noteDirectory: noteDirectory)
            }
        }

        let header = cells(rows[0])
        var html = "<table><thead><tr>" + header.map { "<th>\($0)</th>" }.joined() + "</tr></thead><tbody>"
        for row in rows.dropFirst(2) {
            let c = cells(row)
            html += "<tr>" + c.map { "<td>\($0)</td>" }.joined() + "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    private static func renderInline(_ text: String, noteDirectory: URL?) -> String {
        var work = text
        var slots: [String] = []
        func park(_ html: String) -> String {
            let token = "%%H\(slots.count)%%"
            slots.append(html)
            return token
        }

        work = replace(work, pattern: #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^)]+))\s*\)"#) { m in
            let raw = m[2].isEmpty ? m[3] : m[2]
            let src = resolveResourceURL(raw.trimmingCharacters(in: .whitespacesAndNewlines), noteDirectory: noteDirectory)
            return park("<img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(m[1]))\">")
        }
        work = replace(work, pattern: #"\[([^\]]+)\]\(\s*(?:<([^>]+)>|([^)]+))\s*\)"#) { m in
            let raw = m[2].isEmpty ? m[3] : m[2]
            let href = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return park("<a href=\"\(escapeHTML(href))\">\(escapeHTML(m[1]))</a>")
        }
        work = replace(work, pattern: #"`([^`]+)`"#) { m in
            park("<code>\(escapeHTML(m[1]))</code>")
        }
        // Bare URLs → clickable (after MD links so `[text](url)` wins).
        work = replace(work, pattern: #"(?i)https?://[^\s<>\"'`\[\]()]+"#) { m in
            let url = trimTrailingURLPunctuation(m[0])
            guard !url.isEmpty else { return m[0] }
            return park("<a href=\"\(escapeHTML(url))\">\(escapeHTML(url))</a>")
        }

        work = escapeHTML(work)
        work = replace(work, pattern: #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        work = replace(work, pattern: #"__(.+?)__"#) { "<strong>\($0[1])</strong>" }
        work = replace(work, pattern: #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        work = replace(work, pattern: #"\*(.+?)\*"#) { "<em>\($0[1])</em>" }

        for (i, html) in slots.enumerated() {
            work = work.replacingOccurrences(of: "%%H\(i)%%", with: html)
        }
        return work
    }

    /// Drop trailing sentence punctuation often glued to pasted URLs.
    private static func trimTrailingURLPunctuation(_ raw: String) -> String {
        var url = raw
        while let last = url.last, ".,:;!?)]}".contains(last) {
            url = String(url.dropLast())
        }
        return url
    }

    private static func resolveResourceURL(_ src: String, noteDirectory: URL?) -> String {
        if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") {
            return src
        }
        if src.hasPrefix("file:") {
            return src
        }
        guard let noteDirectory else { return src }
        var path = src.removingPercentEncoding ?? src
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        let fileURL = noteDirectory.appendingPathComponent(path)
        // Embed as data URL — sandboxed WKWebView often blocks relative/file image loads.
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            let ext = fileURL.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            case "tif", "tiff": mime = "image/tiff"
            case "bmp": mime = "image/bmp"
            case "heic": mime = "image/heic"
            default: mime = "image/png"
            }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return path
    }

    // MARK: - Utils

    private static func isIndentedCode(_ source: String) -> Bool {
        let lines = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { $0.hasPrefix("\t") || $0.hasPrefix("    ") }
    }

    private static func looksLikeTable(_ source: String) -> Bool {
        let rows = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard rows.count >= 2 else { return false }
        return rows[0].contains("|") && rows[1].contains("|") && rows[1].contains("-")
    }

    private static func isList(_ source: String) -> Bool {
        let first = source.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        for m in ["- ", "* ", "+ "] where first.hasPrefix(m) { return true }
        guard let dot = first.firstIndex(of: ".") else { return false }
        let num = first[first.startIndex..<dot]
        return !num.isEmpty && num.allSatisfy(\.isNumber)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" }
            || compact.allSatisfy { $0 == "*" }
            || compact.allSatisfy { $0 == "_" }
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return level
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(
        _ text: String,
        pattern: String,
        replacer: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            var groups: [String] = [ns.substring(with: match.range)]
            for i in 1..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            let replacement = replacer(groups)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}

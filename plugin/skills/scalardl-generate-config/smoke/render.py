#!/usr/bin/env python3
"""Minimal Mustache renderer for scalardl-generate-config smoke tests.

Supports the subset of Mustache the templates use:
  - {{var}}                 — variable interpolation (no HTML escape)
  - {{#section}}...{{/}}    — section (renders if truthy)
  - {{^section}}...{{/}}    — inverted section (renders if falsy)
  - Nested sections of the same name
  - Standalone-tag rule (per Mustache spec): when a section tag (#, ^, /)
    appears alone on a line with only whitespace before/after, the entire
    line — including the trailing newline — is stripped from the output.
    Critical for shell scripts where `\` line-continuation breaks if a
    standalone section tag leaves a blank line behind.

Doesn't support: partials, lambdas, dotted names, list iteration, comments.
That's all this skill's templates need.

Usage:
  ./render.py <template-path> '<json-context>' > rendered.txt
"""
import re
import sys
import json


def _standalone_line_span(template, tag_start, tag_end):
    """Return (line_start, line_end_after_newline) if the tag at template[tag_start:tag_end]
    is a 'standalone' tag — i.e., everything from the preceding \n (or BOS) up to tag_start
    is whitespace, AND everything from tag_end up to the next \n (or EOS) is whitespace.
    Otherwise return None.

    Per Mustache spec, the entire line including the trailing newline is removed.
    """
    line_start = template.rfind('\n', 0, tag_start) + 1   # 0 if no \n
    pre = template[line_start:tag_start]
    if pre.strip() != '':
        return None
    nl = template.find('\n', tag_end)
    line_end = nl + 1 if nl != -1 else len(template)
    post = template[tag_end:line_end - 1 if nl != -1 else line_end]
    if post.strip() != '':
        return None
    return (line_start, line_end)


def render(template, ctx):
    out = []
    pos = 0
    while pos < len(template):
        m = re.search(r'\{\{([#^/])?\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}', template[pos:])
        if not m:
            out.append(template[pos:])
            break
        kind, name = m.group(1), m.group(2)
        tag_abs_start = pos + m.start()
        tag_abs_end = pos + m.end()

        # Standalone-tag detection (only for section tags, not interpolation).
        standalone = None
        if kind in ('#', '^', '/'):
            standalone = _standalone_line_span(template, tag_abs_start, tag_abs_end)

        if standalone is not None:
            # Emit text up to the start of this standalone line (drop the line itself).
            out.append(template[pos:standalone[0]])
        else:
            out.append(template[pos:tag_abs_start])

        if kind in ('#', '^'):
            depth = 1
            cursor = tag_abs_end
            while depth > 0:
                m2 = re.search(
                    r'\{\{([#^/])\s*' + re.escape(name) + r'\s*\}\}',
                    template[cursor:],
                )
                if not m2:
                    raise ValueError(f"Unclosed section {name}")
                if m2.group(1) in ('#', '^'):
                    depth += 1
                elif m2.group(1) == '/':
                    depth -= 1
                cursor += m2.end()
            # cursor is now just past the closing {{/name}} tag.
            closing_abs_start = cursor - len(m2.group(0))

            # Standalone-strip the closing tag too, if applicable.
            closing_standalone = _standalone_line_span(template, closing_abs_start, cursor)

            inner_start = standalone[1] if standalone is not None else tag_abs_end
            inner_end = closing_standalone[0] if closing_standalone is not None else closing_abs_start
            inner = template[inner_start:inner_end]

            val = ctx.get(name, False)
            truthy = bool(val) and val != "false"
            if kind == '#' and truthy:
                out.append(render(inner, ctx))
            elif kind == '^' and not truthy:
                out.append(render(inner, ctx))

            pos = closing_standalone[1] if closing_standalone is not None else cursor
        elif kind == '/':
            # Stray closing tag at top level — shouldn't happen with well-formed templates,
            # but handle gracefully by skipping past it (and its standalone line if any).
            pos = standalone[1] if standalone is not None else tag_abs_end
        else:
            val = ctx.get(name, "")
            # Python's str(True) is "True" / str(False) is "False". ScalarDL
            # properties + Helm YAML both expect lowercase "true" / "false".
            # Java's Boolean.parseBoolean is case-insensitive, but YAML 1.2
            # only recognises lowercase as the boolean type — capitalised
            # values become strings, which trips strict parsers. The skill's
            # production rendering path (Claude doing manual substitution)
            # is documented to do the same lowercasing; this keeps the smoke
            # renderer aligned.
            if isinstance(val, bool):
                val = "true" if val else "false"
            out.append(str(val))
            pos = tag_abs_end
    return ''.join(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: render.py <template-path> <json-context>", file=sys.stderr)
        sys.exit(2)
    template_path = sys.argv[1]
    ctx = json.loads(sys.argv[2])
    with open(template_path) as f:
        sys.stdout.write(render(f.read(), ctx))

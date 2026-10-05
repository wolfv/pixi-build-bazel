"""A small block-style YAML parser, sufficient for pixi.lock files.

Supports block mappings, block sequences (including sequences indented at the
same level as their parent key), plain / single / double quoted scalars and
empty flow collections (`[]`, `{}`). Starlark has no recursion, so parsing is
done with an explicit stack.
"""

def _scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        inner = s[1:-1]
        if s[0] == "'":
            return inner.replace("''", "'")
        return inner.replace("\\\"", "\"").replace("\\\\", "\\")
    if s == "[]":
        return []
    if s == "{}":
        return {}
    if s in ("null", "~"):
        return None
    return s

def _split_key(text):
    """Returns (key, value) if `text` is a `key: value` pair, else None."""
    if not text or text[0] in "'\"":
        return None
    if text.endswith(":"):
        return (text[:-1], "")
    idx = text.find(": ")
    if idx <= 0:
        return None
    return (text[:idx], text[idx + 2:])

def parse_yaml(content):
    """Parses `content` into nested dicts / lists / strings.

    Args:
        content: YAML document text.
    Returns:
        The parsed document (a dict for pixi.lock).
    """
    root = {}

    # (child indent, container, kind) — kind is "map" or "seq".
    stack = [(-1, root, "map")]
    pending = None  # (parent map, key, key indent) waiting for a nested block

    for raw in content.split("\n"):
        line = raw.rstrip()
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#") or stripped == "---":
            continue
        indent = len(line) - len(stripped)
        is_item = stripped == "-" or stripped.startswith("- ")

        if pending:
            parent, key, key_indent = pending
            pending = None
            if is_item and indent >= key_indent:
                new = []
                parent[key] = new
                stack.append((indent, new, "seq"))
            elif not is_item and indent > key_indent:
                new = {}
                parent[key] = new
                stack.append((indent, new, "map"))
            else:
                parent[key] = None

        for _ in range(len(stack)):
            top_indent, _, top_kind = stack[-1]
            if top_indent > indent or (top_indent == indent and (top_kind == "seq") != is_item):
                stack.pop()
            else:
                break

        _, container, kind = stack[-1]

        # A sequence item may itself start a mapping: `- key: value`.
        entries = []
        if is_item:
            if kind != "seq":
                fail("pixi.lock: unexpected list item: " + line)
            rest = stripped[1:].strip()
            kv = _split_key(rest)
            if kv == None:
                container.append(_scalar(rest))
                continue
            item = {}
            container.append(item)
            indent = indent + 2
            stack.append((indent, item, "map"))
            container = item
            entries.append(kv)
        else:
            if kind != "map":
                fail("pixi.lock: unexpected mapping entry: " + line)
            kv = _split_key(stripped)
            if kv == None:
                fail("pixi.lock: cannot parse line: " + line)
            entries.append(kv)

        for key, value in entries:
            key = _scalar(key)
            if value.strip() == "":
                pending = (container, key, indent)
            else:
                container[key] = _scalar(value)

    if pending:
        pending[0][pending[1]] = None
    return root

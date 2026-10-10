#!/usr/bin/env python3
"""anchor.py: anchored source patching that fails loudly.

Typical use in a patch script:

    from anchor import Patch
    p = Patch.load("dec/scripts/Main.as")
    p.sub("import flash.desktop.*;\\n", "")                     # exactly once
    p.sub("NativeApplication.nativeApplication.exit();", 'fscommand("quit");', count=3)
    p.sub_regex(r"var\\s+steam\\s*:\\s*\\w+;", "", count=1)
    p.drop_method("initSteam")
    p.insert_after("function init():void\\n{", "trace('boot');")
    p.insert_before("function quit():void", "// comment\\n")
    p.forbid(["Steamworks", "nativeWindow", "NativeApplication"])
    p.save("out/Main.as")
    p.summary()

Every anchor must match exactly the expected number of times, otherwise the script exits
with status 1 and the message  patch anchor matched Nx (expected M): '<anchor start>'.
A different build of the game therefore fails loudly instead of being patched halfway.

Library use returns nothing on success. Set Patch(..., raise_errors=True) to get a
PatchError exception instead of SystemExit (useful for tests).
"""
import re
import sys


class PatchError(Exception):
    pass


def read_text(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


class Patch:
    def __init__(self, text, name="source", raise_errors=False):
        self.src = text
        self.name = name
        self.raise_errors = raise_errors
        self.log = []  # (description, count)

    @classmethod
    def load(cls, path, **kw):
        return cls(read_text(path), name=path, **kw)

    def save(self, path):
        write_text(path, self.src)

    def _fail(self, msg):
        if self.raise_errors:
            raise PatchError(msg)
        sys.exit(msg)

    def _expect(self, n, count, what):
        if n != count:
            self._fail("patch anchor matched %dx (expected %d): %r" % (n, count, what[:80]))

    def sub(self, old, new, count=1):
        """Replace the literal text old by new. old must occur exactly count times."""
        self._expect(self.src.count(old), count, old)
        self.src = self.src.replace(old, new)
        self.log.append(("sub " + old.strip()[:50], count))

    def sub_regex(self, pattern, repl, count=1, flags=0):
        """Regex substitution; the pattern must match exactly count times. repl may use \\1 groups."""
        rx = re.compile(pattern, flags)
        n = len(rx.findall(self.src))
        self._expect(n, count, pattern)
        self.src = rx.sub(repl, self.src)
        self.log.append(("regex " + pattern[:50], count))

    def drop_method(self, name, count=1):
        """Remove a whole method (any modifiers) by brace matching, including its body.
        Braces inside string literals and comments are skipped."""
        rx = re.compile(r"\n[ \t]*(?:(?:public|private|protected|internal|static|override|final|native)\s+)*"
                        r"function\s+" + re.escape(name) + r"\s*\(")
        found = 0
        while True:
            m = rx.search(self.src)
            if not m:
                break
            end = self._match_brace(self.src.index("{", m.end()))
            self.src = self.src[:m.start()] + self.src[end + 1:]
            found += 1
        self._expect(found, count, "method " + name)
        self.log.append(("drop_method " + name, found))

    def _match_brace(self, i):
        s = self.src
        depth = 0
        j = i
        n = len(s)
        while j < n:
            c = s[j]
            if c in "\"'":
                q = c
                j += 1
                while j < n and s[j] != q:
                    j += 2 if s[j] == "\\" else 1
            elif s.startswith("//", j):
                j = s.find("\n", j)
                if j < 0:
                    break
            elif s.startswith("/*", j):
                j = s.find("*/", j) + 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return j
            j += 1
        self._fail("unbalanced braces while dropping a method")

    def insert_after(self, anchor, text, count=1):
        """Insert text right after the anchor (anchor must occur exactly count times)."""
        self._expect(self.src.count(anchor), count, anchor)
        self.src = self.src.replace(anchor, anchor + text)
        self.log.append(("insert_after " + anchor.strip()[:40], count))

    def insert_before(self, anchor, text, count=1):
        """Insert text right before the anchor (anchor must occur exactly count times)."""
        self._expect(self.src.count(anchor), count, anchor)
        self.src = self.src.replace(anchor, text + anchor)
        self.log.append(("insert_before " + anchor.strip()[:40], count))

    def forbid(self, identifiers, word=True):
        """Exit if any identifier is still referenced. Whole word match by default."""
        left = []
        for ident in identifiers:
            rx = re.compile((r"(?<![\w$.])" + re.escape(ident) + r"(?![\w$])") if word and ident.isidentifier()
                            else re.escape(ident))
            hits = [self.src.count("\n", 0, m.start()) + 1 for m in rx.finditer(self.src)]
            if hits:
                left.append("%s (lines %s)" % (ident, ",".join(map(str, hits[:5]))))
        if left:
            self._fail("leftover forbidden references: " + "; ".join(left))
        self.log.append(("forbid %d identifiers" % len(identifiers), 0))

    def summary(self, out=sys.stdout):
        for desc, n in self.log:
            out.write("  %-60s x%d\n" % (desc, n))
        out.write("patched OK (%s, %d steps)\n" % (self.name, len(self.log)))


def _selftest():
    src = ("package\n{\n   import flash.desktop.*;\n   public class T\n   {\n"
           "      public function a():void\n      {\n         var s:String = \"}{\";\n"
           "         if(x) { NativeApplication.nativeApplication.exit(); }\n      }\n"
           "      private function b():void\n      {\n         // }\n         y();\n      }\n"
           "      function c():void\n      {\n         NativeApplication.nativeApplication.exit();\n      }\n   }\n}\n")
    p = Patch(src, raise_errors=True)
    p.sub("   import flash.desktop.*;\n", "")
    p.sub("NativeApplication.nativeApplication.exit();", 'fscommand("quit");', count=2)
    for bad in (lambda: p.sub("nothing here", "x"), lambda: p.sub("fscommand", "x", count=1),
                lambda: p.insert_after("missing", "x")):
        try:
            bad()
        except PatchError as e:
            assert "patch anchor matched" in str(e) and "expected" in str(e), e
        else:
            raise AssertionError("anchor miss not detected")
    p.sub_regex(r"y\(\)", "z()")
    p.drop_method("b")
    assert "function b" not in p.src and "function c" in p.src and "function a" in p.src
    p.insert_after("function c():void\n      {\n", "         trace(1);\n")
    p.insert_before("      function c", "      // c below\n")
    p.forbid(["Steamworks", "nativeWindow"])
    try:
        p.forbid(["fscommand"])
    except PatchError as e:
        assert "leftover forbidden references" in str(e)
    else:
        raise AssertionError("forbid did not fire")
    p.summary(out=open("/dev/null", "w"))
    try:
        Patch("a a a", raise_errors=True).sub("a", "b", count=2)
    except PatchError as e:
        assert str(e).startswith("patch anchor matched 3x (expected 2)")
    # SystemExit mode
    try:
        Patch("abc").sub("zzz", "y")
    except SystemExit as e:
        assert "patch anchor matched 0x (expected 1)" in str(e)
    else:
        raise AssertionError("SystemExit expected")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        _selftest()
        print("anchor self test OK")
    else:
        sys.stderr.write(__doc__)
        sys.exit(1)

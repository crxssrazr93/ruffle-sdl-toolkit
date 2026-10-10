#!/usr/bin/env python3
"""example_patch.py <decompiled dir> [Class]  (template, edit the anchors for your game)

Patches the decompiled AS3 shell class of an AIR game so it runs in Ruffle:
  1. strip AIR only imports (flash.desktop, flash.filesystem, ANE packages)
  2. NativeApplication.nativeApplication.exit()  ->  fscommand("quit")
  3. remove nativeWindow code (window sizing, fullscreen, close listeners)
  4. replace save files by a SharedObject with a path independent name
  5. boot parameters through loaderInfo.parameters (flashvars) instead of command line args
  6. scan for leftovers and fail if any AIR reference survived

Workflow (see README.md):
  tools/swf/ffdec.sh as3 MYGAME.swf work/dec Main
  python3 tools/swf/example_patch.py work/dec Main        # writes work/patched/Main.as
  tools/swf/ffdec.sh replace-as3 MYGAME.swf out.swf Main work/patched/Main.as

Every anchor below is an EXAMPLE. Read your own decompiled source, copy the exact text
(JPEXS indents three spaces per level and writes "function f() : void" with spaces around the colon) and set the expected counts.
Anchors that do not match exactly make the script exit with
"patch anchor matched Nx (expected M)", which is the point: a different build of the game
must fail loudly instead of being half patched.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anchor import Patch  # noqa: E402

if len(sys.argv) < 2:
    sys.exit(__doc__)
dec = sys.argv[1]
cls = sys.argv[2] if len(sys.argv) > 2 else "Main"
src_path = os.path.join(dec, "scripts", cls + ".as")
out_dir = os.path.join(os.path.dirname(os.path.abspath(dec)), "patched")
os.makedirs(out_dir, exist_ok=True)

p = Patch.load(src_path)

# 1. AIR only imports (playerglobal has no flash.desktop or flash.filesystem, so the recompile fails)
p.sub("   import flash.desktop.*;\n", "")
p.sub("   import flash.filesystem.*;\n", "")
# a store SDK shipped as a native extension (ANE) is dropped the same way:
# p.sub("   import com.vendor.sdk.*;\n", "")
# fscommand lives in flash.system.fscommand; add the import if the class has none
# (also needed for SharedObject below: flash.net.SharedObject)
p.sub_regex(r"(package[^\n]*\n\s*\{\n)", r"\1   import flash.system.fscommand;\n   import flash.net.SharedObject;\n", count=1)

# 2. quit: ruffle_sdl maps fscommand("quit") to a clean exit
p.sub("NativeApplication.nativeApplication.exit();", 'fscommand("quit");', count=1)

# 3. window code: remove the whole method, then every call site
p.drop_method("setupNativeWindow")
p.sub("         this.setupNativeWindow();\n", "")
# or single statements:
# p.sub("         stage.nativeWindow.maximize();\n", "")

# 4. saves: AIR games often write files; Ruffle persists SharedObjects, keyed by a path you control.
#    "/" as local path makes the key independent of where the SWF sits on each device.
p.sub_regex(r"[ \t]*(?:private|public|protected)\s+var\s+saveFile\s*:\s*File\s*=[^;]*;\n", "", count=1)
p.drop_method("writeSaveFile")
p.insert_before("      public function loadGame() : void", """      private function saveGame(data:Object) : void
      {
         var so:SharedObject = SharedObject.getLocal("mygame_save","/");
         so.data.save = data;
         so.flush();
      }

""")

# 5. flashvars: the front end passes  --flashvars "key=value&key2=value2"
# (after the super() call: loaderInfo is only valid once the display object exists)
p.insert_after("         super();\n", """         var fv:Object = this.loaderInfo.parameters;
         var startLevel:String = fv.level ? String(fv.level) : "";
""")

# 6. nothing AIR may survive (a leftover is a runtime error 1065 or a compile error)
p.forbid(["NativeApplication", "nativeWindow", "NativeWindow", "flash.desktop", "flash.filesystem",
          "File.", "FileStream", "Steamworks", "GameInput"])

p.save(os.path.join(out_dir, cls + ".as"))
p.summary()
print("wrote", os.path.join(out_dir, cls + ".as"))

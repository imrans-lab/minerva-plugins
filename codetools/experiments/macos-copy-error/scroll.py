"""WIP: explicitly positioned wheel event; read README before use."""
import argparse
import ctypes as C

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--allow-ui-control", action="store_true", required=True)
parser.add_argument("--x", type=float, required=True)
parser.add_argument("--y", type=float, required=True)
parser.add_argument("--delta", type=int, required=True)
args = parser.parse_args()
ax = C.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
ax.AXIsProcessTrusted.restype = C.c_bool
if not ax.AXIsProcessTrusted():
    raise SystemExit("Accessibility permission required")

class Point(C.Structure):
    _fields_ = [("x", C.c_double), ("y", C.c_double)]

cg = C.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
create = cg.CGEventCreateScrollWheelEvent
create.restype = C.c_void_p
create.argtypes = [C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32]
cg.CGEventSetLocation.argtypes = [C.c_void_p, Point]
cg.CGEventPost.argtypes = [C.c_uint32, C.c_void_p]
cf.CFRelease.argtypes = [C.c_void_p]
event = create(None, 0, 1, args.delta)
if not event:
    raise SystemExit("Could not create scroll event")
try:
    cg.CGEventSetLocation(event, Point(args.x, args.y))
    cg.CGEventPost(0, event)
finally:
    cf.CFRelease(event)

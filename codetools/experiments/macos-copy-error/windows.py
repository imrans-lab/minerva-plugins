import ctypes as C, json
cf=C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg=C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
def bind(lib,name,result,args):
 f=getattr(lib,name); f.restype=result; f.argtypes=args; return f
ptr=C.c_void_p; lng=C.c_long
string=bind(cf,'CFStringCreateWithCString',ptr,[ptr,C.c_char_p,C.c_uint32])
get=bind(cf,'CFDictionaryGetValue',ptr,[ptr,ptr])
num=bind(cf,'CFNumberGetValue',C.c_bool,[ptr,C.c_int,ptr])
text=bind(cf,'CFStringGetCString',C.c_bool,[ptr,C.c_char_p,lng,C.c_uint32])
release=bind(cf,'CFRelease',None,[ptr])
count=bind(cf,'CFArrayGetCount',lng,[ptr]); at=bind(cf,'CFArrayGetValueAtIndex',ptr,[ptr,lng])
listing=bind(cg,'CGWindowListCopyWindowInfo',ptr,[C.c_uint32,C.c_uint32])
def field(d,k):
 key=string(None,k.encode(),0x08000100); v=get(d,key); release(key); return v
def number(p):
 v=C.c_longlong(); num(p,4,C.byref(v)); return v.value
def txt(p):
 if not p:return ''
 b=C.create_string_buffer(4096); text(p,b,4096,0x08000100);return b.value.decode()
a=listing(1,0); out=[]
for i in range(count(a)):
 d=at(a,i); owner=txt(field(d,'kCGWindowOwnerName'))
 if owner!='Godot':continue
 b=field(d,'kCGWindowBounds')
 out.append({'id':number(field(d,'kCGWindowNumber')),'pid':number(field(d,'kCGWindowOwnerPID')),'owner':owner,'title':txt(field(d,'kCGWindowName')),'bounds':{k:number(field(b,k)) for k in ['X','Y','Width','Height']}})
release(a)
print(json.dumps(out,indent=2))

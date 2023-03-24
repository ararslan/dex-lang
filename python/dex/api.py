# Copyright 2020 Google LLC
#
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file or at
# https://developers.google.com/open-source/licenses/bsd

import ctypes
import pathlib
import atexit
from pkg_resources import resource_filename
from typing import List

lib = ctypes.cdll.LoadLibrary(resource_filename('dex', 'libDex.so'))

def tagged_union(name: str, members: List[type]):
  named_members = [(f"t{i}", member) for i, member in enumerate(members)]
  payload = type(name + "Payload", (ctypes.Union,), {"_fields_": named_members})
  union = type(name, (ctypes.Structure,), {
    "_fields_": [("tag", ctypes.c_uint64), ("payload", payload)],
    "value": property(
        fget=lambda self: getattr(self.payload, f"t{self.tag}"),
        fset=lambda self, value: setattr(self.payload, f"t{self.tag}", value)),
    "Payload": payload,
  })
  return union

CLit = tagged_union("Lit", [
  ctypes.c_int64,
  ctypes.c_int32,
  ctypes.c_uint8,
  ctypes.c_double,
  ctypes.c_float,
  ctypes.c_uint32,
  ctypes.c_uint64
])
class CRectArray(ctypes.Structure):
  _fields_ = [("data", ctypes.c_void_p),
              ("shape_ptr", ctypes.POINTER(ctypes.c_int64)),
              ("strides_ptr", ctypes.POINTER(ctypes.c_int64))]
CAtom = tagged_union("CAtom", [CLit, CRectArray])
assert ctypes.sizeof(CAtom) == 4 * 8

class HsAtom(ctypes.Structure): pass
class HsContext(ctypes.Structure): pass
class NativeFunctionObj(ctypes.Structure): pass
class NativeFunctionSignature(ctypes.Structure):
  _fields_ = [("arg", ctypes.c_char_p),
              ("res", ctypes.c_char_p),
              ("ccall", ctypes.c_char_p)]

class ExportCC:
  def __init__(self, value):
    self._as_parameter_ = ctypes.c_int32(value)

  @classmethod
  def from_param(cls, p):
    return p._as_parameter_
FlatCC = ExportCC(0)
XLACC = ExportCC(1)


HsAtomPtr = ctypes.POINTER(HsAtom)
HsContextPtr = ctypes.POINTER(HsContext)
CAtomPtr = ctypes.POINTER(CAtom)
NativeFunctionSignaturePtr = ctypes.POINTER(NativeFunctionSignature)
NativeFunction = ctypes.POINTER(NativeFunctionObj)

def dex_func(name, *signature):
  argtypes, restype = signature[:-1], signature[-1]
  f = getattr(lib, name)
  f.restype = restype
  f.argtypes = argtypes
  return f

init = dex_func('dexInit', None)
fini = dex_func('dexFini', None)
getError = dex_func('dexGetError', ctypes.c_char_p)

createContext  = dex_func('dexCreateContext',  HsContextPtr)
destroyContext = dex_func('dexDestroyContext', HsContextPtr, None)
forkContext    = dex_func('dexForkContext',    HsContextPtr, HsContextPtr)

eval      = dex_func('dexEval',      HsContextPtr, ctypes.c_char_p, ctypes.c_int)
lookup    = dex_func('dexLookup',    HsContextPtr, ctypes.c_char_p, HsAtomPtr)
freshName = dex_func('dexFreshName', HsContextPtr, ctypes.c_char_p)

print     = dex_func('dexPrint',     HsContextPtr, HsAtomPtr, ctypes.c_char_p)
toCAtom   = dex_func('dexToCAtom',   HsAtomPtr,    CAtomPtr,  ctypes.c_int)
fromCAtom = dex_func('dexFromCAtom', CAtomPtr,                HsAtomPtr)

compile    = dex_func('dexCompile', HsContextPtr, ExportCC, HsAtomPtr, NativeFunction)
unload     = dex_func('dexUnload',  HsContextPtr, NativeFunction, None)

getFunctionSignature  = dex_func('dexGetFunctionSignature', HsContextPtr, NativeFunction, NativeFunctionSignaturePtr)
freeFunctionSignature = dex_func('dexFreeFunctionSignature', NativeFunctionSignaturePtr, None)

roundtripJaxprJson = dex_func('dexRoundtripJaxprJson', ctypes.c_char_p, ctypes.c_char_p)
compileJaxpr = dex_func('dexCompileJaxpr', HsContextPtr, ExportCC, ctypes.c_char_p, NativeFunction)

xlaCpuTrampoline = lib.dexXLACPUTrampoline

init()
nofree = False
@atexit.register
def _teardown():
  global nofree
  fini()
  nofree = True  # Don't destruct any Haskell objects after the RTS has been shutdown

def as_cstr(x: str):
  return ctypes.c_char_p(x.encode('ascii'))

def from_cstr(cx):
  return cx.decode('ascii')

def raise_from_dex():
  raise RuntimeError(from_cstr(getError()))

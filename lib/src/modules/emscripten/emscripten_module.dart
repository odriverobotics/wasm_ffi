@JS()
library emscripten_module;

import 'dart:typed_data';
import 'package:js/js.dart';
import 'package:js/js_util.dart';
import '../module.dart';
import '../table.dart';
import '../../../wasm_ffi_meta.dart';

@JS('globalThis')
external Object get _globalThis;

@JS('Object.entries')
external List? _entries(Object? o);

@JS('WebAssembly.Global')
class WasmGlobal {
  external Object get value;
}

@JS('WebAssembly.Memory')
class WasmMemory {
  external ByteBuffer get buffer;
}

@JS()
@anonymous
class _EmscriptenModuleJs {
  external Uint8List? get wasmBinary;
  // ignore: non_constant_identifier_names
  external Uint8List? get HEAPU8;

  external Object? get asm; // Emscripten <3.1.44
  external Object? get wasmExports; // Emscripten >=3.1.44

  // Must have an unnamed factory constructor with named arguments.
  external factory _EmscriptenModuleJs({Uint8List wasmBinary});
}

const String _github = r'https://github.com/vm75/wasm_ffi';
String _adu(WasmSymbol? original, WasmSymbol? tried) =>
    'CRITICAL EXCEPTION! Address double use! This should never happen, please report this issue on github immediately at $_github'
    '\r\nOriginal: $original'
    '\r\nTried: $tried';

typedef _Malloc = int Function(int size);
typedef _Free = void Function(int address);

FunctionDescription _fromWasmFunction(String name, Function func) {
  String? s = getProperty(func, 'name');
  if (s != null) {
    int? index = int.tryParse(s);
    if (index != null) {
      int? length = getProperty(func, 'length');
      if (length != null) {
        return FunctionDescription(
            tableIndex: index,
            name: name,
            function: func,
            argumentCount: length);
      } else {
        throw ArgumentError('$name does not seem to be a function symbol!');
      }
    } else {
      throw ArgumentError('$name does not seem to be a function symbol!');
    }
  } else {
    throw ArgumentError('$name does not seem to be a function symbol!');
  }
}

/// Documentation is in `emscripten_module_stub.dart`!
@extra
class EmscriptenModule extends Module {
  static Function _moduleFunction(String moduleName) {
    Function? moduleFunction = getProperty(_globalThis, moduleName);
    if (moduleFunction != null) {
      return moduleFunction;
    } else {
      throw StateError('Could not find a emscripten module named $moduleName');
    }
  }

  /// Documentation is in `emscripten_module_stub.dart`!
  static Future<EmscriptenModule> process(String moduleName) async {
    Function moduleFunction = _moduleFunction(moduleName);
    _EmscriptenModuleJs modulePrototype = _EmscriptenModuleJs();
    Object? o = moduleFunction(modulePrototype);
    if (o != null) {
      final module = await promiseToFuture<_EmscriptenModuleJs>(o);
      return EmscriptenModule._fromJs(module);
    } else {
      throw StateError('Could not instantiate an emscripten module!');
    }
  }

  /// Documentation is in `emscripten_module_stub.dart`!
  static Future<EmscriptenModule> compile(
      Uint8List wasmBinary, String moduleName, {void Function(_EmscriptenModuleJs)? preinit}) async {
    Function moduleFunction = _moduleFunction(moduleName);
    _EmscriptenModuleJs modulePrototype =
        _EmscriptenModuleJs(wasmBinary: wasmBinary);
    Object? o = moduleFunction(modulePrototype);
    if (o != null) {
      final module = await promiseToFuture<_EmscriptenModuleJs>(o);
      preinit?.call(module);
      return EmscriptenModule._fromJs(module);
    } else {
      throw StateError('Could not instantiate an emscripten module!');
    }
  }

  final _EmscriptenModuleJs _emscriptenModuleJs;
  final List<WasmSymbol> _exports;
  final Table? indirectFunctionTable;
  final ByteBuffer _heap;
  final _Malloc _malloc;
  final _Free _free;

  @override
  List<WasmSymbol> get exports => _exports;

  EmscriptenModule._(
      this._emscriptenModuleJs, this._exports, this.indirectFunctionTable, this._heap, this._malloc, this._free);

  factory EmscriptenModule._fromJs(_EmscriptenModuleJs module) {
    Object? asm = module.wasmExports ?? module.asm;
    ByteBuffer? heap = null;
    if (asm != null) {
      Map<int, WasmSymbol> knownAddresses = {};
      _Malloc? malloc;
      _Free? free;
      List<WasmSymbol> exports = [];
      List? entries = _entries(asm);
      Table? indirectFunctionTable;
      if (entries != null) {
        for (dynamic entry in entries) {
          if (entry is List) {
            Object value = entry.last;
            // TODO: Not sure if `value` can ever be `int` directly. I only
            // observed it being WebAssembly.Global for globals.
            if (value is int || ((value is WasmGlobal) && value.value is int)) {
              final int address =
                  (value is int) ? value : ((value as WasmGlobal).value as int);
              Global g = Global(address: address, name: entry.first as String);
              if (knownAddresses.containsKey(address) &&
                  knownAddresses[address] is! Global) {
                throw StateError(_adu(knownAddresses[address], g));
              }
              knownAddresses[address] = g;
              exports.add(g);
            } else if (value is Function) {
              FunctionDescription description =
                  _fromWasmFunction(entry.first as String, value);
              // It might happen that there are two different c functions that do nothing else than calling the same underlying c function
              // In this case, a compiler might substitute both functions with the underlying c function
              // So we got two functions with different names at the same table index
              // So it is actually ok if there are two things at the same address, as long as they are both functions
              if (knownAddresses.containsKey(description.tableIndex) &&
                  knownAddresses[description.tableIndex]
                      is! FunctionDescription) {
                throw StateError(
                    _adu(knownAddresses[description.tableIndex], description));
              }
              knownAddresses[description.tableIndex] = description;
              exports.add(description);
              if (description.name == 'malloc') {
                malloc = description.function as _Malloc;
              } else if (description.name == 'free') {
                free = description.function as _Free;
              }
            } else if (value is Table && entry.first as String == "__indirect_function_table") {
              indirectFunctionTable = value;
            } else if (entry.first as String == "memory") {
              assert (value is WasmMemory);
              heap ??= (value as WasmMemory).buffer;
            } else {
              print(
                  'Warning: Unexpected value in entry list! Entry is $entry, value is $value (of type ${value.runtimeType})');
            }
          } else {
            throw StateError('Unexpected entry in entries(Module[\'asm\'])!');
          }
        }
        if (malloc != null) {
          if (free != null) {
            assert(heap != null, 'Heap not found in module exports.');
            return EmscriptenModule._(module, exports, indirectFunctionTable, heap!, malloc, free);
          } else {
            throw StateError('Module does not export the free function!');
          }
        } else {
          throw StateError('Module does not export the malloc function!');
        }
      } else {
        throw StateError(
            'JavaScript error: Could not access entries of Module[\'asm\']!');
      }
    } else {
      throw StateError(
          'Could not access Module[\'asm\'], are your sure your module was compiled using emscripten?');
    }
  }

  @override
  void free(int pointer) => _free(pointer);

  @override
  ByteBuffer get heap => _heap;

  @override
  int malloc(int size) => _malloc(size);

  _EmscriptenModuleJs get module => _emscriptenModuleJs;
}

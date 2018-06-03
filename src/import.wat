;; $ wat2wasm import.wat -o import.wasm
(module
  (func $imported (import "imports" "imported_func") (param i32))
  (func $exported (export "exported_func")
    i32.const 18
    call $imported
  )
)

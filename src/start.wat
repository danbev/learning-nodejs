;; $ wat2wasm start.wat -o start.wasm
(module
  (func $imported (import "imports" "imported_func") (param i32))
  (func $exported (export "exported_func")
    get_global 0
    call $imported
  )
  (func $start_function 
    i32.const 2
    set_global 0)
  (global (mut i32) (i32.const 0))
  (start $start_function)
)

(module
  (func $add (export "add") (param $first i32) (param $second i32) (result i32)
    get_local $first
    get_local $second
    (i32.add)
  )
  (func $addTwo (param i32) (param i32) (result i32)
    get_local 0
    get_local 1
    call $add
  )
  (export "addTwo" (func $addTwo))
)

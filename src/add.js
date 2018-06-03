const fs = require('fs');
const buffer = fs.readFileSync('../scripts/helloworld.wasm');
WebAssembly.validate(buffer);

const promise = WebAssembly.instantiate(buffer);

promise.then((result) => {
  const instance = result.instance;
  const module = result.module;
  const add = instance.exports.add;
  console.log(add(1, 2));
  console.log(instance.exports.addTwo(2, 3));
});

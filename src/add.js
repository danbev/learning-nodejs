const fs = require('fs');
const buffer = fs.readFileSync('../scripts/helloworld.wasm');
console.log(WebAssembly.validate(buffer));

const promise = WebAssembly.instantiate(buffer, {});
console.log(promise);
promise.then((result) => {
  const instance = result.instance;
  const module = result.module;
  console.log('instance:', instance);
  console.log('instance.exports:', instance.exports);
  console.log('module:', module);
  const add = instance.exports.add;
  console.log(add(1, 2));
  console.log(instance.exports.addTwo(2, 3));
});


console.log(WebAssembly.Memory);

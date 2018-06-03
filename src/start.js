const fs = require('fs');
const buffer = fs.readFileSync('src/start.wasm');

WebAssembly.validate(buffer);

var importObject = {
    imports: { 
      imported_func: arg => console.log('imported_func:', arg) 
    }
};
const promise = WebAssembly.instantiate(buffer, importObject);

promise.then((result) => {
   result.instance.exports.exported_func()
});

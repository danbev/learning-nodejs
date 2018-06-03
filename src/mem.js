const fs = require('fs');
const buffer = fs.readFileSync('./src/mem.wasm');

const memory = new WebAssembly.Memory({initial:1});

function consoleLogString(offset, length) {
  const bytes = new Uint8Array(memory.buffer, offset, length);
  console.log(Buffer.from(bytes, 'utf8').toString());
}

const importObj = { 
  console: { log: consoleLogString }, 
  js: { mem: memory } 
};

const promise = WebAssembly.instantiate(buffer, importObj);
promise.then((result) => {
  result.instance.exports.hi();
});

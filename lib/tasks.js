function run() {
  const timeout = setTimeout(function timeout_cb(something) {
    console.log('timeout, arg1:', something);
  }, 0, "argument1");
  console.log(timeout);
  console.log(timeout._idlePrev);
  setImmediate(() => console.log('immediate'));
  process.nextTick(() => console.log('nextTick'));
  console.log('run completed.');
}

class S {
  constructor() {
  }
};
console.log({s: new S()});
run();

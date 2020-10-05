const crypto = require('crypto')
const tls = require('tls')
const fs = require('fs')

const private_key = fs.readFileSync('./lib/rsa_private_4096.pem', 'utf-8')
const public_key = fs.readFileSync('./lib/rsa_public_4096.pem', 'utf-8')
const message = 'bajja';


const signer = crypto.createSign('sha256');
signer.update(message);
signer.end();

// Just here to trigger NewRootCertDir
const root_certs = tls.rootCertificates;

const signature = signer.sign(private_key, 'base64')
const signature_hex = signature.toString('hex')

const verifier = crypto.createVerify('sha256');
verifier.update(message);
verifier.end();

const verified = verifier.verify(public_key, signature);

console.log(JSON.stringify({
    message: message,
    signature: signature_hex,
    verified: verified,
}, null, 2));

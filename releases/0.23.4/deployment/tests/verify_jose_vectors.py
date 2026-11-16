"""Independent standards decryption of ephemeral JOSE fixtures, stdin only."""
import base64, hashlib, hmac, json, pathlib, struct, sys, xml.etree.ElementTree as ET
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'test-libs'))
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives import hashes, padding as sympadding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_unwrap

def b64(value): return base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
def private(xml):
    root = ET.fromstring(xml)
    values = {item.tag: int.from_bytes(base64.b64decode(item.text), 'big') for item in root}
    return rsa.RSAPrivateNumbers(values['P'], values['Q'], values['D'], values['DP'], values['DQ'], values['InverseQ'], rsa.RSAPublicNumbers(values['Exponent'], values['Modulus'])).private_key()
def jws(value, jwk):
    head, payload, sig = value.split('.')
    assert json.loads(b64(head))['alg'] == 'RS256'
    key = rsa.RSAPublicNumbers(int.from_bytes(b64(jwk['e']), 'big'), int.from_bytes(b64(jwk['n']), 'big')).public_key()
    key.verify(b64(sig), (head + '.' + payload).encode(), padding.PKCS1v15(), hashes.SHA256())
    return json.loads(b64(payload))
def cbc(parts, cek):
    head, _, iv, ciphertext, tag = parts
    aad = head.encode(); ciphertext = b64(ciphertext); iv = b64(iv)
    expected = hmac.new(cek[:32], aad + iv + ciphertext + struct.pack('>Q', len(aad) * 8), hashlib.sha512).digest()[:32]
    assert hmac.compare_digest(expected, b64(tag))
    decryptor = Cipher(algorithms.AES(cek[32:]), modes.CBC(iv)).decryptor()
    plaintext = decryptor.update(ciphertext) + decryptor.finalize()
    unpadder = sympadding.PKCS7(128).unpadder()
    return (unpadder.update(plaintext) + unpadder.finalize()).decode()

value = json.loads(sys.stdin.buffer.read(262145).decode('utf-8-sig'))
request = jws(value['PairRequest'], value['RecipientJwk'])
parts = value['Authorization'].split('.'); head = json.loads(b64(parts[0]))
assert head['alg'] == 'RSA-OAEP-256' and head['enc'] == 'A256CBC-HS512'
cek = private(value['RecipientPrivateKey']).decrypt(b64(parts[1]), padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
authorization = jws(cbc(parts, cek), value['ServerJwk'])
assert request['RequestDigest'] == authorization['RequestDigest']
parts = value['Recovery'].split('.'); head = json.loads(b64(parts[0]))
assert head['alg'] == 'PBES2-HS512+A256KW' and 10000 <= head['p2c'] <= 120000
kek = hashlib.pbkdf2_hmac('sha512', value['RecoveryPassword'].encode(), head['alg'].encode() + b'\0' + b64(head['p2s']), head['p2c'], dklen=32)
cek = aes_key_unwrap(kek, b64(parts[1])); recovery = json.loads(cbc(parts, cek))
assert recovery['Kind'] == 'TradeChannel.ManagementRecovery'
sys.stdout.write(json.dumps({'Ok': True, 'RS256': True, 'RSA_OAEP_256': True, 'A256CBC_HS512': True, 'PBES2_HS512_A256KW': True}))

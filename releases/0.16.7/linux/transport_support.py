"""Pinned Linux TCP component helpers; imported into the SSH bootstrap payload.

No external installer is executed. A fixed upstream archive is hashed before a
single regular ELF member is installed; foreign files are never overwritten.
"""
import hashlib
import io
import os
import re
import stat
import tarfile
import urllib.request
import uuid

VERSION = '1.14.2'
ARCHIVE_URL = 'https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-linux-amd64.tar.gz'
ARCHIVE_SHA256 = 'a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6'
BIN_DIRECTORY = '/usr/lib/tradechannel/1.14.2'
BINARY = BIN_DIRECTORY + '/sing-box'
BINARY_SHA256 = 'fc9c6e6ab345f045b16a0ed10d1ff28d68e8e56e7749fca30738d1406e98d7b8'
LIBRARY = BIN_DIRECTORY + '/libcronet.so'
LIBRARY_SHA256 = '23109c55b08829bb1a68682a61a64852b1bbf243753b153cbd8f6e4ea2c05294'
RECEIPT = BINARY + '.sha256'
MAX_ARCHIVE = 96 * 1024 * 1024

def install_binary(require):
    require(os.name == 'posix' and os.geteuid() == 0, 'UnsupportedHost', 'Linux root is required for the server component.')
    for parent in ('/usr', '/usr/lib', '/usr/lib/tradechannel', BIN_DIRECTORY):
        if not os.path.exists(parent):
            require(parent in ('/usr/lib/tradechannel', BIN_DIRECTORY), 'UnsafePath', 'Required system directory is missing.')
            os.mkdir(parent, 0o755)
        info = os.lstat(parent)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'UnsafePath', 'TCP component directory ownership is unsafe.')
    if os.path.lexists(BINARY):
        verify_binary(require)
        return BINARY
    request = urllib.request.Request(ARCHIVE_URL, headers={'User-Agent': 'TradeChannel/0.9.2'})
    with urllib.request.urlopen(request, timeout=40) as response:
        raw = response.read(MAX_ARCHIVE + 1)
    require(len(raw) <= MAX_ARCHIVE and hashlib.sha256(raw).hexdigest() == ARCHIVE_SHA256,
            'TransportHashMismatch', 'TCP component download does not match the pinned official archive.')
    components = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for leaf, target, expected in (('sing-box', BINARY, BINARY_SHA256), ('libcronet.so', LIBRARY, LIBRARY_SHA256)):
            members = [m for m in archive.getmembers() if m.name == 'sing-box-1.14.2-linux-amd64/'+leaf]
            require(len(members) == 1 and members[0].isfile() and members[0].size <= 160 * 1024 * 1024,
                    'TransportArchiveInvalid', 'Unexpected TCP component archive layout.')
            data = archive.extractfile(members[0]).read()
            require(data.startswith(b'\x7fELF') and hashlib.sha256(data).hexdigest() == expected,
                    'TransportHashMismatch', 'TCP binary or runtime library does not match the pinned release.')
            require(not os.path.lexists(target), 'OwnershipMismatch', 'An unowned TCP component is already present.')
            components[target] = data
    require(not os.path.lexists(RECEIPT), 'OwnershipMismatch', 'TCP component receipt already exists without its binary.')
    try:
        for target, data in components.items():
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755 if target == BINARY else 0o644)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
        descriptor = os.open(RECEIPT, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w', encoding='ascii') as stream:
            stream.write(ARCHIVE_SHA256 + '|' + BINARY_SHA256 + '|' + LIBRARY_SHA256 + '\n'); stream.flush(); os.fsync(stream.fileno())
    except Exception:
        # Preserve an incomplete installation for an explicit diagnostic; never
        # replace an existing binary on a retry or claim it is verified.
        raise
    verify_binary(require)
    return BINARY

def verify_binary(require):
    for path in (BINARY, LIBRARY, RECEIPT):
        info = os.lstat(path)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022,
                'UnsafePath', 'TCP component ownership or permissions changed.')
    with open(RECEIPT, 'r', encoding='ascii') as stream:
        receipt = stream.read(256).strip()
    require(receipt == ARCHIVE_SHA256+'|'+BINARY_SHA256+'|'+LIBRARY_SHA256,
            'TransportHashMismatch', 'TCP component receipt is invalid.')
    for path, expected in ((BINARY, BINARY_SHA256), (LIBRARY, LIBRARY_SHA256)):
        with open(path, 'rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        require(digest == expected, 'TransportHashMismatch', 'Installed TCP component changed.')
    return BINARY

def configuration(plan, peers, identity):
    port = int(plan['Transport']['Port'])
    endpoint_host, endpoint_port = plan['PublicEndpoint'].rsplit(':', 1)
    return {
        'log': {'level': 'warn', 'timestamp': True},
        'inbounds': [{'type': 'vless', 'tag': 'tc-transport-in', 'listen': '0.0.0.0', 'listen_port': port,
                      'users': [{'uuid': str(uuid.UUID(identity['Uuid']))}],
                      'tls': {'enabled': True, 'server_name': plan['Transport']['ServerName'],
                              'reality': {'enabled': True, 'handshake': {'server': plan['Transport']['ServerName'], 'server_port': 443},
                                          'private_key': identity['PrivateKey'], 'short_id': [identity['ShortId']]}}}],
        'outbounds': [{'type': 'direct', 'tag': 'wg-relay'}],
        'route': {'rules': [
            {'inbound': ['tc-transport-in'], 'network': 'udp', 'ip_cidr': [endpoint_host + '/32'],
             'port': [int(endpoint_port)], 'action': 'route', 'outbound': 'wg-relay', 'override_address': '127.0.0.1'},
            {'inbound': ['tc-transport-in'], 'action': 'reject'}], 'final': 'wg-relay'},
    }

def public_parameters(plan, manifest, peer):
    identity = manifest['Transport']
    return {'Type': 'tcp-reality', 'Server': plan['PublicEndpoint'].rsplit(':', 1)[0],
            'Port': int(plan['Transport']['Port']), 'ServerName': plan['Transport']['ServerName'],
            'Uuid': identity['Uuid'], 'RealityPublicKey': identity['PublicKey'], 'RealityShortId': identity['ShortId']}


def transport_info(plan, manifest, peer, owner):
    """Project only client parameters after the backend checks identity/health.

    The authenticated SSH management session is the trust boundary. The result
    binds the existing client public identity; it is not a new authorization.
    Never serialize the manifest, identity store or another device's record.
    """
    result = {'Kind': 'TradeChannel.TransportInfo', 'NodeId': plan['NodeId'],
              'RemoteOwnerId': owner['OwnerId'], 'ServerPublicKey': manifest['ServerPublicKey'],
              'ClientPublicKey': peer['ClientPublicKey'], 'ClientAddress': peer['ClientAddress'],
              'Status': 'Available' if plan.get('Transport') else 'NotConfigured'}
    if plan.get('Transport'):
        result['Transport'] = public_parameters(plan, manifest, peer)
    return result

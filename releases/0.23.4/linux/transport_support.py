"""Pinned Linux TCP component helpers; imported into the SSH bootstrap payload.

No external installer is executed. A fixed upstream archive is hashed before a
single regular ELF member is installed; foreign files are never overwritten.
"""
import hashlib
import io
import os
import platform
import re
import stat
import sys
import tarfile
import urllib.error
import urllib.request
import uuid
try:
    import connection_methods
except ModuleNotFoundError as exc:
    if exc.name != 'connection_methods':
        raise
    import importlib.util
    _spec = importlib.util.spec_from_file_location('connection_methods', os.path.join(os.path.dirname(__file__), 'connection_methods.py'))
    connection_methods = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(connection_methods)
    sys.modules['connection_methods'] = connection_methods

VERSION = '1.14.2'
# Archive digests are the official GitHub release asset digests. Member digests
# were computed only after verifying that complete archive. Keep the deployed
# version, directory and three-digest receipt format compatible with amd64.
RELEASES = {
    'amd64': {
        'ArchiveSHA256': 'a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6',
        'BinarySHA256': 'fc9c6e6ab345f045b16a0ed10d1ff28d68e8e56e7749fca30738d1406e98d7b8',
        'LibrarySHA256': '23109c55b08829bb1a68682a61a64852b1bbf243753b153cbd8f6e4ea2c05294',
    },
    'arm64': {
        'ArchiveSHA256': 'b43a1fb1bda131c6653576741ce527eb2bdeab7c9308ca90ee8b972abb7e4a7f',
        'BinarySHA256': 'b8610f45abb7e967e195264383f5cbd20fba7821a3c37e3a8c4c5ab6cad28eac',
        'LibrarySHA256': '3c1fcfcb56261a4b318ffb6d2227b9726782edb5a894e74db2b534406db62498',
    },
}
COMPONENT_ROOT = '/usr/lib/tradechannel'
BIN_DIRECTORY = COMPONENT_ROOT + '/' + VERSION
BINARY = BIN_DIRECTORY + '/sing-box'
LIBRARY = BIN_DIRECTORY + '/libcronet.so'
RECEIPT = BINARY + '.sha256'
MAX_ARCHIVE = 96 * 1024 * 1024
MAX_COMPONENT = 160 * 1024 * 1024
# Legacy informational constants. Installation and verification always select
# component_release() from the actual host architecture, never these aliases.
ARCHIVE_URL = 'https://github.com/SagerNet/sing-box/releases/download/v' + VERSION + '/sing-box-' + VERSION + '-linux-amd64.tar.gz'
ARCHIVE_SHA256 = RELEASES['amd64']['ArchiveSHA256']
BINARY_SHA256 = RELEASES['amd64']['BinarySHA256']
LIBRARY_SHA256 = RELEASES['amd64']['LibrarySHA256']


def component_release(require, machine=None):
    arch = connection_methods.architecture(platform.machine() if machine is None else machine, require)
    result = dict(RELEASES[arch['Id']], Architecture=arch['Id'], ElfMachine=arch['ElfMachine'], Version=VERSION)
    result['ArchivePrefix'] = 'sing-box-' + VERSION + '-linux-' + arch['Id']
    result['ArchiveURL'] = ('https://github.com/SagerNet/sing-box/releases/download/v' + VERSION + '/'
                            + result['ArchivePrefix'] + '.tar.gz')
    return result


def _guard(require):
    require(sys.platform == 'linux' and os.name == 'posix' and os.geteuid() == 0,
            'UnsupportedHost', 'Linux root is required for the server component.')


def _directories(require, create=False):
    for parent in ('/usr', '/usr/lib', COMPONENT_ROOT, BIN_DIRECTORY):
        if not os.path.exists(parent):
            require(create and parent in (COMPONENT_ROOT, BIN_DIRECTORY), 'UnsafePath', 'Required component directory is missing.')
            os.mkdir(parent, 0o755)
        info = os.lstat(parent)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'UnsafePath', 'TCP component directory ownership is unsafe.')


def _elf(header, release, require):
    require(len(header) >= 64 and header[:4] == b'\x7fELF' and header[4:7] == b'\x02\x01\x01'
            and int.from_bytes(header[16:18], 'little') in (2, 3)
            and int.from_bytes(header[18:20], 'little') == release['ElfMachine']
            and int.from_bytes(header[20:24], 'little') == 1,
            'TransportArchitectureMismatch', 'TCP component must be a 64-bit little-endian Linux ELF for this host architecture.')


def _receipt(release):
    return '|'.join(release[key] for key in ('ArchiveSHA256', 'BinarySHA256', 'LibrarySHA256'))


def install_binary(require):
    _guard(require)
    release = component_release(require)
    _directories(require, create=True)
    if os.path.lexists(BINARY):
        verify_binary(require)
        return BINARY
    require(not os.path.lexists(LIBRARY) and not os.path.lexists(RECEIPT),
            'OwnershipMismatch', 'An incomplete TCP component installation is already present; it will not be overwritten.')
    request = urllib.request.Request(release['ArchiveURL'], headers={'User-Agent': 'TradeChannel/0.18.0'})
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            raw = response.read(MAX_ARCHIVE + 1)
    except (urllib.error.URLError, OSError, TimeoutError):
        require(False, 'TransportDownloadFailed', 'The pinned official TCP component could not be downloaded.')
    require(len(raw) <= MAX_ARCHIVE and hashlib.sha256(raw).hexdigest() == release['ArchiveSHA256'],
            'TransportHashMismatch', 'TCP component download does not match the pinned official archive.')
    components = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for leaf, target, expected in (('sing-box', BINARY, release['BinarySHA256']), ('libcronet.so', LIBRARY, release['LibrarySHA256'])):
            members = [m for m in archive.getmembers() if m.name == release['ArchivePrefix'] + '/' + leaf]
            require(len(members) == 1 and members[0].isfile() and 64 <= members[0].size <= MAX_COMPONENT,
                    'TransportArchiveInvalid', 'Unexpected TCP component archive layout.')
            with archive.extractfile(members[0]) as stream:
                data = stream.read(MAX_COMPONENT + 1)
            require(len(data) == members[0].size, 'TransportArchiveInvalid', 'TCP archive member size is invalid.')
            _elf(data[:64], release, require)
            require(hashlib.sha256(data).hexdigest() == expected,
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
            stream.write(_receipt(release) + '\n'); stream.flush(); os.fsync(stream.fileno())
    except Exception:
        # Preserve an incomplete installation for an explicit diagnostic; never
        # replace an existing binary on a retry or claim it is verified.
        raise
    verify_binary(require)
    return BINARY

def verify_binary(require):
    _guard(require)
    release = component_release(require)
    _directories(require)
    for path in (BINARY, LIBRARY, RECEIPT):
        require(os.path.lexists(path), 'TransportComponentMissing', 'A required TCP component file is missing.')
        info = os.lstat(path)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022,
                'UnsafePath', 'TCP component ownership or permissions changed.')
        require(info.st_size <= (256 if path == RECEIPT else MAX_COMPONENT),
                'TransportHashMismatch', 'Installed TCP component exceeds its size limit.')
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as stream:
            opened = os.fstat(stream.fileno())
            require((opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid, opened.st_nlink, opened.st_size)
                    == (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size),
                    'UnsafePath', 'TCP component changed during verification.')
            if path == RECEIPT:
                require(stream.read(257) == (_receipt(release) + '\n').encode('ascii'),
                        'TransportHashMismatch', 'TCP component receipt is invalid for this architecture.')
            else:
                header = stream.read(64)
                _elf(header, release, require)
                digest = hashlib.sha256(header)
                size = len(header)
                while True:
                    chunk = stream.read(min(1024 * 1024, MAX_COMPONENT + 1 - size))
                    if not chunk:
                        break
                    size += len(chunk)
                    require(size <= MAX_COMPONENT, 'TransportHashMismatch', 'TCP component changed during verification.')
                    digest.update(chunk)
                expected = release['BinarySHA256' if path == BINARY else 'LibrarySHA256']
                require(size == opened.st_size and digest.hexdigest() == expected,
                        'TransportHashMismatch', 'Installed TCP component changed.')
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

# Deployment dependencies

All redistributed binaries are locked by version and SHA256 in `dependencies.lock.json`.
Package acquisition used the official NuGet HTTPS flat-container endpoint; no floating downloads occur at runtime.
Original licenses and notices are under `assets/lib/licenses/`.

| Component | Version | Asset target | Official project |
|---|---|---|---|
| SSH.NET | 2025.1.0 | net462 | https://github.com/sshnet/SSH.NET |
| jose-jwt | 5.3.0 | net472 | https://github.com/dvsekhvalnov/jose-jwt |
| BouncyCastle.Cryptography | 2.6.2 | net461 | https://github.com/bcgit/bc-csharp |
| Microsoft.Extensions.Logging.Abstractions | 8.0.3 | net462 | https://github.com/dotnet/runtime |
| Microsoft.Extensions.DependencyInjection.Abstractions | 8.0.2 | net462 | https://github.com/dotnet/runtime |
| Microsoft.Bcl.AsyncInterfaces | 8.0.0 | net462 | https://github.com/dotnet/runtime |
| System.Formats.Asn1 | 8.0.2 | net462 | https://github.com/dotnet/runtime |
| System.Buffers | 4.5.1 | net461 | https://github.com/dotnet/runtime |
| System.Memory | 4.5.5 | net461 | https://github.com/dotnet/runtime |
| System.Runtime.CompilerServices.Unsafe | 6.0.0 | net461 | https://github.com/dotnet/runtime |
| System.Numerics.Vectors | 4.5.0 | net46 | https://github.com/dotnet/runtime |
| System.Threading.Tasks.Extensions | 4.5.4 | net461 | https://github.com/dotnet/runtime |
| System.ValueTuple | 4.5.0 | net47 | https://github.com/dotnet/runtime |

The execution host targets .NET Framework 4.8 / Windows PowerShell 5.1. The Framework builds are deliberately selected instead of .NET Core assets. `System.ValueTuple` is a Framework-compatible forwarding assembly. Full dependency loading is exercised by real SSH authentication and JOSE encryption tests.

The JOSE suite is restricted to RS256 signatures, RSA-OAEP-256/A256CBC-HS512 authorization encryption, and PBES2-HS512+A256KW/A256CBC-HS512 recovery encryption. Recovery salt is the library's cryptographically random 96-bit salt (12 bytes); accepted KDF counts are 10,000 through 120,000, default 120,000. Recovery passphrases must be at least 12 characters. The cap is validated before decryption to prevent attacker-controlled work inflation.

Development-only package extracts, Paramiko fixture libraries, temporary state and test credentials are excluded from release packaging. They are never dependencies of the product runtime.

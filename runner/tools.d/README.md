# tools.d

Put `NN-name.sh` scripts here to bake extra tools into the runner image. They run as root, in
lexical order, at image build time, with `TARGETARCH` set to `amd64` or `arm64`. Pin versions.

Example `20-kubectl.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
KUBECTL_VERSION=v1.31.2
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"
chmod +x /usr/local/bin/kubectl
```

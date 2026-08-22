# LG webOS TV: SSH pairing and sideloading (Developer Mode)

TV: `192.168.8.53` (LG NetCast/webOS, "LGwebOSTV", aarch64, kernel 5.4.96 mole).

I hit this because my TV's stock browser can't run the self-hosted
Stremio web client. Its Chromium engine is too old to support the WASM
reftypes feature that `stremio_core_web_bg.wasm` requires, so the app
failed to load with
`WebAssembly.instantiateStreaming() invalid value type externref`. So
instead of fighting the browser, I sideloaded a native-ish Stremio app
via Developer Mode.

## Why I kept hitting "Handshake failed: signature verification failed"

My TV's SSH server only offers the legacy `ssh-rsa` (SHA-1) host key
algorithm, and that broke in two separate ways:

1. Modern OpenSSH (8.8+) refuses `ssh-rsa` by default (removed for
   security reasons). Fix: explicitly re-enable it per-connection.
2. Modern OpenSSL (3.x) refuses to verify SHA-1 RSA signatures under
   its default security policy, even once SSH offers the algorithm.
   This hit both my system `ssh` client and Node's `ssh2` library
   (used internally by both `@webosose/ares-cli` and
   `@webos-tools/cli`), since both link against system OpenSSL. Fix:
   an `OPENSSL_CONF` override that allows legacy SHA-1 signatures.

Switching Node packages alone did not fix it. I tried
`@webosose/ares-cli` (old, deprecated, bundles ancient `ssh2@0.8.9`)
and `@webos-tools/cli` (current, maintained, bundles `ssh2@^1.17.0`),
and both failed identically until I had the OpenSSL override in place.
The npm scope changed from `@webosose` to `@webos-tools` around v3.0.2
(March 2024), so use `@webos-tools/cli`, not `@webosose/ares-cli`.

I also ran into a secondary issue: `ares-install`/`ares-novacom` had no
working non-interactive passphrase prompt in my environment (no
`ssh-askpass` binary installed, so anything needing an interactive
passphrase just hung or failed silently). I worked around it by
decrypting the private key to a passphrase-free copy once, then
pointing the device config at that.

## Working setup, step by step

1. On the TV: open the **Developer Mode** app, turn on **Dev Mode**,
   turn on **Key Server**, note the passphrase (6 hex-looking
   characters, e.g. `78DB5E`).

2. Fetch the encrypted private key from the TV's key server (port
   9991, plain HTTP):

   ```bash
   curl -sS "http://<TV_IP>:9991/webos_rsa" -o ~/.ssh/webos_rsa
   chmod 600 ~/.ssh/webos_rsa
   ```

3. Decrypt it once to a passphrase-free copy (avoids the broken
   interactive-passphrase path in ares-cli, and avoids needing
   `ssh-askpass`):

   ```bash
   cp ~/.ssh/webos_rsa ~/.ssh/lgtv_webos_nopass
   chmod 600 ~/.ssh/lgtv_webos_nopass
   ssh-keygen -p -P "<passphrase>" -N "" -f ~/.ssh/lgtv_webos_nopass
   ```

   Note: this re-encodes the key into the newer `OPENSSH PRIVATE KEY`
   format, which is not itself a problem.

4. Create an OpenSSL legacy-signature override (scoped, not
   system-wide):

   ```bash
   mkdir -p ~/.config/lg-tv-ssh
   cat > ~/.config/lg-tv-ssh/openssl_legacy.cnf << 'EOF'
   openssl_conf = openssl_init

   [openssl_init]
   alg_section = evp_properties

   [evp_properties]
   rh-allow-sha1-signatures = yes
   EOF
   ```

   Export it for any shell session that needs to talk to the TV:

   ```bash
   export OPENSSL_CONF=~/.config/lg-tv-ssh/openssl_legacy.cnf
   ```

5. Raw `ssh`/`scp` (useful for diagnosis, and works standalone):

   ```bash
   ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
       -o BatchMode=yes -i ~/.ssh/lgtv_webos_nopass -p 9922 \
       prisoner@<TV_IP> exit
   ```

   Or add a `~/.ssh/config` `Host` block with those same options so
   plain `ssh lgtv-webos` works.

6. Install `@webos-tools/cli` on demand (no global install needed,
   avoids permission issues with a root-owned npm prefix):

   ```bash
   npx --yes -p @webos-tools/cli -c "<command and args>"
   ```

7. Register the device, key relative to `~/.ssh/`, empty passphrase
   since the key is already decrypted:

   ```bash
   npx --yes -p @webos-tools/cli -c \
     "ares-setup-device --add lgtv --info '{\"host\":\"<TV_IP>\",\"port\":\"9922\",\"username\":\"prisoner\",\"privatekey\":\"lgtv_webos_nopass\",\"passphrase\":\"\",\"description\":\"LG webOS TV\"}'"
   ```

8. With `OPENSSL_CONF` exported, everything works normally:

   ```bash
   npx --yes -p @webos-tools/cli -c "ares-install -d lgtv --list"
   npx --yes -p @webos-tools/cli -c "ares-install -d lgtv <path-to-ipk>"
   npx --yes -p @webos-tools/cli -c "ares-launch -d lgtv <app-id>"
   ```

## What I tried that did not work

- `@webosose/ares-cli` (any config): old `ssh2@0.8.9`, fails at
  `onKEXDH_REPLY` regardless of OpenSSL config.
- `@webos-tools/cli` without `OPENSSL_CONF`: fails at
  `DHExchange.finish` (same symptom, `ssh2@1.17` still needs OpenSSL to
  allow the SHA-1 verify).
- Raw Luna API calls (`luna-send-pub -f luna://com.webos.appInstallService/dev/install ...`)
  as a manual substitute for `ares-install`. This silently returned
  nothing and the app never installed. Once the SSH layer worked,
  `ares-install` itself worked fine, so I stopped trying to
  reimplement it by hand.
- `luna-send` (not `-pub`) as `prisoner`: permission denied, it's a
  root-only binary. `luna-send-pub` is the world-executable one, but I
  still prefer `ares-install` over calling it directly.
- `ares-novacom --getkey` piped via `echo`/`printf`: inconsistent for
  me. Fetching the key directly from the port 9991 HTTP endpoint
  (step 2 above) worked more reliably.

## Example: sideloading kieranbrown/stremio-webos

```bash
curl -sSL -o io.strem.tv.ipk \
  "https://github.com/kieranbrown/stremio-webos/releases/latest/download/io.strem.tv_<version>_all.ipk"
# verify against the sha256 in the release's manifest.json/asset digest first
export OPENSSL_CONF=~/.config/lg-tv-ssh/openssl_legacy.cnf
npx --yes -p @webos-tools/cli -c "ares-install -d lgtv ./io.strem.tv.ipk"
npx --yes -p @webos-tools/cli -c "ares-launch -d lgtv io.strem.tv"
```

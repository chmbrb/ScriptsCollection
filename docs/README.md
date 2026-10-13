# SSH key setup

Notes for using keys created by `scripts/user/create-certificate.sh ssh <name>`.
Keys are written to `_output/ssh/<name>` (private) and `_output/ssh/<name>.pub` (public).

## Permissions

| Path                  | Mode | Notes                  |
|-----------------------|------|------------------------|
| `~/.ssh`              | 700  | `drwx------`           |
| `~/.ssh/<name>`       | 600  | private key            |
| `~/.ssh/<name>.pub`   | 644  | public key             |
| `~/.ssh/config`       | 600  |                        |

The script sets these on its own output; apply them again if you move the keys.

## Client: install the key

Copy the private key and `.pub` into `~/.ssh/`, then send the public key to the host:

```sh
ssh-copy-id -i ~/.ssh/<name>.pub <user>@<host>
```

## Client: `~/.ssh/config`

Define a host alias so you can run `ssh <alias>`:

```
Host alias-or-shortened-hostname
    HostName FQDN-dev.example.com-or-ip-address
    Port 22
    User username
    PubkeyAuthentication yes
    IdentityFile ~/.ssh/<name>
    IdentitiesOnly yes
```

`IdentitiesOnly yes` stops ssh offering every key in your agent, which avoids
"too many authentication failures" on hosts that limit attempts.

## Host: first-time key install

`ssh-copy-id` logs in with a password, so the host must allow it temporarily.
In `/etc/ssh/sshd_config`:

```
PubkeyAuthentication yes
PasswordAuthentication yes
```

Then restart the server (`ssh` on Debian/Ubuntu, `sshd` on Fedora/Arch):

```sh
sudo systemctl restart ssh
```

## Host: lock it down afterwards

Once key login works (test from a second terminal before closing the first),
disable passwords in `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
```

and restart the server again. Also confirm on the host that `~/.ssh` is `700`
and `~/.ssh/authorized_keys` is `600`.

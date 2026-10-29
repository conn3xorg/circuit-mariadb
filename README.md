# circuit-mariadb

A Conn3x circuit that installs MariaDB from your distribution, cleans out what a fresh install leaves lying around, and creates the databases, users and grants your apps log in with. It does what `mysql_secure_installation` would, without anyone typing answers into it, and keeps doing it: if an anonymous user or a `test` database turns up later, the next plan shows it.

Passwords never land in state. You pass them in at run time through an ephemeral variable, and the plan shows only that a password changed.

## Usage

```hcl
variable "app_db_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "mariadb" {
  source = "github.com/conn3xorg/circuit-mariadb?ref=v0.1.0"

  hosts                = { db = "192.168.1.30" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  bind_address = "0.0.0.0"
  settings     = { innodb_buffer_pool_size = "1G", max_connections = "200" }

  users          = ["app"]
  user_passwords = { app = var.app_db_password }
  user_hosts     = ["localhost", "192.168.1.%"]
  databases      = ["app"]
  grants         = [{ user = "app", database = "app" }]
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_app_db_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks file paths by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.db : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. On the Red Hat family, when `settings` sets a `port` other than 3306, installs `policycoreutils-python-utils` and labels the port `mysqld_port_t` with `semanage`, so SELinux lets MariaDB bind it. Hosts with SELinux off skip the label.
2. Installs `mariadb-server` from the distribution.
3. Writes a drop-in, `zz-conn3x.cnf`, with a `[mariadbd]` section holding `bind_address` and `settings`. Its name sorts after the packages' own files, so your values win.
4. Checks the new file before anything restarts. `mariadbd --help --verbose` reads every option file the way a server start would, so a misspelt setting fails the apply with MariaDB's own `unknown variable` message, and the server keeps running on what it had. Fix the input and apply again.
5. Restarts MariaDB when the drop-in changed, then keeps it running and enabled at boot. `bind-address`, `port` and most settings do nothing until a restart.
6. Removes anonymous users, any `root` account that isn't on `localhost`, `127.0.0.1` or `::1`, the `test` database and the grants that let anyone use it. That's what `mysql_secure_installation` does, apart from setting a root password: `root` logs in over the local socket as the system's root user, with no password to steal, and that's how the circuit connects.
7. For each of `users`, writes its password to `/etc/conn3x/mariadb/NAME` (root only, mode 0600) and creates one account per entry in `user_hosts`, locked, so none is ever open without a password. It then sets the password and unlocks the accounts, again whenever that file changed or an account was added.
8. Creates each of `databases`.
9. Grants each of `grants` on every one of the user's accounts. If someone revokes a privilege by hand, the next plan shows it and the apply grants it again.

A password reaches the `mariadb` client on standard input, so it never shows up in `ps`, and the server stores only its hash. It does pass through the server's statement handling, so don't turn on the general query log while you change one.

A `_` in a database name is a wildcard in MariaDB grants, so a grant on `my_db` would also cover `myXdb`. The circuit escapes it, and a grant covers only the database it names.

If someone edits `zz-conn3x.cnf` by hand, the next plan shows the difference and the apply puts yours back, restarting as above.

### Which MariaDB you get

Each supported distribution ships a MariaDB long-term release, and gets security fixes for it from the distribution, so the circuit installs that rather than adding MariaDB's own repository:

| | Ubuntu 24.04 | Debian 13 | Rocky Linux 10 | Fedora 45 |
| --- | --- | --- | --- | --- |
| MariaDB | 10.11 | 11.8 | 10.11 | 12.3 |
| Drop-in | `/etc/mysql/mariadb.conf.d/zz-conn3x.cnf` | `/etc/mysql/mariadb.conf.d/zz-conn3x.cnf` | `/etc/my.cnf.d/zz-conn3x.cnf` | `/etc/my.cnf.d/zz-conn3x.cnf` |

The systemd unit is `mariadb` everywhere. The `config_files` output gives the drop-in's path per host.

The flip side is that the version follows the distribution, so two hosts on different distributions can run different majors. Rocky Linux 10 and Fedora also package 11.8 as `mariadb11.8-server`, which this circuit doesn't install.

### What it doesn't cover

- **Upgrades between majors.** You get whatever the distribution upgrades you to.
- **Removal.** Taking a user, host, database or grant out of the inputs leaves it in MariaDB. Drop or revoke it in `mariadb` first.
- **Global privileges.** Grants are per database. `SUPER`, `PROCESS`, `RELOAD` and the like are yours to grant.
- **TLS, replication, backups and Galera.** None of these are set up.
- **Firewall.** The circuit doesn't open port 3306. The [firewall circuit](https://github.com/conn3xorg/circuit-firewall) can.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `bind_address` | string | `"127.0.0.1"` | Addresses to listen on, comma-separated, such as `"0.0.0.0"` or `"127.0.0.1,10.0.0.5"`. Changing it restarts MariaDB. |
| `settings` | map(string) | `{}` | Server settings, such as `{ max_connections = "200" }`. Changing them restarts MariaDB. Set `bind_address` with its own input. |
| `users` | list(string) | `[]` | Users to create. Names use lowercase letters, digits and `_`, up to 32 characters. |
| `user_passwords` | map(string), ephemeral | `{}` | Password for each of `users`, by name. Every user needs one. |
| `user_hosts` | list(string) | `["localhost", "127.0.0.1", "::1"]` | Where each of `users` may connect from, such as `"192.168.1.%"` or `"10.0.0.0/255.255.255.0"`. Every user gets one account per entry, with the same password and grants. |
| `databases` | list(string) | `[]` | Databases to create, such as `["app"]`. |
| `grants` | list(object) | `[]` | Privileges on a database, each `{ user, database, privileges }`. `user` must be one of `users`. `privileges` defaults to `["ALL PRIVILEGES"]`, or lists database-level ones in capitals, such as `["SELECT", "INSERT", "UPDATE", "DELETE"]`. One grant per user and database. |

## Outputs

| Name | Description |
| --- | --- |
| `config_files` | The drop-in holding `bind_address` and `settings` on each host, such as `{ db = "/etc/mysql/mariadb.conf.d/zz-conn3x.cnf" }`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with access to the distribution's package mirrors.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, then logs in over TCP as the example's user with its password, creates a table in its database, and checks it's refused the other database. The same ran by hand in arm64 containers, along with a misspelt setting, which failed the apply and left the server running; a password containing a quote and a backslash, then a password change; a move to port 3307; a second user with only `SELECT` and `SHOW VIEW`, which couldn't delete rows; a grant on a database with `_` in its name; and an anonymous user, a remote `root`, a `test` database and a revoked privilege added by hand, each of which the next plan caught and the apply removed or put back.

All of that ran in containers, where SELinux is off. On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, the example's users and grants were applied by hand, with MariaDB on port 3307 on Rocky. The circuit labelled 3307 `mysqld_port_t`, MariaDB ran confined as `mysqld_t`, the user checks passed, the second plan had no changes, and the audit log had no denials. Both came back after a reboot with MariaDB running, the checks passing and the second plan clean.

## License

MPL-2.0. See [LICENSE](LICENSE). MariaDB itself is GPL-2.0.
